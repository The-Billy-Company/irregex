//! gist `rg` — the portable `stat(2)` projection.
//!
//! THE one raw-stat definition in the package: Zig 0.16's `std.c` deliberately
//! declares no `fstat`/`fstatat` on Linux (the libc wrappers there are legacy
//! shims), so the Linux leg rides `statx(2)` directly while every other libc
//! target keeps the `fstatat`/`fstat` calls this replaced, byte-identically.
//! Every consumer — `--one-file-system` device ids, `--sort created` birth
//! times, fd classification for stdin, mmap sizing, and the T3 freshness
//! overlay — asks here rather than reaching for a platform call, so a
//! `std.posix.Stat` shape change breaks one file instead of six.

const std = @import("std");
const builtin = @import("builtin");

/// The slice of `stat(2)` gist actually consumes, projected portably: device
/// identity (`--one-file-system`), type+mode bits (fd classification, lstat
/// reconcile), byte size (mmap bounds), and birth time where the platform
/// records one.
pub const RawStat = struct {
    dev: i128,
    mode: u32,
    size: u64,
    /// Birth (creation) time in ns when the platform+filesystem record one
    /// (macOS `st_birthtimespec`, Linux `statx` BTIME); null otherwise —
    /// callers fall back rather than mislabel ctime as creation.
    birthtime_ns: ?i96,
    /// Modification + status-change clocks in ns — the same conservative
    /// freshness pair the T3 overlay compares against the build anchor
    /// (`bulkstat.needsLiveRead`). Null when the platform didn't report one.
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// `stat(2)` following symlinks — `--one-file-system` device ids and
/// `--sort created` birth times. Null on any failure (caller falls back).
pub fn statPath(path: []const u8) ?RawStat {
    return statAt(path, false);
}

/// `lstat(2)` — never follows the final symlink (the walk treats a symlink
/// as its own entry). Null when the path is gone/unreachable.
pub fn lstatPath(path: []const u8) ?RawStat {
    return statAt(path, true);
}

fn statAt(path: []const u8, nofollow: bool) ?RawStat {
    const cpath = std.posix.toPosixPath(path) catch return null;
    if (comptime builtin.os.tag == .linux) {
        const flags: u32 = if (nofollow) std.os.linux.AT.SYMLINK_NOFOLLOW else 0;
        return statxCall(std.os.linux.AT.FDCWD, &cpath, flags);
    }
    var st: std.posix.Stat = undefined;
    const flags: u32 = if (nofollow) std.posix.AT.SYMLINK_NOFOLLOW else 0;
    if (std.c.fstatat(std.posix.AT.FDCWD, &cpath, &st, flags) != 0) return null;
    return fromStat(st);
}

/// `fstat(2)` on an already-open fd — stdin classification and mmap sizing.
pub fn statFd(fd: std.posix.fd_t) ?RawStat {
    if (comptime builtin.os.tag == .linux) {
        return statxCall(fd, "", std.os.linux.AT.EMPTY_PATH);
    }
    var st: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return fromStat(st);
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
    };
}

fn fromStat(st: std.posix.Stat) RawStat {
    return .{
        .dev = st.dev,
        .mode = st.mode,
        .size = std.math.cast(u64, st.size) orelse 0,
        // Darwin records birth time in `struct stat` itself; gist declines to
        // invent one on libc targets that don't (matching ripgrep).
        .birthtime_ns = if (comptime builtin.os.tag.isDarwin()) @as(i96, st.birthtime().sec) * std.time.ns_per_s + st.birthtime().nsec else null,
        .mtime_ns = @as(i128, st.mtime().sec) * std.time.ns_per_s + st.mtime().nsec,
        .ctime_ns = @as(i128, st.ctime().sec) * std.time.ns_per_s + st.ctime().nsec,
    };
}
