//! gist T4 — result ranking via weighted Reciprocal Rank Fusion (RRF).
//!
//! The lexical tiers (T0–T2) answer *which files contain the match* as an
//! unordered set. An agent doesn't want a set — it wants the **one** line that
//! answers the question first (the *definition* of a symbol, not its 200 call
//! sites), and it pays tokens for every line below that. T4 turns the verified
//! match set into a ranked list.
//!
//! RRF (Cormack et al. 2009) is the right fusion primitive here, not a hand-tuned
//! linear score: it needs no per-signal normalization (it consumes *ranks*, not
//! raw magnitudes), is robust to one signal's blowups, and trivially admits new
//! signals. score(d) = Σ_i wᵢ / (k + rankᵢ(d)). We fuse three intrinsic signals
//! computed from the matches themselves —
//!   • **lexical** density (more occurrences ⇒ more relevant),
//!   • **symbol** boost (a match on a *definition* line ⇨ what you were looking
//!     for; weighted highest — this is the agent win rg can't express),
//!   • **shallow path** (fewer path segments ⇒ closer to a package root, usually
//!     more central than a deep test/vendor file),
//! — plus an **optional external ranking** (`graph_rank`): pass graphify's
//! graph-centrality order and it fuses in for free; pass null and it's ignored.
//! Embeddings stay deliberately out (CoREB: short keyword queries collapse them).

const std = @import("std");

/// Per-doc features derived from the verified matches; the harness fills these, the kernel stays filesystem-agnostic.
pub const Doc = struct {
    id: u32, // caller's document id (index into its own path table)
    matches: u32, // needle occurrences in the file
    is_def: bool, // any match sits on a definition line
    best_line: u32, // 1-based line to surface (the def line if any, else first match)
    depth: u16, // path segment count (number of '/'); shallower ranks higher
};

/// Tunable fusion constants. `k` damps the head so rank-1 isn't pathologically dominant (60 is the canonical RRF value).
/// Weights encode the editorial call definition > raw frequency > shallowness; the external graph signal, when present, is co-equal with lexical.
pub const Weights = struct {
    k: f64 = 60.0,
    lexical: f64 = 1.0,
    symbol: f64 = 2.0,
    shallow: f64 = 0.5,
    graph: f64 = 1.0,
};

fn byMatchesDesc(docs: []const Doc, a: u32, b: u32) bool {
    if (docs[a].matches != docs[b].matches) return docs[a].matches > docs[b].matches;
    return docs[a].best_line < docs[b].best_line; // stable, deterministic tiebreak
}
fn byDefFirst(docs: []const Doc, a: u32, b: u32) bool {
    if (docs[a].is_def != docs[b].is_def) return docs[a].is_def;
    if (docs[a].matches != docs[b].matches) return docs[a].matches > docs[b].matches;
    return docs[a].best_line < docs[b].best_line;
}
fn byShallow(docs: []const Doc, a: u32, b: u32) bool {
    if (docs[a].depth != docs[b].depth) return docs[a].depth < docs[b].depth;
    return docs[a].best_line < docs[b].best_line;
}

/// Fill `buf` with 0,1,2,… — the identity permutation we sort in place.
fn iota(buf: []u32) void {
    for (buf, 0..) |*v, i| v.* = @intCast(i);
}

/// One RRF term: weight wᵢ over the damped rank (k + position).
fn rrf(w: f64, k: f64, pos: usize) f64 {
    return w / (k + @as(f64, @floatFromInt(pos)));
}

/// Add one signal's RRF contribution to `score`: rank `docs` by `less`, credit
/// each wᵢ/(k+rank). `scratch` is a reusable id buffer (len == n).
fn addSignal(score: []f64, docs: []const Doc, scratch: []u32, w: f64, k: f64, comptime less: fn ([]const Doc, u32, u32) bool) void {
    iota(scratch);
    std.sort.pdq(u32, scratch, docs, less);
    for (scratch, 0..) |doc_idx, pos| score[doc_idx] += rrf(w, k, pos);
}

/// Credit an externally-supplied ranking (graphify centrality) given as doc
/// *ids* best-first; ids absent from the list simply earn nothing from it.
fn addExternal(score: []f64, docs: []const Doc, order: []const u32, w: f64, k: f64) void {
    for (order, 0..) |id, pos| {
        for (docs, 0..) |d, i| if (d.id == id) {
            score[i] += rrf(w, k, pos);
            break;
        };
    }
}

/// Rank `docs` best-first by fused RRF score; returns caller-owned indices into `docs`.
/// `graph_rank`, if non-null, is doc *ids* in graphify's centrality order, fused as a co-equal signal.
pub fn rank(gpa: std.mem.Allocator, docs: []const Doc, w: Weights, graph_rank: ?[]const u32) std.mem.Allocator.Error![]u32 {
    const n = docs.len;
    const order = try gpa.alloc(u32, n);
    errdefer gpa.free(order);
    iota(order);
    if (n <= 1) return order;

    const score = try gpa.alloc(f64, n);
    defer gpa.free(score);
    @memset(score, 0);
    const scratch = try gpa.alloc(u32, n);
    defer gpa.free(scratch);

    addSignal(score, docs, scratch, w.lexical, w.k, byMatchesDesc);
    addSignal(score, docs, scratch, w.symbol, w.k, byDefFirst);
    addSignal(score, docs, scratch, w.shallow, w.k, byShallow);
    if (graph_rank) |gr| addExternal(score, docs, gr, w.graph, w.k);

    // Sort the id list by fused score desc; id asc breaks ties for determinism.
    const Ctx = struct {
        s: []const f64,
        fn less(self: @This(), a: u32, b: u32) bool {
            if (self.s[a] != self.s[b]) return self.s[a] > self.s[b];
            return a < b;
        }
    };
    std.sort.pdq(u32, order, Ctx{ .s = score }, Ctx.less);
    return order;
}

// ───────────────────────────── tests ─────────────────────────────

test "rrf: definition beats a higher-frequency call site" {
    const docs = [_]Doc{
        .{ .id = 10, .matches = 50, .is_def = false, .best_line = 5, .depth = 3 }, // hot usage
        .{ .id = 20, .matches = 2, .is_def = true, .best_line = 1, .depth = 3 }, // the def
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    // The symbol signal (weight 2) lifts the definition above the 25×-hotter usage.
    try std.testing.expectEqual(@as(u32, 1), order[0]); // docs[1] == the def
    try std.testing.expectEqual(@as(u32, 0), order[1]);
}

test "rrf: among non-defs, density then shallowness win" {
    const docs = [_]Doc{
        .{ .id = 1, .matches = 1, .is_def = false, .best_line = 9, .depth = 6 },
        .{ .id = 2, .matches = 9, .is_def = false, .best_line = 2, .depth = 2 },
        .{ .id = 3, .matches = 9, .is_def = false, .best_line = 2, .depth = 5 },
    };
    const order = try rank(std.testing.allocator, &docs, .{}, null);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(u32, 1), order[0]); // most matches AND shallowest
    try std.testing.expectEqual(@as(u32, 2), order[1]); // same matches, deeper
    try std.testing.expectEqual(@as(u32, 0), order[2]); // fewest matches
}

test "rrf: external graph ranking fuses in and drives the order" {
    const docs = [_]Doc{
        .{ .id = 100, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
        .{ .id = 200, .matches = 5, .is_def = false, .best_line = 3, .depth = 4 },
    };
    // A dominant graph signal puts whichever id it ranks first on top, and flipping the order flips the result —
    // proving the optional signal fuses in and is weight-controlled.
    const graph_a = [_]u32{ 200, 100 };
    const a = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_a);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(u32, 1), a[0]); // docs[1].id == 200

    const graph_b = [_]u32{ 100, 200 };
    const b = try rank(std.testing.allocator, &docs, .{ .graph = 100 }, &graph_b);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 0), b[0]); // docs[0].id == 100
}

test "rank: trivial sizes are well-defined" {
    const empty = try rank(std.testing.allocator, &[_]Doc{}, .{}, null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const one = [_]Doc{.{ .id = 7, .matches = 1, .is_def = false, .best_line = 1, .depth = 1 }};
    const got = try rank(std.testing.allocator, &one, .{}, null);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(u32, 0), got[0]);
}
