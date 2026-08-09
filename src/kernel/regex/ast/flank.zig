//! The flanks of a match — the literal SETS every match must begin and end
//! with, where `facts.zig` proves one run per side.
//!
//! `LitInfo.prefix` is the strongest form of this answer that fits in a single
//! string: the longest literal every match provably starts with. It is also
//! empty for the shape a host most wants it for. `foo|bar` has no common
//! prefix, so the run is `""` and a host holding an index gets nothing to probe
//! with — even though two anchored probes would settle the question outright.
//! `regex-syntax`'s `hir::literal` answers with a set for exactly this reason,
//! and this file is that answer over the same interned DAG the rest of `ast/`
//! reads.
//!
//! **A set form is only usable if it is EXHAUSTIVE.** "Every match starts with
//! SOME member" licenses a host to run one anchored probe per member and
//! conclude nothing matched when all of them miss. "Here are some literals seen
//! at the start of some matches" licenses nothing at all, and a host that mistook
//! the second for the first would silently miss matches — the one unforgivable
//! bug in a search library. So exhaustiveness here is STRUCTURAL rather than
//! graded: a shape this file cannot prove exhaustive answers `null`, and there
//! is deliberately no spelling for "some of the prefixes".
//!
//! Because the claim is exhaustiveness and not equality, two weakenings are
//! free and worth knowing about: a member may be SHORTENED (anything starting
//! with `foobar` starts with `foo`), and a member whose extension is already
//! covered by a shorter member may be DROPPED. Nothing may be dropped
//! otherwise. `absorb` spends the second of those; the first is left to a
//! caller who would rather run three-byte probes than nine-byte ones.
//!
//! ## The algebra
//!
//! Three sets per node, and one invariant that ties them:
//!
//!   * `whole` — a finite set that CONTAINS every string the node can match.
//!     A superset, not an equality: `^foo` matches only at a line start, and
//!     `whole = {"foo"}` still holds because every match of it *is* `"foo"`.
//!     Superset is exactly what the concatenation rule needs, which is why the
//!     weaker claim is the one stored.
//!   * `leading` / `trailing` — exhaustive prefix and suffix sets.
//!
//! Invariant: a node with a `whole` has that same set as both flanks, because a
//! string is a prefix and a suffix of itself. Every constructor maintains it,
//! and it is what makes concatenation a two-line rule.
//!
//! | node | `whole` | `leading` |
//! |---|---|---|
//! | zero-width (`^`, `$`, `\b`, ε) | `{""}` | `{""}` |
//! | class / uclass, enumerable | one member per byte / codepoint | same |
//! | `x·y` | `whole(x) × whole(y)` | `whole(x) × leading(y)`, else `leading(x)` |
//! | `x\|y` | union | union |
//! | `x+` | — | `leading(x)` |
//! | `x?` | `whole(x) ∪ {""}` | same |
//! | `x*` | — | `{""}` |
//!
//! The concatenation rule is the whole point: a prefix set can only be extended
//! THROUGH the left operand when that operand's language is finitely
//! enumerable, because otherwise there is no way to say what byte the right
//! operand's contribution begins at. `a*function` therefore gets nothing, and
//! `(a|b)cdef` gets `{acdef, bcdef}` — an alternation the run form reported as
//! empty.
//!
//! `{""}` inside an intermediate set is load-bearing (it is how `^foo` reaches
//! `{"foo"}` at all) and inadmissible in an answer: a set holding the empty
//! string is exhaustive and admits every position, which is a filter that
//! eliminates nothing while costing a probe. `usable` is where that is refused,
//! once, at the boundary.
//!
//! Soundness posture matches the rest of the layer: every `null` costs a full
//! scan and no `null` can cost a match.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const analysis = @import("../analysis/analysis.zig");
const intern = @import("intern.zig");
const facts = @import("facts.zig");

const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;
const Id = intern.Id;
const Graph = intern.Graph;

/// Literals a match must begin (or end) with — one probe per member.
pub const Set = []const []const u8;

/// Which end of a match a set speaks about. The two are mirror images
/// everywhere except in `absorb`, where one asks about prefixes and the other
/// about suffixes.
pub const Side = enum { leading, trailing };

/// Members a set may hold before it is withheld whole.
///
/// The economics are `analysis.max_cover`'s: a host runs one anchored probe per
/// member, so past some width a full scan is cheaper than the probes — and a
/// set that would exceed the cap is REFUSED rather than truncated, because a
/// truncated cover is no longer exhaustive and is therefore not the fact the
/// caller was promised.
pub const max_members: usize = 64;

/// Bytes one member may reach before a cross is declined.
///
/// The cap exists because repeated squaring means a nested bound like
/// `(a{40}){40}` is a handful of nodes each holding a literal orders of
/// magnitude longer than the pattern: cheap for the DAG, and expensive for
/// anyone materializing one string per member. Declining leaves the shorter set
/// the left operand already proved, which is weaker and still exhaustive — and
/// `sharpen` then prefers the mandatory run, which is longer still.
pub const max_bytes: usize = 1024;

/// The two answers, each `null` where nothing is provable.
pub const Flanks = struct {
    leading: ?Set,
    trailing: ?Set,
};

/// The one-member set holding the empty string: what a zero-width node matches,
/// and the unit the concatenation rule multiplies through.
const nil: Set = &.{""};

/// One node's three sets, `null` for each one it cannot prove.
const Claim = struct {
    whole: ?Set = null,
    leading: ?Set = null,
    trailing: ?Set = null,

    /// Nothing provable — the answer for a class too wide to enumerate.
    const nothing: Claim = .{};

    /// A node whose language `s` contains: both flanks are `s` too, since a
    /// string is a prefix and a suffix of itself.
    fn exactly(s: Set) Claim {
        return .{ .whole = s, .leading = s, .trailing = s };
    }

    /// A node that may match nothing at all (`x*`), so it starts and ends with
    /// nothing in particular — and cannot be enumerated, since it is infinite.
    const anywhere: Claim = .{ .whole = null, .leading = nil, .trailing = nil };
};

/// Sweep the DAG for both flank sets. `arena` owns the answer and every byte
/// reachable from it.
///
/// One forward pass, as everything over this graph is: ids are topological by
/// construction, so a child's sets are already sitting in `memo` when its
/// parent is reached, and a shared subtree is enumerated once no matter how many
/// parents want it. Superseded nodes are skipped rather than swept — a set costs
/// an allocation per node, which is the same reason `Ast.cover` skips them and
/// the arithmetic-only sweep in `facts.zig` does not.
pub fn flanks(arena: std.mem.Allocator, g: *const Graph, root: Id) ParseError!Flanks {
    const memo = try arena.alloc(Claim, g.len());
    const reach = try g.live(arena, &.{root});
    for (memo, reach, 0..) |*slot, alive, i| {
        if (!alive) {
            slot.* = .nothing;
            continue;
        }
        const kids = g.kidsOf(@enumFromInt(i));
        slot.* = switch (g.payload(@enumFromInt(i))) {
            // A zero-width node matches the empty string at a position, which
            // is what lets a mandatory run span it: `^foo` is `{""} × {"foo"}`.
            .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word => .exactly(nil),

            .class => |set| try ofClass(arena, set),
            .uclass => |ranges| try ofScalars(arena, ranges),

            .concat => try cat(arena, memo[kids[0].index()], memo[kids[1].index()]),
            .alt => try either(arena, memo[kids[0].index()], memo[kids[1].index()]),
            // Transparent, exactly as it is to every other analysis here.
            .capture => memo[kids[0].index()],

            // One iteration is mandatory, so the first one's start is the
            // match's start and the last one's end is the match's end — but the
            // language is infinite, so there is no `whole`.
            .plus => once(memo[kids[0].index()]),
            .quest => try optional(arena, memo[kids[0].index()]),
            .star => .anywhere,
        };
    }

    const at = memo[root.index()];
    return .{
        .leading = try usable(arena, at.leading, .leading),
        .trailing = try usable(arena, at.trailing, .trailing),
    };
}

/// The better of a proved flank set and the sweep's own single mandatory run.
///
/// Both are exhaustive claims about the same side, so either may be answered and
/// the question is only which one a host would rather have. Selectivity is the
/// set's WEAKEST member — `analysis.weakest`, the same rule the cover calculus
/// picks covers by — and cost is one probe per member, so the run wins when it
/// is longer, and on a tie when the set would charge more probes for the same
/// selectivity.
///
/// This is not a tidiness pass. It is what makes the set form provably no weaker
/// than the run form it replaces at the C seam, including at `max_bytes`, where a
/// cross is declined and the run keeps going.
pub fn sharpen(arena: std.mem.Allocator, set: ?Set, run: []const u8) ParseError!?Set {
    if (run.len == 0) return set;
    const s = set orelse return try lone(arena, run);
    const floor = analysis.weakest(s);
    if (run.len > floor or (run.len == floor and s.len > 1)) return try lone(arena, run);
    return s;
}

fn lone(arena: std.mem.Allocator, member: []const u8) ParseError!Set {
    return try arena.dupe([]const u8, &.{member});
}

// ── the leaves ───────────────────────────────────────────────────────────────

fn ofClass(arena: std.mem.Allocator, set: ByteSet) ParseError!Claim {
    const n = set.count();
    if (n == 0 or n > max_members) return .nothing;
    const out = try arena.alloc([]const u8, n);
    var w: usize = 0;
    var b: u16 = 0;
    while (b <= 0xFF) : (b += 1) {
        if (!set.has(@intCast(b))) continue;
        out[w] = try arena.dupe(u8, &[_]u8{@intCast(b)});
        w += 1;
    }
    return .exactly(out);
}

/// A codepoint class as the UTF-8 strings it matches — the encoding the engine
/// lowers it to, so the members are the byte strings a match really consumes.
/// An unencodable scalar (a lone surrogate, which no valid UTF-8 input carries)
/// withholds the whole claim rather than being skipped: a member missing from a
/// set that promises exhaustiveness is the one error worth failing closed on.
fn ofScalars(arena: std.mem.Allocator, ranges: []const [2]u21) ParseError!Claim {
    var n: usize = 0;
    for (ranges) |r| {
        if (r[1] < r[0]) return .nothing;
        n += @as(usize, r[1] - r[0]) + 1;
        if (n > max_members) return .nothing;
    }
    if (n == 0) return .nothing;

    const out = try arena.alloc([]const u8, n);
    var w: usize = 0;
    for (ranges) |r| {
        var cp: u32 = r[0];
        while (cp <= r[1]) : (cp += 1) {
            var buf: [4]u8 = undefined;
            const k = std.unicode.utf8Encode(@intCast(cp), &buf) catch return .nothing;
            out[w] = try arena.dupe(u8, buf[0..k]);
            w += 1;
        }
    }
    return .exactly(out);
}

// ── the operators ────────────────────────────────────────────────────────────

/// A prefix set extends through the left operand only when that operand's
/// language is finitely enumerable; otherwise the left operand's own prefix set
/// still speaks for the concatenation, because a match of `x·y` starts where a
/// match of `x` starts.
fn cat(arena: std.mem.Allocator, x: Claim, y: Claim) ParseError!Claim {
    if (try cross(arena, x.whole, y.whole)) |w| return .exactly(w);
    return .{
        .whole = null,
        .leading = (try cross(arena, x.whole, y.leading)) orelse x.leading,
        .trailing = (try cross(arena, x.trailing, y.whole)) orelse y.trailing,
    };
}

/// A match takes one branch, so every branch must contribute — a union with one
/// unprovable side is unprovable whole. This is where `foo|bar` stops being
/// nothing and becomes two probes.
fn either(arena: std.mem.Allocator, x: Claim, y: Claim) ParseError!Claim {
    if (try merge(arena, x.whole, y.whole)) |w| return .exactly(w);
    return .{
        .whole = null,
        .leading = try merge(arena, x.leading, y.leading),
        .trailing = try merge(arena, x.trailing, y.trailing),
    };
}

fn once(x: Claim) Claim {
    return .{ .whole = null, .leading = x.leading, .trailing = x.trailing };
}

/// `x?` matches what `x` matches, or nothing — finite exactly when `x` is.
fn optional(arena: std.mem.Allocator, x: Claim) ParseError!Claim {
    const w = x.whole orelse return .anywhere;
    return .exactly((try merge(arena, w, nil)) orelse return .anywhere);
}

// ── set arithmetic ───────────────────────────────────────────────────────────

/// Pairwise concatenation, declined whole when it would breach either cap. The
/// product is checked BEFORE anything is built, so a `[a-z]{4}` cross costs a
/// multiply rather than four hundred thousand allocations.
fn cross(arena: std.mem.Allocator, left: ?Set, right: ?Set) ParseError!?Set {
    const x = left orelse return null;
    const y = right orelse return null;
    if (x.len == 0 or y.len == 0 or x.len *| y.len > max_members) return null;

    var out: std.ArrayList([]const u8) = try .initCapacity(arena, x.len * y.len);
    for (x) |p| for (y) |q| {
        if (p.len + q.len > max_bytes) return null;
        const joined = try facts.join(arena, p, q);
        if (!holds(out.items, joined)) out.appendAssumeCapacity(joined);
    };
    return out.items;
}

/// Union, order-preserving and deduplicated. Duplicates are real rather than
/// theoretical — `(a|ab)b?` crosses two sets whose products collide — and a set
/// whose count over-reports its members would charge a host for probes it
/// already ran.
fn merge(arena: std.mem.Allocator, left: ?Set, right: ?Set) ParseError!?Set {
    const x = left orelse return null;
    const y = right orelse return null;
    if (x.len +| y.len > max_members) return null;

    var out: std.ArrayList([]const u8) = try .initCapacity(arena, x.len + y.len);
    for ([_]Set{ x, y }) |side| for (side) |member| {
        if (!holds(out.items, member)) out.appendAssumeCapacity(member);
    };
    return out.items;
}

fn holds(seen: []const []const u8, member: []const u8) bool {
    for (seen) |m| if (std.mem.eql(u8, m, member)) return true;
    return false;
}

// ── the boundary ─────────────────────────────────────────────────────────────

/// What a caller may be handed. Two refusals and one simplification, applied
/// once at the root rather than at every node — the empty-string member is the
/// unit the whole algebra multiplies through, so it may not be refused any
/// earlier than this.
fn usable(arena: std.mem.Allocator, set: ?Set, side: Side) ParseError!?Set {
    const s = set orelse return null;
    if (s.len == 0) return null;
    // An empty member makes the set exhaustive and useless: every string starts
    // with "", so the filter admits everything while still costing a probe.
    for (s) |member| if (member.len == 0) return null;
    return try absorb(arena, s, side);
}

/// Drop every member a shorter one already covers. Exhaustiveness survives —
/// anything starting with `foobar` starts with `foo` — so `foo|foobar` answers
/// with one probe instead of two.
fn absorb(arena: std.mem.Allocator, s: Set, side: Side) ParseError!Set {
    var kept: std.ArrayList([]const u8) = try .initCapacity(arena, s.len);
    for (s) |member| if (!shadowed(s, member, side)) kept.appendAssumeCapacity(member);
    return kept.items;
}

/// Whether a STRICTLY shorter member already covers `member`. Strictly, so that
/// two equal members could never eliminate each other and leave the set with a
/// hole; `merge` and `cross` have already made equal members impossible, and
/// this does not rely on that.
fn shadowed(s: Set, member: []const u8, side: Side) bool {
    for (s) |other| {
        if (other.len >= member.len) continue;
        const covers = switch (side) {
            .leading => std.mem.startsWith(u8, member, other),
            .trailing => std.mem.endsWith(u8, member, other),
        };
        if (covers) return true;
    }
    return false;
}
