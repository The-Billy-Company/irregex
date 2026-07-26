//! irregex — macOS `getattrlistbulk(2)` batched directory enumeration, the
//! platform-correct answer to the freshness overlay's dominant cold-query cost
//! (see `fresh.zig`'s doc comment and the README's "make the freshness walk
//! incremental" next rung). That rung's own text pointed at `io_uring`
//! batching — a Linux-only API that doesn't exist on this box (Darwin/Apple
//! Silicon, confirmed via `uname`/`sysctl`). The macOS-native equivalent for
//! "stop paying one syscall per file" is `getattrlistbulk`: unlike
//! `readdir()` + `stat()` per entry (2 syscalls/file), one bulk call returns
//! name + type + mtime + ctime for many siblings at once — Apple's own
//! filesystem-dev
//! list documents 4–50× fewer syscalls (readdir vs getdirentriesattr thread,
//! Dec 2014; independently reproduced: ~1,600× fewer syscalls, ~4-5× faster
//! on a warm NVMe SSD, quivent/getattrlistbulk-rs, 2025 benchmark on M1).
//! `pkg/kernels/irregex/changelog.d/+bulkstat-freshness.changed.md` cites the
//! measurement on THIS corpus.
//!
//! Why hand-rolled instead of `mmap`-ing files or another IO trick: the
//! freshness walk never reads file *bytes* — it only needs each file's
//! change timestamps, so the lever is metadata syscalls, not data IO.
//! (Candidate file
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
//! MODTIME, CHGTIME for our exact request — with `NAME`'s bytes stored
//! out-of-line via
//! an `attrreference_t` offset+length pair). Cross-checked byte-for-byte
//! against a maintained, benchmarked Rust binding
//! (quivent/getattrlistbulk-rs `src/{ffi,parser}.rs`) before writing this.
//!
//! FAIL-SOFT, NEVER FAIL-OPEN: a bulk call failing on some directory (an
//! unusual mount, a permissions edge, or simply a filesystem that doesn't
//! implement it) falls back to the proven stat-based walk for *that*
//! subtree only. Under `README.md`'s local-filesystem model, uncertain bulk
//! metadata therefore loses speed rather than weakening the conservative
//! live-read decision.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("../../fault.zig");
const haystack = @import("haystack.zig");
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

/// This module's private control-flow vocabulary (ADR-373 law 1). `Declined`
/// means the accelerator stepped aside — the syscall is absent on this
/// filesystem, or the buffer it packed did not hold up — and it **never leaves
/// the module**: the two public listings convert it into a
/// `fault.Answer(…).declined = .capability_missing`, exactly as the PCRE2
/// shadow rewriter converts its `error.Bail`.
///
/// It must be a non-`pub` **named** set, not an inline `error{Declined}` in each
/// signature: an inline set is inferred outward, so the name would escape the
/// file and owe the global fault taxonomy a member. Named and private, it stays
/// this module's business.
///
/// The split from `OutOfMemory` is the point. The previous single
/// `error.BulkStatUnsupported` merged both facts, so every caller's `catch`
/// treated an allocation failure as "this platform lacks the syscall" and
/// silently walked the slower path with a dying allocator.
const Declines = error{Declined};

/// Only attempted on Darwin; every other target statically falls back to the
/// caller's stat-based walk (checked once, not per-directory).
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .ios or
    builtin.os.tag == .tvos or builtin.os.tag == .watchos or builtin.os.tag == .visionos;

// ─────────────────────── hand-declared Darwin ABI (<sys/attr.h>) ───────────────────────

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_CMN_CHGTIME: u32 = 0x00000800;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const FSOPT_PACK_INVAL_ATTRS: u64 = 0x00000008;

// <sys/vnode.h> enum vtype (VNON=0, VREG=1, VDIR=2, VBLK=3, VCHR=4, VLNK=5, …).
const VREG: u32 = 1;
const VDIR: u32 = 2;

/// Mirror of C `struct attrlist` (<sys/attr.h>) — field order is the ABI.
const AttrList = extern struct {
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

const requested_commonattr: u32 = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME;

/// One directory entry's freshness metadata, one bulk call away instead of one
/// `stat()` syscall away. `name` aliases the iterator's internal buffer —
/// valid only until the next `next()` call (mirrors `haystack.Haystack`).
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// Only metadata strictly older than the build anchor proves an indexed file
/// unchanged. Either timestamp at/after the anchor, or either one unavailable,
/// forces a live read. `>=` intentionally keeps same-tick/coarse-clock boundary
/// values conservative.
pub fn needsLiveRead(anchor_ns: i128, mtime_ns: ?i128, ctime_ns: ?i128) bool {
    const mtime = mtime_ns orelse return true;
    const ctime = ctime_ns orelse return true;
    return mtime >= anchor_ns or ctime >= anchor_ns;
}

/// Bulk-enumerates ONE open directory. 8 KiB batches (not 64 KiB): this is a
/// per-recursion-depth stack local (`visitFresh` below), and a monorepo path
/// is at most ~15 components deep, so 8 KiB × depth stays a rounding error
/// against any thread's stack — while still batching dozens of typical
/// same-directory siblings per syscall (most directories in this repo hold
/// well under 8 KiB / ~64 B-per-entry ≈ 128 entries, i.e. ONE syscall each).
pub const BulkDir = struct {
    dirfd: std.posix.fd_t,
    buf: [8192]u8 align(@alignOf(u32)) = undefined,
    count: c_int = 0, // entries left unparsed in `buf` from the last refill
    off: usize = 0, // byte offset of the next unparsed entry
    exhausted: bool = false, // last refill returned 0 (directory fully drained)

    pub fn init(dirfd: std.posix.fd_t) BulkDir {
        return .{ .dirfd = dirfd };
    }

    fn refill(self: *BulkDir) Declines!void {
        var al = AttrList{ .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = requested_commonattr };
        const n = getattrlistbulk(self.dirfd, &al, &self.buf, self.buf.len, FSOPT_PACK_INVAL_ATTRS);
        if (n < 0) return error.Declined;
        self.off = 0;
        self.count = n;
        if (n == 0) self.exhausted = true;
    }

    /// Next entry, or null at end-of-directory. `error.Declined` means the
    /// syscall itself failed (wrong fs, permissions, …) — the caller must fall
    /// back to a stat-based walk, never treat this as "done". Distinct from the
    /// `null` that means "done", which is why the two cannot be confused here.
    pub fn next(self: *BulkDir) Declines!?Entry {
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

/// Bounds-checked little-endian field read — `std.mem.readInt` on a byte
/// slice (never a direct pointer cast): the kernel's packing isn't guaranteed
/// to leave every field naturally aligned for a typed load.
inline fn readAt(comptime T: type, buf: []const u8, pos: usize) Declines!T {
    if (pos + @sizeOf(T) > buf.len) return error.Declined;
    return std.mem.readInt(T, buf[pos..][0..@sizeOf(T)], .little);
}

/// One packed `timespec` (i64 sec + i64 nsec) → nanoseconds, or null when
/// `returned_common` says the kernel didn't have the value (the field still
/// occupies its 16 bytes under `FSOPT_PACK_INVAL_ATTRS`).
inline fn readTimespec(buf: []const u8, pos: usize, valid: bool) Declines!?i128 {
    const sec = try readAt(i64, buf, pos);
    const nsec = try readAt(i64, buf, pos + 8);
    return if (valid) @as(i128, sec) * std.time.ns_per_s + @as(i128, nsec) else null;
}

/// Parse one entry at `start`. Layout (Apple's fixed group order for our
/// exact request): `u32 length` │ `attribute_set_t returned` (5×u32=20 B) │
/// `attrreference_t name` (i32 offset + u32 length, 8 B — the offset is
/// relative to the FIELD's own address, and the bytes it points to live
/// out-of-line, appended after every fixed attribute) │ `u32 objtype` │
/// `timespec modtime` · `timespec chgtime` (each i64 sec + i64 nsec). Every
/// multi-byte read goes through `std.mem.readInt` on a byte slice (never a
/// direct pointer cast) — the kernel's packing isn't guaranteed to leave every
/// field naturally aligned for a typed load. `FSOPT_PACK_INVAL_ATTRS` physically
/// packs every requested field; `returned_common` says whether each value is
/// valid, so invalid timestamps still advance `pos` but become null metadata.
fn parseEntry(buf: []const u8, start: usize) Declines!Parsed {
    const length = try readAt(u32, buf, start);
    if (length == 0 or start + length > buf.len) return error.Declined;

    var pos = start + 4;
    const returned_common = try readAt(u32, buf, pos);
    pos += 20; // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr

    if (returned_common & ATTR_CMN_NAME == 0 or returned_common & ATTR_CMN_OBJTYPE == 0)
        return error.Declined;

    const data_offset = try readAt(i32, buf, pos);
    const data_len = try readAt(u32, buf, pos + 4);
    const name_start = @as(i64, @intCast(pos)) + data_offset;
    if (name_start < 0) return error.Declined;
    const ns: usize = @intCast(name_start);
    const ne = ns + data_len;
    if (ne > buf.len or ns > ne) return error.Declined;
    var name = buf[ns..ne];
    if (std.mem.indexOfScalar(u8, name, 0)) |nul| name = name[0..nul]; // NUL-terminated
    pos += 8;

    const objtype = try readAt(u32, buf, pos);
    pos += 4;

    const mtime_ns = try readTimespec(buf, pos, returned_common & ATTR_CMN_MODTIME != 0);
    pos += 16;
    const ctime_ns = try readTimespec(buf, pos, returned_common & ATTR_CMN_CHGTIME != 0);

    return .{
        .value = .{
            .name = name,
            .is_dir = objtype == VDIR,
            .is_file = objtype == VREG,
            .mtime_ns = mtime_ns,
            .ctime_ns = ctime_ns,
        },
        .advance = length,
    };
}

/// Recursively collect every file under `dir` (relative path `prefix`) whose
/// mtime or ctime is `>= built_ns` (or metadata is unavailable), applying the
/// shared `haystack.isSkipDir` policy — the bulk-enumeration twin of
/// `fresh.zig`'s portable per-file-`statFile` walk.
/// Degrades directory-by-directory: a bulk failure on one directory falls
/// back to `fallbackWalk` (the proven stat-based path) for that subtree only,
/// preserving the same metadata rule.
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
            const sub_prefix = haystack.joinRoot(a, prefix, entry.name) catch return;
            visitFresh(a, io, sub, sub_prefix, built_ns, out);
            continue;
        }
        if (!entry.is_file) continue; // symlinks/etc — never followed, matches haystack.Walker
        if (!needsLiveRead(built_ns, entry.mtime_ns, entry.ctime_ns)) continue;
        const full = haystack.joinRoot(a, prefix, entry.name) catch return;
        out.append(a, full) catch return;
    }
}

/// One directory entry, name durably owned (`gpa`-allocated) rather than
/// aliasing `BulkDir`'s reused scratch buffer — for callers that must hold
/// entries past the next `next()` call, i.e. `listOneLevel` below.
pub const OwnedEntry = struct {
    name: []u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// Fully drains ONE level of `dirfd` via `getattrlistbulk`, duping every name
/// into `gpa` up front. All-or-nothing: any parse/syscall failure partway
/// discards what's been collected and declines rather than handing back a
/// truncated listing — the caller re-opens a fresh handle and retries with the
/// portable `Dir.Iterator`, never mixes a partial bulk result with a partial
/// iterate one (which could double- or under-count an entry).
///
/// The module boundary (ADR-373 law 1): a declinature crosses in the SUCCESS
/// position, so a caller cannot `try` its way past the fallback, while
/// `OutOfMemory` stays in the error channel where it belongs.
pub fn listOneLevel(gpa: Allocator, dirfd: std.posix.fd_t) error{OutOfMemory}!fault.Answer([]OwnedEntry) {
    var list: std.ArrayList(OwnedEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var bd = BulkDir.init(dirfd);
    while (bd.next() catch return declineList(gpa, &list)) |e| {
        try list.append(gpa, .{
            .name = try gpa.dupe(u8, e.name),
            .is_dir = e.is_dir,
            .is_file = e.is_file,
            .mtime_ns = e.mtime_ns,
            .ctime_ns = e.ctime_ns,
        });
    }
    return .{ .got = try list.toOwnedSlice(gpa) };
}

/// Release a partially-built listing and declare the accelerator stepped aside.
/// Shared by both drains so the all-or-nothing promise has one implementation
/// rather than a `errdefer` that no longer fires once the failure became a
/// success-position value.
fn declineList(gpa: Allocator, list: *std.ArrayList(OwnedEntry)) fault.Answer([]OwnedEntry) {
    for (list.items) |e| gpa.free(e.name);
    list.deinit(gpa);
    return .{ .declined = .capability_missing };
}

/// Fully drains ONE level of `dirfd` via raw `getdirentries(2)` — names +
/// `d_type` only, no timestamps (`mtime_ns = ctime_ns = null`). When the caller
/// doesn't need per-entry metadata (the parallel walk without index elision),
/// this is strictly cheaper than `listOneLevel`: `getattrlistbulk` makes the
/// kernel resolve and pack attributes per entry, while `getdirentries` is the
/// same thin readdir path ripgrep rides. Darwin-only (same `supported` gate).
///
/// Same boundary contract as `listOneLevel`: declining is a value, OOM is an error.
pub fn listNamesOnly(gpa: Allocator, dirfd: std.posix.fd_t) error{OutOfMemory}!fault.Answer([]OwnedEntry) {
    var list: std.ArrayList(OwnedEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var buf: [64 * 1024]u8 align(@alignOf(u64)) = undefined;
    var seek: i64 = 0;
    while (true) {
        const rc = std.posix.system.getdirentries(dirfd, &buf, buf.len, &seek);
        if (std.posix.errno(rc) != .SUCCESS) return declineList(gpa, &list);
        const n: usize = @intCast(rc);
        if (n == 0) return .{ .got = try list.toOwnedSlice(gpa) };
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
            try list.append(gpa, .{
                .name = try gpa.dupe(u8, name),
                .is_dir = is_dir,
                .is_file = is_file,
                .mtime_ns = null,
                .ctime_ns = null,
            });
        }
    }
}

/// The pre-bulkstat walk (readdir + `statFile` per entry), scoped to one
/// subtree — reused verbatim as `visitFresh`'s degrade path so a bulk-call
/// failure can only fall back to previously-proven-correct behavior.
/// `pub` because `fresh.zig::visitItem` is the same walk on a non-Darwin
/// target — one definition, so the two paths cannot drift (§Boilerplate).
pub fn fallbackWalk(a: Allocator, io: std.Io, root_path: []const u8, built_ns: i128, out: *std.ArrayList([]const u8)) void {
    var w = haystack.Walker.init(io, a, root_path) catch return;
    defer w.deinit(io);
    while (w.next(io) catch return) |hay| {
        const st = hay.dir.statFile(io, hay.name, .{}) catch {
            out.append(a, hay.path) catch return;
            continue;
        };
        if (!needsLiveRead(built_ns, st.mtime.nanoseconds, st.ctime.nanoseconds)) continue;
        out.append(a, hay.path) catch return;
    }
}
