//! Forced-crest calculus tests — hand-computed ĝ for every construct the AST
//! can present, plus the SIEVE THEOREM itself checked against the real matcher:
//! for every (pattern, document) pair, `matched ⇒ !pruned`. That differential is
//! what makes the no-false-negative claim a property of the code rather than an
//! observation about today's corpus, and it is the test that would have caught
//! `\<` being read as a literal `<` by a second, private grammar.
//!
//! The corpus-scale version (real host tree, real index) is `zig build crest`.

const std = @import("std");
const testing = std.testing;
const crest = @import("../../math/crest.zig");
const lower = @import("../linear/program/lower.zig");
const oracle_cases = @import("oracle_cases.gen.zig");
const ranked = @import("swell.zig");
const Regex = @import("../linear/program/core.zig").Regex;

const Options = Regex.Options;
const ascii: Options = .{ .unicode = false };
const uni: Options = .{ .unicode = true };

fn swellOf(pattern: []const u8, opts: Options) crest.Swell {
    return Regex.forcedSwell(testing.allocator, pattern, opts);
}

fn rankedOf(pattern: []const u8, opts: Options, rank: u8, budget: u8) !crest.RankedSwell {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ast = try lower.parse(arena, pattern, opts);
    return ranked.forcedRanked(arena, ast, budget, rank);
}

fn matchedSwell(pattern: []const u8, doc: []const u8, rank: u8) !crest.RankedSwell {
    var re = try Regex.compileOpts(testing.allocator, pattern, ascii);
    defer re.deinit();
    var sim = try Regex.Sim.init(testing.allocator, &re);
    defer sim.deinit();
    try testing.expect(re.docMatch(&sim, doc));

    const swell = Regex.forcedRankedSwell(testing.allocator, pattern, ascii, 8, rank);
    try testing.expect(swell.len != 0);
    try testing.expect(!swell.prunesSpectrum(crest.spectrum(doc, rank)));
    return swell;
}

fn expectExactRequirementsZero(swell: crest.RankedSwell) !void {
    for (swell.requirements[0..swell.len]) |requirement| {
        inline for (std.enums.values(crest.ExactProperty)) |property| {
            for (0..swell.rank) |rank|
                try testing.expectEqual(@as(u16, 0), requirement[crest.spectrumLane(crest.exactLane(property), rank)]);
        }
    }
}

/// Assert the run a pattern's SOLE alternative forces in one class.
/// Single-branchness is part of the assertion on purpose: a pattern that
/// silently gained a second alternative would otherwise keep passing while
/// measuring something else entirely.
fn expectForced(want: u16, pattern: []const u8, opts: Options, c: crest.Class) !void {
    return expectForcedIn(want, pattern, opts, c, .ascii);
}

/// The same, naming which alphabet's half of the family to read — the ASCII
/// lane for a byte class, the scalar-closed lane for a codepoint class.
fn expectForcedIn(want: u16, pattern: []const u8, opts: Options, c: crest.Class, a: crest.Alphabet) !void {
    const s = swellOf(pattern, opts);
    try testing.expectEqual(@as(u8, 1), s.len);
    try testing.expectEqual(want, s.crests[0][crest.lane(c, a)]);
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
    // \d in ASCII mode is a byte class and certifies the ASCII half outright.
    try expectForced(3, "\\d{3}", ascii, .digit);
    // Under the engine's DEFAULT unicode mode the parser lowers it to a
    // `uclass`, which still cannot certify the ASCII half — U+0660 is no ASCII
    // digit — but does certify the scalar-closed half, which is what the
    // document scan measures alongside it. This is the Alphabet Contract's
    // open case (PROOF.md §3.6), and the reason `\d{6}` used to prune nothing
    // while `[0-9]{6}` pruned 92.8% of the corpus.
    try expectForced(0, "\\d{3}", uni, .digit);
    try expectForcedIn(3, "\\d{3}", uni, .digit, .scalar);
    try expectForcedIn(3, "\\d{3}", uni, .hex, .scalar); // digit ⊂ hex
    try expectForcedIn(3, "\\d{3}", uni, .word, .scalar); // …⊂ word
    try expectForcedIn(0, "\\d{3}", uni, .space, .scalar);
    try expectForcedIn(4, "\\w{4}", uni, .word, .scalar);
    try expectForcedIn(0, "\\w{4}", uni, .alpha, .scalar); // '_' and digits are in neither
    try expectForcedIn(5, "\\s{5}", uni, .space, .scalar);

    // The codepoint-run lane (§3.7c) certifies the SAME classes as its `+u`
    // sibling for an ASCII-only run — every byte here is also one codepoint —
    // so the two agree exactly until non-ASCII text enters the mix (below).
    try expectForcedIn(3, "\\d{3}", uni, .digit, .codepoint);
    try expectForcedIn(3, "\\d{3}", uni, .hex, .codepoint);
    try expectForcedIn(3, "\\d{3}", uni, .word, .codepoint);
    try expectForcedIn(4, "\\w{4}", uni, .word, .codepoint);
    try expectForcedIn(5, "\\s{5}", uni, .space, .codepoint);

    // The bound is in BYTES, so a class whose cheapest member is multi-byte
    // forces more of them than it has codepoints. \p{L} has no one-byte
    // member under Unicode — every ASCII letter is folded out of it? no: it
    // keeps them, so one byte is right — while a class confined above U+07FF
    // must spend three.
    try expectForcedIn(2, "\\p{L}{2}", uni, .word, .scalar);
    try expectForcedIn(6, "[\u{4e00}-\u{9fff}]{2}", uni, .word, .scalar);
    try expectForcedIn(8, "[\u{1f600}-\u{1f64f}]{2}", uni, .word, .scalar);

    // §3.7c's whole point: the codepoint lane prices the SAME two patterns at
    // their true codepoint count, not their encoded byte count. A 3-byte CJK
    // character costs `word+u` 3 and `word+cp` exactly 1; a 4-byte emoji costs
    // `word+u` 4 and `word+cp` still 1 — this is the gap that used to clear
    // `\d{6}` on two CJK characters and no digits at all.
    try expectForcedIn(2, "\\p{L}{2}", uni, .word, .codepoint);
    try expectForcedIn(2, "[\u{4e00}-\u{9fff}]{2}", uni, .word, .codepoint);
    try expectForcedIn(2, "[\u{1f600}-\u{1f64f}]{2}", uni, .word, .codepoint);
}

test "forced-crest: the codepoint-run lane refuses a set holding a continuation byte (Lemma 2c)" {
    // `[\x80-\xFF]` in BYTE mode is a `.class` node — a raw byte set, not a
    // codepoint population — and it contains the whole continuation range
    // `[0x80,0xBF]`. A document of six lone continuation bytes measures
    // codepoint-run ZERO (they are transparent, not advancing), so certifying
    // this atom at any positive codepoint length would be a false negative.
    // The refusal must hold on EVERY class, not just one, since the set
    // itself — not any particular class — is what disqualifies it.
    inline for (.{ crest.Class.word, crest.Class.digit, crest.Class.punct, crest.Class.space }) |c| {
        try expectForcedIn(0, "[\\x80-\\xFF]{6}", ascii, c, .codepoint);
    }
    // The scalar-closed lane still certifies it as usual — every non-ASCII
    // byte, continuation or lead alike, is unconditionally IN every scalar
    // twin — unaffected by the codepoint lane's stricter first-byte rule.
    // The point is that ONE lane refuses while its sibling does not, not
    // that the whole atom goes unknown.
    try expectForcedIn(6, "[\\x80-\\xFF]{6}", ascii, .word, .scalar);

    // `[^x]` admits NUL, which is in no member of ANY alphabet — the
    // intersection already empties for the byte and scalar lanes (tested
    // above); the codepoint lane must empty the same way, in both engine modes.
    try expectForcedIn(0, "[^x]{9}", uni, .word, .codepoint);
    try expectForcedIn(0, "[^x]{9}", ascii, .word, .codepoint);
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
    try testing.expectEqual(@as(u16, 0), epsilon.min_cp);
    // A mandatory atom spends bytes, so it can never be mistaken for ε — the
    // distinction `concat`'s seam term leans on. The two units are genuinely
    // independent: an atom can spend 3 bytes and still cost only 1 codepoint.
    var one = @import("../syntax/syntax.zig").ByteSet{};
    one.set('x');
    try testing.expectEqual(@as(u16, 1), analysis.ForcedProfile.atom(one, 1, one, 1).min_len);
    try testing.expectEqual(@as(u16, 3), analysis.ForcedProfile.atom(one, 3, one, 1).min_len);
    try testing.expectEqual(@as(u16, 1), analysis.ForcedProfile.atom(one, 3, one, 1).min_cp);
}

test "top-level alternation is a disjunction, not a componentwise min" {
    // Pareto-equivalent alternatives collapse: clearing the weaker same-class
    // demand already admits every document the stronger branch could admit.
    try expectBranches(&.{2}, "[0-9]{4}|[0-9]{2}", uni, .digit);
    try expectBranches(&.{ 4, 0 }, "[0-9]{4}|abcd", uni, .digit);
    // Multi `-e` and a capture group both reach the calculus as alternation.
    try expectBranches(&.{2}, "(?:[0-9]{4})|(?:[0-9]{2})", uni, .digit);
    try expectBranches(&.{2}, "([0-9]{4}|[0-9]{2})", uni, .digit);
    try expectBranches(&.{2}, "[0-9]{4}|[0-9]{2}|[0-9]{6}", uni, .digit);

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
    // display: `.` admits the NUL byte, which belongs to no member of the
    // family, so that branch admits every document and nothing may be elided.
    try testing.expect(!swellOf("[0-9a-f]{12}|.+", uni).active());
}

test "the split budget degrades toward the folded sieve, never past it" {
    const pattern = "[0-9]{4}|[~]{6}";
    const split = try rankedOf(pattern, ascii, 1, 8);
    const folded = try rankedOf(pattern, ascii, 1, 1);
    try testing.expectEqual(@as(u8, 2), split.len);
    try testing.expect(split.active());
    try testing.expectEqual(@as(u8, 1), folded.len);
    try testing.expect(!folded.active());

    const plain = crest.spectrum("plain prose", 1);
    try testing.expect(split.prunesSpectrum(plain));
    try testing.expect(!folded.prunesSpectrum(plain));
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

test "unicode mode certifies the ASCII half only for explicit ASCII classes" {
    // Explicit ASCII class: codepoint ≡ byte, certifies in both modes.
    try expectForced(8, "[0-9a-f]{8}", uni, .hex);
    // A Perl class inside [...] is still a codepoint population under unicode,
    // so the ASCII half declines and the scalar-closed half carries it.
    try expectForced(0, "[\\d]{6}", uni, .digit);
    try expectForcedIn(6, "[\\d]{6}", uni, .digit, .scalar);
    try expectForced(6, "[\\d]{6}", ascii, .digit);
    // A NEGATED class is the one shape neither half can certify: `[^x]` admits
    // the NUL byte, which is in no member at all, so the intersection empties.
    try expectForced(0, "[^x]{9}", uni, .word);
    try expectForcedIn(0, "[^x]{9}", uni, .word, .scalar);
    try expectForcedIn(0, "[^x]{9}", uni, .punct, .scalar);
}

test "sieve decision + saturation monotonicity" {
    const s = swellOf("[0-9a-f]{8}", uni);
    try testing.expect(s.active());
    try testing.expect(s.prunes(crest.crest("no hex run here: zz zz")));
    try testing.expect(!s.prunes(crest.crest("id=0123abcdef more")));
    try testing.expect(!swellOf(".+", uni).active());
    // `\w+` is NOT inert any more: one word codepoint is at least one byte of
    // `word+u`, whichever alphabet it came from. A weak demand, but a real and
    // sound one — strictly better than the 0⃗ it used to fold to. It elides a
    // document holding neither a word character nor any non-ASCII byte, and
    // nothing else.
    const w = swellOf("\\w+", uni);
    try testing.expect(w.active());
    try testing.expect(w.prunes(crest.crest("  ...  ")));
    try testing.expect(!w.prunes(crest.crest("a")));
    try testing.expect(!w.prunes(crest.crest("\u{4e2d}")));
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

    // NON-ASCII documents, now that a `uclass` certifies something. A wrong
    // `encoded` view — a byte set that misses an encoding, or a `min_len` above
    // the true minimum — is a false negative that can ONLY appear here, since
    // every ASCII document leaves the scalar-closed half equal to its base.
    // Deliberately invalid UTF-8 is in the pool too: the sieve reads bytes and
    // must stay sound on input the matcher may decode differently.
    const tokens = [_][]const u8{
        "\u{0660}", "\u{00e9}", "\u{4e2d}", "\u{1f600}", "\u{00a0}",
        "a",        "0",        "_",        " ",         "\xff",
        "\x80\x80",
    };
    for (0..48) |_| {
        var piece: std.ArrayList(u8) = .empty;
        for (0..1 + rng.uintLessThan(usize, 6)) |_| {
            try piece.appendSlice(a, tokens[rng.uintLessThan(usize, tokens.len)]);
        }
        try docs.append(a, piece.items);
    }
    try docs.append(a, "\u{0660}\u{0661}\u{0662}\u{0663}");
    try docs.append(a, "caf\u{00e9} 123");
    try docs.append(a, "\u{4e2d}\u{6587}\u{4e2d}\u{6587}");

    const crests = try a.alloc(crest.Vector, docs.items.len);
    for (docs.items, crests) |d, *v| v.* = crest.crest(d);

    var matches: usize = 0;
    var prunes: usize = 0;
    var split: usize = 0;
    // Pareto absorption deliberately collapses equivalent split branches, so
    // sample enough patterns to retain the original >100 split-case floor.
    for (0..5000) |i| {
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
    if (matches <= 1000 or prunes <= 100 or split <= 100)
        std.debug.print("\nsieve theorem coverage: matches={d}, active={d}, Pareto-split={d}\n", .{ matches, prunes, split });
    try testing.expect(matches > 1000);
    try testing.expect(prunes > 100);
    try testing.expect(split > 100);
}

test "bounded Pareto compiler preserves disjoint alternatives" {
    const swell = try rankedOf("[0-9]{8}|[~]{12}", ascii, 1, 8);
    try testing.expectEqual(@as(u8, 2), swell.len);
    try testing.expect(swell.active());

    try testing.expect(!swell.prunesSpectrum(crest.spectrum("id=01234567", 1)));
    try testing.expect(!swell.prunesSpectrum(crest.spectrum("rule=" ++ "~" ** 12, 1)));
    try testing.expect(swell.prunesSpectrum(crest.spectrum("plain prose", 1)));
}

test "rank-four compiler proves separated maximal runs" {
    const swell = try rankedOf("[0-9]{3}x[0-9]{5}y[0-9]{2}", ascii, 4, 8);
    try testing.expectEqual(@as(u8, 1), swell.len);
    const requirement = swell.requirements[0];
    const digit = crest.lane(.digit, .ascii);
    try testing.expectEqual(@as(u16, 5), requirement[crest.spectrumLane(digit, 0)]);
    try testing.expectEqual(@as(u16, 3), requirement[crest.spectrumLane(digit, 1)]);
    try testing.expectEqual(@as(u16, 2), requirement[crest.spectrumLane(digit, 2)]);
}

test "byte-mode high-byte sets never certify exact UCD lanes" {
    const cases = [_]struct { pattern: []const u8, doc: []const u8 }{
        .{ .pattern = "[\\xC0]", .doc = "\xC0" },
        .{ .pattern = "[\\xC0-\\xC1]{2}", .doc = "\xC0\xC1" },
        .{ .pattern = "[A\\xC0]{2}", .doc = "A\xC0" },
        .{ .pattern = "[^\\x00-\\x7F]{2}", .doc = "\x80\xFF" },
    };
    for (cases) |case| {
        for ([_]u8{ 1, 4 }) |rank|
            try expectExactRequirementsZero(try matchedSwell(case.pattern, case.doc, rank));
    }

    const separated_q1 = try matchedSwell("[0-9][^\\x00-\\x7F][0-9]", "0\x800", 1);
    const separated_q4 = try matchedSwell("[0-9][^\\x00-\\x7F][0-9]", "0\x800", 4);
    const nd = crest.exactLane(.nd);
    try testing.expectEqual(@as(u16, 1), separated_q1.requirements[0][crest.spectrumLane(nd, 0)]);
    try testing.expectEqual(@as(u16, 1), separated_q4.requirements[0][crest.spectrumLane(nd, 0)]);
    try testing.expectEqual(@as(u16, 0), separated_q4.requirements[0][crest.spectrumLane(nd, 1)]);
}

test "ASCII byte sets retain exact UCD certificates" {
    const cases = .{
        .{ "[0-9]{3}", "123", crest.ExactProperty.nd },
        .{ "[A-Z]{3}", "ABC", crest.ExactProperty.letter },
        .{ "[ \\t]{3}", " \t ", crest.ExactProperty.white_space },
    };
    inline for (cases) |case| {
        for ([_]u8{ 1, 4 }) |rank| {
            const swell = try matchedSwell(case[0], case[1], rank);
            try testing.expectEqual(
                @as(u16, 3),
                swell.requirements[0][crest.spectrumLane(crest.exactLane(case[2]), 0)],
            );
        }
    }

    const separated = try matchedSwell("[0-9]_[0-9]", "0_0", 4);
    const nd = crest.exactLane(.nd);
    try testing.expectEqual(@as(u16, 1), separated.requirements[0][crest.spectrumLane(nd, 0)]);
    try testing.expectEqual(@as(u16, 1), separated.requirements[0][crest.spectrumLane(nd, 1)]);
}

test "Unicode classes certify exact pinned-UCD lanes" {
    const swell = try rankedOf("\\d{3}", uni, 1, 8);
    try testing.expectEqual(@as(u16, 3), swell.requirements[0][crest.spectrumLane(crest.exactLane(.nd), 0)]);
    try testing.expect(!swell.prunesSpectrum(crest.spectrum("\u{0660}\u{0661}\u{0662}", 1)));
    try testing.expect(swell.prunesSpectrum(crest.spectrum("abc", 1)));
}

test "ranked compiler refuses unsupported q and B" {
    try testing.expectError(error.Unsupported, rankedOf("[0-9]", ascii, 3, 8));
    try testing.expectError(error.Unsupported, rankedOf("[0-9]", ascii, 1, 3));
}

fn oracleClass(predicate: oracle_cases.Predicate) crest.Class {
    return switch (predicate) {
        .digit => .digit,
        .hex => .hex,
        .upper => .upper,
        .lower => .lower,
        .alpha => .alpha,
        .word => .word,
        .space => .space,
        .punct => .punct,
        .literal_space => .literal_space,
        .dot => .dot,
        .quote => .quote,
        .lparen => .lparen,
        .slash => .slash,
        .underscore => .underscore,
        .assign_sep => .assign_sep,
    };
}

fn projectedPattern(template: []const u8, projection: oracle_cases.Projection) ![]u8 {
    var substitutions: usize = 0;
    for (template) |byte| substitutions += @intFromBool(byte == 'a' or byte == 'b');

    const pattern = try testing.allocator.alloc(u8, template.len + substitutions * 3);
    const hex = "0123456789abcdef";
    var cursor: usize = 0;
    for (template) |byte| {
        const projected = switch (byte) {
            'a' => projection.member,
            'b' => projection.nonmember,
            else => {
                pattern[cursor] = byte;
                cursor += 1;
                continue;
            },
        };
        pattern[cursor..][0..2].* = "\\x".*;
        pattern[cursor + 2] = hex[projected >> 4];
        pattern[cursor + 3] = hex[projected & 0x0f];
        cursor += 4;
    }
    std.debug.assert(cursor == pattern.len);
    return pattern;
}

fn weakestRequirement(swell: crest.RankedSwell, predicate: usize, order: usize) u16 {
    var bound: u16 = std.math.maxInt(u16);
    for (swell.requirements[0..swell.len]) |requirement|
        bound = @min(bound, requirement[crest.spectrumLane(predicate, order)]);
    return bound;
}

test "independent automata oracle bounds the production ranked compiler" {
    try testing.expectEqual(oracle_cases.fixture_count, oracle_cases.cases.len * oracle_cases.projections.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 4 }, &oracle_cases.supported_production_ranks);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &oracle_cases.order_statistics);

    for (oracle_cases.cases) |case| {
        for (oracle_cases.projections) |projection| {
            const pattern = try projectedPattern(case.pattern, projection);
            defer testing.allocator.free(pattern);
            const predicate = crest.lane(oracleClass(projection.predicate), .ascii);
            const swell = try rankedOf(pattern, ascii, 4, 8);
            try testing.expect(swell.len != 0);

            inline for (oracle_cases.order_statistics, 0..) |order_statistic, oracle_index| {
                const got = weakestRequirement(swell, predicate, order_statistic - 1);
                const exact = case.oracle[oracle_index];
                if (got > exact or (case.exact_subset and got != exact)) {
                    std.debug.print(
                        "\nCREST ORACLE MISMATCH /{s}/ predicate={s} q={d}: compiler={d}, oracle={d}, exact_subset={}\n",
                        .{
                            pattern,
                            @tagName(projection.predicate),
                            order_statistic,
                            got,
                            exact,
                            case.exact_subset,
                        },
                    );
                }
                try testing.expect(got <= exact);
                if (case.exact_subset) try testing.expectEqual(exact, got);
            }
        }
    }
}
