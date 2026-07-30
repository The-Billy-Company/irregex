//! gist — regex *class-run analysis*: conservative, read-only reductions of an
//! AST (`../syntax/syntax.zig`) to a repeated single-class run, feeding the
//! SIMD class-run / class-span kernels (`../../scan/classrun.zig`) — the
//! dense-class escape from the DFA's chained table walk. Two strengths:
//!   • `classRunShape` proves the boolean reduction — match existence is
//!     exactly "the haystack holds ≥ `min` consecutive members of `set`".
//!   • `classSpanShape` proves the strictly stronger leftmost-first *window*
//!     rule that `find_iter`-style `-o` chunking needs.
//! Every reduction is conservative — a null only forgoes the SIMD kernel,
//! never a match.
//!
//! Private sibling of `analysis.zig`, which owns the AST-side literal layer and
//! re-exports `ClassRunShape`/`classRunShape`/`ClassSpanShape`/`no_max`/
//! `classSpanShape` as its public face; the compiled-NFA reachability visitors
//! are the third layer in `reach.zig`.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const Node = syn.Node;
const ByteSet = syn.ByteSet;

/// The provable class-run reduction of a whole pattern: match existence is
/// exactly "the haystack holds ≥ `min` consecutive members of `set`". Feeds
/// the SIMD class-run kernel (`scan/classrun.zig`) — the dense-class escape
/// from the DFA's chained table walk. `exact=false` marks an ASCII projection
/// of a codepoint class (`\w` under Unicode mode): a run-hit is still a real
/// match, but a miss is final only over a high-byte-free haystack — UNLESS
/// `cp` is present: the class's full codepoint ranges, carried through only
/// when every forcing leaf agreed on them, which upgrades the reduction to
/// "≥ `min` consecutive CODEPOINTS of `cp`" and lets the kernel settle high
/// bytes itself (no verdict deferral, no DFA needed at all).
pub const ClassRunShape = struct { set: ByteSet, min: u32, exact: bool, cp: ?[]const [2]u21 };

/// A sub-pattern's class-run summary. `set == null` means nullable; `empty_only`
/// distinguishes literal ε from a quantifier that may also consume bytes.
/// A consumed nullable prefix/suffix remains existence-transparent at the whole
/// pattern edge, but it dirties that edge: a later concat may not merge a run
/// through it (`digit [a-z]? digit` must decline, not invent digit{2}).
/// `cp` survives only when both forcing leaves carry the same full ranges.
const RunPart = struct {
    set: ?ByteSet,
    exact: bool,
    min: u32,
    cp: ?[]const [2]u21 = null,
    left_clean: bool = true,
    right_clean: bool = true,
    empty_only: bool = false,
};

const epsilon_part: RunPart = .{ .set = null, .exact = true, .min = 0, .empty_only = true };
const nullable_part: RunPart = .{ .set = null, .exact = true, .min = 0 };

/// If the whole pattern reduces to a class run, return its shape; else null.
/// The algebra: a class/`uclass` leaf is one forced unit; `+` is
/// existence-transparent (any child match IS a witness, any `+` match
/// contains one); `*`/`?` are nullable ⇒ transparent (regardless of what
/// they wrap — even a non-class-run child); concat sums forced floors when
/// both sides force adjacent bytes, and drops a nullable edge while recording
/// that no later merge may cross bytes it could consume; alternation takes the
/// weaker floor. Anything with a positioned assertion outside a nullable
/// wrapper declines. Conservative: a null only forgoes the SIMD kernel.
pub fn classRunShape(node: *Node) ?ClassRunShape {
    const p = runPart(node) orelse return null;
    const set = p.set orelse return null; // nullable pattern: eol_empty machinery owns it
    return .{ .set = set, .min = p.min, .exact = p.exact, .cp = p.cp };
}

fn runPart(node: *Node) ?RunPart {
    switch (node.*) {
        .empty => return epsilon_part,
        .class => |s| return .{ .set = s, .exact = true, .min = 1 },
        // A codepoint class forces one CODEPOINT; its ASCII members are the
        // byte-exact projection (codepoint ≡ byte below 0x80), so a run of
        // `min` projected bytes is `min` real codepoints in any haystack.
        // The full ranges ride along so the kernel can resolve high bytes.
        .uclass => |ranges| return .{ .set = uclassAscii(ranges), .exact = false, .min = 1, .cp = ranges },
        // Nullable quantifiers are existence-transparent no matter what they
        // wrap (ε embeds the sibling's match; any match contains a sibling
        // match) — the child is deliberately NOT inspected.
        .star, .quest => return nullable_part,
        // `E+` matches ⟺ `E` matches: one copy is a witness, and any
        // repetition contains a single-copy match as a substring.
        .plus => |r| return runPart(r.node),
        .capture => |g| return runPart(g.child), // transparent to boolean match
        .concat => |ab| {
            var x = runPart(ab[0]) orelse return null;
            var y = runPart(ab[1]) orelse return null;
            if (x.set == null and y.set == null) {
                return if (x.empty_only and y.empty_only) epsilon_part else nullable_part;
            }
            if (x.set == null) {
                y.left_clean = y.left_clean and x.empty_only;
                return y;
            }
            if (y.set == null) {
                x.right_clean = x.right_clean and y.empty_only;
                return x;
            }
            if (!x.right_clean or !y.left_clean) return null;
            const m = mergeLeaf(x, y) orelse return null;
            return .{
                .set = m.set,
                .exact = m.exact,
                .min = x.min +| y.min,
                .cp = m.cp,
                .left_clean = x.left_clean,
                .right_clean = y.right_clean,
            };
        },
        .alt => |ab| {
            const x = runPart(ab[0]) orelse return null;
            const y = runPart(ab[1]) orelse return null;
            if (x.set == null or y.set == null) return nullable_part; // a nullable branch nullifies the alt
            const m = mergeLeaf(x, y) orelse return null;
            return .{
                .set = m.set,
                .exact = m.exact,
                .min = @min(x.min, y.min),
                .cp = m.cp,
                .left_clean = x.left_clean and y.left_clean,
                .right_clean = x.right_clean and y.right_clean,
            };
        },
        // Positioned assertions gate on WHERE, which a run count can't see.
        .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => return null,
    }
}

/// The provable SPAN reduction of a whole pattern — a strictly stronger claim
/// than `classRunShape`'s boolean one: not just "a match exists ⟺ a run
/// exists", but that the leftmost-first match at any position `p` is exactly
///
///     match at p  ⟺  run(p) ≥ min,   with length = lazy ? min : @min(run(p), max)
///
/// where `run(p)` counts consecutive members from `p`. That window rule is
/// what `find_iter`-style `-o` chunking needs, and it holds only for a
/// pattern that is a CONCATENATION of quantifiers over ONE class leaf
/// (`\w+`, `[a-z]{3,8}`, `\w\w+`, `[0-9]{4}`): over a uniform set, greedy
/// backtracking always realizes the maximal feasible total and lazy the
/// minimal, and alternation/anchors — where branch priority or position
/// could beat run length — decline. `max == no_max` means unbounded.
pub const ClassSpanShape = struct { set: ByteSet, min: u32, max: u32, exact: bool, lazy: bool, cp: ?[]const [2]u21 };

pub const no_max: u32 = std.math.maxInt(u32);

/// A sub-pattern's span summary: it matches exactly the words `set^k` for
/// `min ≤ k ≤ max` (codepoint-wise when `cp` rides along), preferring
/// `max` copies when greedy and `min` when lazy. `lazy == null` ⇔ no
/// quantifier constrained preference yet (a bare leaf chain) — compatible
/// with either; mixed greedy/lazy quantifiers decline in the merge.
const SpanPart = struct { set: ByteSet, exact: bool, min: u32, max: u32, lazy: ?bool, cp: ?[]const [2]u21 };

/// If the whole pattern reduces to a span-exact class run, return its shape;
/// else null. `min == 0` (nullable — zero-width spans at every position)
/// declines: the Pike VM's progress rule owns that case.
pub fn classSpanShape(node: *Node) ?ClassSpanShape {
    const p = spanPart(node) orelse return null;
    if (p.min == 0) return null;
    return .{ .set = p.set, .min = p.min, .max = p.max, .exact = p.exact, .lazy = p.lazy orelse false, .cp = p.cp };
}

fn spanPart(node: *Node) ?SpanPart {
    switch (node.*) {
        .class => |s| return .{ .set = s, .exact = true, .min = 1, .max = 1, .lazy = null, .cp = null },
        .uclass => |ranges| return .{ .set = uclassAscii(ranges), .exact = false, .min = 1, .max = 1, .lazy = null, .cp = ranges },
        .capture => |g| return spanPart(g.child), // spans ignore groups
        // A quantifier is window-composable only over a SINGLE-unit body: a
        // multi-unit body (`(\w\w)+`) steps in strides, which the uniform
        // window rule can't express (`(\w\w)+` on "abc" matches 2, not 3).
        .star => |r| return quantified(r, 0, no_max),
        .plus => |r| return quantified(r, 1, no_max),
        .quest => |r| return quantified(r, 0, 1),
        .concat => |ab| {
            const x = spanPart(ab[0]) orelse return null;
            const y = spanPart(ab[1]) orelse return null;
            const m = mergeSpan(x, y) orelse return null;
            return .{
                .set = m.set,
                .exact = m.exact,
                .min = x.min +| y.min,
                .max = if (x.max == no_max or y.max == no_max) no_max else x.max +| y.max,
                .lazy = m.lazy,
                .cp = m.cp,
            };
        },
        else => return null,
    }
}

fn quantified(r: Node.Rep, lo: u32, hi: u32) ?SpanPart {
    const c = spanPart(r.node) orelse return null;
    if (c.min != 1 or c.max != 1) return null; // single-codepoint bodies only
    return .{ .set = c.set, .exact = c.exact, .min = lo, .max = hi, .lazy = r.lazy, .cp = c.cp };
}

/// Unify two span parts: the sets must be IDENTICAL (byte-exact when both
/// exact; identical full codepoint sets — not just projections — when a
/// codepoint class is involved, since the span kernel must resolve high
/// bytes itself), and quantifier preference must not mix greedy with lazy.
fn mergeSpan(x: SpanPart, y: SpanPart) ?struct { set: ByteSet, exact: bool, lazy: ?bool, cp: ?[]const [2]u21 } {
    const lazy: ?bool = if (x.lazy) |a|
        if (y.lazy) |b| (if (a == b) a else return null) else a
    else
        y.lazy;
    if (x.exact and y.exact) {
        if (!std.mem.eql(u64, &x.set.bits, &y.set.bits)) return null;
        return .{ .set = x.set, .exact = true, .lazy = lazy, .cp = null };
    }
    if (x.exact != y.exact) return null;
    const cp = sameRanges(x.cp, y.cp) orelse return null;
    return .{ .set = x.set, .exact = false, .lazy = lazy, .cp = cp };
}

/// Unify two forcing parts' byte sets. Two exact sets must agree on all 256
/// bytes. Once a codepoint-class projection is involved, the kernel already
/// defers any high-byte haystack to the full engine, so only the ASCII
/// halves must agree — and the merged set is that shared projection. The
/// codepoint ranges survive the merge only when both sides carry the SAME
/// ranges (pointer-or-content equal), which is the exact condition for the
/// codepoint-level run invariant to keep holding.
fn mergeLeaf(x: RunPart, y: RunPart) ?struct { set: ByteSet, exact: bool, cp: ?[]const [2]u21 } {
    const a = x.set.?;
    const b = y.set.?;
    if (x.exact and y.exact) {
        if (!std.mem.eql(u64, &a.bits, &b.bits)) return null;
        return .{ .set = a, .exact = true, .cp = null };
    }
    const pa = asciiProject(a);
    const pb = asciiProject(b);
    if (!std.mem.eql(u64, &pa.bits, &pb.bits)) return null;
    return .{ .set = pa, .exact = false, .cp = sameRanges(x.cp, y.cp) };
}

/// Both parts' full codepoint sets, when they agree; null otherwise. An
/// exact-ASCII part (`cp == null`) never agrees — its "full set" is its byte
/// set, which the projection equality already covers only up to 0x7F.
fn sameRanges(x: ?[]const [2]u21, y: ?[]const [2]u21) ?[]const [2]u21 {
    const a = x orelse return null;
    const b = y orelse return null;
    if (a.ptr == b.ptr and a.len == b.len) return a;
    if (a.len != b.len) return null;
    for (a, b) |ra, rb| {
        if (ra[0] != rb[0] or ra[1] != rb[1]) return null;
    }
    return a;
}

/// The byte-exact ASCII slice of a codepoint-range class (codepoint ≡ byte
/// below 0x80; everything above is multi-byte UTF-8 the kernel defers on).
fn uclassAscii(ranges: []const [2]u21) ByteSet {
    var s: ByteSet = .{};
    for (ranges) |r| {
        if (r[0] > 0x7F) break; // sorted + coalesced: nothing ASCII follows
        s.setRange(@intCast(r[0]), @intCast(@min(r[1], 0x7F)));
    }
    return s;
}

fn asciiProject(s: ByteSet) ByteSet {
    return .{ .bits = .{ s.bits[0], s.bits[1], 0, 0 } };
}
