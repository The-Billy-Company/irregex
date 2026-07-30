//! irregex compose — `context`: graded coverage packing inside the exact filter.
//!
//! The composed answer to "give me the minimal non-redundant reading set among
//! files that actually match these intents." `relate pack` over the whole
//! corpus surfaces whatever the corpus finds cheap regardless of the query's
//! exact intent; running the exact `PatternSet` first (`candidates.select`) and
//! pricing the query's aspects over ONLY the candidate docs measures novelty
//! inside the matching set, so the greedy submodular sweep (`coverage.zig`)
//! never spends a pick on a file the caller's patterns didn't hit.
//!
//! Pricing is deliberately LOCAL here. Inside a twelve-file `--matching` set,
//! a term one file holds is the most discriminating thing in the population
//! even though the whole corpus may be full of it — that is the entire point
//! of having narrowed first.
//!
//! Two scores stay honest and separate (ADR-367): each pick carries the exact
//! `mask` of patterns that admitted its file AND the compression `marginal_bits`
//! it adds beyond earlier picks — no fused relevance number. Pure kernel: the
//! driver loads the corpus and renders; this measures and packs.

const std = @import("std");
const coverage = @import("../kinship/recall/coverage.zig");
const candidates = @import("candidates.zig");

/// One packed pick: a corpus doc id, the exact patterns that admitted it, and
/// the compression accounting (bits it adds, cumulative coverage fraction, the
/// aspects it is the best explanation of).
pub const Pick = struct {
    doc: u32,
    mask: u64,
    marginal_bits: f64,
    coverage: f64,
    owns: u64,
};

pub const Packed = struct {
    gpa: std.mem.Allocator,
    picks: []Pick,
    /// The priced aspect table, borrowed term slices into the caller's terms.
    aspects: []coverage.Aspect,
    total_bits: f64,
    foreign: usize,
    glue: usize,
    candidates: usize,

    pub fn deinit(self: *Packed) void {
        self.gpa.free(self.picks);
        self.gpa.free(self.aspects);
    }
};

/// Coverage-pack `terms` within `cset`. Prices each aspect against the
/// candidate docs alone, grades every candidate on it by saturating density,
/// greedily picks the set that jointly explains the most priced bits, and maps
/// picks back to corpus ids + their exact masks. `terms` must outlive the
/// result (the aspect table borrows the slices). Caller owns the result.
pub fn pack(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    cset: *const candidates.CandidateSet,
    terms: []const []const u8,
    top: usize,
) !Packed {
    const m = cset.count();
    const cand_docs = try gpa.alloc([]const u8, m);
    defer gpa.free(cand_docs);
    const cand_paths = try gpa.alloc([]const u8, m);
    defer gpa.free(cand_paths);
    for (cset.ids, 0..) |id, k| {
        cand_docs[k] = docs[id];
        cand_paths[k] = paths[id];
    }

    var table = try coverage.measure(gpa, terms, cand_docs);
    defer table.deinit();
    const total_bits = coverage.pricedBits(table.aspects);

    const raw = try coverage.greedy(
        gpa,
        table.aspects,
        table.candidates,
        cand_paths,
        top,
        minGain(total_bits),
    );
    defer gpa.free(raw);

    const picks = try gpa.alloc(Pick, raw.len);
    errdefer gpa.free(picks);
    for (raw, picks) |p, *out| {
        out.* = .{
            .doc = cset.ids[p.doc],
            .mask = cset.masks[p.doc],
            .marginal_bits = p.marginal_bits,
            .coverage = if (total_bits > 0.0) p.covered_bits / total_bits else 0.0,
            .owns = p.owns,
        };
    }
    // The aspect table outlives its `Table`: only the (borrowed) term slices
    // and the scalar pricing survive, which is exactly what a renderer needs.
    const aspects = try gpa.dupe(coverage.Aspect, table.aspects);
    return .{
        .gpa = gpa,
        .picks = picks,
        .aspects = aspects,
        .total_bits = total_bits,
        .foreign = table.count(.foreign),
        .glue = table.count(.glue),
        .candidates = m,
    };
}

/// The floor a pick must clear to earn a place in the reading set — see
/// `exec/cold/engine/retrieval.zig`, which applies the same policy to
/// the warm rung so all three rungs stop at the same kind of pick.
pub fn minGain(total_bits: f64) f64 {
    return @max(0.02 * total_bits, 0.25);
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;
const compileSet = candidates.compileSet;

test "context: packs only inside the exact filter, never a non-matching file" {
    const gpa = t.allocator;
    // The query describes wallet-grant code. Doc 2 does not contain the pattern
    // literal, so the exact filter must exclude it however well it would score.
    //
    // Each admitted doc owns one aspect outright — `wallet` in a.zig, `ledger`
    // in b.zig — so both earn a pick well clear of `minGain`. A fixture where
    // every admitted doc merely mentions the terms prices them at ~0 bits
    // (df == n ⇒ −log₂(1) == 0) and packs nothing, which would vacuously pass
    // the "never a non-matching file" loop below.
    const terms = [_][]const u8{ "wallet", "grant", "ledger" };
    const docs = [_][]const u8{
        "fn grant() { the wallet wallet credit lands on the balance }",
        "grant helper: ledger ledger rows land on the audit trail",
        "unrelated telemetry sampling notes for the fleet dashboards here",
        "grant summary: totals only, nothing else of note here",
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.txt" };
    var set = try compileSet(gpa, &.{"grant"});
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();

    var packed_result = try pack(gpa, &docs, &paths, &cs, &terms, 8);
    defer packed_result.deinit();

    // Both aspect-owning docs earn a pick, so the exclusion below is checked
    // against a non-empty set rather than passing on an empty one.
    try t.expect(packed_result.picks.len >= 2);
    // c.zig (no `grant`) is never a candidate, so it can never be picked.
    for (packed_result.picks) |p| try t.expect(p.doc != 2);
    // Every pick's mask is non-zero — it earned its place on the exact filter.
    for (packed_result.picks) |p| try t.expect(p.mask != 0);
}

test "context: local pricing keeps a rare-in-the-set term discriminating" {
    const gpa = t.allocator;
    // `wallet` sits in one of the three admitted docs. Corpus-wide it might be
    // house vocabulary; inside this narrowed set it is the whole signal, and
    // the doc that owns it must be pickable.
    const terms = [_][]const u8{ "wallet", "grant" };
    const docs = [_][]const u8{
        "grant grant grant grant ledger notes",
        "grant wallet wallet wallet wallet wallet balance",
        "grant grant grant audit trail rows",
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    var set = try compileSet(gpa, &.{"grant"});
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();

    var packed_result = try pack(gpa, &docs, &paths, &cs, &terms, 8);
    defer packed_result.deinit();
    try t.expectEqual(@as(usize, 0), packed_result.glue);
    try t.expectEqual(@as(u32, 1), packed_result.picks[0].doc);
}

const select = candidates.select;
