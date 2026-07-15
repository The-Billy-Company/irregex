//! gist resident client — the CLI's warm fast path (ADR-352 rung 2.5).
//!
//! `attempt` is the thin, fail-open bridge between the bare `gist <pattern>`
//! front door and the resident daemon: it classifies the argv, and only when the
//! request is one the warm path can answer *byte-identically to cold* does it
//! dial the socket, run the query, and emit the result in the exact shape the
//! cold engine would. Anything else — an ineligible argv, no daemon listening, a
//! `decline`, any wire hiccup — returns `.cold`, and the caller runs the
//! certified cold path unchanged. The daemon never becomes a new source of truth
//! or a new failure mode; it is a pure accelerator that can always be skipped.
//!
//! Parity scope: only `-l`/`--files-with-matches` (files-with-matches) is routed
//! warm. Its output is the matched paths, sorted, one per line — trivially
//! reproducible from the wire. `-c` (per-file `path:count`) and every richer
//! shape stay cold: the daemon speaks `count` on the wire as a corpus-wide total
//! for embedders, but the CLI never claims rg's per-file `-c` layout from it.

const std = @import("std");
const request = @import("../../session/request.zig");
const protocol = @import("../../session/protocol.zig");
const corpus = @import("../../corpus/corpus.zig");
const net = std.Io.net;

/// Best-effort detached daemon auto-spawn: when an eligible query finds no
/// daemon, `maybeSpawn` forks one so the *next* query lands warm (`spawn.zig`).
pub const spawn = @import("spawn.zig");

/// The outcome of a warm attempt. `.served` means the result was fully emitted
/// to stdout with the given exit code (0 = matched, 1 = no match — rg's codes);
/// `.cold` means the caller must run the cold engine (nothing was emitted).
pub const Outcome = union(enum) {
    served: u8,
    cold,
};

/// Try to answer `argv` warm. Never errors: any failure is `.cold`.
pub fn attempt(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, socket_path: []const u8) Outcome {
    const req = request.classify(argv) catch return .cold;
    // Only files-mode is byte-parity-safe to emit from the daemon's answer.
    if (req.mode != .files) return .cold;

    const ua = net.UnixAddress.init(socket_path) catch return .cold;
    const stream = ua.connect(io) catch return .cold; // no daemon → cold
    defer stream.close(io);
    const fd = stream.socket.handle;

    return exchange(gpa, fd, req) catch .cold;
}

/// One request/response over an open connection: handshake, send the query, and
/// on a `result` frame emit the sorted file list to stdout. A `decline`/`err`
/// frame (or any wire error) propagates so `attempt` degrades to cold.
fn exchange(gpa: std.mem.Allocator, fd: std.posix.fd_t, req: request.Request) !Outcome {
    // Handshake: HELLO → READY. A daemon speaking another protocol version is
    // not one we can trust to frame-match, so bail to cold.
    try protocol.sendFrame(gpa, fd, .hello, &.{protocol.protocol_version});
    {
        var ready = try protocol.recvFrame(gpa, fd);
        defer ready.deinit();
        if (ready.op != .ready) return .cold;
        const r = protocol.decodeReady(ready.payload()) catch return .cold;
        if (r.proto != protocol.protocol_version) return .cold;
    }

    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    if (!protocol.writeAll(fd, qbuf.items)) return .cold;

    var resp = try protocol.recvFrame(gpa, fd);
    defer resp.deinit();
    if (resp.op != .result) return .cold; // decline / err → cold
    const view = protocol.decodeResult(resp.payload()) catch return .cold;

    return switch (view) {
        .files => |files_iter| emitFiles(gpa, files_iter),
        .count => .cold, // CLI never emits count warm (see file header)
    };
}

/// Emit the matched paths one per line and return rg's exit code (0 matched /
/// 1 none). The set is identical to cold `-l`; the daemon returns it sorted (a
/// deterministic canonicalization of ripgrep's otherwise walk-order output).
/// One batched write mirrors the cold path's buffered emit.
fn emitFiles(gpa: std.mem.Allocator, files_iter: protocol.FileIter) Outcome {
    var it = files_iter;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var any = false;
    while (it.next() catch return .cold) |path| {
        any = true;
        out.appendSlice(gpa, path) catch return .cold;
        out.append(gpa, '\n') catch return .cold;
    }
    if (out.items.len > 0) _ = corpus.writeStdout(out.items);
    return .{ .served = if (any) 0 else 1 };
}
