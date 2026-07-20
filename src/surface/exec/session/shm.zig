//! shm — a portable, anonymous, one-shot shared buffer for fd-passed emit.
//!
//! The warm daemon renders a large `lines` answer into ONE of these, hands the
//! client its fd over the socket's SCM_RIGHTS control channel (`wire.zig`), and
//! the client mmaps it read-only straight to stdout — so a multi-MB answer never
//! traverses the socket (no user→kernel→user copy of the payload bytes, only the
//! fd rides the wire). It backs the same finished bytes the `chunk` frames would
//! carry; nothing about how they're computed changes.
//!
//! Anonymous + bounded to the exact rendered length on both platforms:
//!   * Linux — `memfd_create` then, once the daemon's writable view is gone,
//!     sealed immutable (`F_SEAL_WRITE|SHRINK|GROW|SEAL`) so the client's view
//!     can never be resized or rewritten under it.
//!   * macOS — `shm_open(O_CREAT|O_EXCL)` on a unique name, `shm_unlink`ed
//!     IMMEDIATELY (the fd stays valid after unlink) so no name lingers in the
//!     global namespace for another process to open.
//!
//! Fail-open: every fallible call returns an error the caller turns back into
//! the classic `chunk`-frame path. This buffer is a pure accelerator, never a
//! new source of truth or a new failure mode.

const std = @import("std");
const builtin = @import("builtin");

/// Only the two targets whose fd-passing + anonymous-shm story we implement and
/// measure. Everywhere else the caller stays on `chunk` frames.
pub const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

const page = std.heap.page_size_min;

pub const Error = error{ Unsupported, ShmFailed, MapFailed };

// Not `pub` in this Zig's `std.c`; declared here at the C ABI it uses elsewhere.
extern "c" fn shm_open(name: [*:0]const u8, flag: c_int, mode: std.c.mode_t) c_int;

/// macOS shm names must be unique per object (O_EXCL) and short (PSHMNAMLEN=31);
/// pid + a monotonic counter keeps them unique across a daemon's lifetime.
var darwin_seq: std.atomic.Value(u64) = .init(0);

/// A writable shared buffer the daemon fills once, then freezes. After `freeze`
/// the bytes are immutable and `fd` is ready to hand to the client; `close`
/// releases the daemon's handle (the object lives until the client's fd closes).
pub const Buffer = struct {
    fd: std.posix.fd_t,
    /// The daemon's writable mapping — valid only until `freeze` (then empty).
    map: []align(page) u8,

    /// An anonymous shared object of exactly `len` bytes, mapped writable.
    pub fn create(len: usize) Error!Buffer {
        if (!supported or len == 0) return Error.Unsupported;
        const fd = try openAnon(len);
        errdefer _ = std.c.close(fd);
        const m = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
            return Error.MapFailed;
        return .{ .fd = fd, .map = m };
    }

    /// Drop the daemon's writable view and (Linux) seal the object immutable,
    /// leaving only `fd` to send. Call once, after filling `map`.
    pub fn freeze(self: *Buffer) void {
        std.posix.munmap(self.map);
        self.map = self.map[0..0];
        if (comptime builtin.os.tag == .linux) {
            const F = std.os.linux.F;
            // Best-effort: the client maps read-only regardless; sealing is
            // defense-in-depth against a resize/rewrite under its view.
            _ = std.os.linux.fcntl(self.fd, F.ADD_SEALS, F.SEAL_SEAL | F.SEAL_SHRINK | F.SEAL_GROW | F.SEAL_WRITE);
        }
    }

    pub fn close(self: *Buffer) void {
        _ = std.c.close(self.fd);
    }
};

/// Map a received buffer fd read-only for the exact `len` the frame declared.
/// The daemon has already frozen it, so the view is a stable immutable snapshot.
pub fn mapReadonly(fd: std.posix.fd_t, len: usize) Error![]align(page) const u8 {
    if (len == 0) return Error.MapFailed;
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0) catch Error.MapFailed;
}

pub fn unmap(m: []align(page) const u8) void {
    std.posix.munmap(m);
}

fn openAnon(len: usize) Error!std.posix.fd_t {
    if (comptime builtin.os.tag == .linux) {
        const fd = std.posix.memfd_create("gist-emit", std.os.linux.MFD.ALLOW_SEALING) catch return Error.ShmFailed;
        errdefer _ = std.c.close(fd);
        if (std.c.ftruncate(fd, @intCast(len)) != 0) return Error.ShmFailed;
        return fd;
    } else if (comptime builtin.os.tag.isDarwin()) {
        var namebuf: [32]u8 = undefined;
        const seq = darwin_seq.fetchAdd(1, .monotonic);
        const pid: u32 = @bitCast(std.c.getpid());
        const name = std.fmt.bufPrintZ(&namebuf, "/gist.{x}.{x}", .{ pid, seq }) catch return Error.ShmFailed;
        const oflag: c_int = @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
        const fd = shm_open(name.ptr, oflag, 0o600);
        if (fd < 0) return Error.ShmFailed;
        errdefer _ = std.c.close(fd);
        // Unlink at once: the fd stays valid, but no name survives for another
        // process to reach and the object is reclaimed when the last fd closes.
        _ = std.c.shm_unlink(name.ptr);
        if (std.c.ftruncate(fd, @intCast(len)) != 0) return Error.ShmFailed;
        return fd;
    } else return Error.Unsupported;
}

test "round-trip: daemon writes, reader maps identical bytes" {
    if (!supported) return error.SkipZigTest;
    const payload = "path/to/file.zig:42:const x = 1;\n" ** 4096; // ~135 KB
    var buf = try Buffer.create(payload.len);
    defer buf.close();
    @memcpy(buf.map[0..payload.len], payload);
    buf.freeze();
    const view = try mapReadonly(buf.fd, payload.len);
    defer unmap(view);
    try std.testing.expectEqualSlices(u8, payload, view[0..payload.len]);
}

test "zero length is unsupported (stays on chunk frames)" {
    try std.testing.expectError(Error.Unsupported, Buffer.create(0));
}
