//! The flag directive at the head of a pattern — `(?i)`, `(?-u)`, `(?ms)`.
//!
//! A pattern can say what it means twice: once in the options its caller passes
//! and once in its own first four bytes. Every regex library a user already
//! knows honors the second spelling — `re.compile("(?i)cat")`,
//! `Regex::new("(?i)cat")`, `regexp.MustCompile("(?i)cat")` — and until this
//! module existed, only the CLI over it did. `irgx_compile("(?i)cat", 0)` was
//! refused, because the recursive-descent parser has no production for a flag
//! group and the seam had nothing that would turn one into the option it asks
//! for. That made the *documented* way to be case-insensitive unavailable to a
//! host whose pattern came from a config file it does not own.
//!
//! So the reading lives here, in the syntax tier, rather than a second time in
//! each face: the CLI reconciles one engine across many patterns
//! (`exec/cold/writ/directive.zig`) and the C ABI folds each pattern's own
//! directive into that pattern's compile, but *what `(?ms-i)` says* must not be
//! two grammars that agree today.
//!
//! Deliberately only the **head**. `(?i)` inside a group, and the scoped
//! `(?i:…)` form, are per-subexpression scoping — a real AST feature, not an
//! option word — and a fold that pretended otherwise would quietly apply a
//! nested flag to the whole pattern. Those keep going to the parser, which
//! refuses them, which routes a host to the PCRE2 arm that does implement them.
//! Position zero is the case where "the directive is the whole pattern's" is a
//! fact rather than an approximation, and it is also the only case Python `re`
//! itself permits (a non-leading global flag has been an error since 3.11).

const std = @import("std");

/// What one or more leading directives asked for. A null field is a question
/// the pattern did not answer, which the caller's own option still owns —
/// `(?i)` says nothing about `.`'s appetite for newlines.
pub const Directive = struct {
    /// The pattern past the last directive read. It is what to compile.
    rest: []const u8,
    /// `i` — fold case for the whole pattern.
    caseless: ?bool = null,
    /// `u` — Unicode mode. `(?-u)` is the ASCII/byte opt-out, spelled the way
    /// ripgrep and rust-regex spell it.
    unicode: ?bool = null,
    /// `m` — `^`/`$` also match at a line break. (The engine's *other*
    /// `multiline`, the one that says the haystack is a buffer, is not a thing a
    /// pattern gets to say.)
    line_anchors: ?bool = null,
    /// `s` — `.` matches a newline too.
    dotall: ?bool = null,
    /// `x` — verbose: ignore unescaped whitespace and `#` comments between
    /// tokens. Python's `re.VERBOSE`, and the whole reason a `re` host reaches
    /// for a leading directive at all: the idiom is a triple-quoted pattern
    /// whose first four bytes are `(?x)`.
    verbose: ?bool = null,
};

/// The three things the head of a pattern can turn out to be.
///
/// `beyond` is the member that keeps this honest. `U` (swap greed) and `R`
/// (CRLF line terminators) are flags of the wider grammar this
/// engine does not implement, and reading them as "not a directive" would hand
/// the parser a pattern it fails on for the wrong reason. Naming the letter lets
/// each caller answer with the remedy it actually has: the CLI says which flag
/// and points at ripgrep, and the ABI leaves the bytes alone so its PCRE2 arm —
/// which has both — is what the refusal routes a host to.
pub const Preamble = union(enum) {
    /// Not a flag directive: no `(?` at all, or a `(?:`/`(?P<`/lookaround/
    /// scoped-flag head. The parser decides, exactly as it did before.
    none,
    /// A directive run this grammar has, folded — and the pattern past it.
    asks: Directive,
    /// A directive carrying a flag letter this grammar does not have.
    beyond: u8,
};

/// Read every directive at the head of `pattern`, folded left to right.
///
/// A run is folded rather than only the first because `(?i)(?s)x` is one
/// statement written twice, and both rust-regex and PCRE2 read it that way; a
/// later letter overrides an earlier one, so `(?i)(?-i)x` is case-sensitive.
pub fn preamble(pattern: []const u8) Preamble {
    var out: Directive = .{ .rest = pattern };
    var read = false;
    while (one(out.rest)) |head| switch (head) {
        // A foreign letter is the whole answer: nothing before it can be
        // honored either, because the pattern it prefixes is not one this
        // grammar compiles.
        .beyond => |c| return .{ .beyond = c },
        .asks => |f| {
            read = true;
            out.rest = f.rest;
            if (f.caseless) |v| out.caseless = v;
            if (f.unicode) |v| out.unicode = v;
            if (f.line_anchors) |v| out.line_anchors = v;
            if (f.dotall) |v| out.dotall = v;
            if (f.verbose) |v| out.verbose = v;
        },
    };
    return if (read) .{ .asks = out } else .none;
}

/// One directive, or null when the head is not one. Narrower than `Preamble` by
/// exactly the member that cannot happen here — "not a directive" is the null.
const Read = union(enum) { asks: Directive, beyond: u8 };

fn one(pattern: []const u8) ?Read {
    if (!std.mem.startsWith(u8, pattern, "(?")) return null;
    // The first `)` and not a balanced scan: a directive holds only flag
    // letters, so any `)` after `(?` either closes this one or proves it was
    // never a directive (the letters loop below rejects whatever came between).
    const close = std.mem.indexOfScalarPos(u8, pattern, 2, ')') orelse return null;
    if (close == 2) return null; // `(?)` — empty, and the parser's to reject
    var f: Directive = .{ .rest = pattern[close + 1 ..] };
    var off = false;
    for (pattern[2..close]) |c| switch (c) {
        '-' => off = true,
        'i' => f.caseless = !off,
        'u' => f.unicode = !off,
        'm' => f.line_anchors = !off,
        's' => f.dotall = !off,
        'x' => f.verbose = !off,
        'U', 'R' => return .{ .beyond = c },
        // A `:` lands here, which is how the scoped `(?i:…)` form stays out:
        // it is not a whole-pattern statement, so it is not this module's.
        else => return null,
    };
    return .{ .asks = f };
}

test "a leading directive is read as the options it asks for" {
    const t = std.testing;
    const got = preamble("(?i)cat");
    try t.expectEqualStrings("cat", got.asks.rest);
    try t.expectEqual(@as(?bool, true), got.asks.caseless);
    // What the pattern did not say stays unanswered, for the caller's own
    // option to keep owning.
    try t.expectEqual(@as(?bool, null), got.asks.unicode);
    try t.expectEqual(@as(?bool, null), got.asks.line_anchors);
    try t.expectEqual(@as(?bool, null), got.asks.dotall);
}

test "negation, multiple letters, and a run all fold left to right" {
    const t = std.testing;
    try t.expectEqual(@as(?bool, false), preamble("(?-u)\\d").asks.unicode);
    try t.expectEqualStrings("\\d", preamble("(?-u)\\d").asks.rest);

    const both = preamble("(?ms)a.b").asks;
    try t.expectEqual(@as(?bool, true), both.line_anchors);
    try t.expectEqual(@as(?bool, true), both.dotall);
    try t.expectEqualStrings("a.b", both.rest);

    // `-` is sticky to the end of the group, as it is everywhere else.
    const mixed = preamble("(?i-u)x").asks;
    try t.expectEqual(@as(?bool, true), mixed.caseless);
    try t.expectEqual(@as(?bool, false), mixed.unicode);

    const run = preamble("(?i)(?s)x").asks;
    try t.expectEqual(@as(?bool, true), run.caseless);
    try t.expectEqual(@as(?bool, true), run.dotall);
    try t.expectEqualStrings("x", run.rest);

    // Later overrides earlier — one statement, written twice.
    try t.expectEqual(@as(?bool, false), preamble("(?i)(?-i)x").asks.caseless);
}

test "an empty rest is a pattern, not an absence" {
    // `re.compile("(?i)")` is a valid empty pattern that matches everywhere,
    // and folding must not turn it into "no directive here".
    const got = preamble("(?i)").asks;
    try std.testing.expectEqualStrings("", got.rest);
    try std.testing.expectEqual(@as(?bool, true), got.caseless);
}

test "everything that only looks like a directive is left to the parser" {
    const t = std.testing;
    for ([_][]const u8{
        "cat", // no `(?` at all
        "(?:ab)c", // a non-capturing group
        "(?P<name>x)", // a named capture
        "(?=ahead)", // a lookaround
        "(?i:ab)c", // the SCOPED form — per-subexpression, not the head's
        "(?)x", // an empty directive
        "(?i", // unterminated
        "\\(?i\\)", // an escaped paren, i.e. literal text
    }) |pat| try t.expectEqual(Preamble.none, preamble(pat));
}

test "a flag from the wider grammar names itself instead of hiding" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 'U'), preamble("(?U)a+").beyond);
    try t.expectEqual(@as(u8, 'R'), preamble("(?R)a$").beyond);
    // Mixed with letters this grammar does have, the foreign one still wins:
    // honoring the `i` and dropping the `U` is the silent wrong answer.
    try t.expectEqual(@as(u8, 'U'), preamble("(?iU)a+").beyond);
    // And a foreign letter later in a run is not reached past either.
    try t.expectEqual(@as(u8, 'U'), preamble("(?i)(?U)a+").beyond);
}

test "verbose is a directive this grammar has, not a foreign letter" {
    const t = std.testing;
    // The Python idiom: the whole pattern is a commented block, and its first
    // four bytes are what say so.
    const got = preamble("(?x) a  b # trailing").asks;
    try t.expectEqual(@as(?bool, true), got.verbose);
    try t.expectEqualStrings(" a  b # trailing", got.rest);
    // Negation and folding work like every other letter.
    try t.expectEqual(@as(?bool, false), preamble("(?-x)a b").asks.verbose);
    const mixed = preamble("(?ix)a b").asks;
    try t.expectEqual(@as(?bool, true), mixed.caseless);
    try t.expectEqual(@as(?bool, true), mixed.verbose);
    try t.expectEqual(@as(?bool, true), preamble("(?i)(?x)a b").asks.verbose);
}
