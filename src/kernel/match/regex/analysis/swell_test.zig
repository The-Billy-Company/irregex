//! Forced-crest calculus tests — hand-computed ĝ for every construct the AST
//! can present, plus the SIEVE THEOREM itself checked against the real matcher:
//! for every (pattern, document) pair, `matched ⇒ !pruned`. That differential is
//! what makes the no-false-negative claim a property of the code rather than an
//! observation about today's corpus, and it is the test that would have caught
//! `\<` being read as a literal `<` by a second, private grammar.
//!
//! The corpus-scale version (real Billy tree, real index) is `zig build crest`.

const std = @import("std");
const testing = std.testing;
const crest = @import("../../../primitives/crest.zig");
const Regex = @import("../linear/program/core.zig").Regex;

const Options = Regex.Options;
const ascii: Options = .{ .unicode = false };
const uni: Options = .{ .unicode = true };

fn ghat(pattern: []const u8, opts: Options) crest.Vector {
    return Regex.forcedCrest(testing.allocator, pattern, opts);
}

fn g(pattern: []const u8, opts: Options, c: crest.Class) u16 {
    return ghat(pattern, opts)[@intFromEnum(c)];
}

test "forced-crest: class repetition is the whole point" {
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .hex));
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .word)); // hex ⊂ word
    try testing.expectEqual(@as(u16, 6), g("[0-9]{6}", uni, .digit));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", uni, .upper));
    // \d certifies in ASCII mode only (Alphabet Contract): under Unicode the
    // parser lowers it to a `uclass`, which spends bytes on non-ASCII scalars.
    try testing.expectEqual(@as(u16, 3), g("\\d{3}", ascii, .digit));
    try testing.expectEqual(@as(u16, 0), g("\\d{3}", uni, .digit));
}

test "forced-crest: straddle across concatenation" {
    try testing.expectEqual(@as(u16, 3), g("[0-9][0-9][0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9]+", uni, .digit)); // one forced copy
    // anchors are zero-width identity: runs cross them freely.
    try testing.expectEqual(@as(u16, 4), g("^[0-9]{4}$", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9](?:)[0-9]", uni, .digit));
}

test "zero-width assertions never force a byte" {
    // THE REGRESSION. `\<`/`\>` are word-boundary assertions, not escaped
    // punctuation: `\<foo\>` matches the document "foo", which holds no punct
    // at all. A calculus that read them as literal `<`/`>` forced punct ≥ 1 and
    // silently elided every such hit — 1500 of 2200 files on the reproduction.
    inline for (.{ "\\<foo\\>", "\\bfoo\\b", "\\Bfoo\\B", "^foo$", "\\Afoo\\z" }) |pat| {
        try testing.expectEqual(@as(u16, 0), g(pat, uni, .punct));
        try testing.expectEqual(@as(u16, 3), g(pat, uni, .lower)); // the body still forces
        try testing.expect(!crest.pruned(crest.crest("foo"), ghat(pat, uni)));
    }
    // An assertion between two class runs must not break the straddle either.
    try testing.expectEqual(@as(u16, 6), g("[0-9]{3}\\b[0-9]{3}", uni, .digit));
    // …while a real escaped punct byte still forces its run.
    try testing.expectEqual(@as(u16, 2), g("\\<\\.\\.", uni, .punct));
}

test "optional profiles preserve only-class certificates without joining separators" {
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]?[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][0-9]?[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]*[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][0-9]*[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][a-z]{0,0}[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]{0,1}[0-9]", uni, .digit));
    try testing.expect(!crest.pruned(crest.crest("1a2"), ghat("[0-9][a-z]?[0-9]", uni)));
    try testing.expect(crest.pruned(crest.crest("1a2"), ghat("[0-9][0-9]?[0-9]", uni)));
}

test "epsilon and unknown profiles cannot be confused" {
    const analysis = @import("analysis.zig");
    const epsilon = analysis.ForcedProfile.epsilon();
    const unknown = analysis.ForcedProfile.unknown();
    inline for (0..crest.K) |i| {
        try testing.expect(epsilon.only_c_cert[i]);
        try testing.expect(!unknown.only_c_cert[i]);
    }
    try testing.expectEqual(@as(u16, 0), epsilon.min_len);
    try testing.expectEqual(@as(u16, 1), analysis.ForcedProfile.unit().min_len);
}

test "forced-crest: alternation takes the adversary's cheaper branch" {
    try testing.expectEqual(@as(u16, 2), g("[0-9]{4}|[0-9]{2}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{4}|abcd", uni, .digit));
    // Multi `-e` arrives as one alternation, and `crest.weaker` is the same fold.
    const many = crest.weaker(ghat("[0-9]{4}", uni), ghat("[0-9]{2}", uni));
    try testing.expectEqual(@as(u16, 2), many[@intFromEnum(crest.Class.digit)]);
    try testing.expectEqual(@as(u16, 2), g("(?:[0-9]{4})|(?:[0-9]{2})", uni, .digit));
}

test "soundness by degradation: what the engine rejects prunes nothing" {
    // A pattern the ENGINE cannot compile yields 0⃗ — the sieve stands down
    // rather than guessing at a language it does not implement.
    try testing.expectEqual(@as(u16, 0), g("(?=foo)[0-9]{8}", uni, .digit)); // lookahead
    try testing.expectEqual(@as(u16, 0), g("(\\d)\\1{7}", ascii, .digit)); // backreference
    try testing.expectEqual(@as(u16, 0), g("[0-9]{3,2}", uni, .digit)); // max < min
    try testing.expectEqual(@as(u16, 0), g("[0-9]{1001}", uni, .digit)); // past the repeat cap
    // Nullable quantifiers force nothing, though they parse fine.
    try testing.expectEqual(@as(u16, 0), g("[0-9]*", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{0,8}", uni, .digit));
    // `\p{L}` is a codepoint class: parsed, but certifies no ASCII class.
    try testing.expectEqual(@as(u16, 0), g("\\p{L}{4}", uni, .alpha));
    // An unescaped `{` must begin a valid count or the pattern is rejected
    // outright (rust-regex parity; a literal brace is `\{`) — so a malformed
    // bound prunes nothing, and the ESCAPED brace is what forces punct.
    try testing.expectEqual(@as(u16, 0), g("[0-9]{3,x}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{,3}", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9]\\{3", uni, .punct));
}

test "caseless: the matcher's own fold, not a private approximation" {
    const ci: Options = .{ .unicode = true, .caseless = true };
    const ci_ascii: Options = .{ .unicode = false, .caseless = true };
    // hex letters a–f never fold outside ASCII, so `(?i)[0-9a-f]{8}` still
    // forces an 8-byte hex (and word) run in BOTH engine modes — the UUID case.
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", ci, .hex));
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", ci, .word));
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", ci_ascii, .hex));
    // digits are case-invariant: `(?i)[0-9]{6}` unchanged from case-sensitive.
    try testing.expectEqual(@as(u16, 6), g("[0-9]{6}", ci, .digit));
    // `upper`/`lower` are the only non-case-closed classes: the fold moves bytes
    // across them, so they always self-decline (`[A-F]` avoids k/K/s/S, so it
    // still certifies its case-closed classes under Unicode `-i`).
    try testing.expectEqual(@as(u16, 0), g("[A-F]{4}", ci, .upper));
    try testing.expectEqual(@as(u16, 4), g("[A-F]{4}", ci, .hex)); // A–F ⊂ hex, no escape
    try testing.expectEqual(@as(u16, 4), g("[A-F]{4}", ci, .alpha));
    // The Unicode escape guard is now STRUCTURAL: `k`→U+212A KELVIN SIGN and
    // `s`→U+017F LONG S leave ASCII, so `foldCaseAst` promotes any class holding
    // them to a `uclass`, which certifies nothing — no hand-maintained k/s check.
    try testing.expectEqual(@as(u16, 0), g("[A-Z]{4}", ci, .alpha));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", ci_ascii, .alpha));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", ci_ascii, .word));
    try testing.expectEqual(@as(u16, 0), g("[A-Z]{4}", ci_ascii, .upper)); // fold ⊄ upper
    try testing.expectEqual(@as(u16, 0), g("[a-z]{5}", ci, .word)); // contains k,s
    try testing.expectEqual(@as(u16, 5), g("[a-z]{5}", ci_ascii, .word));
    try testing.expectEqual(@as(u16, 0), g("[s-z]{5}", ci, .word)); // contains s
    try testing.expectEqual(@as(u16, 4), g("[g-j]{4}", ci, .word)); // no k/s: safe
    // The sieve engages and prunes a doc lacking the run.
    try testing.expect(crest.pruned(crest.crest("no hex zz"), ghat("[0-9a-f]{8}", ci)));
    try testing.expect(!crest.pruned(crest.crest("v=DEADBEEF n"), ghat("[0-9a-f]{8}", ci)));
}

test "escapes carry their real bytes (\\n is newline, not 'n')" {
    // \n{5}: five newlines — a SPACE run of 5, and no word run at all. Getting
    // this wrong (treating \n as the byte 'n') would manufacture false negatives.
    try testing.expectEqual(@as(u16, 5), g("\\n{5}", uni, .space));
    try testing.expectEqual(@as(u16, 0), g("\\n{5}", uni, .word));
    try testing.expectEqual(@as(u16, 2), g("\\t\\t", uni, .space));
    // escaped metachar is itself: \. is the punct byte '.'.
    try testing.expectEqual(@as(u16, 3), g("\\.{3}", uni, .punct));
    // `\x41` is 'A' to this engine, so it forces upper — the private grammar
    // used to decline the whole pattern here.
    try testing.expectEqual(@as(u16, 4), g("\\x41{4}", uni, .upper));
}

test "unicode mode certifies explicit ASCII classes only" {
    // Explicit ASCII class: codepoint ≡ byte, certifies in both modes.
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .hex));
    // Perl class inside [...] under unicode: population uncertifiable.
    try testing.expectEqual(@as(u16, 0), g("[\\d]{6}", uni, .digit));
    try testing.expectEqual(@as(u16, 6), g("[\\d]{6}", ascii, .digit));
    // Negated class accepts multi-byte codepoints — never certifies ASCII.
    try testing.expectEqual(@as(u16, 0), g("[^x]{9}", uni, .word));
}

test "sieve decision + saturation monotonicity" {
    const gv = ghat("[0-9a-f]{8}", uni);
    try testing.expect(crest.active(gv));
    try testing.expect(crest.pruned(crest.crest("no hex run here: zz zz"), gv));
    try testing.expect(!crest.pruned(crest.crest("id=0123abcdef more"), gv));
    try testing.expect(!crest.active(ghat("\\w+", uni)));
    // Both query and document values share the saturated u16 domain: nested
    // repetition reaches 100 000 forced digits, past the u16 cap.
    const big = ghat("(?:[0-9]{1000}){100}", uni);
    try testing.expectEqual(std.math.maxInt(u16), big[@intFromEnum(crest.Class.digit)]);
    var long_doc: [70_000]u8 = @splat('0');
    const long_crest = crest.crest(&long_doc);
    try testing.expectEqual(std.math.maxInt(u16), long_crest[@intFromEnum(crest.Class.digit)]);
    try testing.expect(!crest.pruned(long_crest, big));
}

// ─────────────────── the Sieve Theorem, against the matcher ──────────────────

/// Every construct the AST can present, so the generator below cannot quietly
/// stop covering one. Zero-width assertions lead the list on purpose.
const atoms = [_][]const u8{
    "\\b",   "\\B",   "\\<",   "\\>",   "^",        "$",    "\\A",   "\\z",
    "a",     "0",     "_",     " ",     "\\.",      "\\n",  "\\t",   "\\x41",
    "[0-9]", "[a-f]", "[A-Z]", "[a-z]", "[0-9a-f]", "[^x]", "[\\d]", "[.-]",
    ".",     "\\d",   "\\w",   "\\s",   "\\D",      "\\W",  "\\S",   "\\p{L}",
};

const quantifiers = [_][]const u8{ "", "", "", "*", "+", "?", "{2}", "{2,4}", "{0,2}", "{3,}", "*?", "+?" };

fn buildPattern(rng: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, depth: u8) !void {
    if (depth == 0 or rng.boolean()) {
        try out.appendSlice(gpa, atoms[rng.uintLessThan(usize, atoms.len)]);
        try out.appendSlice(gpa, quantifiers[rng.uintLessThan(usize, quantifiers.len)]);
        return;
    }
    switch (rng.uintLessThan(u8, 3)) {
        0 => { // concatenation
            try buildPattern(rng, out, gpa, depth - 1);
            try buildPattern(rng, out, gpa, depth - 1);
        },
        1 => { // alternation inside a group (so the quantifier below binds it)
            try out.appendSlice(gpa, "(?:");
            try buildPattern(rng, out, gpa, depth - 1);
            try out.append(gpa, '|');
            try buildPattern(rng, out, gpa, depth - 1);
            try out.append(gpa, ')');
        },
        else => { // a quantified group, capturing half the time
            try out.appendSlice(gpa, if (rng.boolean()) "(" else "(?:");
            try buildPattern(rng, out, gpa, depth - 1);
            try out.append(gpa, ')');
            try out.appendSlice(gpa, quantifiers[rng.uintLessThan(usize, quantifiers.len)]);
        },
    }
}

test "sieve theorem: a matching document is never pruned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Short documents over a small, class-diverse alphabet, so random patterns
    // actually MATCH often enough for the implication to have teeth (a suite
    // where nothing matches proves nothing).
    const alphabet = "01aAf_ .\t\n<>";
    var docs: std.ArrayList([]const u8) = .empty;
    var prng = std.Random.DefaultPrng.init(0x5EED_C4E5);
    const rng = prng.random();
    for (0..96) |_| {
        const len = rng.uintLessThan(usize, 14);
        const doc = try a.alloc(u8, len);
        for (doc) |*b| b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
        try docs.append(a, doc);
    }
    try docs.append(a, "");
    try docs.append(a, "foo");
    try docs.append(a, "0123abcdef");

    const crests = try a.alloc(crest.Vector, docs.items.len);
    for (docs.items, crests) |d, *v| v.* = crest.crest(d);

    var matches: usize = 0;
    var prunes: usize = 0;
    for (0..1500) |i| {
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        try buildPattern(rng, &pat, a, 3);
        const opts: Options = .{ .unicode = i % 2 == 0, .caseless = i % 3 == 0 };

        var re = Regex.compileOpts(a, pat.items, opts) catch continue;
        defer re.deinit();
        var sim = Regex.Sim.init(a, &re) catch continue;
        const gv = Regex.forcedCrest(a, pat.items, opts);
        if (crest.active(gv)) prunes += 1;

        for (docs.items, crests) |doc, rho| {
            if (!re.docMatch(&sim, doc)) continue;
            matches += 1;
            if (crest.pruned(rho, gv)) {
                std.debug.print(
                    "\nSIEVE VIOLATION: /{s}/ (unicode={}, caseless={}) matches \"{f}\" but ĝ prunes it\n  ρ={any}\n  ĝ={any}\n",
                    .{ pat.items, opts.unicode, opts.caseless, std.zig.fmtString(doc), rho, gv },
                );
                return error.FalseNegative;
            }
        }
    }
    // The run has to have exercised both sides, or it proved nothing.
    try testing.expect(matches > 1000);
    try testing.expect(prunes > 100);
}
