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

fn swellOf(pattern: []const u8, opts: Options) crest.Swell {
    return Regex.forcedSwell(testing.allocator, pattern, opts);
}

/// Assert the run a pattern's SOLE alternative forces in one class.
/// Single-branchness is part of the assertion on purpose: a pattern that
/// silently gained a second alternative would otherwise keep passing while
/// measuring something else entirely.
fn expectForced(want: u16, pattern: []const u8, opts: Options, c: crest.Class) !void {
    const s = swellOf(pattern, opts);
    try testing.expectEqual(@as(u8, 1), s.len);
    try testing.expectEqual(want, s.crests[0][@intFromEnum(c)]);
}

/// Assert a pattern yields NO alternative at all — the stand-down the calculus
/// takes when the engine itself declined the pattern. Distinct from a parsed
/// branch forcing 0: one analyzed nothing, the other analyzed and found nothing.
/// Both prune nothing, and the difference is worth keeping legible.
fn expectStandDown(pattern: []const u8, opts: Options) !void {
    const s = swellOf(pattern, opts);
    try testing.expectEqual(@as(u8, 0), s.len);
    try testing.expect(!s.active());
    try testing.expect(!s.prunes(crest.crest("")));
}

/// Assert the runs every alternative forces in one class, as a multiset — the
/// split order is an implementation detail of the worklist, the contents are
/// the contract.
fn expectBranches(want: []const u16, pattern: []const u8, opts: Options, c: crest.Class) !void {
    const s = swellOf(pattern, opts);
    var got: [crest.Swell.capacity]u16 = undefined;
    for (s.crests[0..s.len], got[0..s.len]) |ghat, *out| out.* = ghat[@intFromEnum(c)];
    std.mem.sort(u16, got[0..s.len], {}, std.sort.asc(u16));
    const sorted = try testing.allocator.dupe(u16, want);
    defer testing.allocator.free(sorted);
    std.mem.sort(u16, sorted, {}, std.sort.asc(u16));
    try testing.expectEqualSlices(u16, sorted, got[0..s.len]);
}

test "forced-crest: class repetition is the whole point" {
    try expectForced(8, "[0-9a-f]{8}", uni, .hex);
    try expectForced(8, "[0-9a-f]{8}", uni, .word); // hex ⊂ word
    try expectForced(6, "[0-9]{6}", uni, .digit);
    try expectForced(4, "[A-Z]{4}", uni, .upper);
    // \d certifies in ASCII mode only (Alphabet Contract): under Unicode the
    // parser lowers it to a `uclass`, which spends bytes on non-ASCII scalars.
    try expectForced(3, "\\d{3}", ascii, .digit);
    try expectForced(0, "\\d{3}", uni, .digit);
}

test "forced-crest: straddle across concatenation" {
    try expectForced(3, "[0-9][0-9][0-9]", uni, .digit);
    try expectForced(1, "[0-9]+", uni, .digit); // one forced copy
    // anchors are zero-width identity: runs cross them freely.
    try expectForced(4, "^[0-9]{4}$", uni, .digit);
    try expectForced(2, "[0-9](?:)[0-9]", uni, .digit);
}

test "zero-width assertions never force a byte" {
    // THE REGRESSION. `\<`/`\>` are word-boundary assertions, not escaped
    // punctuation: `\<foo\>` matches the document "foo", which holds no punct
    // at all. A calculus that read them as literal `<`/`>` forced punct ≥ 1 and
    // silently elided every such hit — 1500 of 2200 files on the reproduction.
    inline for (.{ "\\<foo\\>", "\\bfoo\\b", "\\Bfoo\\B", "^foo$", "\\Afoo\\z" }) |pat| {
        try expectForced(0, pat, uni, .punct);
        try expectForced(3, pat, uni, .lower); // the body still forces
        try testing.expect(!swellOf(pat, uni).prunes(crest.crest("foo")));
    }
    // An assertion between two class runs must not break the straddle either.
    try expectForced(6, "[0-9]{3}\\b[0-9]{3}", uni, .digit);
    // …while a real escaped punct byte still forces its run.
    try expectForced(2, "\\<\\.\\.", uni, .punct);
}

test "optional profiles preserve only-class certificates without joining separators" {
    try expectForced(1, "[0-9][a-z]?[0-9]", uni, .digit);
    try expectForced(2, "[0-9][0-9]?[0-9]", uni, .digit);
    try expectForced(1, "[0-9][a-z]*[0-9]", uni, .digit);
    try expectForced(2, "[0-9][0-9]*[0-9]", uni, .digit);
    try expectForced(2, "[0-9][a-z]{0,0}[0-9]", uni, .digit);
    try expectForced(1, "[0-9][a-z]{0,1}[0-9]", uni, .digit);
    try testing.expect(!swellOf("[0-9][a-z]?[0-9]", uni).prunes(crest.crest("1a2")));
    try testing.expect(swellOf("[0-9][0-9]?[0-9]", uni).prunes(crest.crest("1a2")));
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

test "top-level alternation is a disjunction, not a componentwise min" {
    // Each alternative keeps its OWN demand. Collapsing them was sound but
    // blunt: it kept only 2 here, and nothing at all in the next two cases.
    try expectBranches(&.{ 4, 2 }, "[0-9]{4}|[0-9]{2}", uni, .digit);
    try expectBranches(&.{ 4, 0 }, "[0-9]{4}|abcd", uni, .digit);
    // Multi `-e` and a capture group both reach the calculus as alternation.
    try expectBranches(&.{ 4, 2 }, "(?:[0-9]{4})|(?:[0-9]{2})", uni, .digit);
    try expectBranches(&.{ 4, 2 }, "([0-9]{4}|[0-9]{2})", uni, .digit);
    try expectBranches(&.{ 6, 4, 2 }, "[0-9]{4}|[0-9]{2}|[0-9]{6}", uni, .digit);

    // THE REGRESSION. Two alternatives forcing DISJOINT classes min to 0⃗, so a
    // single-vector ĝ sieved by nothing — and every extra `-e` could only make
    // that worse. `gist -e '[0-9a-f]{12}' -e '[~]{60}'` measured 12.8× slower
    // than its first half alone for a byte-identical answer.
    const disjoint = swellOf("[0-9a-f]{12}|[~]{60}", uni);
    try testing.expect(disjoint.active());
    try testing.expect(disjoint.prunes(crest.crest("plain prose, no hex, no tildes")));
    try testing.expect(!disjoint.prunes(crest.crest("id=0123456789ab")));
    try testing.expect(!disjoint.prunes(crest.crest("~" ** 60)));

    // A branch that forces nothing disarms the whole swell — soundness on
    // display: `\w+` matches almost anything, so nothing may be elided.
    try testing.expect(!swellOf("[0-9a-f]{12}|\\w+", uni).active());
}

test "the split budget degrades toward the folded sieve, never past it" {
    // Alternatives beyond `capacity` stay one subtree, which `Profile.alt`
    // min-folds exactly as the old single-vector calculus did.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..40) |i| {
        if (i != 0) try many.append(testing.allocator, '|');
        try many.print(testing.allocator, "[0-9]{{{d}}}", .{i + 2});
    }
    const s = swellOf(many.items, uni);
    try testing.expectEqual(@as(u8, crest.Swell.capacity), s.len);
    try testing.expect(s.active());
    // Every alternative still demands ≥2 digits, so the weakest possible
    // disjunction is still the weakest single branch — never weaker.
    for (s.crests[0..s.len]) |ghat| try testing.expect(ghat[@intFromEnum(crest.Class.digit)] >= 2);
    try testing.expect(s.prunes(crest.crest("only one 1 digit")));
    try testing.expect(!s.prunes(crest.crest("12345678901234567890")));
}

test "soundness by degradation: what the engine rejects prunes nothing" {
    // A pattern the ENGINE cannot compile yields no alternative at all — the
    // sieve stands down rather than guessing at a language it does not
    // implement. There is nothing to be disjunctive ABOUT when the parse failed.
    try expectStandDown("(?=foo)[0-9]{8}", uni); // lookahead
    try expectStandDown("(\\d)\\1{7}", ascii); // backreference
    try expectStandDown("[0-9]{3,2}", uni); // max < min
    try expectStandDown("[0-9]{1001}", uni); // past the repeat cap
    // Nullable quantifiers force nothing, though they parse fine.
    try expectForced(0, "[0-9]*", uni, .digit);
    try expectForced(0, "[0-9]{0,8}", uni, .digit);
    // `\p{L}` is a codepoint class: parsed, but certifies no ASCII class.
    try expectForced(0, "\\p{L}{4}", uni, .alpha);
    // An unescaped `{` must begin a valid count or the pattern is rejected
    // outright (rust-regex parity; a literal brace is `\{`) — so a malformed
    // bound prunes nothing, and the ESCAPED brace is what forces punct.
    try expectStandDown("[0-9]{3,x}", uni);
    try expectStandDown("[0-9]{,3}", uni);
    try expectForced(1, "[0-9]\\{3", uni, .punct);
}

test "caseless: the matcher's own fold, not a private approximation" {
    const ci: Options = .{ .unicode = true, .caseless = true };
    const ci_ascii: Options = .{ .unicode = false, .caseless = true };
    // hex letters a–f never fold outside ASCII, so `(?i)[0-9a-f]{8}` still
    // forces an 8-byte hex (and word) run in BOTH engine modes — the UUID case.
    try expectForced(8, "[0-9a-f]{8}", ci, .hex);
    try expectForced(8, "[0-9a-f]{8}", ci, .word);
    try expectForced(8, "[0-9a-f]{8}", ci_ascii, .hex);
    // digits are case-invariant: `(?i)[0-9]{6}` unchanged from case-sensitive.
    try expectForced(6, "[0-9]{6}", ci, .digit);
    // `upper`/`lower` are the only non-case-closed classes: the fold moves bytes
    // across them, so they always self-decline (`[A-F]` avoids k/K/s/S, so it
    // still certifies its case-closed classes under Unicode `-i`).
    try expectForced(0, "[A-F]{4}", ci, .upper);
    try expectForced(4, "[A-F]{4}", ci, .hex); // A–F ⊂ hex, no escape
    try expectForced(4, "[A-F]{4}", ci, .alpha);
    // The Unicode escape guard is now STRUCTURAL: `k`→U+212A KELVIN SIGN and
    // `s`→U+017F LONG S leave ASCII, so `foldCaseAst` promotes any class holding
    // them to a `uclass`, which certifies nothing — no hand-maintained k/s check.
    try expectForced(0, "[A-Z]{4}", ci, .alpha);
    try expectForced(4, "[A-Z]{4}", ci_ascii, .alpha);
    try expectForced(4, "[A-Z]{4}", ci_ascii, .word);
    try expectForced(0, "[A-Z]{4}", ci_ascii, .upper); // fold ⊄ upper
    try expectForced(0, "[a-z]{5}", ci, .word); // contains k,s
    try expectForced(5, "[a-z]{5}", ci_ascii, .word);
    try expectForced(0, "[s-z]{5}", ci, .word); // contains s
    try expectForced(4, "[g-j]{4}", ci, .word); // no k/s: safe
    // The sieve engages and prunes a doc lacking the run.
    try testing.expect(swellOf("[0-9a-f]{8}", ci).prunes(crest.crest("no hex zz")));
    try testing.expect(!swellOf("[0-9a-f]{8}", ci).prunes(crest.crest("v=DEADBEEF n")));
}

test "escapes carry their real bytes (\\n is newline, not 'n')" {
    // \n{5}: five newlines — a SPACE run of 5, and no word run at all. Getting
    // this wrong (treating \n as the byte 'n') would manufacture false negatives.
    try expectForced(5, "\\n{5}", uni, .space);
    try expectForced(0, "\\n{5}", uni, .word);
    try expectForced(2, "\\t\\t", uni, .space);
    // escaped metachar is itself: \. is the punct byte '.'.
    try expectForced(3, "\\.{3}", uni, .punct);
    // `\x41` is 'A' to this engine, so it forces upper — the private grammar
    // used to decline the whole pattern here.
    try expectForced(4, "\\x41{4}", uni, .upper);
}

test "unicode mode certifies explicit ASCII classes only" {
    // Explicit ASCII class: codepoint ≡ byte, certifies in both modes.
    try expectForced(8, "[0-9a-f]{8}", uni, .hex);
    // Perl class inside [...] under unicode: population uncertifiable.
    try expectForced(0, "[\\d]{6}", uni, .digit);
    try expectForced(6, "[\\d]{6}", ascii, .digit);
    // Negated class accepts multi-byte codepoints — never certifies ASCII.
    try expectForced(0, "[^x]{9}", uni, .word);
}

test "sieve decision + saturation monotonicity" {
    const s = swellOf("[0-9a-f]{8}", uni);
    try testing.expect(s.active());
    try testing.expect(s.prunes(crest.crest("no hex run here: zz zz")));
    try testing.expect(!s.prunes(crest.crest("id=0123abcdef more")));
    try testing.expect(!swellOf("\\w+", uni).active());
    // Both query and document values share the saturated u16 domain: nested
    // repetition reaches 100 000 forced digits, past the u16 cap.
    const big = swellOf("(?:[0-9]{1000}){100}", uni);
    try expectForced(std.math.maxInt(u16), "(?:[0-9]{1000}){100}", uni, .digit);
    var long_doc: [70_000]u8 = @splat('0');
    const long_crest = crest.crest(&long_doc);
    try testing.expectEqual(std.math.maxInt(u16), long_crest[@intFromEnum(crest.Class.digit)]);
    try testing.expect(!big.prunes(long_crest));
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
    var split: usize = 0;
    for (0..1500) |i| {
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        // A third of the run is a BARE top-level alternation of 2–9 branches —
        // the shape the swell splits on, and the only one that can expose a
        // false negative in the disjunction itself (including past `capacity`,
        // where the tail min-folds).
        const branches = if (i % 3 == 0) 1 + rng.uintLessThan(usize, 9) else 1;
        for (0..branches) |b| {
            if (b != 0) try pat.append(a, '|');
            try buildPattern(rng, &pat, a, 3);
        }
        const opts: Options = .{ .unicode = i % 2 == 0, .caseless = i % 5 == 0 };

        var re = Regex.compileOpts(a, pat.items, opts) catch continue;
        defer re.deinit();
        var sim = Regex.Sim.init(a, &re) catch continue;
        const swell = Regex.forcedSwell(a, pat.items, opts);
        if (swell.active()) prunes += 1;
        if (swell.len > 1) split += 1;

        for (docs.items, crests) |doc, rho| {
            if (!re.docMatch(&sim, doc)) continue;
            matches += 1;
            if (swell.prunes(rho)) {
                std.debug.print(
                    "\nSIEVE VIOLATION: /{s}/ (unicode={}, caseless={}) matches \"{f}\" but the swell prunes it\n  ρ={any}\n  ĝ×{d}={any}\n",
                    .{ pat.items, opts.unicode, opts.caseless, std.zig.fmtString(doc), rho, swell.len, swell.crests[0..swell.len] },
                );
                return error.FalseNegative;
            }
        }
    }
    // The run has to have exercised every side, or it proved nothing: matches
    // to give the implication an antecedent, prunes to give it teeth, and
    // multi-branch swells to cover the disjunction the theorem now ranges over.
    try testing.expect(matches > 1000);
    try testing.expect(prunes > 100);
    try testing.expect(split > 100);
}
