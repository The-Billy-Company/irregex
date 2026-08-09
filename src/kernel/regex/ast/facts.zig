//! The fused sweep — every synthesized attribute of a pattern's shape, computed
//! in one forward pass over the interned AST.
//!
//! Fusing is not a mechanism here; it is one `fold` whose accumulator happens to
//! be a struct. That is the property worth keeping: adding the next question
//! costs a field and a few lines in `sweep`, not another traversal of the tree.
//!
//! Soundness posture is inherited from the analyses these replace — every fact
//! is a conservative under-claim, so a wrong "don't know" costs a full scan and
//! never a missed match.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const analysis = @import("../analysis/analysis.zig");
const intern = @import("intern.zig");

const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;
const Id = intern.Id;
const Op = intern.Op;

/// A length no bounded repetition can reach — `star`/`plus` saturate here.
pub const unbounded: u32 = std.math.maxInt(u32);

/// Everything one sweep learns about a node. Each field either replaces a
/// traversal that exists today, or supplies one the pipeline currently recovers
/// the hard way from the compiled program.
pub const Facts = struct {
    /// Mandatory-literal facts for the trigram prefilter. Replaces
    /// `analysis.literalInfo`, and makes `requiredAny` linear by handing it the
    /// per-node answer it currently recomputes at every level.
    lit: analysis.LitInfo,
    /// Bytes a match of this node may begin with. Today's `analyzeFirst` walks
    /// the compiled NFA to recover this; the AST knew it all along.
    first: ByteSet,
    /// Can match the empty string. Today: `reachesMatchZeroWidth`, over the
    /// compiled program.
    nullable: bool,
    /// Every match must begin at a line start. Replaces `analysis.startsAnchored`.
    anchored: bool,
    /// Shortest and longest match in bytes; `max == unbounded` under a Kleene
    /// closure. New — nothing computes these today, and they are what a cost
    /// model and a bounded-window prefilter need.
    min_len: u32,
    max_len: u32,
    /// Kleene nesting depth. Replaces `parabix/admit.starHeight`, whose rung
    /// admits only at height ≤ 1. Counts the UNBOUNDED closures only — `?`
    /// repeats at most once, so it adds no iteration nesting for the
    /// bit-parallel rung to unroll.
    star_height: u8,
    /// Holds a codepoint class anywhere. Replaces `symbolic.hasCodepointClass`.
    has_cp: bool,
    /// Leaves this node would have if the DAG were expanded back to a tree —
    /// the size every recursive walker actually pays, and the size this one
    /// does not.
    leaves: u32,
};

/// The fold body. Sees only `done`, the facts of strictly-lower ids, which is
/// every child's answer and nothing else.
pub fn sweep(arena: std.mem.Allocator, _: Id, op: Op, kids: [2]Id, done: []const Facts) ParseError!Facts {
    return switch (op) {
        .empty, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => zeroWidth(false),
        .anchor_start => zeroWidth(true),

        .class => |set| consuming(litOfClass(arena, set) catch |e| return e, set, 1),
        .uclass => |ranges| consumingCp(try analysis.uclassLiteral(arena, ranges), leadBytes(ranges), utf8Min(ranges), utf8Max(ranges)),

        .concat => cat(arena, done[kids[0].index()], done[kids[1].index()]),
        .alt => either(done[kids[0].index()], done[kids[1].index()]),

        // A capture is structurally transparent to every analysis here, exactly
        // as it is to the main compiler; only the capture VM reads its index.
        .capture => done[kids[0].index()],

        .plus => repeated(done[kids[0].index()], .plus),
        .star => repeated(done[kids[0].index()], .star),
        .quest => repeated(done[kids[0].index()], .quest),
    };
}

/// A zero-width node matches the empty string at a position, so `exact = ""`
/// deliberately lets a mandatory literal run span it: `^func` yields "func",
/// and so does `\bfunc\b`.
fn zeroWidth(anchors: bool) Facts {
    return .{
        .lit = .{ .exact = "", .prefix = "", .suffix = "", .best = "" },
        .first = .{},
        .nullable = true,
        .anchored = anchors,
        .min_len = 0,
        .max_len = 0,
        .star_height = 0,
        .has_cp = false,
        .leaves = 1,
    };
}

fn litOfClass(arena: std.mem.Allocator, set: ByteSet) ParseError!?[]const u8 {
    const b = set.only() orelse return null;
    return try arena.dupe(u8, &[_]u8{b});
}

fn consuming(lit: ?[]const u8, set: ByteSet, width: u32) Facts {
    return .{
        .lit = if (lit) |l|
            .{ .exact = l, .prefix = l, .suffix = l, .best = l }
        else
            .{ .exact = null, .prefix = "", .suffix = "", .best = "" },
        .first = set,
        .nullable = false,
        .anchored = false,
        .min_len = width,
        .max_len = width,
        .star_height = 0,
        .has_cp = false,
        .leaves = 1,
    };
}

fn consumingCp(lit: ?[]const u8, leads: ByteSet, lo: u32, hi: u32) Facts {
    var f = consuming(lit, leads, lo);
    f.max_len = hi;
    f.has_cp = true;
    return f;
}

/// Lead bytes any codepoint in `ranges` can start with. Sound by construction:
/// a range reaching past ASCII contributes every lead byte its members could
/// use, so the set is a superset and a prefilter built on it can only
/// over-admit.
fn leadBytes(ranges: []const [2]u21) ByteSet {
    var set: ByteSet = .{};
    for (ranges) |r| {
        const lo = r[0];
        const hi = r[1];
        if (lo <= 0x7F) set.setRange(@intCast(lo), @intCast(@min(hi, 0x7F)));
        if (hi < 0x80) continue;
        set.setRange(leadOf(@max(lo, 0x80)), leadOf(hi));
    }
    return set;
}

fn leadOf(cp: u21) u8 {
    if (cp < 0x800) return @intCast(0xC0 | (cp >> 6));
    if (cp < 0x10000) return @intCast(0xE0 | (cp >> 12));
    return @intCast(0xF0 | (cp >> 18));
}

fn utf8Min(ranges: []const [2]u21) u32 {
    var best: u32 = 4;
    for (ranges) |r| best = @min(best, utf8Len(r[0]));
    return best;
}
fn utf8Max(ranges: []const [2]u21) u32 {
    var best: u32 = 1;
    for (ranges) |r| best = @max(best, utf8Len(r[1]));
    return best;
}
fn utf8Len(cp: u21) u32 {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

fn cat(arena: std.mem.Allocator, x: Facts, y: Facts) ParseError!Facts {
    return shaped(x, y, try catLit(arena, x.lit, y.lit));
}

/// Literal facts follow `analysis.literalInfo` exactly: a mandatory prefix run
/// extends through x into y only when x is fully exact, symmetrically for the
/// suffix, and the boundary span — x's mandatory tail immediately followed by
/// y's mandatory head — is itself mandatory and contiguous. That span is what
/// recovers the trailing literal a non-exact prefix would otherwise hide
/// (`a*function` ⇒ "function", not "f").
fn catLit(arena: std.mem.Allocator, x: analysis.LitInfo, y: analysis.LitInfo) ParseError!analysis.LitInfo {
    // Every constructor here maintains one invariant: a node that HAS an exact
    // has that same string as its prefix and its suffix. So when both sides are
    // exact, all four fields below name the same concatenation — and a literal
    // spine, which is the common shape and the one that reaches thousands of
    // nodes, costs one allocation per node instead of four.
    if (x.exact) |xe| if (y.exact) |ye| {
        const whole = try join(arena, xe, ye);
        return .{ .exact = whole, .prefix = whole, .suffix = whole, .best = whole };
    };
    const prefix = if (x.exact) |xe| try join(arena, xe, y.prefix) else x.prefix;
    const suffix = if (y.exact) |ye| try join(arena, x.suffix, ye) else y.suffix;
    const span = try join(arena, x.suffix, y.prefix);
    return .{
        .exact = null,
        .prefix = prefix,
        .suffix = suffix,
        .best = longer(longer(x.best, y.best), span),
    };
}

/// Concatenation that does not allocate to say what one side already says.
/// Zero-width nodes and single-byte classes make an empty operand the common
/// case, and the result is only ever read, never appended to.
///
/// Public because `flank.zig` joins the same literals over the same DAG, one
/// member at a time instead of one run at a time, and two spellings of "append
/// a literal without paying for an empty operand" would be the same code twice.
pub fn join(arena: std.mem.Allocator, a: []const u8, b: []const u8) ParseError![]const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    return std.mem.concat(arena, u8, &.{ a, b });
}

/// Everything about a concatenation that isn't its literals.
fn shaped(x: Facts, y: Facts, lit: analysis.LitInfo) Facts {
    var first = x.first;
    if (x.nullable) first.unionWith(y.first);
    return .{
        .lit = lit,
        .first = first,
        .nullable = x.nullable and y.nullable,
        // Mirrors `startsAnchored`: only the left operand can anchor a concat.
        // Re-association never moves which operand is leftmost in the flattened
        // spine, so this is invariant under the rebalancing `intern` does.
        .anchored = x.anchored,
        .min_len = x.min_len +| y.min_len,
        .max_len = if (x.max_len == unbounded or y.max_len == unbounded) unbounded else x.max_len +| y.max_len,
        .star_height = @max(x.star_height, y.star_height),
        .has_cp = x.has_cp or y.has_cp,
        .leaves = x.leaves +| y.leaves,
    };
}

fn either(x: Facts, y: Facts) Facts {
    var first = x.first;
    first.unionWith(y.first);
    return .{
        // An alternation guarantees no literal of its own. The cover set that
        // CAN speak for it is `requiredAny`, which reads these per-branch facts
        // instead of recomputing them.
        .lit = .{ .exact = null, .prefix = "", .suffix = "", .best = "" },
        .first = first,
        .nullable = x.nullable or y.nullable,
        .anchored = x.anchored and y.anchored,
        .min_len = @min(x.min_len, y.min_len),
        .max_len = @max(x.max_len, y.max_len),
        .star_height = @max(x.star_height, y.star_height),
        .has_cp = x.has_cp or y.has_cp,
        .leaves = x.leaves +| y.leaves,
    };
}

fn repeated(x: Facts, comptime kind: enum { star, plus, quest }) Facts {
    return .{
        // `plus` occurs at least once, so its content's mandatory runs survive
        // — but the minimum is a single iteration, so there is no
        // cross-iteration run and the whole is not exact. `star`/`quest` may
        // occur zero times and guarantee nothing.
        .lit = if (kind == .plus)
            .{ .exact = null, .prefix = x.lit.prefix, .suffix = x.lit.suffix, .best = x.lit.best }
        else
            .{ .exact = null, .prefix = "", .suffix = "", .best = "" },
        .first = x.first,
        .nullable = kind != .plus or x.nullable,
        .anchored = kind == .plus and x.anchored,
        .min_len = if (kind == .plus) x.min_len else 0,
        .max_len = switch (kind) {
            .quest => x.max_len,
            .star, .plus => unbounded,
        },
        .star_height = if (kind == .quest) x.star_height else x.star_height +| 1,
        .has_cp = x.has_cp,
        .leaves = x.leaves,
    };
}

fn longer(a: []const u8, b: []const u8) []const u8 {
    return if (a.len >= b.len) a else b;
}
