//! irregex `rg` — the portable `stat(2)` projection.
//!
//! THE one raw-stat definition in the package: Zig 0.16's `std.c` deliberately
//! declares no `fstat`/`fstatat` on Linux (the libc wrappers there are legacy
//! shims), so the Linux leg rides `statx(2)` directly while every other libc
//! target keeps the `fstatat`/`fstat` calls this replaced, byte-identically.
//! Every consumer — `--sort created` birth times, fd classification for stdin,
//! mmap sizing, and the T3 freshness overlay — asks here rather than reaching
//! for a platform call, so a `std.posix.Stat` shape change breaks one file
//! instead of six. Volume identity (`--one-file-system`) is the one fact with
//! its own entry point (`devicePath`), because Windows answers it from a
//! separate query and only that flag ever asks.

const std = @import("std");
const builtin = @import("builtin");
const portal = @import("../../portal.zig");

/// The slice of `stat(2)` this package actually consumes, projected portably:
/// device identity (`--one-file-system`), type+mode bits (fd classification,
/// lstat reconcile), byte size (mmap bounds), and birth time where the platform
/// records one.
pub const RawStat = struct {
    dev: i128,
    mode: u32,
    size: u64,
    /// What the entry *is*, decided here rather than by each caller masking mode
    /// bits. `std.posix.S` does not exist on Windows and the attribute word there
    /// carries the same fact in a different encoding, so every "is this a regular
    /// file?" question is answered in this file — which is what the module header
    /// already promised for the rest of the projection.
    kind: Kind,
    /// Birth (creation) time in ns when the platform+filesystem record one
    /// (macOS `st_birthtimespec`, Linux `statx` BTIME); null otherwise —
    /// callers fall back rather than mislabel ctime as creation.
    birthtime_ns: ?i96,
    /// Modification + status-change clocks in ns — the same conservative
    /// freshness pair the T3 overlay compares against the build anchor
    /// (`bulkstat.needsLiveRead`). Null when the platform didn't report one.
    mtime_ns: ?i128,
    ctime_ns: ?i128,

    /// Deliberately coarser than `stat(2)`'s type bits: these are every
    /// distinction the engine actually makes — the walk needs file/dir/symlink,
    /// and stdin admission needs to tell a pipe from a socket from a tty.
    /// `other` is devices and ttys, which every caller declines identically.
    pub const Kind = enum { file, directory, sym_link, fifo, socket, other };
};

/// Project POSIX type bits onto `RawStat.Kind`.
fn kindOfMode(mode: u32) RawStat.Kind {
    const S = std.posix.S;
    return switch (mode & S.IFMT) {
        S.IFREG => .file,
        S.IFDIR => .directory,
        S.IFLNK => .sym_link,
        S.IFIFO => .fifo,
        S.IFSOCK => .socket,
        else => .other,
    };
}

/// `stat(2)` following symlinks — `--sort created` birth times and the
/// freshness overlay's clocks. Null on any failure (caller falls back).
pub fn statPath(path: []const u8) ?RawStat {
    return statAt(path, false);
}

/// The volume a path lives on, as an opaque id compared only for equality —
/// the single fact `--one-file-system` asks of a directory before descending.
///
/// Its own call rather than a `RawStat` field because Windows answers it from a
/// different query than everything else in the projection: folding it into
/// `statPath` would tax every stat in the walk (and the freshness overlay) to
/// serve a flag that is off by default and, when on, is consulted once per
/// directory. POSIX keeps paying nothing — `st_dev` already rode along.
pub fn devicePath(path: []const u8) ?i128 {
    if (comptime builtin.os.tag != .windows) return (statPath(path) orelse return null).dev;
    const h = portal.openPath(portal.cwd(), path, .{}) catch return null;
    defer portal.close(h);
    return volumeSerial(h);
}

/// The Windows leg of `devicePath`: the volume serial from
/// `FILE_ID_INFORMATION`, which is the same number `walkdir` (and through it
/// ripgrep) compares for `--one-file-system` on this platform — so a mount point
/// prunes here exactly where it prunes there. Null when the volume declines to
/// answer, which keeps the flag's failure mode "stops pruning" rather than
/// "prunes wrongly": `crossesDevice` reads a missing id as same-volume.
///
/// This class rather than `FileFsVolumeInformation`, which reads like the
/// obvious choice and is the one Wine answers `STATUS_NOT_IMPLEMENTED` — a
/// silently inert flag on the only Windows runtime this repo can execute. It is
/// also the better id on its merits: 64 bits where the volume-information
/// struct carries 32, and one fixed-size query where that struct trails a
/// variable-length label.
fn volumeSerial(h: std.posix.fd_t) ?i128 {
    const w = std.os.windows;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var info: extern struct { VolumeSerialNumber: u64, FileId: [16]u8 } = undefined;
    return switch (w.ntdll.NtQueryInformationFile(h, &iosb, &info, @sizeOf(@TypeOf(info)), .Id)) {
        .SUCCESS => info.VolumeSerialNumber,
        else => null,
    };
}

/// `lstat(2)` — never follows the final symlink (the walk treats a symlink
/// as its own entry). Null when the path is gone/unreachable.
pub fn lstatPath(path: []const u8) ?RawStat {
    return statAt(path, true);
}

fn statAt(path: []const u8, nofollow: bool) ?RawStat {
    if (comptime builtin.os.tag == .windows) {
        // Windows has no `fstatat`, so the same answer is reached the way the
        // platform reaches it: open the name relative to CWD (declining to
        // traverse the final link when asked), then query the handle.
        const h = portal.openPath(portal.cwd(), path, .{ .follow_symlinks = !nofollow }) catch
            return null;
        defer portal.close(h);
        return statFd(h);
    }
    const cpath = std.posix.toPosixPath(path) catch return null;
    if (comptime builtin.os.tag == .linux) {
        const flags: u32 = if (nofollow) std.os.linux.AT.SYMLINK_NOFOLLOW else 0;
        return statxCall(std.os.linux.AT.FDCWD, &cpath, flags);
    }
    var st: std.posix.Stat = undefined;
    const flags: u32 = if (nofollow) std.posix.AT.SYMLINK_NOFOLLOW else 0;
    if (std.c.fstatat(portal.cwd(), &cpath, &st, flags) != 0) return null;
    return fromStat(st);
}

/// `fstat(2)` on an already-open fd — stdin classification and mmap sizing.
pub fn statFd(fd: std.posix.fd_t) ?RawStat {
    if (comptime builtin.os.tag == .windows) return fromFileInfo(fd);
    if (comptime builtin.os.tag == .linux) {
        return statxCall(fd, "", std.os.linux.AT.EMPTY_PATH);
    }
    var st: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return fromStat(st);
}

/// The Windows leg: one `NtQueryInformationFile(.All)` carries every field
/// `RawStat` projects except volume identity, which `devicePath` asks for
/// separately so this call stays a single query.
fn fromFileInfo(h: std.posix.fd_t) ?RawStat {
    const w = std.os.windows;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var info: w.FILE.ALL_INFORMATION = undefined;
    switch (w.ntdll.NtQueryInformationFile(h, &iosb, &info, @sizeOf(@TypeOf(info)), .All)) {
        // `.All` ends in a variable-length name, so a short buffer is the normal
        // outcome and every fixed-size field ahead of it is already filled.
        .SUCCESS, .BUFFER_OVERFLOW => {},
        else => return null,
    }
    const attrs = info.BasicInformation.FileAttributes;
    return .{
        // Volume identity is not in this query's answer, and no consumer of
        // `RawStat.dev` on this platform reads it — `--one-file-system` goes
        // through `devicePath`, which asks the volume directly.
        .dev = 0,
        // Synthesized for the POSIX consumers that still read mode bits; `kind`
        // below is the field callers should be asking.
        .mode = if (attrs.DIRECTORY) 0o040000 else 0o100000,
        .size = @bitCast(info.StandardInformation.EndOfFile),
        .birthtime_ns = w.fromSysTime(info.BasicInformation.CreationTime).nanoseconds,
        .mtime_ns = w.fromSysTime(info.BasicInformation.LastWriteTime).nanoseconds,
        // Windows' ChangeTime is the metadata-change clock, the same role POSIX
        // gives ctime — which is exactly what the freshness overlay compares.
        .ctime_ns = w.fromSysTime(info.BasicInformation.ChangeTime).nanoseconds,
        // A handle's *device* type is what separates a pipe from a disk file on
        // Windows; the attribute word only distinguishes directories and reparse
        // points. Windows has no unix-domain socket on stdin, so `.socket` simply
        // never occurs here — which is why the socket-silence guard the POSIX
        // stdin path carries has nothing to guard against on this platform.
        .kind = switch (portal.device(h)) {
            .pipe => .fifo,
            .character => .other,
            else => if (attrs.REPARSE_POINT) .sym_link else if (attrs.DIRECTORY) .directory else .file,
        },
    };
}

/// The one `statx(2)` invocation both Linux legs ride (path-relative and
/// fd-only via `AT.EMPTY_PATH`); null on any errno.
fn statxCall(dirfd: std.posix.fd_t, path: [*:0]const u8, flags: u32) ?RawStat {
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dirfd, path, flags, statx_mask, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return fromStatx(stx);
}

/// Exactly the fields `RawStat` projects — BTIME rides along; the kernel's
/// returned mask (not this request) decides whether it was actually filled.
const statx_mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .BTIME = true, .MTIME = true, .CTIME = true };

fn fromStatx(stx: std.os.linux.Statx) RawStat {
    return .{
        // statx splits dev_t into major/minor; recombine losslessly — only
        // equality matters (mount-point detection), not the packed encoding.
        .dev = (@as(i128, stx.dev_major) << 32) | stx.dev_minor,
        .mode = stx.mode,
        .size = stx.size,
        .birthtime_ns = if (stx.mask.BTIME) @as(i96, stx.btime.sec) * std.time.ns_per_s + stx.btime.nsec else null,
        .mtime_ns = if (stx.mask.MTIME) @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec else null,
        .ctime_ns = if (stx.mask.CTIME) @as(i128, stx.ctime.sec) * std.time.ns_per_s + stx.ctime.nsec else null,
        .kind = kindOfMode(stx.mode),
    };
}

fn fromStat(st: std.posix.Stat) RawStat {
    return .{
        .dev = st.dev,
        .mode = st.mode,
        .size = std.math.cast(u64, st.size) orelse 0,
        // Darwin records birth time in `struct stat` itself; this projection
        // declines to invent one on libc targets that don't (matching ripgrep).
        .birthtime_ns = if (comptime builtin.os.tag.isDarwin()) @as(i96, st.birthtime().sec) * std.time.ns_per_s + st.birthtime().nsec else null,
        .mtime_ns = @as(i128, st.mtime().sec) * std.time.ns_per_s + st.mtime().nsec,
        .ctime_ns = @as(i128, st.ctime().sec) * std.time.ns_per_s + st.ctime().nsec,
        .kind = kindOfMode(st.mode),
    };
}

// ─────────────────────────────────── tests ───────────────────────────────────

const t = std.testing;

test "volume identity answers, and answers the same for two paths on one volume" {
    // The property `--one-file-system` rests on, and the one a silently-failing
    // platform query breaks invisibly: a null or a per-path-varying id turns the
    // flag into a no-op (nothing prunes) or a shredder (siblings prune each
    // other). Asserting BOTH is what makes the Windows volume-serial leg a
    // tested claim rather than an inference from a passing walk.
    const dir = devicePath(".") orelse return error.NoDeviceId;
    const same = devicePath("." ++ std.fs.path.sep_str ++ ".") orelse return error.NoDeviceId;
    try t.expectEqual(dir, same);
}

test "volume identity of a missing path is null, never a value that could match" {
    try t.expectEqual(@as(?i128, null), devicePath("does-not-exist-cbb0f1e2"));
}
