//! gist — the **conjunctive cover**: lowering a parsed pattern to a boolean
//! query over trigrams that the index may soundly demand (ADR-352, Layer L).
//!
//! `prefilter.zig` answers the *one-literal* question: which single literal (or
//! single alternation cover) is mandatory? That question throws away most of
//! what a pattern proves. `if\s+err\s*!=\s*nil` forces FOUR disjoint literal
//! runs; the one-literal planner picks the longest and discards the other three.
//! `func\s+\w+\(` forces `func` immediately followed by a whitespace byte, but
//! `\s` is not a singleton class so the run stops at `func` and the adjacency —
//! the most selective fact in the pattern — is never asked of the index.
//!
//! This module answers the *whole* question. It returns a *conjunction of
//! disjunctions of conjunctions*:
//!
//! ```text
//!   plan   ≔ clause ∧ clause ∧ …     every clause is necessary
//!   clause ≔ atom ∨ atom ∨ …         some atom holds
//!   atom   ≔ literal ∧ literal ∧ …   all of these literals' trigrams present
//! ```
//!
//! which is exactly the shape `trigram.Index.queryPlan` evaluates, and exactly
//! the shape csearch's `regexp/query.go` builds — with two differences that are
//! the point of Layer L:
//!
//!   1. **Byte-class cross-products are kept as one run.** csearch composes
//!      `exact` string sets across concatenation and stops at a size cap; so do
//!      we, but the accumulator here is a *run of adjacent bytes* carried across
//!      the whole concat spine, and it survives a non-exact node by folding that
//!      node's provable head set into the run before closing it. That is what
//!      turns `func\s` into `{func␠, func\t, func\n, func\r, func\x0b, func\x0c}`
//!      instead of `func`.
//!   2. **Every clause is emitted, and the INDEX picks.** A syntactic planner has
//!      to guess which constraint is worth evaluating. `queryPlan` knows the real
//!      posting cardinality of every trigram, so this module's job is to emit
//!      every *sound* necessary condition and let the measured cost model order
//!      them and decline the ones that cost more than they prune. Emitting more
//!      here is therefore free: it widens the choice, never the answer.
//!
//! **Soundness contract.** Every clause returned is a NECESSARY condition: if a
//! document matches, it contains, for every clause, all the literals of at least
//! one of that clause's atoms. A clause is emitted only when *every* atom in it
//! is filterable (each literal ≥3 bytes) — one unfilterable alternative would
//! make the disjunction vacuous and, if evaluated as if it were not, would elide
//! real matches. `cover_test.zig` asserts this by exhaustive brute force against
//! the real matcher; `queryPlan` never sees a clause this module declined.

const std = @import("std");
const regex = @import("../regex/regex.zig");
const syn = regex.syntax;
const lower = regex.lower;

const Node = syn.Node;
const ParseError = syn.ParseError;
/// The matcher's own parse options — a plan derived under different fold /
/// dotall / multiline settings than the engine would be unsound, so the caller
/// passes the very options it compiled with (exactly as `lower.forcedSwell` does).
pub const Options = lower.Options;

/// A conjunction of literals: a candidate satisfies the atom when it holds every
/// trigram of every literal. Structurally identical to `trigram.Index.Atom`.
pub const Atom = []const []const u8;
/// A disjunction of atoms — `trigram.Index.Clause`.
pub const Clause = []const Atom;

/// The bounds that keep a cross-product from exploding into more posting-list
/// work than the scan it replaces. Every one of them is a *cost* bound, never a
/// soundness bound: exceeding any of them makes the planner emit a weaker (or
/// no) clause, which only ever widens the candidate set.
///
/// The defaults are the measured optimum on the Layer-L slate
/// (`bench/sieve/indexq.zig`); `--cover-*` overrides exist there so the frontier
/// is re-derived from data rather than asserted.
pub const Limits = struct {
    /// Members of one byte/codepoint class admissible as a choice point. 64 is
    /// the measured knee AND the natural boundary: it is exactly the size of an
    /// *identifier-byte* class (`[\w.]`), the commonest wildcard adjacent to a
    /// literal in code search. Below it, `[0-9a-fA-F]` (22) and `[\w.]` are
    /// walls; above it nothing on the Layer-L slate improves — `.` (255) never
    /// pays, and the atom ceiling bounds the product regardless.
    class: usize = 64,
    /// Alternatives one clause may carry — the cross-product ceiling. Each costs
    /// a literal's worth of posting decode, so this is the single knob trading
    /// planning reach against query work. 256 is csearch's own ceiling and the
    /// measured knee here: 128 gives back 69 MB of candidates on the Layer-L
    /// slate, 512 and 1024 buy nothing and only cost planning time.
    atoms: usize = 256,
    /// Clauses in a plan. `queryPlan` intersects cheapest-first and stops on its
    /// own budget, so this only bounds planning work.
    clauses: usize = 16,
    /// The trigram floor: a literal shorter than this cannot be asked of a
    /// trigram index at all.
    min_literal: usize = 3,
};

/// Build the plan for a parsed pattern, or null when nothing is provable (the
/// caller keeps its full-scan fallback). Allocates only in `arena`; the returned
/// plan borrows from it and from `node`'s own literal storage.
pub fn plan(arena: std.mem.Allocator, node: *Node, lim: Limits) ParseError!?[]const Clause {
    var acc: Accum = .{ .arena = arena, .lim = lim, .out = .empty };
    try acc.collect(node);
    if (acc.out.items.len == 0) return null;
    return try acc.out.toOwnedSlice(arena);
}

/// The plan for a pattern SOURCE — the seam a caller holding only the pattern
/// string (the cold prefilter, the warm gather) uses. Parses with the matcher's
/// own `lower.parse`, so the plan can never disagree with the engine about what
/// a construct means. Null on any parse failure or unprovable pattern: an
/// unsupported construct may cost pruning, never a match.
pub fn planSource(arena: std.mem.Allocator, pattern: []const u8, opts: Options, lim: Limits) ?[]const Clause {
    const node = lower.parse(arena, pattern, opts) catch return null;
    return plan(arena, node, lim) catch null;
}

// ── the accumulator ──────────────────────────────────────────────────────────

const Accum = struct {
    arena: std.mem.Allocator,
    lim: Limits,
    out: std.ArrayList(Clause),

    /// Walk `node` for every clause it forces. Structure-directed: a concat
    /// spine is where runs are grown, an alternation is where they multiply, and
    /// a star/quest forces nothing at all.
    fn collect(self: *Accum, node: *Node) ParseError!void {
        if (self.out.items.len >= self.lim.clauses) return;
        switch (node.*) {
            .concat => try self.spine(node),
            .capture => |g| try self.collect(g.child),
            .plus => |r| try self.collect(r.node), // ≥1 iteration ⇒ its clauses hold
            .alt => try self.branch(node),
            // A star/quest may match empty; a bare leaf is one codepoint. Neither
            // forces a trigram. (A leaf inside a concat is picked up by `spine`.)
            else => {},
        }
    }

    /// An alternation forces a clause only where BOTH sides force one: for every
    /// pair of clauses (one from each side), their union is necessary. The full
    /// cross-product is the strongest sound reading and is what csearch's
    /// `Query.or` approximates; past the clause budget we keep the first pairs,
    /// which is still sound (dropping a clause only widens).
    fn branch(self: *Accum, node: *Node) ParseError!void {
        const ab = node.alt;
        var left: Accum = .{ .arena = self.arena, .lim = self.lim, .out = .empty };
        var right: Accum = .{ .arena = self.arena, .lim = self.lim, .out = .empty };
        try left.collect(ab[0]);
        try right.collect(ab[1]);
        if (left.out.items.len == 0 or right.out.items.len == 0) return;
        for (left.out.items) |la| {
            for (right.out.items) |rb| {
                if (self.out.items.len >= self.lim.clauses) return;
                if (la.len + rb.len > self.lim.atoms) continue;
                const merged = try std.mem.concat(self.arena, Atom, &.{ la, rb });
                try self.push(merged);
            }
        }
    }

    /// The heart. A concat spine is a sequence of *positions* — at each one the
    /// match must consume one string from a known finite set — punctuated by
    /// *breaks* where nothing finite is provable. `segment` then reads each run
    /// of consecutive positions.
    ///
    /// A partially-known node contributes three things: its head set (which is
    /// still adjacent to what came before), a break, and its tail set (adjacent
    /// to what comes after). That is what keeps `\s+` from being a wall: `func`
    /// and the whitespace byte after it stay in one segment, and the whitespace
    /// byte before `err` joins the next one.
    fn spine(self: *Accum, node: *Node) ParseError!void {
        var items: std.ArrayList(*Node) = .empty;
        try flatten(self.arena, node, &items);

        var seg: std.ArrayList([]const []const u8) = .empty;
        for (items.items) |n| {
            if (try self.exacts(n)) |ex| {
                if (ex.len == 1 and ex[0].len == 0) continue; // zero-width: no position
                try seg.append(self.arena, ex);
                continue;
            }
            if (try self.heads(n)) |h| try seg.append(self.arena, h);
            try self.segment(seg.items);
            seg.clearRetainingCapacity();
            if (try self.tails(n)) |tl| try seg.append(self.arena, tl);
            try self.collect(n); // clauses forced strictly INSIDE the opaque node
        }
        try self.segment(seg.items);
    }

    /// Read every clause a run of adjacent positions forces.
    ///
    /// The whole segment is tried first: when its cross-product fits the atom
    /// ceiling that single clause is the strongest thing the segment can say
    /// (`func` + `\s` ⇒ the six 5-byte alternatives), and nothing weaker is worth
    /// adding beside it. Only when the product overflows do we fall back to
    /// **sliding windows** — every start position, extended to the shortest
    /// extent that clears the trigram floor, kept when its own product fits.
    ///
    /// That fallback is where a hex-run pattern stops being unfilterable.
    /// `[0-9a-f]{8}-[0-9a-f]{4}` has a 16¹²-way whole product, but three of its
    /// windows straddle the dash and each fits in 256: `{hex hex -}`, `{hex - hex}`
    /// and `{- hex hex}`. csearch's planner takes exactly one of those three and
    /// stops; their CONJUNCTION is what a cost-ordered evaluator can afford to
    /// ask, and it is strictly more selective than any one of them.
    fn segment(self: *Accum, positions: []const []const []const u8) ParseError!void {
        if (positions.len == 0) return;
        if (try self.window(positions)) return;
        var i: usize = 0;
        while (i < positions.len) : (i += 1) {
            if (self.out.items.len >= self.lim.clauses) return;
            var j = i + 1;
            while (j <= positions.len and minBytes(positions[i..j]) < self.lim.min_literal) j += 1;
            if (j > positions.len) return; // no remaining start can reach the floor
            _ = try self.window(positions[i..j]);
        }
    }

    /// Materialize one span of positions as a clause, or decline it. Declines
    /// when the cross-product overflows the atom ceiling (a cost bound) or when
    /// any alternative falls below the trigram floor (a soundness bound: one
    /// unwitnessable alternative makes the whole disjunction vacuous, and a
    /// vacuous clause that is evaluated as if it were real elides matches).
    fn window(self: *Accum, positions: []const []const []const u8) ParseError!bool {
        if (positions.len == 0 or self.out.items.len >= self.lim.clauses) return false;
        var run: []const []const u8 = try self.arena.dupe([]const u8, &.{""});
        for (positions) |p| run = (try self.cross(run, p)) orelse return false;
        for (run) |lit| if (lit.len < self.lim.min_literal) return false;
        const atoms = try self.arena.alloc(Atom, run.len);
        for (atoms, run) |*a, lit| a.* = try self.arena.dupe([]const u8, &.{lit});
        try self.push(atoms);
        return true;
    }

    /// Append a clause unless an identical one is already present. Duplicates are
    /// sound but pay posting decode twice for no extra pruning.
    fn push(self: *Accum, clause: Clause) ParseError!void {
        for (self.out.items) |have| if (sameClause(have, clause)) return;
        try self.out.append(self.arena, clause);
    }

    /// `a ⊗ b` — every concatenation of an element of `a` with one of `b`. Null
    /// when the product exceeds the atom ceiling, which is the caller's signal to
    /// treat the node as a boundary instead of a factor.
    fn cross(self: *Accum, a: []const []const u8, b: []const []const u8) ParseError!?[]const []const u8 {
        if (a.len * b.len > self.lim.atoms) return null;
        const out = try self.arena.alloc([]const u8, a.len * b.len);
        var i: usize = 0;
        for (a) |x| for (b) |y| {
            out[i] = if (x.len == 0) y else if (y.len == 0) x else try std.mem.concat(self.arena, u8, &.{ x, y });
            i += 1;
        };
        return out;
    }

    /// The COMPLETE set of strings `node` matches — every one of them, or null.
    /// Bounded by `lim.class`/`lim.atoms`. This is csearch's `exact` set, taken
    /// down to bytes so a small class is a choice point rather than a wall.
    fn exacts(self: *Accum, node: *Node) ParseError!?[]const []const u8 {
        switch (node.*) {
            .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word_boundary, .not_word_boundary, .word_start, .word_end => return try self.arena.dupe([]const u8, &.{""}),
            .class => |set| {
                const n = set.count();
                if (n == 0 or n > self.lim.class) return null;
                const out = try self.arena.alloc([]const u8, n);
                var i: usize = 0;
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (!set.has(@intCast(b))) continue;
                    out[i] = try self.arena.dupe(u8, &[_]u8{@intCast(b)});
                    i += 1;
                }
                return out;
            },
            .uclass => |ranges| {
                var n: usize = 0;
                for (ranges) |r| n += @as(usize, r[1] - r[0]) + 1;
                if (n == 0 or n > self.lim.class) return null;
                const out = try self.arena.alloc([]const u8, n);
                var i: usize = 0;
                for (ranges) |r| {
                    var cp: u21 = r[0];
                    while (cp <= r[1]) : (cp += 1) {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return null;
                        out[i] = try self.arena.dupe(u8, buf[0..len]);
                        i += 1;
                    }
                }
                return out;
            },
            .concat => |ab| {
                const x = (try self.exacts(ab[0])) orelse return null;
                const y = (try self.exacts(ab[1])) orelse return null;
                return self.cross(x, y);
            },
            .alt => |ab| {
                const x = (try self.exacts(ab[0])) orelse return null;
                const y = (try self.exacts(ab[1])) orelse return null;
                if (x.len + y.len > self.lim.atoms) return null;
                return try std.mem.concat(self.arena, []const u8, &.{ x, y });
            },
            .capture => |g| return self.exacts(g.child),
            // `x?` is exactly {ε, x} — a FINITE set, and the only repetition
            // that is. Reading it as opaque is what made `https?://` stop at
            // `http`; read as a choice point it factors the whole scheme into
            // {http://, https://}, two 7–8 B literals where csearch's planner
            // can only reach 3 B boundary trigrams.
            .quest => |r| {
                const inner = (try self.exacts(r.node)) orelse return null;
                if (inner.len + 1 > self.lim.atoms) return null;
                return try std.mem.concat(self.arena, []const u8, &.{ try self.arena.dupe([]const u8, &.{""}), inner });
            },
            .star, .plus => return null, // unbounded repetition is not a finite set
        }
    }

    /// The set of strings every match of `node` must BEGIN with, or null. Falls
    /// back to `exacts` where the whole node is known; the interesting case is a
    /// repetition, whose first iteration is mandatory (`\s+` ⇒ the `\s` members).
    fn heads(self: *Accum, node: *Node) ParseError!?[]const []const u8 {
        if (try self.exacts(node)) |ex| return ex;
        switch (node.*) {
            .plus => |r| return self.heads(r.node),
            .capture => |g| return self.heads(g.child),
            .concat => |ab| {
                if (try self.exacts(ab[0])) |x| {
                    const y = (try self.heads(ab[1])) orelse return x;
                    return self.cross(x, y);
                }
                return self.heads(ab[0]);
            },
            .alt => |ab| {
                const x = (try self.heads(ab[0])) orelse return null;
                const y = (try self.heads(ab[1])) orelse return null;
                if (x.len + y.len > self.lim.atoms) return null;
                return try std.mem.concat(self.arena, []const u8, &.{ x, y });
            },
            .star, .quest => return null, // may consume nothing
            else => return null,
        }
    }

    /// The mirror of `heads` — what every match must END with.
    fn tails(self: *Accum, node: *Node) ParseError!?[]const []const u8 {
        if (try self.exacts(node)) |ex| return ex;
        switch (node.*) {
            .plus => |r| return self.tails(r.node),
            .capture => |g| return self.tails(g.child),
            .concat => |ab| {
                if (try self.exacts(ab[1])) |y| {
                    const x = (try self.tails(ab[0])) orelse return y;
                    return self.cross(x, y);
                }
                return self.tails(ab[1]);
            },
            .alt => |ab| {
                const x = (try self.tails(ab[0])) orelse return null;
                const y = (try self.tails(ab[1])) orelse return null;
                if (x.len + y.len > self.lim.atoms) return null;
                return try std.mem.concat(self.arena, []const u8, &.{ x, y });
            },
            .star, .quest => return null,
            else => return null,
        }
    }
};

/// Flatten a right- or left-folded concat spine into visit order, so the run
/// accumulator sees adjacency the AST's shape would otherwise hide.
fn flatten(arena: std.mem.Allocator, node: *Node, out: *std.ArrayList(*Node)) ParseError!void {
    switch (node.*) {
        .concat => |ab| {
            try flatten(arena, ab[0], out);
            try flatten(arena, ab[1], out);
        },
        else => try out.append(arena, node),
    }
}

/// The shortest string a span of positions can produce — the only length that
/// may be compared against the trigram floor, since a longer alternative in the
/// same clause does not rescue a short one.
fn minBytes(positions: []const []const []const u8) usize {
    var n: usize = 0;
    for (positions) |p| {
        var least: usize = std.math.maxInt(usize);
        for (p) |s| least = @min(least, s.len);
        n += if (least == std.math.maxInt(usize)) 0 else least;
    }
    return n;
}

fn sameClause(a: Clause, b: Clause) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.len != y.len) return false;
        for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    }
    return true;
}

/// Total literals across a plan — the planner's own size, for the harness and
/// for a caller deciding whether to bother.
pub fn atomCount(p: []const Clause) usize {
    var n: usize = 0;
    for (p) |c| n += c.len;
    return n;
}
