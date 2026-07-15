//! gist resident daemon — `gist serve` (ADR-352 rung 2.5).
//!
//! Holds one `ResidentSession` warm behind a Unix-domain socket so a persistent
//! client answers an eligible query without re-paying the cold subprocess's
//! process + index-mmap + candidate-read startup on every call — the whole
//! reason the warm certificate can post a geomean the cold path never could. It
//! is the transport shell only; the correctness (freshness, parity) lives in the
//! session (`src/session/`).
//!
//! Lifecycle: grab the single-instance lock, build the session, arm the
//! freshness watcher, bind the socket (unlinking a stale one), then a **serial**
//! accept loop — one client's frame loop runs to completion before the next
//! connection is taken. A local single-user daemon has no fan-out to serve, and
//! serial accept keeps the session's mutation overlay single-threaded without a
//! per-connection thread to join on teardown (the concurrency-safety of the
//! engine itself is proven directly in `resident` under `std.Thread`, not
//! through the socket). Every failure is fail-open toward cold: a
//! declined/again-errored query costs the client a fallback subprocess, never a
//! wrong answer.
//!
//! Two self-management properties make the daemon safe to auto-spawn (the cold
//! CLI forks one on the first eligible miss, so ~10 coworker CLIs may each race
//! to start one):
//!
//!   * **Single-instance** — before touching the socket, `run` takes an advisory
//!     `flock` on `<socket>.lock`. Exactly one racer wins; the losers return at
//!     once *without* unlinking the winner's live socket. The lock is taken
//!     first precisely so a loser never runs the stale-socket cleanup below.
//!   * **Idle-TTL self-exit** — the accept loop `poll`s with a timeout; if no
//!     client dials within `idle_ttl_ms` the daemon exits so an abandoned
//!     session doesn't pin RAM forever. The next query just re-spawns it.
//!
//! An explicit `shutdown` frame also stops the loop; a client merely
//! disconnecting just frees the daemon for the next one.

const std = @import("std");
const resident = @import("../../session/resident.zig");
const protocol = @import("../../session/protocol.zig");
const watch = @import("../../session/watch.zig");
const corpus = @import("../../corpus/corpus.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

extern "c" fn flock(fd: std.posix.fd_t, operation: c_int) c_int;
extern "c" fn close(fd: std.posix.fd_t) c_int;

/// What a completed connection tells the accept loop to do next.
const After = enum { next, stop };

/// Idle window with zero connections before a warm daemon self-exits: the
/// resident index/corpus stops earning its RAM once nobody is querying, and a
/// fresh query re-spawns one in the background anyway (see `client/spawn.zig`).
const idle_ttl_ms: i32 = 10 * 60 * 1000;

/// Serve `roots` warm on `socket_path` until it goes idle, a client sends
/// `shutdown`, or the listener dies. Owns the session + socket for its whole
/// lifetime. Returns immediately (no-op) if another daemon already holds the
/// single-instance lock, so it is safe to auto-spawn or run twice.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket_path: []const u8) !void {
    // Singleton FIRST — before any socket mutation — so a losing racer never
    // unlinks the winner's live socket during the stale-socket cleanup below.
    const lock_fd = acquireSingleton(io, socket_path) orelse {
        std.debug.print("gist serve: another daemon already warm on {s}\n", .{socket_path});
        return;
    };
    defer _ = close(lock_fd); // closing releases the advisory flock

    var session = try ResidentSession.init(gpa, io, roots);
    defer session.deinit();
    session.daemon_gen = @bitCast(@as(i64, @truncate(std.Io.Clock.now(.real, io).nanoseconds)));

    var watcher = watch.Watcher.init(gpa, io, &session);
    watcher.start();
    defer watcher.stop();

    if (std.fs.path.dirnamePosix(socket_path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    Dir.cwd().deleteFile(io, socket_path) catch {}; // clear a stale socket from a crashed daemon
    const ua = try net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    defer Dir.cwd().deleteFile(io, socket_path) catch {};

    std.debug.print("gist serve: warm on {s} ({d} roots)\n", .{ socket_path, roots.len });

    var pfd = [_]std.posix.pollfd{.{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    var session_gen: u64 = 0;
    while (true) {
        // Wait for a pending connection, but no longer than the idle TTL: a
        // timeout (ready == 0) means the daemon has gone cold and self-exits.
        const ready = std.posix.poll(&pfd, idle_ttl_ms) catch break;
        if (ready == 0) break;
        const stream = server.accept(io) catch break;
        session_gen +%= 1;
        const after = serveConn(&session, gpa, io, stream.socket.handle, session_gen);
        stream.close(io);
        if (after == .stop) break;
    }
}

/// Take the advisory single-instance lock on `<socket_path>.lock`. Returns the
/// held fd (keep it open for the daemon's lifetime — closing releases the lock),
/// or `null` if another daemon owns it or the lock file can't be opened (in
/// which case the caller declines to start rather than fight over the socket).
fn acquireSingleton(io: std.Io, socket_path: []const u8) ?std.posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{socket_path}) catch return null;
    if (std.fs.path.dirnamePosix(lock_path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    const fd = std.posix.openat(std.posix.AT.FDCWD, lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch return null;
    if (flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        _ = close(fd); // held by a live daemon → this racer stands down
        return null;
    }
    return fd;
}

/// Drive one client's frame loop to completion. Returns `.stop` only on an
/// explicit `shutdown` opcode; a closed/again-errored connection is `.next`.
fn serveConn(session: *ResidentSession, gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, session_gen: u64) After {
    while (true) {
        var frame = protocol.recvFrame(gpa, fd) catch return .next; // closed/oversized/bad → drop peer
        defer frame.deinit();
        switch (frame.op) {
            .hello, .status => sendReady(session, gpa, fd, session_gen) catch return .next,
            .ping => protocol.sendFrame(gpa, fd, .pong, "") catch return .next,
            .query => handleQuery(session, gpa, io, fd, frame.payload()) catch return .next,
            .shutdown => return .stop,
            // Anything server→client, or an unknown verb, is not a request: refuse
            // it as decline so a confused client falls back cold rather than hangs.
            else => protocol.sendFrame(gpa, fd, .decline, "") catch return .next,
        }
    }
}

fn sendReady(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, session_gen: u64) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeReady(&buf, gpa, session.daemon_gen, session_gen, session.index_gen);
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// Decode + answer one query. A malformed frame or an unservable request
/// (`error.Stale` from a lost freshness anchor / rebuilt index, OOM) comes back
/// as `decline` — the client re-runs it on the certified cold path.
fn handleQuery(session: *ResidentSession, gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, payload: []const u8) !void {
    _ = io;
    const req = protocol.decodeQuery(payload) catch
        return protocol.sendFrame(gpa, fd, .decline, "");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = session.query(arena.allocator(), req) catch
        return protocol.sendFrame(gpa, fd, .decline, "");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    switch (result.mode) {
        .files => try protocol.encodeFiles(&buf, gpa, result.files),
        .count => try protocol.encodeCount(&buf, gpa, result.count),
    }
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// The socket path a daemon binds / a client dials: `$GIST_SESSION_SOCK` when
/// set, else the per-repo default beside the index (`corpus.out_dir`). The
/// returned slice is gpa-owned.
pub fn socketPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("GIST_SESSION_SOCK")) |p| return gpa.dupe(u8, p);
    return std.fmt.allocPrint(gpa, "{s}/gistd.sock", .{corpus.out_dir});
}
