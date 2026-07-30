//! The identities. What is true of the operators regardless of what they are
//! applied to, spent to make the graph smaller before anything reads it.
//!
//! A regex operator algebra is small and completely known: concatenation has ε
//! as its unit, alternation is idempotent and its union of two byte classes is
//! a byte class, and the three closure operators compose into exactly one of
//! themselves. Each identity is worth a rule only because the DAG makes them
//! cheap to apply — a rewrite is one `intern` of a node whose children are
//! already final, and hash-consing decides in one comparison whether it changed
//! anything.
//!
//! The rules are carried by SMART CONSTRUCTORS rather than by a pattern-matching
//! pass, so a rewrite that exposes another rewrite is closed by construction:
//! `alt` of two classes builds a class, and a `star` above it consults the
//! closure table against that class rather than against the alternation that is
//! no longer there. [`simplify`](#simplify) is then just one forward pass
//! rebuilding each node through those constructors — bottom-up is a fixpoint
//! here because every rule is local and every child is final before its parent
//! is built.
//!
//! Deliberately NOT an e-graph. `egg`-style saturation keeps every equivalent
//! form so a cost function can choose among them; here every rule strictly
//! shrinks the graph, so there is nothing to choose and one canonical form is
//! the whole answer.
//!
//! Scope. These are LANGUAGE identities: they preserve which strings match, and
//! `(a*)*` → `a*` visibly does not preserve how a backtracker would get there.
//! That is exactly the trade `ast/` already made — the engine lowers the
//! parser's own tree and keeps leftmost-first priority; this graph exists to be
//! asked questions of, and the answers are properties of the language.
//!
//! `L((x)) = L(x)` is on that list, and it has to be. A group is where real
//! patterns put their alternations, so a canonicalizer that stopped at a
//! capture would decline to merge `(a|b|c)` and decline to flatten `(a*)*` —
//! the two rules most worth having, blocked by a node every fact already looks
//! straight through. So the pass drops captures, and the faithful shape stays
//! one call away: `analyze` with `canonicalize = false` keeps every group, and
//! the capture VM was never going to read this graph anyway — it lowers the
//! parser's tree, where the group indices still live.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const intern = @import("intern.zig");

const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;
const Id = intern.Id;
const Op = intern.Op;
const Graph = intern.Graph;
const none: Id = .none;

/// What one canonicalization pass did.
pub const Report = struct {
    root: Id,
    /// Nodes whose rebuild landed somewhere other than where they started —
    /// the rules that fired, counted once each.
    rewrites: u32,
    /// Live nodes before and after. The superseded originals stay in the graph
    /// (interning never removes); `Dag.live` separates them from the rubble.
    before: usize,
    after: usize,
};

/// Rebuild every node of `g` through the smart constructors and report the new
/// root. `arena` owns any merged codepoint range list and must outlive the
/// graph; `gpa` owns the graph as before.
pub fn simplify(gpa: std.mem.Allocator, arena: std.mem.Allocator, g: *Graph, root: Id) ParseError!Report {
    const n0 = g.len();
    const map = try gpa.alloc(Id, n0);
    defer gpa.free(map);

    var rewrites: u32 = 0;
    for (0..n0) |i| {
        const here: Id = @enumFromInt(i);
        const kids = g.kidsOf(here);
        // Children are strictly lower, so their images are already decided.
        const a = if (kids[0].present()) map[kids[0].index()] else none;
        const b = if (kids[1].present()) map[kids[1].index()] else none;
        map[i] = try rebuild(gpa, arena, g, g.payload(here), a, b);
        if (map[i] != here) rewrites += 1;
    }

    const out = map[root.index()];
    return .{
        .root = out,
        .rewrites = rewrites,
        .before = n0,
        .after = try reachable(gpa, g, out),
    };
}

fn reachable(gpa: std.mem.Allocator, g: *const Graph, root: Id) !usize {
    const live = try g.live(gpa, &.{root});
    defer gpa.free(live);
    var n: usize = 0;
    for (live) |on| n += @intFromBool(on);
    return n;
}

fn rebuild(gpa: std.mem.Allocator, arena: std.mem.Allocator, g: *Graph, op: Op, a: Id, b: Id) ParseError!Id {
    return switch (op) {
        .concat => cat(gpa, g, a, b),
        .alt => either(gpa, arena, g, a, b),
        .star => |lazy| rep(gpa, g, .star, lazy, a),
        .plus => |lazy| rep(gpa, g, .plus, lazy, a),
        .quest => |lazy| rep(gpa, g, .quest, lazy, a),
        // `L((x)) = L(x)`. Dropping the group is what lets every other rule
        // reach the operator underneath it.
        .capture => a,
        else => g.intern(gpa, op, .{ a, b }),
    };
}

// ── the identities ───────────────────────────────────────────────────────────

/// `ε·x = x = x·ε`. The unit law, and the only concatenation identity that is
/// unconditionally sound: adjacent equal operands are a repetition, which
/// `intern` already raises by squaring, and everything else about a
/// concatenation is order.
pub fn cat(gpa: std.mem.Allocator, g: *Graph, a: Id, b: Id) ParseError!Id {
    if (isEmpty(g, a)) return b;
    if (isEmpty(g, b)) return a;
    return g.intern(gpa, .concat, .{ a, b });
}

/// Alternation's three identities: idempotence (`x|x = x`), unit-as-option
/// (`x|ε = x?`), and — the one that pays — the union of two character classes
/// being a character class.
///
/// The class union is why `(a|b|c|d)` costs one node here and four plus three
/// alternations in the parse tree: the balanced `alt` spine `intern` builds
/// collapses pairwise from the bottom, so an n-way alternation of literals
/// becomes a single byte class in `n−1` unions. Every downstream analysis then
/// sees a class — one first-set, one length, one prefilter lane — instead of a
/// branch it has to reason about.
pub fn either(gpa: std.mem.Allocator, arena: std.mem.Allocator, g: *Graph, a: Id, b: Id) ParseError!Id {
    if (a == b) return a;

    // `x|ε` prefers x and `ε|x` prefers ε, which is exactly greedy versus lazy
    // `x?` — so the option this folds to carries the branch order it replaced.
    if (isEmpty(g, b)) return rep(gpa, g, .quest, false, a);
    if (isEmpty(g, a)) return rep(gpa, g, .quest, true, b);

    if (try merged(arena, g.payload(a), g.payload(b))) |op| return g.intern(gpa, op, .{ none, none });
    return g.intern(gpa, .alt, .{ a, b });
}

pub const Closure = enum { star, plus, quest };

/// The closure composition table. Two nested closures are always one closure,
/// because the language each denotes depends only on whether zero iterations
/// and whether unboundedly many are allowed — and both properties are decided
/// by the pair, not by the nesting.
///
/// This is the rule that retires the star-height problem rather than measuring
/// it: `parabix`'s bit-parallel rung admits only height ≤ 1, and a pattern like
/// `(a*)*` is height 2 written down and height 1 in fact. Collapsing first
/// means the rung's admission test sees what the language actually costs.
pub fn rep(gpa: std.mem.Allocator, g: *Graph, kind: Closure, lazy: bool, child: Id) ParseError!Id {
    // ε repeated any number of times is still ε.
    if (isEmpty(g, child)) return child;

    // Only fold a nest whose priority agrees. Greedy-over-lazy denotes the same
    // language, but its two levels disagree about which match to prefer, and
    // flattening it would quietly pick one — a rewrite that has to choose is
    // not an identity.
    if (inner(g.payload(child))) |in| if (in.lazy == lazy) {
        const folded: Closure = switch (kind) {
            .star => .star,
            .plus => if (in.kind == .plus) .plus else .star,
            .quest => if (in.kind == .quest) .quest else .star,
        };
        return g.intern(gpa, payload(folded, lazy), g.kidsOf(child));
    };

    return g.intern(gpa, payload(kind, lazy), .{ child, none });
}

fn payload(kind: Closure, lazy: bool) Op {
    return switch (kind) {
        .star => .{ .star = lazy },
        .plus => .{ .plus = lazy },
        .quest => .{ .quest = lazy },
    };
}

fn inner(op: Op) ?struct { kind: Closure, lazy: bool } {
    return switch (op) {
        .star => |l| .{ .kind = .star, .lazy = l },
        .plus => |l| .{ .kind = .plus, .lazy = l },
        .quest => |l| .{ .kind = .quest, .lazy = l },
        else => null,
    };
}

fn tag(op: Op) std.meta.Tag(Op) {
    return std.meta.activeTag(op);
}

fn isEmpty(g: *const Graph, id: Id) bool {
    return id.present() and tag(g.payload(id)) == .empty;
}

// ── class union ──────────────────────────────────────────────────────────────

/// The union of two consuming classes, when it is itself one class.
///
/// A byte class and a codepoint class only merge when the byte class is pure
/// ASCII. Above 0x7F the two mean different things — a `class` bit is one raw
/// byte, a `uclass` range is a scalar that encodes to several — so unioning
/// them would silently reinterpret the bytes, and the pair is left as an
/// alternation instead.
fn merged(arena: std.mem.Allocator, x: Op, y: Op) ParseError!?Op {
    if (tag(x) == .class and tag(y) == .class) {
        var set = x.class;
        set.unionWith(y.class);
        return .{ .class = set };
    }
    // Runs in 128 ASCII bytes cannot exceed 64, so the scratch never overflows.
    var xbuf: [64][2]u21 = undefined;
    var ybuf: [64][2]u21 = undefined;
    const xr = ranges(x, &xbuf) orelse return null;
    const yr = ranges(y, &ybuf) orelse return null;
    return .{ .uclass = try coalesced(arena, xr, yr) };
}

/// A consuming class as scalar ranges — null when the operand is not a class at
/// all, or is a byte class carrying a byte that is not a codepoint.
fn ranges(op: Op, buf: *[64][2]u21) ?[]const [2]u21 {
    return switch (op) {
        .uclass => |r| r,
        .class => |c| asciiRanges(c, buf),
        else => null,
    };
}

/// An all-ASCII byte set as scalar ranges, written into `buf`. Null when any
/// byte ≥ 0x80 is present, which is where a byte stops being a codepoint.
fn asciiRanges(set: ByteSet, buf: *[64][2]u21) ?[]const [2]u21 {
    if (set.bits[2] != 0 or set.bits[3] != 0) return null;
    var n: usize = 0;
    var b: u16 = 0;
    while (b <= 0x7F) {
        if (!set.has(@intCast(b))) {
            b += 1;
            continue;
        }
        const lo = b;
        while (b <= 0x7F and set.has(@intCast(b))) b += 1;
        buf[n] = .{ @intCast(lo), @intCast(b - 1) };
        n += 1;
    }
    return if (n == 0) null else buf[0..n];
}

/// Sorted, coalesced union of two range lists — the `uclass` normal form the
/// parser's `ScalarSet` also produces, so a merged class is indistinguishable
/// from one that was written that way.
fn coalesced(arena: std.mem.Allocator, x: []const [2]u21, y: []const [2]u21) ParseError![]const [2]u21 {
    const all = try arena.alloc([2]u21, x.len + y.len);
    @memcpy(all[0..x.len], x);
    @memcpy(all[x.len..], y);
    std.mem.sort([2]u21, all, {}, struct {
        fn lt(_: void, p: [2]u21, q: [2]u21) bool {
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    }.lt);
    var w: usize = 0;
    for (all) |r| {
        // Widened: 0x10FFFF's successor does not fit in a u21.
        if (w > 0 and r[0] <= @as(u32, all[w - 1][1]) + 1) {
            if (r[1] > all[w - 1][1]) all[w - 1][1] = r[1];
        } else {
            all[w] = r;
            w += 1;
        }
    }
    return all[0..w];
}
