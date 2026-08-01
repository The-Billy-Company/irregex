//! irregex — the sheaf: one bundle of directory entries as each platform's
//! batched-enumeration syscall hands it over.
//!
//! A directory walk has exactly two questions per level — *what is in here*, and
//! *when did each of those change* — and every kernel will answer both in one
//! call if asked correctly. Asking per entry instead is the difference between a
//! walk that keeps up with `find` and one that does not: `readdir()` + `stat()`
//! is two syscalls per file, and on a monorepo that is six figures of them.
//!
//! Three arms, one shape (`next()` → `Entry` → `null`, `error.Declined` when the
//! accelerator steps aside). `bulkstat.zig` next door owns what the freshness
//! walk *does* with a sheaf; this file owns only how one is gathered.
//!
//! | Platform | names + kinds | + change timestamps |
//! |---|---|---|
//! | Darwin | `getdirentries(2)` | `getattrlistbulk(2)` |
//! | Linux | `getdents64(2)` | — (the caller stats) |
//! | Windows | `NtQueryDirectoryFile` | the same call, same buffer |
//!
//! **Windows is the interesting row, and the reason this file exists.** NT has no
//! separate "cheap listing" and "listing with metadata": a single
//! `FILE_DIRECTORY_INFORMATION` record carries the name, the attributes, *and*
//! `LastWriteTime` + `ChangeTime`, so one call answers both questions and `Names`
//! is literally the same iterator as `Sheaf` there. Which means the portable path
//! this replaces was not merely slower — it was asking twice for something it had
//! already been told. `std.Io.Dir.Iterator` requests the metadata-bearing
//! information class, keeps the name and the kind, and discards the timestamps;
//! the freshness walk then re-opened every file to ask again. Per file that is an
//! `NtCreateFile` + `NtQueryInformationFile` + `NtClose` — and on Windows an open
//! is the expensive operation, because it is the one every filesystem filter
//! driver (Defender included) is interposed on. So the Windows arm is not a port
//! of the Darwin optimization so much as the deletion of a redundant question.
//!
//! FAIL-SOFT, NEVER FAIL-OPEN, on every arm: a batch call that refuses — an
//! unusual mount, a permissions edge, a filesystem that does not implement it, a
//! handle opened for overlapped I/O — declines, and the caller falls back to the
//! proven per-entry stat walk for that subtree only. Uncertain bulk metadata
//! therefore costs speed, never the conservative live-read decision.
//!
//! ABI provenance. Zig's std binds none of the Darwin calls, so `struct attrlist`,
//! the `ATTR_CMN_*`/`FSOPT_*` bits, and the packed per-entry layout are declared
//! from the SDK headers (`<sys/attr.h>`, `<sys/unistd.h>`, `<sys/vnode.h>`) and
//! were cross-checked byte-for-byte against a maintained, benchmarked Rust
//! binding (quivent/getattrlistbulk-rs `src/{ffi,parser}.rs`) first. The Windows
//! record layout is std's own `w.FILE_DIRECTORY_INFORMATION`, and every field
//! position is taken with `@offsetOf` rather than written down — a hand-copied
//! offset table is a second source of truth that can rot silently against the
//! first.

const std = @import("std");
const builtin = @import("builtin");

const w = std.os.windows;

/// The batched-listing pair's private control-flow vocabulary (fault-channel law 1).
/// `Declined` means the accelerator stepped aside — the syscall is absent on this
/// filesystem, or the buffer it packed did not hold up.
///
/// It is `pub` for exactly one importer, `bulkstat.zig`, which converts it into a
/// `fault.Answer(…).declined = .capability_missing` at the module boundary. It
/// never reaches a third file and therefore never owes the global fault taxonomy
/// a member — same posture as the PCRE2 shadow rewriter's `error.Bail`.
///
/// The split from `OutOfMemory` is the point. A single merged error had every
/// caller's `catch` treat an allocation failure as "this platform lacks the
/// syscall" and silently walk the slower path with a dying allocator.
pub const Declines = error{Declined};

/// Whether this target can batch **names + kinds + change timestamps** in one
/// call, which is what lets the walk elide unchanged indexed files inline with no
/// separate freshness stat sweep.
pub const supported = builtin.os.tag.isDarwin() or builtin.os.tag == .windows;

/// Whether the cheaper **names + kinds** drain has a raw batched implementation
/// here. Broader than `supported`, because Linux's `getdents64(2)` enumerates
/// without resolving attributes. Every other target declines and its callers take
/// the portable `Dir.Iterator` path.
///
/// The two facts are separate constants because they fail differently. A target
/// outside `supported` still has correct freshness (it stats); a target outside
/// this one cannot enumerate a directory here at all, which is why
/// `phantom/treemap.zig` refuses to publish a snapshot there rather than recording
/// every directory as childless.
pub const names_supported = supported or builtin.os.tag == .linux;

/// Whether the names-only drain is *cheaper* than this platform's own
/// `Dir.Iterator` — a different question from whether it exists, and the reason
/// `names_supported` is not the whole answer.
///
/// On POSIX it plainly is: `Dir.Iterator` walks with `readdir` and the caller
/// then stats, so batching removes a syscall per file. On Windows it plainly is
/// not, because `std.Io.Dir.Iterator` is *already* `NtQueryDirectoryFile` — the
/// same call this file makes. Routing names alone through here would pay an extra
/// owned array and a copy for a syscall the iterator makes for free, which
/// measured as a 3–6% loss on a 10.9k-file cold walk under Wine.
///
/// `supported` is still true there, and that is not a contradiction: with index
/// elision live the iterator's *discarded timestamps* cost an
/// `NtCreateFile` + `NtQueryInformationFile` + `NtClose` per candidate file, and
/// deleting that is worth 1.5–1.7× on the same corpus. So the batched drain wins
/// exactly when the caller wants metadata, and a caller that wants an owned
/// listing (`phantom/treemap.zig`) wants it either way.
pub const names_undercut_iterator = names_supported and builtin.os.tag != .windows;

/// One directory entry, one batch call away instead of one `stat()` away.
///
/// `name` aliases the iterator's internal buffer — valid only until the next
/// `next()` call (mirrors `haystack.Haystack`). A null timestamp means the kernel
/// had no value for it, which every caller reads as "assume changed"; that is why
/// the names-only drains can share this type honestly rather than needing a
/// second, timestamp-free one.
pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// The metadata drain: names, kinds, and both change clocks per entry.
/// Darwin rides `getattrlistbulk(2)`; Windows rides `NtQueryDirectoryFile`.
pub const Sheaf = if (builtin.os.tag == .windows) NtDir else BulkDir;

/// The names-and-kinds drain, for callers that need no timestamps (the parallel
/// walk without index elision). On POSIX this is strictly cheaper than `Sheaf`:
/// `getattrlistbulk` makes the kernel resolve and pack attributes per entry,
/// while this is the same thin readdir path ripgrep rides.
///
/// On Windows it *is* `Sheaf`, because there is no cheaper call to drop to — the
/// timestamps ride the record whether or not anybody reads them. Stating that as
/// an alias rather than a second implementation is what keeps the two drains from
/// drifting on the one platform where they cannot differ.
pub const Names = if (builtin.os.tag == .windows) NtDir else PosixNames;

/// Bounds-checked little-endian field read — `std.mem.readInt` on a byte slice,
/// never a direct pointer cast: no kernel guarantees every packed field lands
/// naturally aligned for a typed load, and at least one (NT, under some
/// virtualization and sandboxing layers) is documented not to.
inline fn readAt(comptime T: type, buf: []const u8, pos: usize) Declines!T {
    if (pos + @sizeOf(T) > buf.len) return error.Declined;
    return std.mem.readInt(T, buf[pos..][0..@sizeOf(T)], .little);
}

// ─────────────────────── Darwin: getattrlistbulk(2) ───────────────────────

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

/// Bulk-enumerates ONE open directory. 8 KiB batches (not 64 KiB): this is a
/// per-recursion-depth stack local (`bulkstat.visitFresh`), and a monorepo path
/// is at most ~15 components deep, so 8 KiB × depth stays a rounding error
/// against any thread's stack — while still batching dozens of typical
/// same-directory siblings per syscall.
///
/// Widening this is a measured dead end, recorded so nobody re-derives it: the
/// original ~64 B-per-entry estimate is indeed low (an attribute-bearing entry
/// is closer to ~110 B once name, `RETURNED_ATTRS`, objtype, and two
/// `timespec`s are counted), but a back-to-back A/B of 8 KiB against 32 KiB over
/// a 21k-file corpus came back inside the noise — 46.3 ms ± 7.4 vs 45.2 ms ± 4.1,
/// with system time 205.4 vs 207.7 ms — and 64 KiB was no better again. Refills
/// are not where this walk's time goes.
///
/// Neither are the clocks, and that correction matters because this comment used
/// to say otherwise and sent the next reader at the wrong target. Priced by
/// attribute set over a 162k-entry tree, min-of-7 interleaved so competing load
/// cannot bias one variant: names+kind alone 2.94 µs/entry, plus MODTIME 2.93,
/// plus CHGTIME 3.02, plus BOTH 2.96. The spread is noise — asking for both
/// timestamps costs about 1%, and both-clocks measured *faster* than mtime-alone
/// on one of three runs. They ride the inode record the call already fetched, so
/// there is no second clock to save and dropping one buys nothing.
///
/// What actually costs is asking `getattrlistbulk` at all instead of the cheap
/// `getdirentries` drain next door: 2.96 vs 2.00 µs per comparable entry, 1.48x,
/// independent of which attributes are named. So the freshness walk's price is
/// set by HOW MANY ENTRIES it enumerates, not by what it asks about each one.
/// The earlier 9.0 → 37.2 ms figure quoted here implied a 4x clock surcharge; it
/// was taken from single wall-clock runs on a machine loaded enough that the
/// 32 KiB "win" above came from the same contamination, and it does not
/// reproduce. Anyone hunting the cold walk should be cutting entries visited
/// (`phantom_stat_budget` in `swarm/descent.zig` is that lever), not attributes.
const BulkDir = struct {
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
        const entry = try parseAttrEntry(self.buf[0..], self.off);
        self.off += entry.advance;
        self.count -= 1;
        return entry.value;
    }
};

const Parsed = struct { value: Entry, advance: usize };

/// One packed `timespec` (i64 sec + i64 nsec) → nanoseconds, or null when
/// `returned_common` says the kernel didn't have the value (the field still
/// occupies its 16 bytes under `FSOPT_PACK_INVAL_ATTRS`).
inline fn readTimespec(buf: []const u8, pos: usize, valid: bool) Declines!?i128 {
    const sec = try readAt(i64, buf, pos);
    const nsec = try readAt(i64, buf, pos + 8);
    return if (valid) @as(i128, sec) * std.time.ns_per_s + @as(i128, nsec) else null;
}

/// Parse one entry at `start`. Layout (Apple's fixed group order for our exact
/// request): `u32 length` │ `attribute_set_t returned` (5×u32=20 B) │
/// `attrreference_t name` (i32 offset + u32 length, 8 B — the offset is relative
/// to the FIELD's own address, and the bytes it points to live out-of-line,
/// appended after every fixed attribute) │ `u32 objtype` │ `timespec modtime` ·
/// `timespec chgtime` (each i64 sec + i64 nsec). `FSOPT_PACK_INVAL_ATTRS`
/// physically packs every requested field; `returned_common` says whether each
/// value is valid, so invalid timestamps still advance `pos` but become null.
fn parseAttrEntry(buf: []const u8, start: usize) Declines!Parsed {
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

// ─────────────────── POSIX: getdirentries(2) / getdents64(2) ───────────────────

/// One decoded directory record: what the entry says, and how many bytes to step
/// to reach the next one. `ino == 0` marks a deleted slot the kernel left in the
/// buffer — a skip, not an error.
const Record = struct { name: []const u8, ino: u64, dtype: u8, advance: usize };

/// The names-and-kinds drain on POSIX. 64 KiB batches: unlike `BulkDir` this is
/// never a per-recursion-depth local — one caller holds one at a time — so the
/// buffer is sized for syscall count instead of stack depth.
const PosixNames = struct {
    dirfd: std.posix.fd_t,
    buf: [64 * 1024]u8 align(@alignOf(u64)) = undefined,
    cursor: i64 = 0, // Darwin's `basep`; Linux keeps its cursor in the fd
    off: usize = 0,
    end: usize = 0,
    exhausted: bool = false,

    pub fn init(dirfd: std.posix.fd_t) PosixNames {
        return .{ .dirfd = dirfd };
    }

    /// Next entry, or null when the directory is drained. Timestamps are always
    /// null here: this call class does not resolve them, and a caller that needs
    /// them wants `Sheaf`.
    pub fn next(self: *PosixNames) Declines!?Entry {
        while (true) {
            if (self.off >= self.end) {
                if (self.exhausted) return null;
                self.end = try refillNames(self.dirfd, &self.buf, &self.cursor);
                self.off = 0;
                if (self.end == 0) {
                    self.exhausted = true;
                    return null;
                }
            }
            const rec = try parseRecord(self.buf[self.off..self.end]);
            self.off += rec.advance;
            if (rec.ino == 0) continue;
            if (std.mem.eql(u8, rec.name, ".") or std.mem.eql(u8, rec.name, "..")) continue;
            const is_dir = rec.dtype == std.posix.DT.DIR;
            const is_file = rec.dtype == std.posix.DT.REG;
            // Symlinks and specials: the walk never follows them, so they are
            // neither, exactly as `Sheaf`'s `objtype` test reports them.
            if (!is_dir and !is_file) continue;
            return .{ .name = rec.name, .is_dir = is_dir, .is_file = is_file, .mtime_ns = null, .ctime_ns = null };
        }
    }
};

/// One batch of directory records into `buf`; 0 means the directory is drained.
/// The two syscalls differ in where the read cursor lives — Darwin threads it
/// through the caller-held `basep`, Linux keeps it in the open file description —
/// so `basep` is simply unread on Linux rather than being two functions.
fn refillNames(dirfd: std.posix.fd_t, buf: []u8, basep: *i64) Declines!usize {
    if (comptime builtin.os.tag == .linux) {
        // The raw syscall, not a libc symbol: musl ships no `getdirentries`, so
        // going through `std.c` here is what broke every static-musl cross build.
        const rc = std.os.linux.getdents64(dirfd, buf.ptr, buf.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.Declined;
        return rc;
    }
    const rc = std.posix.system.getdirentries(dirfd, buf.ptr, buf.len, basep);
    if (std.posix.errno(rc) != .SUCCESS) return error.Declined;
    return @intCast(rc);
}

/// Decode the leading record of `rec` by explicit field offset (no pointer casts,
/// so the two layouts cannot silently alias each other):
///
/// - Darwin 64-bit `struct dirent`: d_ino u64 @0 · d_seekoff u64 @8 ·
///   d_reclen u16 @16 · d_namlen u16 @18 · d_type u8 @20 · name @21.
/// - Linux `struct linux_dirent64`: d_ino u64 @0 · d_off i64 @8 · d_reclen u16
///   @16 · d_type u8 @18 · NUL-terminated name @19 (no length field — the name is
///   scanned to its terminator inside the record).
///
/// Reading a Linux buffer with the Darwin layout is not a crash but a silent
/// wrong answer: `d_type` lands where `d_namlen`'s low byte is, so every entry
/// decodes to a bogus name and kind. That is what made a freshly indexed tree
/// report zero files on Linux, so the record is bounds-checked here and a
/// truncated one declines rather than reading past the batch.
fn parseRecord(rec: []const u8) Declines!Record {
    const darwin = comptime builtin.os.tag != .linux;
    const name_off: usize = if (darwin) 21 else 19;
    if (rec.len < name_off) return error.Declined;
    const reclen: usize = std.mem.readInt(u16, rec[16..18], .little);
    if (reclen < name_off or reclen > rec.len) return error.Declined;
    const body = rec[name_off..reclen];
    const name = if (darwin)
        body[0..@min(@as(usize, std.mem.readInt(u16, rec[18..20], .little)), body.len)]
    else
        std.mem.sliceTo(body, 0);
    return .{
        .name = name,
        .ino = std.mem.readInt(u64, rec[0..8], .little),
        .dtype = if (darwin) rec[20] else rec[18],
        .advance = reclen,
    };
}

// ───────────────────── Windows: NtQueryDirectoryFile ─────────────────────

/// std's own record layout, so there is exactly one description of it in the
/// process. Every field below is located with `@offsetOf` against this type
/// rather than a written-down offset, which is what makes the parse immune to a
/// std-side field reorder instead of silently misreading one.
const Info = w.FILE_DIRECTORY_INFORMATION;

const info_next = @offsetOf(Info, "NextEntryOffset");
const info_write = @offsetOf(Info, "LastWriteTime");
const info_change = @offsetOf(Info, "ChangeTime");
const info_attrs = @offsetOf(Info, "FileAttributes");
const info_namelen = @offsetOf(Info, "FileNameLength");
/// Where the WTF-16 name begins, and therefore the smallest a populated record
/// can be — a shorter one is a truncated batch, not an entry.
const info_name = @offsetOf(Info, "FileName");

/// 1601-01-01 → 1970-01-01 in FILETIME's 100 ns ticks. NT counts from the start
/// of the Gregorian calendar's current 400-year cycle; Unix counts from 1970, and
/// every caller's anchor is the Unix one.
const filetime_epoch_ticks: i128 = 116_444_736_000_000_000;

/// A FILETIME tick count as Unix nanoseconds, or null when the filesystem has no
/// value for this clock. Zero is NT's "not recorded" (FAT and some network
/// redirectors leave `ChangeTime` unset), and null is what every caller reads as
/// "assume changed" — so an unrecorded clock costs a live read, never a wrong
/// elision.
///
/// Public because the resident session's Windows watcher stamps its notes from
/// `FILE_NOTIFY_EXTENDED_INFORMATION` timestamps, and those notes are compared
/// against the `mtime`/`ctime` this very function produced for the same entries
/// (`watch/notify.zig`). Two spellings of one conversion is exactly the kind of
/// drift that would make a note look older than the change it describes.
pub inline fn filetimeNs(ticks: i64) ?i128 {
    if (ticks <= 0) return null;
    return (@as(i128, ticks) - filetime_epoch_ticks) * 100;
}

/// Batch-enumerates ONE open directory handle through `NtQueryDirectoryFile`,
/// which fills the buffer with a `NextEntryOffset`-linked run of records carrying
/// name, attributes, and both change clocks at once.
///
/// 8 KiB batches for the same reason Darwin's arm uses them — this is a
/// per-recursion-depth stack local — plus one name's worth of WTF-8 scratch. The
/// scratch is what keeps the `Entry.name` contract ("valid until the next
/// `next()`") honest without either transcoding into the record buffer, which
/// would clobber the entries after it, or allocating per name in the walk's
/// hottest loop.
const NtDir = struct {
    handle: w.HANDLE,
    buf: [8192]u8 align(@alignOf(Info)) = undefined,
    /// A component is at most `NAME_MAX` WTF-16 code units, each of which is at
    /// most three WTF-8 bytes.
    name: [w.NAME_MAX * 3]u8 = undefined,
    off: usize = 0,
    end: usize = 0,
    /// NT's scan cursor lives in the handle, and the first call is the one that
    /// must ask for it to be rewound.
    restart: bool = true,
    exhausted: bool = false,

    pub fn init(handle: std.posix.fd_t) NtDir {
        return .{ .handle = handle };
    }

    fn refill(self: *NtDir) Declines!void {
        var iosb: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtQueryDirectoryFile(
            self.handle,
            null, // event: the handle is synchronous, so the call completes in place
            null, // APC routine
            null, // APC context
            &iosb,
            &self.buf,
            @intCast(self.buf.len),
            // The leanest information class that still carries both clocks. std's
            // iterator asks for `.BothDirectory`, which adds the 8.3 short name
            // nobody here reads.
            .Directory,
            .FALSE, // return every entry that fits, not one per call
            null, // no filename filter: this is a whole-directory drain
            .fromBool(self.restart),
        );
        self.restart = false;
        self.off = 0;
        self.end = 0;
        switch (status) {
            .SUCCESS => {},
            // The scan is drained. NT reports that as a status rather than a zero
            // byte count, and reports a directory that was empty to begin with
            // the same way — both are `null`, not a decline.
            .NO_MORE_FILES, .NO_SUCH_FILE => {
                self.exhausted = true;
                return;
            },
            // Everything else declines to the portable walk. `.PENDING` lands
            // here deliberately: it means the handle was opened for overlapped
            // I/O, so with a null Event the buffer holds nothing yet and waiting
            // on it is not this drain's job.
            else => return error.Declined,
        }
        self.end = iosb.Information;
        if (self.end == 0) self.exhausted = true;
    }

    /// Next entry, or null at end-of-directory. `error.Declined` means the batch
    /// refused or contradicted itself — the caller must fall back to a stat-based
    /// walk, never treat it as "done".
    pub fn next(self: *NtDir) Declines!?Entry {
        while (true) {
            if (self.off >= self.end) {
                if (self.exhausted) return null;
                try self.refill();
                if (self.off >= self.end) return null;
            }
            const rec = self.buf[self.off..self.end];
            if (rec.len < info_name) return error.Declined;

            // Advance first, from the record's own link, so every `continue`
            // below cannot fail to make progress. A zero link means "last record
            // in this batch"; a non-zero one shorter than a header would aim the
            // cursor back inside the record it came from, which is a malformed
            // batch rather than a short one.
            const link = try readAt(u32, rec, info_next);
            if (link == 0) {
                self.off = self.end;
            } else {
                if (link < info_name) return error.Declined;
                self.off += link;
            }

            const name_len: usize = try readAt(u32, rec, info_namelen);
            // NTFS caps a component at NAME_MAX UTF-16 units; anything claiming
            // more has contradicted the layout it was read through.
            if (name_len % 2 != 0 or name_len / 2 > w.NAME_MAX) return error.Declined;
            if (info_name + name_len > rec.len) return error.Declined;

            // The one place a typed load is taken instead of `readAt`, and the
            // alignment is structural rather than assumed: the buffer is
            // `Info`-aligned, NT packs each record at an 8-byte boundary (so every
            // `NextEntryOffset` keeps that), and `FileName` sits at an even offset
            // inside one. Decoding the name a code unit at a time instead measured
            // ~8% of a whole cold walk — the name is the only per-entry field big
            // enough for the difference to show.
            const wtf16: []const u16 = @as([*]const u16, @ptrCast(@alignCast(rec[info_name..].ptr)))[0 .. name_len / 2];
            if (std.mem.eql(u16, wtf16, &.{'.'}) or std.mem.eql(u16, wtf16, &.{ '.', '.' })) continue;

            const attrs: w.FILE.ATTRIBUTE = @bitCast(try readAt(u32, rec, info_attrs));
            // A reparse point is neither, whichever it points at — symlinks,
            // junctions, and mount points are entries the walk never follows —
            // and it is dropped rather than reported as neither, because this
            // iterator is `Names` as well as `Sheaf`. `Sheaf`'s consumers ignore a
            // both-false entry either way, but `Names`' don't: the phantom
            // treemap records every row it is handed as a child, so returning
            // one here would make a Windows snapshot count links that a POSIX
            // snapshot of the same tree does not. One rule, both drains.
            const is_dir = attrs.DIRECTORY and !attrs.REPARSE_POINT;
            const is_file = !attrs.DIRECTORY and !attrs.REPARSE_POINT;
            if (!is_dir and !is_file) continue;

            const written = std.unicode.wtf16LeToWtf8(&self.name, wtf16);
            return .{
                .name = self.name[0..written],
                .is_dir = is_dir,
                .is_file = is_file,
                .mtime_ns = filetimeNs(try readAt(i64, rec, info_write)),
                .ctime_ns = filetimeNs(try readAt(i64, rec, info_change)),
            };
        }
    }
};
