//! The warm corpus every analytic producer is handed, and the cancel handle any
//! thread may trip.
//!
//! ## Why this is substrate and not one face's
//!
//! Every face's `…_run` entry takes an OPEN ENGINE. An engine
//! is only interpretable by the copy of the engine code that made it — the
//! corpus, its arenas, and its process-global caches all belong to one image — so
//! the opener has to be a symbol every producer resolves to the SAME function.
//! While it lived in the exact face's library, the kinship one had two ways to
//! get one and neither worked: link that library (which would make the kinship
//! package depend on the search package for a type neither owns) or compile its
//! own copy (which it did, and a handle from the other copy then segfaults).
//! Down here, one opener serves all four libraries, and the kinship header stops
//! including the exact face's for a struct that was never that face's.
//!
//! `Engine` and `CancelToken` were always this package's (`surface/api.zig`);
//! only the five C shims lived upstairs. This file is where they came home.
//!
//! ## Which module this is in
//!
//! `exports.zig`'s, not the library's — it imports `irregex` as a dependency the
//! way any embedder would. That is deliberate and ward enforces it: `api.zig` is
//! the curated veneer and is kept to `root.zig`, so a file *inside* the library
//! may not reach across to it. Lowering the veneer to C is a consumer's job, and
//! the artifact root is the consumer. Bodies live here rather than in
//! `exports.zig` so they can be tested without going through C.

const std = @import("std");
const irregex = @import("irregex");

const api = irregex.api;
const contract = irregex.ffi.contract;

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// Stand a warm corpus up over `roots[0..nroots]` (NUL-terminated paths), writing
/// the handle to `out`. `nroots == 0` is the rootless CWD walk, not an error.
pub fn open(roots_ptr: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const roots = gpa.alloc([]const u8, nroots) catch return contract.report(.{ .code = error.OutOfMemory });
    defer gpa.free(roots);
    if (nroots != 0) {
        const rp = roots_ptr orelse return .invalid;
        for (roots, 0..) |*r, i| r.* = std.mem.span(rp[i]);
    }
    slot.* = api.Engine.open(gpa, roots) catch |e| return contract.reportAny(e, .open_failed);
    return .ok;
}

/// Tear down a corpus opened by `open`, and everything it holds warm.
pub fn close(engine: *api.Engine) void {
    engine.close();
}

/// Allocate a fresh (unset) cancellation token, writing it to `out`.
pub fn cancelNew(out: ?**api.CancelToken) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const token = gpa.create(api.CancelToken) catch return contract.report(.{ .code = error.OutOfMemory });
    token.* = .{};
    slot.* = token;
    return .ok;
}

/// Trip a token, cancelling every in-flight search using it. Thread-safe by
/// construction: this is the one operation a caller runs from another thread.
pub fn cancelRequest(token: *api.CancelToken) void {
    token.cancel();
}

/// Free a token from `cancelNew`, after every search using it has returned.
pub fn cancelFree(token: *api.CancelToken) void {
    gpa.destroy(token);
}

test "a rootless open stands up and tears down" {
    var engine: *api.Engine = undefined;
    try std.testing.expectEqual(Status.ok, open(null, 0, &engine));
    close(engine);
}

test "a null out slot is refused rather than dereferenced" {
    try std.testing.expectEqual(Status.invalid, open(null, 0, null));
    try std.testing.expectEqual(Status.invalid, cancelNew(null));
}

test "a successful entry hands back no fault, however the previous call failed" {
    const t = std.testing;
    const fault = irregex.fault;
    const sc = fault.scope();
    defer sc.end();

    // The failure a host would have just been told about, still in the slot.
    fault.install(.{ .code = error.Corrupt, .path = "kinship.atlas", .at = 7 });
    var detail: contract.FaultDetail = .{ .struct_size = @sizeOf(contract.FaultDetail), .status = 0, .at_space = 0, .name = "", .path = null, .path_len = 0, .at = 0 };
    try t.expectEqual(Status.match, contract.lastFault(&detail));

    var token: *api.CancelToken = undefined;
    try t.expectEqual(Status.ok, cancelNew(&token));
    defer cancelFree(token);

    // The assertion the scope policy exists for: no stale fault survives a call
    // that succeeded. Without `beginCall` at this entry the pull still reports
    // `Corrupt`, and a host would blame a clean run for an earlier failure.
    try t.expectEqual(Status.ok, contract.lastFault(&detail));
}

test "a token is unset until tripped, and freeing it is not tripping it" {
    var token: *api.CancelToken = undefined;
    try std.testing.expectEqual(Status.ok, cancelNew(&token));
    try std.testing.expect(!token.requested());
    cancelRequest(token);
    try std.testing.expect(token.requested());
    cancelFree(token);
}
