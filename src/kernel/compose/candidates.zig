//! irregex compose — the typed candidate set the composed verbs narrow through.
//!
//! The exact-before-statistical seam of the third face (ADR-367). A loaded
//! corpus plus a compiled `PatternSet` (the MATCH primitive) yields a
//! `CandidateSet`: the subset of docs the exact selector admits, each carrying
//! the per-pattern mask that admitted it. `context` and `family` then run their
//! compression kernels ONLY over this subset — so an exact intent narrows the
//! statistical one, instead of the caller unioning two independent queries by
//! hand and paying whole-corpus noise (README/changelog files that never
//! matched) in the process.
//!
//! Pure kernel: no I/O, no argv, no stdout; the mask is a single `u64`, so the
//! set is capped at 64 patterns — well past any composed workflow's ask, and a
//! caller with more intents is running a `relate patterns` sweep, not this.

const std = @import("std");
const patterns_mod = @import("../slate/patterns.zig");

/// The mask is one `u64`, one bit per pattern — the composed verbs take a
/// handful of intents, never a lint-slate's worth.
pub const max_patterns = 64;

/// How a doc qualifies: `any` = at least one pattern matched (the union), `all`
/// = every pattern matched (the intersection).
pub const Match = enum { any, all };

/// The subset of a corpus a `PatternSet` selects. `ids` are corpus doc ids
/// ascending; `masks[k]` is the bitset of patterns that matched `ids[k]`.
pub const CandidateSet = struct {
    gpa: std.mem.Allocator,
    ids: []u32,
    masks: []u64,
    npatterns: usize,

    pub fn count(self: *const CandidateSet) usize {
        return self.ids.len;
    }

    pub fn deinit(self: *CandidateSet) void {
        self.gpa.free(self.ids);
        self.gpa.free(self.masks);
    }
};

/// Select the docs matching `set` under `match`. One `docMask` pass per doc:
/// the fused gate rejects all-miss docs cheaply, then per-pattern attribution
/// fills the mask (bit-identical to N single-pattern runs — ADR-363). Caller
/// owns the returned set.
pub fn select(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    set: *const patterns_mod.PatternSet,
    match: Match,
) !CandidateSet {
    const n = set.len();
    if (n == 0 or n > max_patterns) return error.TooManyPatterns;

    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask_buf = try gpa.alloc(u64, patterns_mod.maskWords(n));
    defer gpa.free(mask_buf);

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(gpa);
    var masks: std.ArrayList(u64) = .empty;
    errdefer masks.deinit(gpa);

    const want_all = match == .all;
    for (docs, 0..) |doc, d| {
        if (!set.docMask(doc, &sc, mask_buf)) continue; // no pattern hit
        var m: u64 = 0;
        for (0..n) |pi| {
            if (patterns_mod.maskHas(mask_buf, pi)) m |= @as(u64, 1) << @intCast(pi);
        }
        if (want_all and @popCount(m) != n) continue;
        try ids.append(gpa, @intCast(d));
        try masks.append(gpa, m);
    }
    return .{
        .gpa = gpa,
        .ids = try ids.toOwnedSlice(gpa),
        .masks = try masks.toOwnedSlice(gpa),
        .npatterns = n,
    };
}

/// Compile a fixed, case-sensitive `PatternSet` from literal patterns — the
/// one-liner every compose-kernel test shares (and the thin face can reuse).
pub fn compileSet(gpa: std.mem.Allocator, pats: []const []const u8) !patterns_mod.PatternSet {
    const specs = try gpa.alloc(patterns_mod.Spec, pats.len);
    defer gpa.free(specs);
    for (pats, specs) |p, *s| s.* = .{ .pattern = p, .fixed = true, .ignore_case = false };
    return patterns_mod.PatternSet.compile(gpa, specs);
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "select any: a doc admitted by either pattern surfaces with its exact mask" {
    const gpa = t.allocator;
    const docs = [_][]const u8{ "alpha only", "beta only", "alpha and beta", "neither here" };
    var set = try compileSet(gpa, &.{ "alpha", "beta" });
    defer set.deinit(gpa);

    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();

    // docs 0,1,2 match ≥1 pattern; doc 3 matches none.
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, cs.ids);
    try t.expectEqual(@as(u64, 0b01), cs.masks[0]); // alpha only
    try t.expectEqual(@as(u64, 0b10), cs.masks[1]); // beta only
    try t.expectEqual(@as(u64, 0b11), cs.masks[2]); // both
}

test "select all: only docs matching every pattern survive the intersection" {
    const gpa = t.allocator;
    const docs = [_][]const u8{ "alpha only", "beta only", "alpha and beta" };
    var set = try compileSet(gpa, &.{ "alpha", "beta" });
    defer set.deinit(gpa);

    var cs = try select(gpa, &docs, &set, .all);
    defer cs.deinit();

    try t.expectEqualSlices(u32, &.{2}, cs.ids);
    try t.expectEqual(@as(u64, 0b11), cs.masks[0]);
}

test "select: membership equals independent single-pattern matching" {
    const gpa = t.allocator;
    const docs = [_][]const u8{ "the wallet grant path", "budget only", "grant only", "unrelated" };
    var set = try compileSet(gpa, &.{ "grant", "budget" });
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();

    // Oracle: a doc is a candidate iff at least one pattern's literal is in it.
    for (docs, 0..) |doc, d| {
        const oracle = std.mem.indexOf(u8, doc, "grant") != null or std.mem.indexOf(u8, doc, "budget") != null;
        var present = false;
        for (cs.ids) |id| present = present or id == d;
        try t.expectEqual(oracle, present);
    }
}
