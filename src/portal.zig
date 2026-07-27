//! The one doorway from a directory handle to bytes — and the only place in the
//! package where a POSIX/Windows difference is stated.
//!
//! gist's descent is *handle-relative*: a worker opens a directory once, then
//! resolves each child against that open handle rather than re-walking an
//! absolute path per entry. On POSIX that is `openat(dirfd, name)`; the kernel
//! resolves one component instead of the whole prefix, which is most of why the
//! walk keeps up with `find`. Windows has no `openat`, but it has the same
//! *property*: `NtCreateFile` takes a `RootDirectory` handle and resolves
//! `ObjectName` against it. So the port is not a different algorithm — it is the
//! same algorithm spelled through a different syscall, and this file is where
//! the spelling changes.
//!
//! **Why a seam and not a branch per call site.** There are ~20 of these calls
//! spread across the corpus walk, the index loaders, and the cold engine's
//! swarm. A `builtin.os.tag` test at each one would put the platform question in
//! twenty places and guarantee that the twenty-first is written without it. Here
//! the question is asked once per primitive, `comptime`, exactly as
//! `primitives/bits.zig::laneMask` asks the endianness question once for the
//! whole matcher. Call sites keep POSIX shape and read identically on both
//! platforms.
//!
//! **What is genuinely different, and honestly so.** `map` is a demand-paged
//! `mmap` on POSIX and an eager whole-file read into `VirtualAlloc` memory on
//! Windows: the interface (a page-aligned read-only view whose lifetime is
//! independent of the handle) is preserved, the mechanism is not. That costs
//! Windows the "OS faults in only the pages you touch" property — a real
//! performance difference, not a correctness one, and it is why a Windows row in
//! `bench/portable/` is never presented as evidence about throughput.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const w = std.os.windows;

/// An open file or directory. Already portable: `std.posix.fd_t` is `HANDLE` on
/// Windows and `i32` elsewhere, so the descent's plumbing needs no rewrite.
pub const Handle = std.posix.fd_t;

/// Whether this platform can host the resident session (`gist serve`).
///
/// The warm tier hands a *file descriptor* to another process through an
/// `SCM_RIGHTS` control message on a unix socket, and arbitrates single-daemon
/// ownership with `flock(2)`. Windows has neither primitive; the equivalent would
/// be a named pipe plus handle duplication, which is a different protocol rather
/// than a different spelling — so it is out of this seam's remit.
///
/// Declining costs correctness nothing. The resident session is *defined* as an
/// optimization over the cold path (`bench/portable/README.md`), every warm
/// answer is required to be byte-identical to the cold one, and a client that
/// cannot reach a daemon already falls back to cold within its dial deadline. On
/// Windows that fallback is simply the only path.
pub const resident_sessions = !windows;

/// A page-aligned view of a whole file. Mutable-typed to match what
/// `std.posix.mmap` hands back (so callers keep coercing it to their own `const`
/// aliases exactly as before, and `advise` can still take it); the *mapping* is
/// read-only by virtue of how it was opened.
pub const Mapping = []align(std.heap.page_size_min) u8;

// Deliberately std's own sets, not a private taxonomy. `posix.OpenError` is
// `Io.File.OpenError || WouldBlock` and is declared for every target, while the
// Windows opener already returns `Io.File.OpenError` — so both arms speak the
// same errors and no caller's `catch |e| switch (e)` changes meaning when it
// moves onto this seam. A seam that renamed the errors would have made every
// call site a semantic edit instead of a one-token one.
pub const OpenError = std.posix.OpenError;
pub const ReadError = std.posix.ReadError;
pub const MapError = std.posix.MMapError;

/// The handle meaning "resolve against the current working directory".
///
/// `std.Io.Dir.cwd()` already *is* this fork upstream — `AT.FDCWD` on POSIX, the
/// PEB's `CurrentDirectory` handle on Windows — so this borrows it rather than
/// restating it, and stays comptime-foldable on POSIX.
pub inline fn cwd() Handle {
    return std.Io.Dir.cwd().handle;
}

/// Open a file for reading, resolved against `dir`.
pub fn openFile(dir: Handle, path: []const u8) OpenError!Handle {
    if (!windows) return std.posix.openat(dir, path, .{ .ACCMODE = .RDONLY }, 0);
    return ntOpen(dir, path, .{});
}

/// Open anything — file or directory — for reading, resolved against `dir`.
/// `follow_symlinks = false` inspects the link itself, which is what a walk that
/// treats a symlink as its own entry needs.
pub fn openPath(dir: Handle, path: []const u8, opts: struct { follow_symlinks: bool = true }) OpenError!Handle {
    if (!windows) {
        return std.posix.openat(dir, path, .{
            .ACCMODE = .RDONLY,
            .NOFOLLOW = !opts.follow_symlinks,
        }, 0);
    }
    return ntOpen(dir, path, .{ .allow_directory = true, .follow_symlinks = opts.follow_symlinks });
}

/// Open a directory for reading + iteration, resolved against `dir`.
pub fn openDir(dir: Handle, path: []const u8) OpenError!Handle {
    if (!windows) return std.posix.openat(dir, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    // `allow_directory` is what distinguishes the two on Windows: the same call
    // with `NON_DIRECTORY_FILE` cleared is the moral equivalent of `O_DIRECTORY`.
    return ntOpen(dir, path, .{ .allow_directory = true });
}

/// Release a handle. Infallible by contract: a close error is unactionable at
/// every call site in the walk, and losing the handle is not an option.
pub fn close(h: Handle) void {
    if (windows) return w.CloseHandle(h);
    _ = std.posix.system.close(h);
}

/// Read up to `buf.len` bytes at the handle's current offset. 0 means EOF.
pub fn read(h: Handle, buf: []u8) ReadError!usize {
    if (!windows) return std.posix.read(h, buf);
    if (buf.len == 0) return 0;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtReadFile(
        h,
        null, // event
        null, // APC routine
        null, // APC context
        &iosb,
        buf.ptr,
        @intCast(@min(buf.len, std.math.maxInt(u32))),
        null, // byte offset: use the handle's own file pointer, like `read(2)`
        null, // key
    );
    return switch (status) {
        .SUCCESS => @intCast(iosb.Information),
        .END_OF_FILE => 0,
        // Deferred to std's own NTSTATUS reporter rather than named here: it is
        // the Win32 twin of `unexpectedErrno`, which is what the POSIX arm's
        // `Unexpected` already comes from, and it logs the status under a safe
        // build instead of collapsing every rare failure into a bare name.
        else => w.unexpectedStatus(status),
    };
}

/// Is `h` readable within `timeout_ms`? Used only to bound the one pathological
/// case a blocking read cannot escape: a socket peer that never writes and never
/// closes.
///
/// Windows cannot reach that case — a unix-domain socket cannot be this process's
/// stdin there, so `inode`'s Windows leg never classifies stdin as `.socket` and
/// this is never consulted. It reports "ready" rather than growing a
/// `WaitForSingleObject` path for a caller that does not exist.
pub fn readable(h: Handle, timeout_ms: i32) bool {
    if (comptime !windows) return pollReadable(h, timeout_ms);
    return true;
}

fn pollReadable(h: Handle, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = h, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    // Only IN counts. A bare HUP/ERR must not read as "a frame arrived" — that
    // would skip a deadline and race a closing peer. A peer that closed after
    // writing nothing still sets IN (the read returns 0), so EOF is not lost.
    return n > 0 and fds[0].revents & std.posix.POLL.IN != 0;
}

/// The canonical, symlink-resolved spelling of `path` into `buf`, or null when
/// the path cannot be resolved. `buf` must outlive the result.
///
/// Windows has no `realpath(3)`. It has the same *fact* in two pieces: open the
/// object, then ask the object manager what it opened — which is what
/// `GetFinalPathNameByHandle` does, symlinks and junctions already followed. Its
/// `\\?\` long-path prefix is stripped so callers compare the spellings they were
/// given. If the open is refused (a permission the lexical answer does not need),
/// it degrades to `GetFullPathName` — an absolute path that folds `.`/`..` but
/// resolves no links. The walk's symlink-loop guard is layered against exactly
/// that case: its depth cap is documented as covering "a platform where
/// `realpath(3)` can't resolve a leg".
pub fn realpath(path: [*:0]const u8, buf: []u8) ?[:0]const u8 {
    std.debug.assert(buf.len >= max_path);
    if (comptime !windows) return std.mem.span(std.c.realpath(path, buf.ptr) orelse return null);
    if (openPath(cwd(), std.mem.span(path), .{}) catch null) |h| {
        defer close(h);
        const n = GetFinalPathNameByHandleA(h, buf.ptr, @intCast(buf.len - 1), 0);
        if (n > 0 and n < buf.len) {
            buf[n] = 0;
            const full = buf[0..n :0];
            // `\\?\C:\x` and `C:\x` name one file; hand back the spelling callers
            // hold. A UNC final path (`\\?\UNC\…`) has no short form, so it stays.
            if (std.mem.startsWith(u8, full, "\\\\?\\") and !std.mem.startsWith(u8, full, "\\\\?\\UNC\\")) {
                std.mem.copyForwards(u8, buf[0 .. n - 4], full[4..]);
                buf[n - 4] = 0;
                return buf[0 .. n - 4 :0];
            }
            return full;
        }
    }
    const n = GetFullPathNameA(path, @intCast(buf.len - 1), buf.ptr, null);
    if (n == 0 or n >= buf.len) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// The smallest buffer `realpath` will write an answer into. POSIX names its own
/// ceiling; Windows' `\\?\` form can in principle reach 32767 bytes, but a
/// buffer that size on every walk frame is not worth a path nobody has — a longer
/// final path declines (null) rather than overflowing.
pub const max_path = if (windows) 4096 else std.c.PATH_MAX;

/// Wall-clock seconds since the Unix epoch, or 0 when the clock refuses to
/// answer. POSIX reads the libc clock; Windows reads the FILETIME counter and
/// subtracts the 1601→1970 offset, because there is no `clock_gettime` there.
pub fn wallSeconds() u64 {
    if (comptime !windows) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
        return @intCast(@max(0, ts.sec));
    }
    var ft: w.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime; // 100 ns
    const epoch_offset_s = 11_644_473_600; // 1601-01-01 → 1970-01-01
    const secs = ticks / 10_000_000;
    return if (secs > epoch_offset_s) secs - epoch_offset_s else 0;
}

/// The largest hostname either platform will hand back. Windows caps a NetBIOS
/// computer name far below POSIX's limit, but a single ceiling keeps the callers'
/// stack buffers one shape.
pub const host_name_max = if (windows) 256 else std.posix.HOST_NAME_MAX;

/// This machine's own name, or null when the kernel declines. Callers treat a
/// null as "no authority" rather than fatal.
pub fn hostName(buf: *[host_name_max]u8) ?[]const u8 {
    if (comptime !windows) return std.posix.gethostname(buf) catch null;
    var len: u32 = buf.len;
    if (GetComputerNameA(buf, &len) == 0) return null;
    return buf[0..len];
}

/// What sort of device a handle names, which is the question POSIX answers with
/// `S_IFMT` and Windows with `GetFileType`. Only meaningful on Windows; the POSIX
/// legs read the mode bits they already have.
pub const Device = enum { disk, pipe, character, unknown };

/// Classify an open handle by device type (Windows only — POSIX callers get the
/// same fact from `stat`'s mode bits and never need this).
pub fn device(h: Handle) Device {
    if (!windows) return .unknown;
    return switch (GetFileType(h)) {
        0x0001 => .disk,
        0x0002 => .character,
        0x0003 => .pipe,
        else => .unknown,
    };
}

/// An iterator over the process's arguments.
///
/// POSIX hands a program a pre-split `argv`; Windows hands it one command-line
/// string that must be *parsed* — and therefore allocated — before it is a list of
/// arguments at all. std states this outright by refusing `Iterator.init` on
/// Windows, so the allocator is threaded to the two callers that need one rather
/// than a Windows-shaped branch appearing at each of them.
pub fn argsIterator(a: std.process.Args, gpa: std.mem.Allocator) !std.process.Args.Iterator {
    if (windows) return std.process.Args.Iterator.initAllocator(a, gpa);
    return std.process.Args.Iterator.init(a);
}

/// The process's stdin.
pub inline fn stdin() Handle {
    if (windows) return w.peb().ProcessParameters.hStdInput;
    return std.posix.STDIN_FILENO;
}

/// The process's stdout. A handle on Windows, the constant 1 elsewhere — so a
/// caller writing bytes out never has to know which.
pub inline fn stdout() Handle {
    if (windows) return w.peb().ProcessParameters.hStdOutput;
    return std.posix.STDOUT_FILENO;
}

/// One raw write attempt. Returns bytes written, or a negative count for the two
/// conditions the emit path distinguishes — a closed pipe and an interrupted
/// call — matching the `write(2)` contract callers already branch on.
pub fn writeOnce(h: Handle, bytes: []const u8) isize {
    if (!windows) return std.posix.system.write(h, bytes.ptr, bytes.len);
    if (bytes.len == 0) return 0;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    return switch (w.ntdll.NtWriteFile(
        h,
        null,
        null,
        null,
        &iosb,
        bytes.ptr,
        @intCast(@min(bytes.len, std.math.maxInt(u32))),
        null,
        null,
    )) {
        .SUCCESS => @intCast(iosb.Information),
        else => -1,
    };
}

/// A whole-file read-only view. The view outlives `h`, so callers may close the
/// handle immediately — true of `mmap` by definition and arranged for on Windows
/// by copying eagerly (see the module header for what that costs).
pub fn map(h: Handle, len: usize) MapError!Mapping {
    if (!windows) return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, h, 0);
    const bytes = (VirtualAlloc(null, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse
        return error.OutOfMemory)[0..len];
    // A short read means the file shrank between the caller's `stat` and here.
    // The view stays `len` bytes, with the lost tail reading as the NULs
    // `MEM_COMMIT` already zeroed it to — which is what POSIX promises for the
    // same race, minus the SIGBUS it delivers on touching the vanished pages.
    // Failing instead would need a fault name for a condition every caller
    // already handles by falling back, and would be stricter than the arm this
    // one exists to imitate.
    var filled: usize = 0;
    while (filled < len) {
        const n = read(h, bytes[filled..]) catch break;
        if (n == 0) break;
        filled += n;
    }
    return bytes;
}

/// Release a `map` view.
pub fn unmap(m: []align(std.heap.page_size_min) const u8) void {
    if (!windows) return std.posix.munmap(m);
    // `MEM_RELEASE` frees the whole reservation and requires the size to be 0.
    _ = VirtualFree(m.ptr, 0, MEM_RELEASE);
}

/// How the caller intends to touch a mapping. Advice is best-effort everywhere,
/// which is what lets the Windows arm decline without changing any outcome: the
/// eager read there has already paid the fault cost these hints exist to batch.
pub const Advice = enum { sequential, will_need };

/// Best-effort pager advice over a `map` view. Returns the failure rather than
/// swallowing it, so callers keep reporting it through their own spare-fault
/// channel exactly as they did when they called `madvise` directly.
pub fn advise(m: Mapping, hint: Advice) std.posix.MadviseError!void {
    if (windows) return;
    return std.posix.madvise(m.ptr, m.len, switch (hint) {
        .sequential => std.posix.MADV.SEQUENTIAL,
        .will_need => std.posix.MADV.WILLNEED,
    });
}

// ── the Windows arm ─────────────────────────────────────────────────────────

/// `NtCreateFile` with `RootDirectory = dir`, which is the Win32 shape of
/// `openat`. The NTSTATUS decoding is std's, not a second copy of Windows' error
/// taxonomy living here: this file carries the *seam*, nothing more.
fn ntOpen(dir: Handle, path: []const u8, opts: std.Io.Dir.OpenFileOptions) OpenError!Handle {
    const T = std.Io.Threaded;
    const space = try T.sliceToPrefixedFileW(dir, path, .{});
    const wide = space.span();
    // An absolute path must not *also* be resolved against a root handle, or the
    // object manager sees `C:\…` nested inside a directory and fails the open.
    const root: ?w.HANDLE = if (std.fs.path.isAbsoluteWindowsWtf16(wide)) null else dir;
    return (try T.dirOpenFileWtf16(root, wide, opts)).handle;
}

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

// Declared here rather than taken from `std.os.windows`, which stopped
// re-exporting the memory API in 0.16. Two externs in the seam that owns the
// difference beats reaching into std's internals from the walk.
//
// Both are declared in the *byte* types the one caller actually wants rather
// than Win32's `LPVOID`, because `VirtualAlloc` returns page-aligned memory by
// definition and `VirtualFree` only reads the pointer's value. Stating that in
// the signature is what lets `map`/`unmap` be cast-free: a `@ptrCast` there
// would be re-asserting, unchecked and at every call, a fact the ABI already
// guarantees once here.
extern "kernel32" fn VirtualAlloc(
    ?*anyopaque,
    usize,
    u32,
    u32,
) callconv(.winapi) ?[*]align(std.heap.page_size_min) u8;
extern "kernel32" fn VirtualFree(
    [*]align(std.heap.page_size_min) const u8,
    usize,
    u32,
) callconv(.winapi) c_int;
extern "kernel32" fn GetFileType(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetSystemTimeAsFileTime(*w.FILETIME) callconv(.winapi) void;
extern "kernel32" fn GetComputerNameA([*]u8, *u32) callconv(.winapi) c_int;
extern "kernel32" fn GetFinalPathNameByHandleA(w.HANDLE, [*]u8, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFullPathNameA([*:0]const u8, u32, [*]u8, ?*?[*:0]u8) callconv(.winapi) u32;
