//! The AST package — the pattern's shape as an interned DAG, and every question
//! the pipeline asks of that shape answered in one sweep.
//!
//! Compiling a pattern today walks the same tree about fourteen times:
//! `literalInfo`, `requiredAny`, `pureLiterals`, `startsAnchored`,
//! `classRunShape`, `classSpanShape`, `forcedSwell`, `symbolic.eligible`,
//! `symbolic.lower`, `starHeight`, `flattenAlt`, `lowerSeq`, the Thompson
//! lowering, and the cover planner — plus `analyzeFirst` and the two
//! reachability probes, which walk the *compiled* program to recover facts the
//! AST already held. None memoizes, so a shared subtree is re-derived once per
//! path that reaches it, and `requiredAny` is quadratic outright: it calls
//! `literalInfo` at every node, and `literalInfo` walks that node's whole
//! subtree.
//!
//! An `Ast` is the fix, in three steps that live in three files:
//!
//!   * [`intern.zig`](intern.zig) folds the parse tree into a hash-consed DAG
//!     (`../../math/dag.zig`), flattening spines and raising repeated runs by
//!     squaring, so `a{1000}` is ~19 distinct nodes rather than a thousand.
//!   * [`algebra.zig`](algebra.zig) spends the operator identities: ε units,
//!     alternation idempotence, the union of two classes being a class, and the
//!     closure table that makes `(a*)*` one star. Every rule shrinks the graph,
//!     so the sweep runs over less than the parser wrote.
//!   * [`facts.zig`](facts.zig) sweeps that DAG once, forward, filling every
//!     synthesized attribute at once — id order is topological by construction,
//!     so a bottom-up analysis is a `for` loop with no recursion, no visited
//!     set, and exactly one visit per distinct node.
//!
//! This is an ANALYSIS structure. `compile/` still lowers the parser's own tree,
//! because the interning re-associates and only the parser's bracketing decides
//! which leftmost-first match is chosen. Every fact here is a property of the
//! flattened sequence, which is why re-association is free for them and is not
//! free for the engine.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const dagmod = @import("../../math/dag.zig");
const analysis = @import("../analysis/analysis.zig");
const intern_mod = @import("intern.zig");
const facts_mod = @import("facts.zig");
const algebra_mod = @import("algebra.zig");

pub const Id = dagmod.Id;
pub const Stats = dagmod.Stats;
pub const Op = intern_mod.Op;
pub const Graph = intern_mod.Graph;
pub const Interned = intern_mod.Interned;
pub const intern = intern_mod.intern;
pub const Facts = facts_mod.Facts;
pub const unbounded = facts_mod.unbounded;

/// How much work to spend before the sweep.
pub const Options = struct {
    /// Apply the operator identities (`algebra.zig`) between interning and
    /// sweeping. On by default: every rule strictly shrinks the graph, and the
    /// facts are language properties, so a smaller graph is the same answers
    /// computed over fewer nodes. Off is the control the tests compare against.
    canonicalize: bool = true,
};

/// An interned pattern and the facts about it: one allocation per attribute
/// array, one sweep to fill them.
pub const Ast = struct {
    interned: Interned,
    facts: []const Facts,
    gpa: std.mem.Allocator,
    /// What the identities did, or a no-op report when they were declined.
    rewritten: algebra_mod.Report,

    pub fn deinit(self: *Ast) void {
        self.gpa.free(self.facts);
        self.interned.deinit(self.gpa);
    }

    /// What is true of the whole pattern.
    pub inline fn root(self: *const Ast) Facts {
        return self.facts[self.interned.root.index()];
    }
    pub inline fn at(self: *const Ast, id: Id) Facts {
        return self.facts[id.index()];
    }
    /// Distinct nodes the root still reaches. Canonicalization supersedes
    /// nodes rather than deleting them, so this is the live count, not the
    /// table's length.
    pub inline fn nodes(self: *const Ast) usize {
        return self.rewritten.after;
    }
    /// Tree nodes the parser offered — what a recursive walker would have paid.
    pub inline fn offered(self: *const Ast) usize {
        return self.interned.graph.stats.offered;
    }
    /// The structural name of the whole pattern. Two patterns whose roots agree
    /// here denote the same language, to within a 128-bit collision — which is
    /// how a wide `-e`/`-f` slate can drop duplicate intents before compiling
    /// one engine each.
    pub inline fn signature(self: *const Ast) u128 {
        return self.interned.graph.digest(self.interned.root);
    }

    /// A set of literals such that EVERY match contains at least one of them,
    /// or null when none is provable — the same contract as
    /// `analysis.requiredAny`, computed the other way round.
    ///
    /// The walker is quadratic for a structural reason: it needs each node's
    /// mandatory literal to decide whether descending buys selectivity, and it
    /// gets it by calling `literalInfo`, which re-walks that node's whole
    /// subtree. Here the literal is already sitting in `facts`, so deciding a
    /// node is O(1) and the whole cover is one forward pass. The ids being
    /// topological is what lets a child's answer be a memo read rather than a
    /// recursive call, and it is what makes a squared repetition cost `O(log
    /// n)` reads where the walker pays the expanded spine.
    ///
    /// `arena` owns the returned slice and everything reachable from it.
    pub fn cover(self: *const Ast, arena: std.mem.Allocator) syn.ParseError!?[]const []const u8 {
        const g = &self.interned.graph;
        const memo = try arena.alloc(?[]const []const u8, g.len());
        // Canonicalization supersedes rather than deletes, and a cover costs an
        // allocation per node — so the rubble is skipped here, unlike the
        // arithmetic-only sweep that just runs over it.
        const reach = try g.live(arena, &.{self.interned.root});
        for (memo, reach, 0..) |*slot, alive, i| {
            if (!alive) {
                slot.* = null;
                continue;
            }
            const id: Id = @enumFromInt(i);
            const best = self.facts[i].lit.best;
            // A single mandatory ≥3 literal is the most selective filter there
            // is, and no descent can beat it — so it also ends the node's work.
            if (best.len >= 3) {
                slot.* = try arena.dupe([]const u8, &.{best});
                continue;
            }
            const kids = g.kidsOf(id);
            const nested: ?[]const []const u8 = switch (g.payload(id)) {
                .alt => blk: {
                    const sa = memo[kids[0].index()] orelse break :blk null;
                    const sb = memo[kids[1].index()] orelse break :blk null;
                    if (sa.len + sb.len > analysis.max_cover) break :blk null;
                    break :blk try std.mem.concat(arena, []const u8, &.{ sa, sb });
                },
                // Both sides of a concat are mandatory, so either side's cover
                // speaks for the whole — take the more selective.
                .concat => thinner(memo[kids[0].index()], memo[kids[1].index()]),
                .plus, .capture => memo[kids[0].index()],
                else => null,
            };
            // A cover is only as selective as its weakest branch, so a descent
            // is worth taking only when even that branch out-reads this node's
            // own literal.
            if (nested) |s| if (weakest(s) > best.len) {
                slot.* = s;
                continue;
            };
            slot.* = if (best.len > 0) try arena.dupe([]const u8, &.{best}) else nested;
        }
        return memo[self.interned.root.index()];
    }
};

/// Length of a cover's shortest literal — what its selectivity is bounded by.
fn weakest(set: []const []const u8) usize {
    if (set.len == 0) return 0;
    var min: usize = std.math.maxInt(usize);
    for (set) |lit| min = @min(min, lit.len);
    return min;
}

/// The more selective of two sound covers, either of which may be absent.
fn thinner(a: ?[]const []const u8, b: ?[]const []const u8) ?[]const []const u8 {
    const sa = a orelse return b;
    const sb = b orelse return sa;
    return if (weakest(sb) > weakest(sa)) sb else sa;
}

/// Intern a parsed pattern, canonicalize it, and sweep it.
///
/// `arena` owns the literal strings the facts point into and must outlive the
/// result; it is also the interning pass's scratch. `gpa` owns the DAG and the
/// fact array, which `Ast.deinit` returns.
pub fn analyze(gpa: std.mem.Allocator, arena: std.mem.Allocator, tree: *const syn.Node, opts: Options) syn.ParseError!Ast {
    var interned = try intern(gpa, arena, tree);
    errdefer interned.deinit(gpa);

    var report: algebra_mod.Report = .{
        .root = interned.root,
        .rewrites = 0,
        .before = interned.graph.len(),
        .after = interned.graph.len(),
    };
    if (opts.canonicalize) {
        report = try algebra_mod.simplify(gpa, arena, &interned.graph, interned.root);
        interned.root = report.root;
    }

    // Swept over the whole table, superseded nodes included: the sweep is a
    // dense forward loop, and skipping the rubble would cost a liveness test
    // per node to save arithmetic on nodes nothing will ever read.
    const facts = try interned.graph.foldTry(gpa, Facts, arena, facts_mod.sweep);
    return .{ .interned = interned, .facts = facts, .gpa = gpa, .rewritten = report };
}
