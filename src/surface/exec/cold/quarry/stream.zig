//! gist — stdin as a haystack: admitting and draining fd 0.
//!
//! `cmd | gist pat` must search the stream instead of walking the tree, which
//! makes "is fd 0 readable?" a correctness question, not a convenience. The rule
//! is ripgrep's (`is_readable_stdin`: not a tty, and a file / FIFO / socket),
//! with one deliberate departure that the doc comments below justify in full: a
//! SOCKET is admitted only behind a bounded `poll`, because a silent-forever
//! control socket on fd 0 would otherwise hang an agent-facing tool. A FIFO gets
//! no such guard — a slow producer is normal, and dropping it would be a real
//! false negative.
//!
//! The classification is non-consuming, so the warm daemon client can ask the
//! same question and decline to cold without stealing the bytes cold will read.

const std = @import("std");
const args = @import("../argv/args.zig");
const inode = @import("../read/inode.zig");

const oom = args.oom;

/// ripgrep's `is_readable_stdin` (grep/cli): `!is_terminal(fd0) && (is_file ||
/// is_fifo || is_socket)`. We whitelist exactly those three fd types — regular
/// file, FIFO (pipe), and socket — which by construction excludes a tty and a
/// char device (`/dev/null`), so the `is_terminal` guard is subsumed. This is
/// the rule that lets `cmd | rg pat` and `sock_producer | rg pat` search the
/// stream while `rg pat` (bare tty) and `rg pat </dev/null` fall through to the
/// directory walk. The socket case matters for exec APIs that wire fd0 to a
/// socketpair; omitting it silently diverged from rg on piped-socket input.
///
/// Deliberate departure from raw rg parity — but ONLY for a socket. A socket can
/// be a long-lived control channel that never writes a byte and never closes
/// (seen in the wild — some sandboxed shell/tool-call harnesses wire fd 0 to
/// exactly such a socket); a blocking `read(2)` against that hangs forever,
/// unacceptable for an agent-facing tool. So a socket is admitted only when
/// `poll(2)` shows it ready within a short deadline (a real producer signals in
/// milliseconds; only the pathological silent-forever socket times out, falling
/// through to the directory walk instead of hanging).
///
/// A FIFO (pipe) gets NO such guard: `cmd | gist pat` is the canonical stream,
/// and a slow producer — bytes arriving after a pause, or the first byte only
/// after setup work — is normal, not pathological. A pipe's blocking `read`
/// always terminates: when the writer finishes it closes the write end and
/// `read` returns EOF. Polling it with a deadline is exactly the delayed-pipe
/// false negative we must avoid (a 500 ms-late producer was being dropped to the
/// walk). So a FIFO is classified readable immediately and block-read to true
/// EOF, byte-for-byte rg. A regular file never blocks on `read` either.
const stdin_poll_timeout_ms = 200;

/// fd 0's stream class, deciding stdin admission + the read strategy below.
const StdinKind = enum { none, blocking, socket };

/// Classify fd 0 (ripgrep's `is_readable_stdin`: not a tty, and a file / FIFO /
/// socket). A regular file or FIFO is `.blocking` — safe to block-read to EOF;
/// a socket is `.socket` — admitted only through the bounded poll guard.
fn stdinKind() StdinKind {
    const st = inode.statFd(0) orelse return .none;
    return switch (st.mode & std.posix.S.IFMT) {
        std.posix.S.IFREG, std.posix.S.IFIFO => .blocking,
        std.posix.S.IFSOCK => .socket,
        else => .none, // tty, /dev/null char device, … ⇒ fall through to the walk
    };
}

/// True iff fd 0 is a readable stdin stream. `pub` for the warm client
/// (`surface/face/gist/daemon/client/client.zig`): a rootless query with a readable stdin
/// is a STREAM search only the cold engine can answer, so the client detects the
/// same condition — with the same fd-type rules — and declines to cold. This is
/// a non-consuming probe (stat, plus a `poll` for a socket): the delayed pipe's
/// bytes are never touched here, so nothing the cold `readStdin` will read is
/// stolen.
pub fn readableStdin() bool {
    return switch (stdinKind()) {
        .none => false,
        .blocking => true, // a regular file or a (possibly slow) pipe
        .socket => blk: {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break :blk false;
            break :blk n > 0;
        },
    };
}

/// Ripgrep has no default cap on stdin size (only `--max-filesize`, which
/// doesn't apply to a stream with no a-priori length) — read to EOF, not to
/// `per_file_cap` (that constant is an indexing-corpus budget, not a search
/// ceiling; see `readOneCandidate`'s identical reasoning for on-disk files).
/// A regular file or FIFO is block-read straight to EOF: a slow or paused pipe
/// writer just makes `read` wait, and the writer's close is the EOF — exactly
/// rg, no delayed-pipe truncation. Only a socket keeps the mid-stream silence
/// guard (poll each chunk, treat a timeout as EOF), since a socket peer can go
/// silent forever without closing; whatever arrived before the stall is kept.
pub fn readStdin(a: std.mem.Allocator) []const u8 {
    const guard = stdinKind() == .socket;
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        if (guard) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, stdin_poll_timeout_ms) catch break;
            if (ready == 0) break; // socket silent for too long — stop waiting, not hanging
        }
        const n = std.posix.read(0, &tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(a, tmp[0..n]) catch oom();
    }
    return buf.toOwnedSlice(a) catch oom();
}
