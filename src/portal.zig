//! The one doorway from a directory handle to bytes — and the only place in the
//! package where a POSIX/Windows difference is stated.
//!
//! The descent here is *handle-relative*: a worker opens a directory once, then
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
//! **`map` is the same property on both, not the same call.** POSIX gets
//! `mmap(PROT_READ, MAP_PRIVATE)`; Windows gets an NT section over the file with
//! one view of it, the section handle dropped immediately. Both are demand-paged
//! and both outlive the handle they were made from, which is what the callers
//! actually depend on: only the pages a scan touches are read, and a sharded scan
//! faults its ranges in parallel. (This arm began as an eager whole-file read into
//! `VirtualAlloc` memory — interface preserved, property lost. That is what the
//! section mapping replaced, and it is why a Windows row in `bench/portable/` is
//! now admissible as throughput evidence.)
//!
//! **What is still genuinely different, and honestly so.** `advise`'s
//! `sequential` hint has no view-level spelling on NT — the streaming-read
//! expectation is a flag on the *open* there, decided before this seam sees a
//! handle — so it declines rather than being faked. `will_need`, which is where
//! the measured win lives, ports exactly onto `PrefetchVirtualMemory`.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const w = std.os.windows;

/// An open file or directory. Already portable: `std.posix.fd_t` is `HANDLE` on
/// Windows and `i32` elsewhere, so the descent's plumbing needs no rewrite.
pub const Handle = std.posix.fd_t;

/// The handle value that names nothing. POSIX spells it `-1` because a
/// descriptor is a small integer; Windows spells it a sentinel *pointer*,
/// because a handle is one. That difference is invisible until something wants
/// to say "no handle" as a literal — a test asserting the refusal path, a
/// zero-initialized slot — at which point `-1` stops compiling on one platform
/// and this constant is what it should have said instead.
pub const invalid_handle: Handle = if (windows) w.INVALID_HANDLE_VALUE else -1;

/// Whether this platform can host the resident session (the warm daemon).
///
/// Everywhere, now — including Windows, whose `AF_UNIX` arrived in Windows 10
/// 1803 and which the kernels here therefore declare as their floor
/// (`_buildkit/build.zig`'s `windowsFloor`, restated by irregex's own
/// `check-windows` triples). That floor is load-bearing rather than tidy:
/// `std.Io.net.has_unix_sockets` is a comptime test against the DECLARED
/// minimum, so a target left at Zig's default `win10` compiles std's unix arm
/// out and every local-socket call fails before reaching a kernel that would
/// have answered it.
///
/// So the transport is the same protocol in a different spelling after all —
/// same socket family, same `[len][op][payload]` frames, same one-shot
/// request/response — and the four things that genuinely differ each got a seam
/// rather than a second protocol: the readiness wait and its wakeup
/// (`conduit/vigil.zig` — AFD's `IOCTL_AFD_POLL` where POSIX has `poll(2)`), the
/// byte I/O (`conduit/wire.zig` rides `std.Io`'s socket vtable there and keeps
/// its raw `sendto`/`read` here), single-daemon arbitration (an exclusive share
/// mode where POSIX has `flock(2)`), and the detached spawn
/// (`CreateProcessW`/`DETACHED_PROCESS` where POSIX forks).
///
/// The one capability that stayed POSIX-only is descriptor passing —
/// `fd_passing` below — and it is an optimization *within* the optimization.
pub const resident_sessions = if (windows) std.Io.net.has_unix_sockets else true;

/// Whether one process can hand an open descriptor to another over the session
/// socket, which is what lets a large answer arrive as shared memory rather than
/// as streamed bytes (`conduit/shm.zig`, the `chunk_fd` response).
///
/// POSIX passes it as an `SCM_RIGHTS` control message on the socket itself — the
/// descriptor rides *with* a byte of the frame, so the receiver needs no separate
/// channel and no permission to reach into the sender. Windows has no such thing:
/// `DuplicateHandle` writes a handle value into a named target *process*, so the
/// sender must first learn the peer's PID, open it with `PROCESS_DUP_HANDLE`, and
/// then ship the resulting integer through a frame the receiver trusts. That is a
/// different protocol with a different trust story, not a different spelling, and
/// it is the one place the port declines rather than translates.
///
/// Declining costs a Windows client only bytes on a socket it was already
/// connected to: `shm.offer` reports `capability_missing`, `wire.sendWithFd`
/// answers `false`, and the daemon falls back to the `chunk` frames every peer
/// that never advertised fd transport already receives. The answer is identical.
pub const fd_passing = resident_sessions and !windows;

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

/// Can a read resolve within `timeout_ms`, including EOF or a read error? Used
/// only for an explicitly requested first-byte deadline; source classification
/// never polls. A negative timeout is POSIX's unbounded wait.
///
/// Windows keeps its existing blocking-read behavior: this POSIX readiness
/// probe does not enforce a deadline there. Descriptor admission is identical.
///
/// Not the same question as the daemon's `conduit/vigil.zig`, which is why both
/// exist: this one is asked of *stdin*, whatever the shell handed us, while
/// vigil's is asked of local sockets it opened itself. On Windows those need
/// different mechanisms outright — AFD can answer for a socket and knows nothing
/// about a pipe — so a single primitive would have to be the union of the two,
/// and neither caller wants the other's half.
pub fn readable(h: Handle, timeout_ms: i32) bool {
    if (comptime !windows) return pollReadable(h, timeout_ms);
    return true;
}

fn pollReadable(h: Handle, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = h, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    // Empty pipes can report HUP alone. Let the actual read distinguish EOF,
    // buffered bytes and errors instead of treating absence of IN as silence.
    const ready = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
    return n > 0 and fds[0].revents & ready != 0;
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
///
/// **The answer is in this package's separator, not the platform's**, for the
/// same reason `corpus/scope/paths.zig::slashed` normalizes a walker path: every
/// consumer of a canonical path here treats it as a KEY, and those keys are
/// `/`-spelled by declared design. They are not merely more convenient that
/// way — they are parsed that way. The warm session's delta resolver locates a
/// path inside its root by testing `path[root.len] == '/'` and then splits the
/// remainder on `'/'` (`reconcile/delta.zig::keyFor`, `classify`); the `-L`
/// cycle guard counts `'/'` to name the offending ancestor
/// (`exec/cold/quarry/walk.zig::loopAncestor`).
/// Handed `C:\repo\src\x.zig`, every one of those silently answered "not under
/// this root" — so on Windows the resident session's scoped reconcile degraded to
/// a full walk on every query, and `-L` could not name a loop. Normalizing at
/// this seam fixes both at the source rather than teaching each consumer a second
/// spelling.
///
/// A UNC long form (`\\?\UNC\…`) is the one shape left alone. Its prefix must be
/// backslashes verbatim or the object manager parses `//?/` as a host named `?`,
/// so slashing it would produce a path that no longer opens. Such a root simply
/// keeps the pre-existing behavior (no key match, every query reconciles fully),
/// which is the fail-closed direction.
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
            // hold.
            if (std.mem.startsWith(u8, full, "\\\\?\\")) {
                if (std.mem.startsWith(u8, full, "\\\\?\\UNC\\")) return full;
                std.mem.copyForwards(u8, buf[0 .. n - 4], full[4..]);
                buf[n - 4] = 0;
                return slashed(buf[0 .. n - 4 :0]);
            }
            return slashed(full);
        }
    }
    const n = GetFullPathNameA(path, @intCast(buf.len - 1), buf.ptr, null);
    if (n == 0 or n >= buf.len) return null;
    buf[n] = 0;
    return slashed(buf[0..n :0]);
}

/// `p` rewritten in place to this package's separator. Spelled here rather than
/// borrowed from `corpus/scope/paths.zig::slashInPlace` because that module
/// imports this one; one `replaceScalar` is a cheaper price than the import
/// cycle.
fn slashed(p: [:0]u8) [:0]const u8 {
    if (comptime std.fs.path.sep != '/') std.mem.replaceScalar(u8, p, std.fs.path.sep, '/');
    return p;
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

/// This process's own id — the token a fixture path or a shm name mixes in so two
/// concurrent runs of the same binary cannot collide on it.
///
/// `getpid(2)` is POSIX's spelling and `GetCurrentProcessId` is Win32's. They
/// agree on the *fact* and disagree on the type — Windows has no `pid_t`, and
/// std's Windows `getpid` shim is typed as a handle rather than a number, so a
/// caller that formats the POSIX one with `{d}` stops compiling there. Widened to
/// `u32` once here so every caller formats the same type.
pub fn processId() u32 {
    if (comptime windows) return GetCurrentProcessId();
    return @bitCast(std.c.getpid());
}

/// The high-water mark of this process's resident set, in bytes — or 0 when the
/// platform declines to answer. This is the number a memory budget is actually
/// judged by: a spike the allocator has since given back is still a spike the
/// machine had to find pages for, and it is exactly what `/usr/bin/time -l`
/// prints as `maximum resident set size`. Reading it in-process is what lets a
/// build attribute its own peak to a phase instead of reporting one total and
/// leaving the cause to be guessed at.
///
/// The unit is the one genuinely unportable thing about `getrusage(2)`: Darwin
/// and the BSDs report `ru_maxrss` in BYTES, Linux in KIBIBYTES. POSIX declines
/// to specify it, so neither is wrong — but a caller that formatted the raw
/// field would be off by 1024x on one of the two platforms with nothing in the
/// number to say which. Normalizing once, here, is the whole reason this is a
/// seam rather than an inline call.
///
/// Windows keeps the fact and moves it: the peak working set is a field of
/// `PROCESS_MEMORY_COUNTERS`, not of a resource-usage struct. `K32GetProcessMemoryInfo`
/// is the kernel32-resident spelling (Windows 7+), so this needs no psapi link.
pub fn peakResident() u64 {
    if (comptime windows) {
        var counters: ProcessMemoryCounters = undefined;
        counters.cb = @sizeOf(ProcessMemoryCounters);
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) return 0;
        return counters.peak_working_set_size;
    }
    const raw: u64 = @intCast(@max(std.posix.getrusage(std.posix.rusage.SELF).maxrss, 0));
    return if (comptime builtin.os.tag == .linux) raw *| 1024 else raw;
}

/// The directory this platform hands out for scratch files, without its trailing
/// separator, written into `buf` (which must outlive the result).
///
/// Both platforms answer from the environment, and both already have a settled
/// cascade for it — so this defers to each rather than inventing a third.
/// POSIX reads `TMPDIR` and falls back to `/tmp`. Windows has no `/tmp` at all
/// and its cascade is four deep (`TMP` → `TEMP` → `USERPROFILE` → the Windows
/// directory), which `GetTempPath` already *is*; reimplementing it here would be
/// a second, worse copy of a convention the OS ships.
///
/// The trailing separator is stripped because only one platform adds one, and a
/// caller joining `"{s}/{s}"` should not have to know which.
pub fn scratchDir(buf: *[max_path]u8) []const u8 {
    if (comptime !windows) {
        const dir = if (std.c.getenv("TMPDIR")) |v| std.mem.span(v) else "/tmp";
        return std.mem.trimEnd(u8, if (dir.len == 0) "/tmp" else dir, "/");
    }
    const n = GetTempPathA(@intCast(buf.len), buf);
    if (n == 0 or n >= buf.len) return "C:\\Windows\\Temp";
    return std.mem.trimEnd(u8, buf[0..n], "\\/");
}

/// How many logical CPUs this process may actually run threads on. Signature and
/// error set are `std.Thread.getCpuCount`'s deliberately, so every call site keeps
/// its own `catch <default>` and the only thing that changes is the answer.
///
/// POSIX defers to std outright. Windows cannot, because std reads
/// `peb().NumberOfProcessors` — the count of the process's **primary processor
/// group**, capped at 64. On a machine with more than 64 logical CPUs that is
/// half the machine or less, and every pool sized from it (the parallel walk, the
/// index build, the kinship sweeps, the render fan-out) runs at half width. It is
/// the same defect `std::thread::hardware_concurrency` still has
/// ([microsoft/STL#5453](https://github.com/microsoft/STL/issues/5453)) and that
/// Rust only just repaired for `available_parallelism`
/// ([rust-lang/rust#159511](https://github.com/rust-lang/rust/pull/159511)) — so
/// leaving it would be a measurable loss to ripgrep on exactly the hardware where
/// parallelism matters most.
///
/// The version question is answered by asking about *this process* rather than
/// about the OS build, which is what keeps a `win10_rs4` floor honest. Before
/// Windows 11 a process is confined to one group, so the primary-group count is
/// the correct answer and `ALL_PROCESSOR_GROUPS` would **overcount**; from
/// Windows 11 / Server 2022 a process's affinity spans every group by default, so
/// the total is correct. `GetProcessGroupAffinity` distinguishes those without
/// naming a version: it reports 1 group in the confined case and more than one
/// once the process spans them. A one-element buffer is all that is needed —
/// a multi-group process fails with `ERROR_INSUFFICIENT_BUFFER` and writes the
/// real group count on the way out, every other case leaves the initial 1 — which
/// is why the `BOOL` itself is ignored.
///
/// Fail-open in both directions: a refused query or a nonsense zero falls back to
/// std's answer, so the worst case is the primary-group count this had before.
pub fn cpuCount() std.Thread.CpuCountError!usize {
    if (comptime !windows) return std.Thread.getCpuCount();
    const primary = try std.Thread.getCpuCount();
    var groups: u16 = 1;
    var buf: [1]u16 = undefined;
    _ = GetProcessGroupAffinity(GetCurrentProcess(), &groups, &buf);
    if (groups <= 1) return primary;
    const all = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    return if (all > primary) all else primary;
}

/// How many of this machine's logical CPUs are its FASTEST ones, or null where
/// the platform draws no such distinction. Callers read null as "the machine is
/// symmetric — every core is worth a worker".
///
/// Only Darwin answers, and only on the hardware where it means something:
/// `hw.perflevel0` is the fastest performance level of an asymmetric (big.LITTLE)
/// Apple Silicon package, and the tree does not exist at all on an Intel Mac. The
/// distinction matters to the walk because a pool sized to `cpuCount` puts
/// workers on efficiency cores that then run the same syscall-heavy loop several
/// times slower while still contending for the same kernel locks — measured on an
/// M4 Max (12 P + 4 E) as 2 % less wall time for 62 % more system time.
///
/// Deliberately NOT a general sysctl accessor: the one integer this walk's
/// topology depends on, asked once, so a caller cannot reach through here for a
/// knob nobody has reasoned about.
pub fn performanceCores() ?usize {
    if (comptime builtin.os.tag != .macos) return null;
    var v: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname("hw.perflevel0.logicalcpu", &v, &len, null, 0) != 0) return null;
    if (len != @sizeOf(c_int) or v <= 0) return null;
    return @intCast(v);
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

/// A whole-file read-only view, demand-paged on both platforms. The view outlives
/// `h`, so callers may close the handle immediately — true of `mmap` by
/// definition, and true of an NT section because a mapped view holds its own
/// reference to the section object and the section holds one to the file.
pub fn map(h: Handle, len: usize) MapError!Mapping {
    if (!windows) return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, h, 0);
    return ntMap(h, len);
}

/// Release a `map` view.
pub fn unmap(m: []align(std.heap.page_size_min) const u8) void {
    if (!windows) return std.posix.munmap(m);
    // The section handle was already closed in `ntMap`; dropping the last view
    // is what releases the object, so there is nothing else to close here.
    _ = w.ntdll.NtUnmapViewOfSection(w.current_process, @ptrCast(@constCast(m.ptr)));
}

/// How the caller intends to touch a mapping. Best-effort everywhere: a platform
/// that cannot express one of these declines, and the scan is correct either way
/// — only its fault pattern changes.
pub const Advice = enum { sequential, will_need };

/// Best-effort pager advice over a `map` view. Returns the failure rather than
/// swallowing it, so callers keep reporting it through their own spare-fault
/// channel exactly as they did when they called `madvise` directly.
pub fn advise(m: Mapping, hint: Advice) std.posix.MadviseError!void {
    if (comptime windows) return ntAdvise(m, hint);
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

/// `mmap(PROT_READ, MAP_PRIVATE)` spelled in NT: a section over the file, one
/// view of it, then the section handle dropped — the view survives both it and
/// the caller's file handle, which is the lifetime `map` promises.
///
/// Demand-paged, which is the property the callers are actually buying: a sharded
/// scan faults its ranges in **parallel** off a real mapping
/// (`corpus/read/slurp.zig`), and a query that stops at its first match a few
/// pages in never pays for the rest of the file.
fn ntMap(h: Handle, len: usize) MapError!Mapping {
    // Naming the size instead of passing null ("however big the file is") is what
    // makes a racing truncation *decline*: a read-only section may not exceed its
    // file, so a file that shrank between the caller's `stat` and here fails to
    // create and the caller takes its copying fallback. POSIX cannot express that
    // — it maps what it can and delivers SIGBUS on the vanished pages — so this
    // arm ends up the safer of the two rather than merely equivalent.
    const size: w.LARGE_INTEGER = @intCast(len);
    var section: w.HANDLE = w.INVALID_HANDLE_VALUE;
    switch (w.ntdll.NtCreateSection(
        &section,
        .{ .SPECIFIC = .{ .SECTION = .{ .QUERY = true, .MAP_READ = true } }, .STANDARD = .{ .RIGHTS = .REQUIRED } },
        null,
        &size,
        .{ .READONLY = true },
        // Backed by the file, every page committed. Neither flag prefetches;
        // `SEC_COMMIT` is what "the whole section is addressable" is called, and
        // is the default for a file-backed section either way.
        .{ .COMMIT = true },
        h,
    )) {
        .SUCCESS => {},
        // A device, a pipe, or a filesystem with no section support — the same
        // conditions POSIX reports as ENODEV, and the caller reads it the same way.
        .INVALID_FILE_FOR_SECTION => return error.MemoryMappingNotSupported,
        .ACCESS_DENIED => return error.AccessDenied,
        .FILE_LOCK_CONFLICT => return error.AccessDenied,
        // The 32-bit lane: a file too large to have an address space, which is
        // exactly what POSIX calls ENOMEM here.
        .SECTION_TOO_BIG, .INSUFFICIENT_RESOURCES => return error.OutOfMemory,
        else => |status| return w.unexpectedStatus(status),
    }
    // Safe to drop now, and deliberately dropped *here*: a mapped view keeps its
    // own reference to the section, so `Mapping` stays a plain slice instead of
    // growing a handle field that every caller would have to carry to `unmap`.
    defer w.CloseHandle(section);

    var base: ?[*]align(std.heap.page_size_min) u8 = null;
    var view_len = len;
    switch (w.ntdll.NtMapViewOfSection(
        section,
        w.current_process,
        @ptrCast(&base),
        null,
        0, // commit nothing up front — the whole point is to fault lazily
        null, // from offset 0: `map` is a whole-file view
        &view_len,
        .Unmap, // a child process does not inherit this view
        .{},
        .{ .READONLY = true },
    )) {
        .SUCCESS => {},
        .CONFLICTING_ADDRESSES => return error.MappingAlreadyExists,
        .SECTION_PROTECTION => return error.PermissionDenied,
        .ACCESS_DENIED => return error.AccessDenied,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => return error.OutOfMemory,
        else => |status| return w.unexpectedStatus(status),
    }
    // `view_len` comes back rounded up to a page; the slice stays the caller's
    // length so both platforms hand back exactly the file's bytes.
    return base.?[0..len];
}

/// The Windows half of `advise`.
///
/// `will_need` is `PrefetchVirtualMemory`, which is the same instruction
/// `MADV_WILLNEED` gives a POSIX pager: start the fault-in now, in bulk, instead
/// of one page-cluster per access fault. That is where the measured win in
/// `slurp.mapWhole` actually comes from, so the hint that matters is the one that
/// ports.
///
/// `sequential` has no view-level equivalent and declines rather than being
/// faked. NT expresses "expect a forward streaming read" as a flag on the *open*
/// (`FILE_FLAG_SEQUENTIAL_SCAN`), which is a decision made before this seam sees
/// a handle. Prefetching the whole range instead would quietly reintroduce the
/// eager read this arm was written to delete.
fn ntAdvise(m: Mapping, hint: Advice) std.posix.MadviseError!void {
    if (hint == .sequential) return;
    const range = MemoryRange{ .base = m.ptr, .len = m.len };
    // Failure is "paging in did not happen", which is exactly the condition
    // `MADV_WILLNEED` reports as ENOMEM — so callers' existing `catch` arms read
    // correctly without learning a Windows-shaped error.
    if (PrefetchVirtualMemory(w.current_process, 1, &.{range}, 0) == 0) return error.OutOfMemory;
}

/// `WIN32_MEMORY_RANGE_ENTRY` — one address range for `PrefetchVirtualMemory`.
const MemoryRange = extern struct { base: [*]const u8, len: usize };

/// `PROCESS_MEMORY_COUNTERS` — only the leading `cb` and the peak working set
/// are read, but the whole struct must be declared or the OS writes past it.
const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};

// Declared here rather than taken from `std.os.windows`, which binds the NT
// memory API but not this kernel32 wrapper. It has no public NT equivalent:
// kernel32 implements it over `NtSetInformationVirtualMemory`, which std does
// not declare and Microsoft does not document.
extern "kernel32" fn PrefetchVirtualMemory(
    w.HANDLE,
    usize,
    [*]const MemoryRange,
    u32,
) callconv(.winapi) c_int;
extern "kernel32" fn GetFileType(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTempPathA(u32, [*]u8) callconv(.winapi) u32;
extern "kernel32" fn GetSystemTimeAsFileTime(*w.FILETIME) callconv(.winapi) void;
extern "kernel32" fn GetComputerNameA([*]u8, *u32) callconv(.winapi) c_int;
extern "kernel32" fn GetFinalPathNameByHandleA(w.HANDLE, [*]u8, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFullPathNameA([*:0]const u8, u32, [*]u8, ?*?[*:0]u8) callconv(.winapi) u32;
extern "kernel32" fn K32GetProcessMemoryInfo(w.HANDLE, *ProcessMemoryCounters, u32) callconv(.winapi) c_int;

/// `GetActiveProcessorCount`'s "every group, not just mine" sentinel.
const ALL_PROCESSOR_GROUPS: u16 = 0xffff;

// The processor-group trio, none of which `std.os.windows` binds — it declares no
// group API at all, which is why `std.Thread` reads the PEB's primary-group count
// and stops there. `GetCurrentProcess` is the pseudo-handle constant rather than a
// call, but std exposes it as `w.self_process_handle` only on some versions, so it
// is declared here beside its one caller.
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetActiveProcessorCount(u16) callconv(.winapi) u32;
extern "kernel32" fn GetProcessGroupAffinity(w.HANDLE, *u16, [*]u16) callconv(.winapi) c_int;

test "cpuCount: never narrower than std's answer, never zero" {
    const ours = try cpuCount();
    const stds = try std.Thread.getCpuCount();
    try std.testing.expect(ours >= 1);
    // Every fallback in the Windows arm lands back on std's count, and the group
    // total only replaces it when strictly larger — so widening is the only legal
    // direction. Off Windows the two are the same call.
    try std.testing.expect(ours >= stds);
    if (comptime !windows) try std.testing.expectEqual(stds, ours);
}
