//! Tests for the interned AST and its fused sweep.
//!
//! Two kinds of claim, held two different ways.
//!
//! **Agreement.** Every fact that replaces a walker in `analysis.zig` is
//! compared against that walker on the same pattern. This is the migration
//! safety net: the sweep may be faster, but it may not answer differently.
//!
//! **Soundness.** Agreement alone would only prove the new code copies the old
//! code's mistakes, so the consuming facts are also checked against a language
//! oracle built from the semantics rather than from either implementation —
//! `reach` below is a set-of-positions recognizer, a few lines of direct
//! denotational reading of `Node`, with no NFA, no DFA, no backtracking and no
//! shared code with the engine. Every string over a small alphabet is run
//! through it, and every one that matches must satisfy what the facts claimed:
//! inside the length bounds, starting with a byte the first-set admits,
//! containing the mandatory literal. A fact that over-claims is a missed match
//! in production, so the direction of each assertion is the direction of the
//! harm.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const ana = @import("../analysis/analysis.zig");
const admit = @import("../linear/parabix/admit.zig");
const ast = @import("ast.zig");

const Node = syn.Node;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

// ── harness ──────────────────────────────────────────────────────────────────

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    node: *Node,

    fn alloc(self: *Parsed) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn parseMode(src: []const u8, unicode: bool) ParseError!Parsed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var p = syn.Parser{ .src = src, .arena = arena.allocator(), .unicode = unicode };
    const n = try p.parseAlt();
    if (p.pos != src.len) return ParseError.BadPattern;
    return .{ .arena = arena, .node = n };
}

fn parse(src: []const u8) ParseError!Parsed {
    return parseMode(src, false);
}

/// Unicode mode, where a non-ASCII literal becomes a `uclass` rather than the
/// byte pair its UTF-8 encoding happens to be. Only the codepoint-class facts
/// can tell the two apart.
fn parseU(src: []const u8) ParseError!Parsed {
    return parseMode(src, true);
}

/// Parse, intern, canonicalize and sweep. The caller keeps `Parsed` alive: the
/// facts point into its arena.
fn analyzed(pr: *Parsed) !ast.Ast {
    return ast.analyze(std.testing.allocator, pr.alloc(), pr.node, .{});
}

/// The same, with the identities declined — the control every canonicalized
/// answer is measured against.
fn raw(pr: *Parsed) !ast.Ast {
    return ast.analyze(std.testing.allocator, pr.alloc(), pr.node, .{ .canonicalize = false });
}

// ── the oracle: a recognizer read straight off the semantics ─────────────────

/// End positions reachable by matching `n` from any position in `from`, as a
/// bitset over `0..=s.len`. Deliberately the most naive thing that is still
/// correct: a set-valued interpretation of the AST, closed under iteration by
/// fixpoint. It shares nothing with the compiler under test.
fn reach(n: *const Node, s: []const u8, from: u64) u64 {
    return switch (n.*) {
        .empty => from,
        .class => |c| step(s, from, struct {
            fn width(set: ByteSet, hay: []const u8, i: usize) usize {
                return if (set.has(hay[i])) 1 else 0;
            }
        }.width, c),
        .uclass => |ranges| step(s, from, struct {
            fn width(rs: []const [2]u21, hay: []const u8, i: usize) usize {
                const len = std.unicode.utf8ByteSequenceLength(hay[i]) catch return 0;
                if (i + len > hay.len) return 0;
                const cp = std.unicode.utf8Decode(hay[i..][0..len]) catch return 0;
                for (rs) |r| if (cp >= r[0] and cp <= r[1]) return len;
                return 0;
            }
        }.width, ranges),

        .anchor_start, .anchor_buf_start => from & 1,
        .anchor_end, .anchor_buf_end => from & (@as(u64, 1) << @intCast(s.len)),
        .word => |mask| from & wordPositions(s, mask),

        .concat => |ab| reach(ab[1], s, reach(ab[0], s, from)),
        .alt => |ab| reach(ab[0], s, from) | reach(ab[1], s, from),
        .capture => |c| reach(c.child, s, from),

        .quest => |r| from | reach(r.node, s, from),
        .plus => |r| closure(r.node, s, reach(r.node, s, from)),
        .star => |r| closure(r.node, s, from),
    };
}

/// Advance every position in `from` by whatever width `w` consumes there.
fn step(s: []const u8, from: u64, comptime w: anytype, arg: anytype) u64 {
    var out: u64 = 0;
    for (0..s.len) |i| {
        if (from & (@as(u64, 1) << @intCast(i)) == 0) continue;
        const n = w(arg, s, i);
        if (n != 0) out |= @as(u64, 1) << @intCast(i + n);
    }
    return out;
}

/// Least fixpoint of "apply the body once more" — Kleene star, by definition.
/// It terminates because the position set only grows and is finite, which is
/// also why a body that matches empty cannot spin.
fn closure(body: *const Node, s: []const u8, seed: u64) u64 {
    var acc = seed;
    while (true) {
        const next = acc | reach(body, s, acc);
        if (next == acc) return acc;
        acc = next;
    }
}

fn wordy(s: []const u8, i: usize) bool {
    if (i >= s.len) return false;
    const c = s[i];
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Positions satisfying a word assertion. Deliberately spells each predicate as
/// logic rather than calling `syn.Word.admits`: an oracle that reached for the
/// production bit test would agree with it by construction, including when it is
/// wrong.
fn wordPositions(s: []const u8, mask: syn.Word) u64 {
    var out: u64 = 0;
    for (0..s.len + 1) |i| {
        const before = i > 0 and wordy(s, i - 1);
        const after = wordy(s, i);
        const hit = switch (mask) {
            .boundary => before != after,
            .not_boundary => before == after,
            .start => !before and after,
            .end => before and !after,
            .start_half => !before,
            .end_half => !after,
        };
        if (hit) out |= @as(u64, 1) << @intCast(i);
    }
    return out;
}

fn wholeMatch(n: *const Node, s: []const u8) bool {
    return reach(n, s, 1) & (@as(u64, 1) << @intCast(s.len)) != 0;
}

/// Every string over `alphabet` of length ≤ `max_len`, shortest first.
fn eachString(
    alphabet: []const u8,
    max_len: usize,
    buf: []u8,
    depth: usize,
    ctx: anytype,
    comptime visit: anytype,
) !void {
    try visit(ctx, buf[0..depth]);
    if (depth == max_len) return;
    for (alphabet) |c| {
        buf[depth] = c;
        try eachString(alphabet, max_len, buf, depth + 1, ctx, visit);
    }
}

// ── soundness: the facts against the oracle ──────────────────────────────────

const Probe = struct { node: *const Node, facts: ast.Facts };

fn checkString(p: Probe, s: []const u8) !void {
    if (!wholeMatch(p.node, s)) return;
    const f = p.facts;

    try std.testing.expect(s.len >= f.min_len);
    if (f.max_len != ast.unbounded) try std.testing.expect(s.len <= f.max_len);
    if (s.len == 0) try std.testing.expect(f.nullable);
    if (s.len > 0) try std.testing.expect(f.first.has(s[0]));
    if (f.lit.best.len > 0) try std.testing.expect(std.mem.indexOf(u8, s, f.lit.best) != null);
    if (f.lit.prefix.len > 0) try std.testing.expect(std.mem.startsWith(u8, s, f.lit.prefix));
    if (f.lit.suffix.len > 0) try std.testing.expect(std.mem.endsWith(u8, s, f.lit.suffix));
    if (f.lit.exact) |e| try std.testing.expectEqualStrings(e, s);
}

test "ast/oracle: no fact over-claims against an independently recognized language" {
    const patterns = [_][]const u8{
        "a",          "ab",     "abc",         "a*",        "a+",
        "a?",         "a|b",    "ab|ba",       "a*b",       "ab*",
        "a*bc",       "(a|b)*", "(a|b)+c",     "a{2}",      "a{2,3}",
        "a{0,2}b",    "(ab)+",  "(ab)*c",      "a(b|bc)a",  "[ab]+",
        "[ab]*c[ab]", "a.c",    ".*a",         ".+",        "^ab",
        "ab$",        "^abc$",  "a|",          "(a)(b)(c)", "((ab)|(ba))c",
        "aa*a",       "a?a?a?", "(a|ab)(b|c)", "c(a|b){2}", "\\ba\\b",
    };
    var buf: [4]u8 = undefined;
    for (patterns) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();

        const probe: Probe = .{ .node = pr.node, .facts = a.root() };
        try eachString("abc", 4, &buf, 0, probe, checkString);
    }
}

// ── agreement: the facts against the walkers they replace ────────────────────

test "ast/agreement: literal facts match analysis.literalInfo" {
    const patterns = [_][]const u8{
        "function", "a*function", "^func",     "\\bfunc\\b", "a.b",
        "ab|cd",    "[0-9]",      "abc+",      "(abc)+",     "x(abc)y",
        "a*",       "foo.*bar",   "(a|b)cdef", "cdef(a|b)",  "a{3}",
        "prefix.*", ".*suffix",
        "«unicode»",
        "a?bcde",   "((a))b",
    };
    for (patterns) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        // The control, not the canonical form: this test asks whether the sweep
        // reproduces the walker, and the identities are allowed to do better.
        var a = try raw(&pr);
        defer a.deinit();
        const want = try ana.literalInfo(pr.alloc(), pr.node);
        const got = a.root().lit;

        try std.testing.expectEqualStrings(want.prefix, got.prefix);
        try std.testing.expectEqualStrings(want.suffix, got.suffix);
        try std.testing.expectEqualStrings(want.best, got.best);
        if (want.exact) |w| {
            try std.testing.expectEqualStrings(w, got.exact orelse return error.LostExactness);
        } else {
            try std.testing.expect(got.exact == null);
        }
    }
}

test "ast/agreement: anchoring matches analysis.startsAnchored" {
    const patterns = [_][]const u8{
        "^a",  "^a|^b", "^a|b", "a|^b",  "^(a|b)",
        "a",   "(^a)b", "^a*",  "(^a)+", "(^a)?",
        "^a$", ".*",    "^",    "a^b",   "(^a|^b)c",
    };
    for (patterns) |pat| {
        var pr = try parse(pat);
        defer pr.deinit();
        var a = try raw(&pr);
        defer a.deinit();
        try std.testing.expectEqual(ana.startsAnchored(pr.node), a.root().anchored);
    }
}

// ── the identities ───────────────────────────────────────────────────────────

/// The union of every pattern the other tests use, so the preservation claim is
/// held over the widest corpus in this file rather than a hand-picked few.
const corpus = [_][]const u8{
    "a",          "ab",         "abc",         "a*",         "a+",
    "a?",         "a|b",        "ab|ba",       "a*b",        "ab*",
    "a*bc",       "(a|b)*",     "(a|b)+c",     "a{2}",       "a{2,3}",
    "a{0,2}b",    "(ab)+",      "(ab)*c",      "a(b|bc)a",   "[ab]+",
    "[ab]*c[ab]", "a.c",        ".*a",         ".+",         "^ab",
    "ab$",        "^abc$",      "a|",          "(a)(b)(c)",  "((ab)|(ba))c",
    "aa*a",       "a?a?a?",     "(a|ab)(b|c)", "c(a|b){2}",  "\\ba\\b",
    "function",   "a*function", "^func",       "\\bfunc\\b", "a.b",
    "ab|cd",      "[0-9]",      "abc+",        "(abc)+",     "x(abc)y",
    "foo.*bar",   "(a|b)cdef",  "cdef(a|b)",   "a{3}",       "prefix.*",
    ".*suffix",   "a?bcde",     "((a))b",      "(a*)*",      "((a+)*)?",
    "(a|a|a)b",   "(a|b|c|d)+", "a{1000}",     "(a??)*",     "((x|y)|z)w",
};

test "ast/algebra: canonicalizing preserves every language fact" {
    for (corpus) |pat| {
        preserves(pat) catch |e| {
            std.debug.print("canonicalization changed a fact of `{s}`\n", .{pat});
            return e;
        };
    }
}

fn preserves(pat: []const u8) !void {
    {
        var pr = try parse(pat);
        defer pr.deinit();
        var before = try raw(&pr);
        defer before.deinit();
        var after = try analyzed(&pr);
        defer after.deinit();

        const b = before.root();
        const c = after.root();
        // Exact: these are properties of the language, and every rule is a
        // language identity, so "preserved" here means equal, not merely sound.
        try std.testing.expectEqual(b.nullable, c.nullable);
        try std.testing.expectEqual(b.min_len, c.min_len);
        try std.testing.expectEqual(b.max_len, c.max_len);
        try std.testing.expectEqual(b.has_cp, c.has_cp);
        try std.testing.expectEqualSlices(u64, &b.first.bits, &c.first.bits);

        // Directional: a rule may only improve these. A collapsed closure nest
        // lowers the measured star height to what the language actually costs,
        // an anchor freed from an ε concatenation becomes visible, and a
        // deduplicated branch can expose a mandatory literal that the branch
        // structure was hiding.
        try std.testing.expect(c.star_height <= b.star_height);
        try std.testing.expect(c.anchored or !b.anchored);
        try std.testing.expect(c.lit.best.len >= b.lit.best.len);
        try std.testing.expect(after.nodes() <= before.nodes());
    }
}

test "ast/algebra: an alternation of literals becomes one class" {
    var pr = try parse("(a|b|c|d|e)");
    defer pr.deinit();
    var a = try analyzed(&pr);
    defer a.deinit();

    // Five branches and four alternations in the parse tree; one byte class
    // here, which is what every downstream analysis would rather be asked
    // about — one first-set, one width, one prefilter lane.
    try std.testing.expectEqual(@as(usize, 1), a.nodes());
    try std.testing.expectEqual(@as(u32, 1), a.root().min_len);
    try std.testing.expectEqual(@as(u32, 1), a.root().max_len);
    inline for (.{ 'a', 'b', 'c', 'd', 'e' }) |c| try std.testing.expect(a.root().first.has(c));
    try std.testing.expect(!a.root().first.has('f'));
}

test "ast/algebra: a closure nest collapses to the one closure it denotes" {
    const cases = [_]struct { pat: []const u8, height: u8 }{
        .{ .pat = "(a*)*", .height = 1 },
        .{ .pat = "(a+)*", .height = 1 },
        .{ .pat = "(a?)*", .height = 1 },
        .{ .pat = "(a*)+", .height = 1 },
        .{ .pat = "(a+)+", .height = 1 },
        .{ .pat = "(a?)?", .height = 0 },
        .{ .pat = "((a+)*)?", .height = 1 },
        // A greedy closure over a lazy one denotes the same language but not
        // the same preference, so the nest stands rather than being flattened
        // by a rule that would have had to pick a side.
        .{ .pat = "(a*?)*", .height = 2 },
    };
    for (cases) |c| {
        var pr = try parse(c.pat);
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();
        try std.testing.expectEqual(c.height, a.root().star_height);
    }
}

test "ast/algebra: the unit law frees an anchor a group was hiding" {
    var pr = try parse("()^abc");
    defer pr.deinit();
    var before = try raw(&pr);
    defer before.deinit();
    var after = try analyzed(&pr);
    defer after.deinit();

    // Only the leftmost operand of a concatenation can anchor it, so the empty
    // group in front makes the pattern look unanchored — `analysis.zig` reads
    // it that way too. Dropping the group and then the ε moves `^` to the
    // front, where it is what it always was.
    try std.testing.expect(!ana.startsAnchored(pr.node));
    try std.testing.expect(!before.root().anchored);
    try std.testing.expect(after.root().anchored);
    try std.testing.expectEqualStrings("abc", after.root().lit.best);
}

// ── the structure itself ─────────────────────────────────────────────────────

test "ast/intern: a bounded repetition costs log-many nodes, not n" {
    var pr = try parse("a{1000}");
    defer pr.deinit();
    var a = try analyzed(&pr);
    defer a.deinit();

    // 1000 concatenations, reached by squaring: a handful of doublings plus the
    // odd-bit joins. The bound is generous — the claim is the ORDER, that the
    // graph is logarithmic in the repetition count rather than linear in it.
    try std.testing.expect(a.nodes() < 64);
    try std.testing.expectEqual(@as(u32, 1000), a.root().min_len);
    try std.testing.expectEqual(@as(u32, 1000), a.root().max_len);
    try std.testing.expectEqual(@as(usize, 1000), a.root().lit.best.len);
}

test "ast/intern: sharing is found, not assumed" {
    var pr = try parse("(abcd|abcd)(abcd|abcd)");
    defer pr.deinit();
    var a = try analyzed(&pr);
    defer a.deinit();

    // Four spellings of `abcd`, one node for it and its every prefix pair.
    try std.testing.expect(a.offered() > a.nodes());
    try std.testing.expect(a.interned.stats().sharing() > 1.0);
}

test "ast/intern: equal shape gets equal identity, different shape does not" {
    var capturing = try parse("(ab)*c");
    defer capturing.deinit();
    var grouped = try parse("(?:ab)*c");
    defer grouped.deinit();
    var other = try parse("(ab)*d");
    defer other.deinit();

    // Faithfully interned, a capturing group is a node and a non-capturing one
    // is not, so the two spellings are different shapes.
    var rx = try raw(&capturing);
    defer rx.deinit();
    var ry = try raw(&grouped);
    defer ry.deinit();
    try std.testing.expect(rx.signature() != ry.signature());

    // Canonicalized, they are the same language and get the same name — which
    // is what makes the signature usable for dropping duplicate intents out of
    // a wide `-e` slate before compiling an engine each.
    var x = try analyzed(&capturing);
    defer x.deinit();
    var y = try analyzed(&grouped);
    defer y.deinit();
    var z = try analyzed(&other);
    defer z.deinit();
    try std.testing.expectEqual(x.signature(), y.signature());
    try std.testing.expect(y.signature() != z.signature());
}

test "ast/agreement: star height matches parabix admit.starHeight" {
    // The sweep measures the nesting it is given, and must measure it the way
    // the rung that reads it does — `?` is bounded and adds no height.
    // Flattening the nesting is the algebra's job, tested separately.
    const cases = [_]struct { pat: []const u8, height: u8 }{
        .{ .pat = "abc", .height = 0 },
        .{ .pat = "a*", .height = 1 },
        .{ .pat = "a+b?", .height = 1 },
        .{ .pat = "a?", .height = 0 },
        .{ .pat = "(a*)*", .height = 2 },
        .{ .pat = "((a+)*)?", .height = 2 },
        .{ .pat = "(a*b)|(c*d)", .height = 1 },
    };
    for (cases) |c| {
        var pr = try parse(c.pat);
        defer pr.deinit();
        var a = try raw(&pr);
        defer a.deinit();
        try std.testing.expectEqual(c.height, a.root().star_height);
        try std.testing.expectEqual(@as(u32, c.height), admit.starHeight(pr.node));
    }
}

test "ast/facts: length bounds saturate under closure and add under concat" {
    const cases = [_]struct { pat: []const u8, min: u32, max: u32 }{
        .{ .pat = "abc", .min = 3, .max = 3 },
        .{ .pat = "a?b", .min = 1, .max = 2 },
        .{ .pat = "a*", .min = 0, .max = ast.unbounded },
        .{ .pat = "a+", .min = 1, .max = ast.unbounded },
        .{ .pat = "ab|cdef", .min = 2, .max = 4 },
        .{ .pat = "a{2,5}", .min = 2, .max = 5 },
        .{ .pat = "xa*y", .min = 2, .max = ast.unbounded },
        .{ .pat = "^ab$", .min = 2, .max = 2 },
    };
    for (cases) |c| {
        var pr = try parse(c.pat);
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();
        try std.testing.expectEqual(c.min, a.root().min_len);
        try std.testing.expectEqual(c.max, a.root().max_len);
    }
}

test "ast/facts: a codepoint class is visible from the root" {
    // An all-ASCII set stays a byte class even in Unicode mode, so `\d` is
    // telling: byte-mode `\d` is `[0-9]`, Unicode-mode `\d` is every Nd
    // codepoint, and only the second is a class the byte engine must widen for.
    inline for (.{ "abc", "[a-z]+", "[0-9]" }) |pat| {
        var pr = try parseU(pat);
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();
        try std.testing.expect(!a.root().has_cp);
    }
    {
        var pr = try parse("\\d");
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();
        try std.testing.expect(!a.root().has_cp);
    }
    inline for (.{ "«", "x«y", "(«|»)+", "\\d", "\\w+" }) |pat| {
        var pr = try parseU(pat);
        defer pr.deinit();
        var a = try analyzed(&pr);
        defer a.deinit();
        try std.testing.expect(a.root().has_cp);
    }
}

test "ast/facts: a non-ASCII literal keeps its UTF-8 bytes as a literal" {
    var pr = try parseU("x«y");
    defer pr.deinit();
    var a = try analyzed(&pr);
    defer a.deinit();
    // Three codepoints, one of them two bytes wide: the mandatory literal is
    // the encoded form, which is what the byte-level prefilter searches for.
    try std.testing.expectEqualStrings("x«y", a.root().lit.exact.?);
    try std.testing.expectEqual(@as(u32, 4), a.root().min_len);
    try std.testing.expectEqual(@as(u32, 4), a.root().max_len);
}

test "ast/facts: leaves count the tree a recursive walker would have paid for" {
    var pr = try parse("a{256}");
    defer pr.deinit();
    var a = try analyzed(&pr);
    defer a.deinit();
    // The expansion is 256 atoms wide, and every one of them is a node a
    // recursive walker would descend to. The sweep touches the graph instead,
    // which for a pure power of two is one node per doubling.
    try std.testing.expectEqual(@as(u32, 256), a.root().leaves);
    try std.testing.expect(a.nodes() < 32);
}
