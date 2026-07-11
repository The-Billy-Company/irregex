//! gist `rg` — stdin-stream detection and reading (ripgrep's stdin-search path).
//!
//! Split from `run.zig`: with no PATH args and a readable stdin (pipe / regular
//! file / socket), ripgrep searches the piped bytes as one unnamed source
//! instead of walking the tree. This module answers "is stdin a stream we
//! should search?" (`readable`) and "read it to EOF" (`read`), with a bounded
//! poll guard on the one fd type (a socket) that can hang a blocking `read(2)`
//! forever — unacceptable for an agent-facing tool. A tty or `/dev/null` falls
//! through to the directory walk.

const std = @import("std");
const die = @import("args.zig").die;

/// ripgrep's `is_readable_stdin` (grep/cli): `!is_terminal(fd0) && (is_file ||
/// is_fifo || is_socket)`. We whitelist exactly those three fd types — regular
/// file, FIFO (pipe), and socket — which by construction excludes a tty and a
/// char device (`/dev/null`), so the `is_terminal` guard is subsumed. This is
/// the rule that lets `cmd | rg pat` and `sock_producer | rg pat` search the
/// stream while `rg pat` (bare tty) and `rg pat </dev/null` fall through to the
/// directory walk. The socket case matters for exec APIs that wire fd0 to a
/// socketpair; omitting it silently diverged from rg on piped-socket input.
///
/// Deliberate departure from raw rg parity, narrowed to the one fd type that
/// actually needs it: a SOCKET can be a long-lived control channel that never
/// writes a byte and never closes (seen in the wild — some sandboxed
/// shell/tool-call harnesses wire fd 0 to exactly such a socket). Blocking
/// `read(2)` against that hangs forever, which is unacceptable for an
/// agent-facing tool, so only a socket pays a bounded `poll(2)` readiness
/// check before committing to the stdin path.
///
/// A FIFO is deliberately exempted: it's what every real shell `cmd | gist
/// pat` pipe actually is, and unlike an adversarial socket it has a
/// well-defined lifetime — the kernel signals HUP the moment the last writer
/// closes, so a `read(2)` against it can never hang past the producer's own
/// exit. A slow-to-start producer (a `make` target doing real work before its
/// first line of output, `docker build`, a network call) can easily outlast
/// any fixed deadline; polling a FIFO for readiness here doesn't add safety,
/// it just misclassifies a slow-but-finite pipe as "not stdin" and sends the
/// pattern down the ordinary directory walk instead — a confusing wrong
/// answer, not a fixed one. A regular file never blocks on `read` either.
const stdin_poll_timeout_ms = 200;

pub fn readable() bool {
    var st: std.posix.Stat = undefined;
    if (std.posix.system.fstat(0, &st) != 0) return false;
    const fmt = st.mode & std.posix.S.IFMT;
    if (fmt == std.posix.S.IFREG or fmt == std.posix.S.IFIFO) return true;
    if (fmt != std.posix.S.IFSOCK) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, stdin_poll_timeout_ms) catch return false;
    return n > 0;
}

/// Ripgrep has no default cap on stdin size (only `--max-filesize`, which
/// doesn't apply to a stream with no a-priori length) — read to EOF, not to
/// `per_file_cap` (that constant is an indexing-corpus budget, not a search
/// ceiling; see `collect.readOneCandidate`'s identical reasoning for on-disk
/// files). Same fd-type split as `readable`: a socket keeps the bounded
/// poll-per-read hang guard (a producer that goes silent mid-stream on that
/// channel must not block this loop forever — whatever arrived before the
/// stall is still searched, nothing is ever discarded), while a FIFO or
/// regular file reads with a plain blocking `read(2)` — rg's own behavior —
/// since a real pipe's natural stalls (build tool output gaps, slow network
/// producers) have no bearing on when it will actually close.
pub fn read(a: std.mem.Allocator) []const u8 {
    var st: std.posix.Stat = undefined;
    const is_socket = std.posix.system.fstat(0, &st) == 0 and (st.mode & std.posix.S.IFMT) == std.posix.S.IFSOCK;
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        if (is_socket) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break;
            if (ready == 0) break; // silent for too long — stop waiting, not hanging
        }
        const n = std.posix.read(0, &tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch die("oom\n", .{});
    }
    return buf.toOwnedSlice(a) catch die("oom\n", .{});
}
