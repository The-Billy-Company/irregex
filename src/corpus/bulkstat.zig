//! gist — macOS `getattrlistbulk(2)` batched directory enumeration, the
//! platform-correct answer to the freshness overlay's dominant cold-query cost
//! (see `fresh.zig`'s doc comment and the README's "make the freshness walk
//! incremental" next rung). That rung's own text pointed at `io_uring`
//! batching — a Linux-only API that doesn't exist on this box (Darwin/Apple
//! Silicon, confirmed via `uname`/`sysctl`). The macOS-native equivalent for
//! "stop paying one syscall per file" is `getattrlistbulk`: unlike
//! `readdir()` + `stat()` per entry (2 syscalls/file), one bulk call returns
//! name + type + mtime for many siblings at once — Apple's own filesystem-dev
//! list documents 4–50× fewer syscalls (readdir vs getdirentriesattr thread,
//! Dec 2014; independently reproduced: ~1,600× fewer syscalls, ~4-5× faster
//! on a warm NVMe SSD, quivent/getattrlistbulk-rs, 2025 benchmark on M1).
//! `pkg/kernels/gist/changelog.d/+bulkstat-freshness.changed.md` cites the
//! measurement on THIS corpus.
//!
//! Why hand-rolled instead of `mmap`-ing files or another IO trick: the
//! freshness walk never reads file *bytes* — it only needs each file's
//! mtime, so the lever is metadata syscalls, not data IO. (Candidate file
//! *reads* are a different, already-solved problem: ripgrep's own author
//! documents why `mmap` is a net loss for "open many small files" —
//! open+mmap+munmap has a *higher* fixed cost per file than open+read+close
//! on typical source-sized files — which is exactly why `emit.zig`/`drivers.zig`
//! already use blocking `read()`, not `mmap`; this module doesn't touch that
//! path at all.)
//!
//! Zig's std has no binding for this syscall (macOS-only, added in Yosemite,
//! `<sys/attr.h>` + `<sys/unistd.h>`), so the ABI below is hand-declared from
//! the SDK headers — `struct attrlist`, the `ATTR_CMN_*`/`FSOPT_*` bit values,
//! and the per-entry buffer layout (a `u32` length prefix, then the
//! `attribute_set_t` of what was actually returned, then each requested
//! attribute in Apple's fixed group order — RETURNED_ATTRS, NAME, OBJTYPE,
//! MODTIME for our exact request — with `NAME`'s bytes stored out-of-line via
//! an `attrreference_t` offset+length pair). Cross-checked byte-for-byte
//! against a maintained, benchmarked Rust binding
//! (quivent/getattrlistbulk-rs `src/{ffi,parser}.rs`) before writing this.
//!
//! FAIL-SOFT, NEVER FAIL-OPEN: a bulk call failing on some directory (an
//! unusual mount, a permissions edge, or simply a filesystem that doesn't
//! implement it) falls back to the proven stat-based walk for *that*
//! subtree only — freshness must never produce a false negative (the one
//! unforgivable bug per `fresh.zig`), so a syscall we're not 100% certain of
//! everywhere degrades instead of risking a silently dropped file.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("haystack.zig");
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

/// Only attempted on Darwin; every other target statically falls back to the
/// caller's stat-based walk (checked once, not per-directory).
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .ios or
    builtin.os.tag == .tvos or builtin.os.tag == .watchos or builtin.os.tag == .visionos;

// ─────────────────────── hand-declared Darwin ABI (<sys/attr.h>) ───────────────────────

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const FSOPT_PACK_INVAL_ATTRS: u64 = 0x00000008;

// <sys/vnode.h> enum vtype (VNON=0, VREG=1, VDIR=2, VBLK=3, VCHR=4, VLNK=5, …).
const VREG: u32 = 1;
const VDIR: u32 = 2;

const attrlist_t = extern struct {
    bitmapcount: u16,
    reserved: u16 = 0,
    commonattr: u32,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

/// `int getattrlistbulk(int dirfd, struct attrlist *alist, void *attrBuf, size_t attrBufSize, uint64_t options)`
/// — returns the number of entries packed into `attrBuf` (0 ⇒ exhausted, -1 ⇒
/// error/errno). Not in any Zig std binding; declared straight off
/// `<sys/unistd.h>` (`SYS_getattrlistbulk` = 461 in `<sys/syscall.h>`).
extern "c" fn getattrlistbulk(dirfd: c_int, alist: *anyopaque, attr_buf: [*]u8, attr_buf_size: usize, options: u64) c_int;

const requested_commonattr: u32 = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME;

/// One directory entry's shape (mtime), one bulk call away instead of one
/// `stat()` syscall away. `name` aliases the iterator's internal buffer —
/// valid only until the next `next()` call (mirrors `haystack.Haystack`).
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: i128,
};

/// Bulk-enumerates ONE open directory. 8 KiB batches (not 64 KiB): this is a
/// per-recursion-depth stack local (`visitFresh` below), and a monorepo path
/// is at most ~15 components deep, so 8 KiB × depth stays a rounding error
/// against any thread's stack — while still batching dozens of typical
/// same-directory siblings per syscall (most directories in this repo hold
/// well under 8 KiB / ~40 B-per-entry ≈ 200 entries, i.e. ONE syscall each).
pub const BulkDir = struct {
    dirfd: std.posix.fd_t,
    buf: [8192]u8 align(@alignOf(u32)) = undefined,
    count: c_int = 0, // entries left unparsed in `buf` from the last refill
    off: usize = 0, // byte offset of the next unparsed entry
    exhausted: bool = false, // last refill returned 0 (directory fully drained)

    pub fn init(dirfd: std.posix.fd_t) BulkDir {
        return .{ .dirfd = dirfd };
    }

    fn refill(self: *BulkDir) !void {
        var al = attrlist_t{ .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = requested_commonattr };
        const n = getattrlistbulk(self.dirfd, &al, &self.buf, self.buf.len, FSOPT_PACK_INVAL_ATTRS);
        if (n < 0) return error.BulkStatUnsupported;
        self.off = 0;
        self.count = n;
        if (n == 0) self.exhausted = true;
    }

    /// Next entry, or null at end-of-directory. `error.BulkStatUnsupported`
    /// means the syscall itself failed (wrong fs, permissions, …) — the
    /// caller must fall back to a stat-based walk, never treat this as "done".
    pub fn next(self: *BulkDir) !?Entry {
        if (self.count == 0) {
            if (self.exhausted) return null;
            try self.refill();
            if (self.count == 0) return null; // exhausted on the very first call
        }
        const entry = try parseEntry(self.buf[0..], self.off);
        self.off += entry.advance;
        self.count -= 1;
        return entry.value;
    }
};

const Parsed = struct { value: Entry, advance: usize };

/// Parse one entry at `start`. Layout (Apple's fixed group order for our
/// exact request): `u32 length` │ `attribute_set_t returned` (5×u32=20 B) │
/// `attrreference_t name` (i32 offset + u32 length, 8 B — the offset is
/// relative to the FIELD's own address, and the bytes it points to live
/// out-of-line, appended after every fixed attribute) │ `u32 objtype` │
/// `timespec modtime` (i64 sec + i64 nsec). Every multi-byte read goes
/// through `std.mem.readInt` on a byte slice (never a direct pointer cast) —
/// the kernel's packing isn't guaranteed to leave every field naturally
/// aligned for a typed load.
fn parseEntry(buf: []const u8, start: usize) !Parsed {
    if (start + 4 > buf.len) return error.BulkStatUnsupported;
    const length = std.mem.readInt(u32, buf[start..][0..4], .little);
    if (length == 0 or start + length > buf.len) return error.BulkStatUnsupported;

    var pos = start + 4;
    if (pos + 20 > buf.len) return error.BulkStatUnsupported;
    const returned_common = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 20; // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr

    var name: []const u8 = "";
    if (returned_common & ATTR_CMN_NAME != 0) {
        if (pos + 8 > buf.len) return error.BulkStatUnsupported;
        const data_offset = std.mem.readInt(i32, buf[pos..][0..4], .little);
        const data_len = std.mem.readInt(u32, buf[pos + 4 ..][0..4], .little);
        const name_start = @as(i64, @intCast(pos)) + data_offset;
        if (name_start < 0) return error.BulkStatUnsupported;
        const ns: usize = @intCast(name_start);
        const ne = ns + data_len;
        if (ne > buf.len or ns > ne) return error.BulkStatUnsupported;
        var raw = buf[ns..ne];
        if (std.mem.findScalar(u8, raw, 0)) |nul| raw = raw[0..nul]; // NUL-terminated
        name = raw;
        pos += 8;
    }

    var objtype: u32 = 0;
    if (returned_common & ATTR_CMN_OBJTYPE != 0) {
        if (pos + 4 > buf.len) return error.BulkStatUnsupported;
        objtype = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
    }

    var mtime_ns: i128 = 0;
    if (returned_common & ATTR_CMN_MODTIME != 0) {
        if (pos + 16 > buf.len) return error.BulkStatUnsupported;
        const sec = std.mem.readInt(i64, buf[pos..][0..8], .little);
        const nsec = std.mem.readInt(i64, buf[pos + 8 ..][0..8], .little);
        mtime_ns = @as(i128, sec) * std.time.ns_per_s + @as(i128, nsec);
    }

    return .{
        .value = .{ .name = name, .is_dir = objtype == VDIR, .is_file = objtype == VREG, .mtime_ns = mtime_ns },
        .advance = length,
    };
}

/// Recursively collect every file under `dir` (relative path `prefix`) whose
/// mtime is `>= built_ns`, applying the shared `haystack.isSkipDir` policy —
/// the bulk-enumeration twin of `fresh.zig`'s old per-file-`statFile` walk.
/// Degrades directory-by-directory: a bulk failure on one directory falls
/// back to `fallbackWalk` (the proven stat-based path) for that subtree only,
/// so a filesystem edge case can only cost speed, never correctness.
pub fn visitFresh(a: Allocator, io: std.Io, dir: Dir, prefix: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) void {
    var bd = BulkDir.init(dir.handle);
    while (true) {
        const entry = bd.next() catch {
            fallbackWalk(a, io, prefix, built_ns, out);
            return;
        } orelse break;
        if (entry.is_dir) {
            if (haystack.isSkipDir(entry.name)) continue;
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const sub_prefix = std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name }) catch return;
            visitFresh(a, io, sub, sub_prefix, built_ns, out);
            continue;
        }
        if (!entry.is_file) continue; // symlinks/etc — never followed, matches haystack.Walker
        if (entry.mtime_ns < built_ns) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name }) catch return;
        out.append(a, full) catch return;
    }
}

/// One directory entry, name durably owned (`gpa`-allocated) rather than
/// aliasing `BulkDir`'s reused scratch buffer — for callers that must hold
/// entries past the next `next()` call, i.e. `listOneLevel` below.
pub const OwnedEntry = struct { name: []u8, is_dir: bool, is_file: bool, mtime_ns: i128 };

/// Fully drains ONE level of `dirfd` via `getattrlistbulk`, duping every name
/// into `gpa` up front. All-or-nothing: any parse/syscall failure partway
/// discards what's been collected and returns the error rather than handing
/// back a truncated listing — the caller re-opens a fresh handle and retries
/// with the portable `Dir.Iterator`, never mixes a partial bulk result with a
/// partial iterate one (which could double- or under-count an entry).
pub fn listOneLevel(gpa: Allocator, dirfd: std.posix.fd_t) ![]OwnedEntry {
    var list: std.ArrayList(OwnedEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var bd = BulkDir.init(dirfd);
    while (try bd.next()) |e| {
        try list.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .is_dir = e.is_dir, .is_file = e.is_file, .mtime_ns = e.mtime_ns });
    }
    return list.toOwnedSlice(gpa);
}

/// Fully drains ONE level of `dirfd` via raw `getdirentries(2)` — names +
/// `d_type` only, no attributes, no mtime (`mtime_ns = 0`). When the caller
/// doesn't need per-entry mtime (the parallel walk without index elision),
/// this is strictly cheaper than `listOneLevel`: `getattrlistbulk` makes the
/// kernel resolve and pack attributes per entry, while `getdirentries` is the
/// same thin readdir path ripgrep rides. Darwin-only (same `supported` gate).
pub fn listNamesOnly(gpa: Allocator, dirfd: std.posix.fd_t) ![]OwnedEntry {
    var list: std.ArrayList(OwnedEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var buf: [64 * 1024]u8 align(@alignOf(u64)) = undefined;
    var seek: i64 = 0;
    while (true) {
        const rc = std.posix.system.getdirentries(dirfd, &buf, buf.len, &seek);
        if (std.posix.errno(rc) != .SUCCESS) return error.BulkStatUnsupported;
        const n: usize = @intCast(rc);
        if (n == 0) return list.toOwnedSlice(gpa);
        var i: usize = 0;
        while (i < n) {
            // Darwin 64-bit `struct dirent`, decoded by explicit field offset
            // (no pointer casts): d_ino u64 @0 · d_seekoff u64 @8 ·
            // d_reclen u16 @16 · d_namlen u16 @18 · d_type u8 @20 · name @21.
            const rec = buf[i..n];
            const ino = std.mem.readInt(u64, rec[0..8], .little);
            const reclen = std.mem.readInt(u16, rec[16..18], .little);
            const namlen = std.mem.readInt(u16, rec[18..20], .little);
            const dtype = rec[20];
            i += reclen;
            if (ino == 0) continue;
            const name = rec[21 .. 21 + @as(usize, namlen)];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const is_dir = dtype == std.posix.DT.DIR;
            const is_file = dtype == std.posix.DT.REG;
            if (!is_dir and !is_file) continue; // symlinks/specials — the walk never follows them
            try list.append(gpa, .{ .name = try gpa.dupe(u8, name), .is_dir = is_dir, .is_file = is_file, .mtime_ns = 0 });
        }
    }
}

/// The pre-bulkstat walk (readdir + `statFile` per entry), scoped to one
/// subtree — reused verbatim as `visitFresh`'s degrade path so a bulk-call
/// failure can only fall back to previously-proven-correct behavior.
fn fallbackWalk(a: Allocator, io: std.Io, root_path: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) void {
    var w = haystack.Walker.init(io, a, root_path) catch return;
    defer w.deinit(io);
    while (w.next(io) catch return) |hay| {
        const st = hay.dir.statFile(io, hay.name, .{}) catch continue;
        if (st.mtime.nanoseconds < built_ns) continue;
        out.append(a, hay.path) catch return;
    }
}
