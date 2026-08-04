//! irregex patterns — adversarial tests for the multi-pattern set.
//!
//! The one contract that matters: a `PatternSet` answer must be EXACTLY the
//! answer N independent single-pattern `CompiledQuery` runs would give — the
//! fused gate and the muster's SIMD roll are accelerators, never oracles. So
//! every test here compares the set against the per-pattern engine directly (a
//! true independent oracle, not a mirror), including the heterogeneous shapes
//! that force the gate OFF (mixed case demands, non-linear bodies) and a
//! differential fuzz over random haystacks.
//!
//! Every parity assertion runs TWICE — once with the muster armed and once with
//! it stripped — because an accelerator that changes an answer is only visible
//! when you can compare against its own absence. Three answers must agree on
//! every document: muster on, muster off, and N independent searches.

const std = @import("std");
const patterns = @import("patterns.zig");
const query = @import("../query/query.zig");

const gpa = std.testing.allocator;
const PatternSet = patterns.PatternSet;
const Spec = query.Spec;

/// Oracle: does `spec` alone match `doc`? Straight through the single-pattern
/// engine, no set machinery.
fn oracleMatches(spec: Spec, doc: []const u8) !bool {
    var q = try query.CompiledQuery.compile(gpa, spec);
    defer q.deinit(gpa);
    var sc = try q.scratch(gpa);
    defer sc.deinit();
    return q.docMatches(doc, &sc);
}

/// Assert the set's docMask over `doc` equals the per-pattern oracle, bit for
/// bit — with the muster armed AND with it stripped, so the SIMD roll is proven
/// to be a pure accelerator rather than a second (possibly disagreeing) oracle.
fn expectMaskParity(specs: []const Spec, doc: []const u8) !void {
    try expectMaskParityOne(specs, doc, true);
    try expectMaskParityOne(specs, doc, false);
}

fn expectMaskParityOne(specs: []const Spec, doc: []const u8, armed: bool) !void {
    var set = try PatternSet.compile(gpa, specs);
    defer set.deinit(gpa);
    if (!armed) if (set.muster) |*m| {
        m.deinit(gpa);
        set.muster = null;
    };
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(mask);
    const any = set.docMask(doc, &sc, mask);

    var oracle_any = false;
    for (specs, 0..) |spec, i| {
        const want = try oracleMatches(spec, doc);
        oracle_any = oracle_any or want;
        try std.testing.expectEqual(want, patterns.maskHas(mask, i));
    }
    try std.testing.expectEqual(oracle_any, any);
    try std.testing.expectEqual(oracle_any, set.anyMatch(doc, &sc));
}

fn expectCompiledMaskParity(
    armed: *const PatternSet,
    armed_sc: *PatternSet.Scratch,
    armed_mask: []u64,
    bare: *const PatternSet,
    bare_sc: *PatternSet.Scratch,
    bare_mask: []u64,
    oracles: []const query.CompiledQuery,
    oracle_sc: []query.Scratch,
    doc: []const u8,
) !void {
    const armed_any = armed.docMask(doc, armed_sc, armed_mask);
    const bare_any = bare.docMask(doc, bare_sc, bare_mask);
    var oracle_any = false;
    for (oracles, oracle_sc, 0..) |*oracle, *sc, i| {
        const want = oracle.docMatches(doc, sc);
        oracle_any = oracle_any or want;
        try std.testing.expectEqual(want, patterns.maskHas(armed_mask, i));
        try std.testing.expectEqual(want, patterns.maskHas(bare_mask, i));
    }
    try std.testing.expectEqual(oracle_any, armed_any);
    try std.testing.expectEqual(oracle_any, bare_any);
    try std.testing.expectEqual(oracle_any, armed.anyMatch(doc, armed_sc));
    try std.testing.expectEqual(oracle_any, bare.anyMatch(doc, bare_sc));
}

test "attribution parity: mixed literals + regex against the single-pattern oracle" {
    const doc =
        \\const store = try SessionStore.init(gpa);
        \\pub fn handleRefund(w: *SessionStore) !void {
        \\    return w.refund(amount);
        \\}
    ;
    const specs = [_]Spec{
        .{ .pattern = "SessionStore", .fixed = true },
        .{ .pattern = "refund\\(", .fixed = false },
        .{ .pattern = "nonexistent_needle_zzz", .fixed = true },
        .{ .pattern = "handle[A-Z]\\w+", .fixed = false },
    };
    try expectMaskParity(&specs, doc);
}

test "gate off (mixed case demands): still exact" {
    // ignore_case differs across specs ⇒ no fused gate; confirm-only must
    // still produce oracle-exact attribution.
    const specs = [_]Spec{
        .{ .pattern = "SESSIONSTORE", .fixed = true, .ignore_case = true },
        .{ .pattern = "SESSIONSTORE", .fixed = true, .ignore_case = false },
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    try std.testing.expect(set.gate == null);
    try expectMaskParity(&specs, "one SessionStore here");
}

test "fixed metacharacters never leak into the gate as syntax" {
    // A `-F` pattern full of regex metachars: if the gate mis-escaped it, the
    // alternation would either fail to compile (gate null — acceptable) or,
    // worse, match the WRONG thing. Parity with the oracle catches both.
    const specs = [_]Spec{
        .{ .pattern = "a.b(c)*d", .fixed = true },
        .{ .pattern = "plainword", .fixed = true },
    };
    try expectMaskParity(&specs, "the literal a.b(c)*d appears; aXbccccd must not count");
    try expectMaskParity(&specs, "aXbccccd only — no fixed hit, no plainword");
}

test "lineHits attributes per line, only where the oracle agrees" {
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "b[e3]ta", .fixed = false },
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);

    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);

    try set.lineHits("alpha and b3ta together", &sc, gpa, &hits);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, hits.items);

    hits.clearRetainingCapacity();
    try set.lineHits("only beta here", &sc, gpa, &hits);
    try std.testing.expectEqualSlices(u32, &.{1}, hits.items);

    hits.clearRetainingCapacity();
    try set.lineHits("neither one", &sc, gpa, &hits);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "single spec set: no gate, still exact" {
    const specs = [_]Spec{.{ .pattern = "needle", .fixed = true }};
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    try std.testing.expect(set.gate == null);
    try expectMaskParity(&specs, "a needle in a haystack");
    try expectMaskParity(&specs, "no such thing");
}

test "differential fuzz: random haystacks, set ≡ N oracles" {
    // Random lowercase haystacks against a fixed pattern slate whose needles
    // are short enough to actually occur — the classic mirror-free oracle
    // loop (same shape as regex/adversarial_test.zig).
    const specs = [_]Spec{
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "c+d", .fixed = false },
        .{ .pattern = "e.g", .fixed = false },
        .{ .pattern = "hh", .fixed = true },
    };
    var prng = std.Random.DefaultPrng.init(0xdecaf);
    const r = prng.random();
    var buf: [96]u8 = undefined;
    for (0..200) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 8);
        try expectMaskParity(&specs, buf[0..n]);
    }
}

test "a slate wider than the muster's bucket count stays exact" {
    // 24 patterns over 8 buckets: every bucket carries three literals, so a
    // candidate lane names three patterns and only the confirm can separate
    // them. Mixed shapes on purpose — bare literals (settled by presence),
    // caseless bodies (never settled), a `-w` body (nominated, never decided),
    // and a bare `.` (no derivable literal ⇒ permanently in play).
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "alphabet", .fixed = true },
        .{ .pattern = "alphanumeric", .fixed = true },
        .{ .pattern = "bravo", .fixed = true },
        .{ .pattern = "bravado", .fixed = true },
        .{ .pattern = "charlie", .fixed = true },
        .{ .pattern = "delta", .fixed = true },
        .{ .pattern = "echo", .fixed = true },
        .{ .pattern = "foxtrot", .fixed = true },
        .{ .pattern = "golf", .fixed = true },
        .{ .pattern = "hotel", .fixed = true },
        .{ .pattern = "india", .fixed = true },
        .{ .pattern = "ALPHA", .fixed = true, .ignore_case = true },
        .{ .pattern = "BRAVO", .fixed = true, .ignore_case = true },
        .{ .pattern = "alpha", .fixed = true, .word = true },
        .{ .pattern = "del[t7]a", .fixed = false },
        .{ .pattern = "ech[o0]", .fixed = false },
        .{ .pattern = "gol[fF]|hote[lL]", .fixed = false },
        .{ .pattern = ".", .fixed = false },
        .{ .pattern = "zz_absent_zz", .fixed = true },
        .{ .pattern = "a.b(c)*d", .fixed = true },
        .{ .pattern = "j", .fixed = true }, // single byte: below the SIMD floor
        .{ .pattern = "k", .fixed = true },
        .{ .pattern = "juliett", .fixed = true },
    };
    // Short enough for the scalar tail, long enough for the vector body, and one
    // document holding nothing at all (the all-miss early rejection).
    try expectMaskParity(&specs, "alphabet");
    try expectMaskParity(&specs, "alpha bravado charlie delta echo foxtrot golf hotel india juliett");
    try expectMaskParity(&specs, "alphanumeric ALPHA and Bravo, del7a, ech0, a.b(c)*d, k");
    try expectMaskParity(&specs, "qqqqqqqq");
    try expectMaskParity(&specs, "");
}

test "differential fuzz: wide slate, muster on ≡ muster off ≡ N oracles" {
    // The same mirror-free loop as above, but with enough patterns to force
    // bucket sharing and enough shapes to exercise every muster arm.
    const specs = [_]Spec{
        .{ .pattern = "ab", .fixed = true },
        .{ .pattern = "ba", .fixed = true },
        .{ .pattern = "abc", .fixed = true },
        .{ .pattern = "c+d", .fixed = false },
        .{ .pattern = "e.g", .fixed = false },
        .{ .pattern = "hh", .fixed = true },
        .{ .pattern = "f|gg", .fixed = false },
        .{ .pattern = "AB", .fixed = true, .ignore_case = true },
        .{ .pattern = "ab", .fixed = true, .word = true },
        .{ .pattern = "d", .fixed = true },
        .{ .pattern = "efe", .fixed = true },
        .{ .pattern = "[gh]{2,3}", .fixed = false },
    };
    var prng = std.Random.DefaultPrng.init(0xdecaf2);
    const r = prng.random();
    var buf: [160]u8 = undefined;
    for (0..200) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + r.uintLessThan(u8, 8);
        try expectMaskParity(&specs, buf[0..n]);
    }
}

test "lineHits is muster-invariant" {
    const specs = [_]Spec{
        .{ .pattern = "alpha", .fixed = true },
        .{ .pattern = "b[e3]ta", .fixed = false },
        .{ .pattern = "GAMMA", .fixed = true, .ignore_case = true },
        .{ .pattern = "absent", .fixed = true },
    };
    const lines = [_][]const u8{
        "alpha and b3ta and Gamma",
        "only beta here",
        "neither one",
        "",
        "alphabetagamma runs them together",
    };
    try expectLineHitsParity(&specs, &lines);
}

/// Three answers per line, all required to agree: muster armed, muster stripped,
/// and N independent single-pattern engines.
fn expectLineHitsParity(specs: []const Spec, lines: []const []const u8) !void {
    for (lines) |line| {
        var armed: std.ArrayList(u32) = .empty;
        defer armed.deinit(gpa);
        var bare: std.ArrayList(u32) = .empty;
        defer bare.deinit(gpa);
        try collectLineHits(specs, line, true, &armed);
        try collectLineHits(specs, line, false, &bare);
        try std.testing.expectEqualSlices(u32, bare.items, armed.items);

        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (specs, 0..) |spec, i| {
            if (try oracleMatches(spec, line)) try want.append(gpa, @intCast(i));
        }
        try std.testing.expectEqualSlices(u32, want.items, armed.items);
    }
}

fn collectLineHits(specs: []const Spec, line: []const u8, armed: bool, out: *std.ArrayList(u32)) !void {
    var set = try PatternSet.compile(gpa, specs);
    defer set.deinit(gpa);
    if (!armed) if (set.muster) |*m| {
        m.deinit(gpa);
        set.muster = null;
    };
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    try set.lineHits(line, &sc, gpa, out);
}

// ── what the muster is allowed to SETTLE ────────────────────────────────────
// A settled pattern skips the engine confirm entirely: the literal hit IS the
// verdict. That is only sound for a match EQUIVALENCE, so these tests fix the
// boundary from both sides — a pattern that may be settled, and the near-misses
// that must not be, each chosen so that settling it would produce a WRONG answer
// rather than merely a slower one.

/// Is pattern `i` of `specs` settled by its literals alone?
fn settles(specs: []const Spec, i: usize) !bool {
    var set = try PatternSet.compile(gpa, specs);
    defer set.deinit(gpa);
    const m = set.muster orelse return false;
    return m.isSettled(i);
}

test "muster settles a pure-literal alternation, and the answer still matches the oracle" {
    // `TODO|FIXME|XXX` is an alternation of literals, so containment of any one
    // of them IS a match — the equivalence `analysis.pureLiterals` proves and
    // the single-pattern scanner has always spent. Before this, the slate
    // treated it as a mere cover and re-confirmed every hit through the engine.
    const specs = [_]Spec{
        .{ .pattern = "TODO|FIXME|XXX", .fixed = false },
        .{ .pattern = "SessionStore", .fixed = true },
    };
    try std.testing.expect(try settles(&specs, 0));

    // Each branch alone, both branches, and a line that misses every branch
    // while still containing near-miss text.
    try expectMaskParity(&specs, "a TODO here");
    try expectMaskParity(&specs, "a FIXME here");
    try expectMaskParity(&specs, "XXX and TODO and SessionStore");
    try expectMaskParity(&specs, "TOD0 FIXM3 XX — none of them, really");
    try expectLineHitsParity(&specs, &.{ "TODO alone", "nothing at all", "XXX" });
}

test "an anchored alternation is NOT settled — containment is not the question" {
    // `^foo|^bar` is covered by {foo,bar} but decided by neither: the literal
    // may sit mid-line. Settling it would report a match for "xxfoo", which the
    // oracle rejects — so the parity assertion below is a real trap, not a
    // restatement. `pureLit` refuses an anchor node, which is what holds it.
    const specs = [_]Spec{
        .{ .pattern = "^foo|^bar", .fixed = false },
        .{ .pattern = "zeta", .fixed = true },
    };
    try std.testing.expect(!try settles(&specs, 0));
    try expectMaskParity(&specs, "xxfoo — the literal is present but not at line start");
    try expectLineHitsParity(&specs, &.{ "xxfoo", "foo at the start", "  bar indented" });
}

test "a word query is nominated, never settled" {
    // `-w` narrows the match set AFTER containment, so `cat` present does not
    // mean `\bcat\b` matched. "concatenate" is the trap.
    const specs = [_]Spec{
        .{ .pattern = "cat", .fixed = true, .word = true },
        .{ .pattern = "dog", .fixed = true },
    };
    try std.testing.expect(!try settles(&specs, 0));
    try expectMaskParity(&specs, "concatenate is not a cat");
    try expectLineHitsParity(&specs, &.{ "concatenate", "a cat sat", "dog only" });
}

test "a literal-prefixed regex is covered but not settled" {
    // `pgxpool\.\w+` has required literal "pgxpool", which is a complete cover
    // and an unsound verdict: "pgxpool" alone, with no `.`, must not match.
    const specs = [_]Spec{
        .{ .pattern = "pgxpool\\.\\w+", .fixed = false },
        .{ .pattern = "JetStream", .fixed = true },
    };
    try std.testing.expect(!try settles(&specs, 0));
    try expectMaskParity(&specs, "pgxpool on its own, no member access");
    try expectMaskParity(&specs, "pgxpool.Acquire here");
    try expectLineHitsParity(&specs, &.{ "pgxpool", "pgxpool.Acquire", "JetStream" });
}

test "differential fuzz: settled patterns agree with N oracles over random haystacks" {
    // The general guard. The slate mixes settle-eligible alternations with the
    // shapes that must not settle, over haystacks assembled from fragments that
    // straddle every boundary above (near-misses, anchors, word edges).
    const specs = [_]Spec{
        .{ .pattern = "TODO|FIXME", .fixed = false }, // settles
        .{ .pattern = "alpha", .fixed = true }, // settles
        .{ .pattern = "^beta", .fixed = false }, // anchored: must not
        .{ .pattern = "gamma", .fixed = true, .word = true }, // word: must not
        .{ .pattern = "delta\\d+", .fixed = false }, // covered only
    };
    const frag = [_][]const u8{
        "TODO",  "TOD",      "FIXME", "alpha",  "alphabet", "beta", "xbeta",
        "gamma", "gammaray", "delta", "delta7", " ",        "\n",   "zz",
    };
    var armed = try PatternSet.compile(gpa, &specs);
    defer armed.deinit(gpa);
    var armed_sc = try armed.scratch(gpa);
    defer armed_sc.deinit(gpa);
    var bare = try PatternSet.compile(gpa, &specs);
    defer bare.deinit(gpa);
    if (bare.muster) |*m| {
        m.deinit(gpa);
        bare.muster = null;
    }
    var bare_sc = try bare.scratch(gpa);
    defer bare_sc.deinit(gpa);

    const oracles = try gpa.alloc(query.CompiledQuery, specs.len);
    defer gpa.free(oracles);
    var compiled: usize = 0;
    defer for (oracles[0..compiled]) |*oracle| oracle.deinit(gpa);
    for (specs, oracles) |spec, *oracle| {
        oracle.* = try query.CompiledQuery.compile(gpa, spec);
        compiled += 1;
    }
    const oracle_sc = try gpa.alloc(query.Scratch, specs.len);
    defer gpa.free(oracle_sc);
    var scratched: usize = 0;
    defer for (oracle_sc[0..scratched]) |*sc| sc.deinit();
    for (oracles, oracle_sc) |*oracle, *sc| {
        sc.* = try oracle.scratch(gpa);
        scratched += 1;
    }
    const armed_mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(armed_mask);
    const bare_mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(bare_mask);

    var prng = std.Random.DefaultPrng.init(0x5EED_5E77_1E00);
    const rand = prng.random();
    var buf: [512]u8 = undefined;
    for (0..2000) |_| {
        var n: usize = 0;
        const parts = rand.intRangeAtMost(usize, 1, 10);
        for (0..parts) |_| {
            const f = frag[rand.intRangeLessThan(usize, 0, frag.len)];
            if (n + f.len > buf.len) break;
            @memcpy(buf[n..][0..f.len], f);
            n += f.len;
        }
        // A random haystack is unreadable from the failure alone; name it, with
        // each pattern's oracle verdict and whether the muster settled it.
        expectCompiledMaskParity(&armed, &armed_sc, armed_mask, &bare, &bare_sc, bare_mask, oracles, oracle_sc, buf[0..n]) catch |e| {
            std.debug.print("disagreement on \"{f}\"\n", .{std.zig.fmtString(buf[0..n])});
            for (specs, 0..) |spec, i| std.debug.print("  [{d}] {s:<12} oracle={} settled={}\n", .{
                i, spec.pattern, try oracleMatches(spec, buf[0..n]), try settles(&specs, i),
            });
            return e;
        };
    }
}

test "the fused gate may reject, but a -w slate's gate may not decide" {
    // The gate is fused from pattern TEXT, so `-w` does not survive into it: its
    // `cat` branch matches "concatenate", which the word query does not. That is
    // fine for rejection and wrong for a verdict, so `anyMatch` must confirm
    // behind an inexact gate rather than return it. Found by the fuzz above.
    const specs = [_]Spec{
        .{ .pattern = "cat", .fixed = true, .word = true },
        .{ .pattern = "unrelated", .fixed = true },
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    try std.testing.expect(set.gate != null); // still built — it still rejects
    try std.testing.expect(!set.gate_exact);

    // Strip the muster so the gate is the only accelerator under test.
    if (set.muster) |*m| {
        m.deinit(gpa);
        set.muster = null;
    }
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    try std.testing.expect(!set.anyMatch("concatenate", &sc));
    try std.testing.expect(set.anyMatch("a cat sat", &sc));
    try std.testing.expect(!set.anyMatch("nothing here", &sc));
}

test "prefilter delegates per pattern" {
    const specs = [_]Spec{
        .{ .pattern = "SessionStore", .fixed = true },
        .{ .pattern = "ab", .fixed = true }, // too short for a trigram
    };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var one: [1][]const u8 = undefined;
    const lits = set.prefilter(0, &one);
    try std.testing.expectEqual(@as(usize, 1), lits.len);
    try std.testing.expectEqualStrings("SessionStore", lits[0]);
    var one2: [1][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), set.prefilter(1, &one2).len);
}

// ── the buffer face ────────────────────────────────────────────────────────
//
// Same contract as everything above, against a different oracle. `docMask` is
// held to N single-pattern `docMatches` runs; `bufMask` is held to N
// single-pattern `glean.Pattern.isMatch` runs — the library verb the C ABI
// publishes, and the one a host also holding a slate would compare against.
//
// The oracle is deliberately the OTHER type. `holds` is what the buffer confirm
// calls, so oracling against `holds` would only prove the loop indexes its own
// array correctly. `glean.Pattern` compiles the pattern independently and
// answers through its own guarded boolean/walk seam, so agreement is a real
// claim: the two faces of this library cannot tell a host different things about
// whether a pattern matches a string.

const rx = @import("../regex/regex.zig");

/// Does `spec` alone match `text` as ONE unit? The library oracle.
fn oracleHolds(spec: Spec, text: []const u8) !bool {
    var one = try rx.Pattern.compileOpts(gpa, spec.pattern, .{
        .caseless = spec.ignore_case,
        .unicode = spec.unicode,
        .word = spec.word,
        .pcre = spec.pcre,
    });
    defer one.deinit();
    return one.isMatch(text);
}

fn expectBufParity(specs: []const Spec, text: []const u8) !void {
    for ([_]bool{ true, false }) |armed| {
        var set = try PatternSet.compile(gpa, specs);
        defer set.deinit(gpa);
        if (!armed) if (set.muster) |*m| {
            m.deinit(gpa);
            set.muster = null;
        };
        var sc = try set.scratch(gpa);
        defer sc.deinit(gpa);
        const mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
        defer gpa.free(mask);
        const any = try set.bufMask(text, &sc, gpa, mask);

        var oracle_any = false;
        for (specs, 0..) |spec, i| {
            const want = try oracleHolds(spec, text);
            oracle_any = oracle_any or want;
            std.testing.expectEqual(want, patterns.maskHas(mask, i)) catch |e| {
                std.debug.print("armed={} pattern={s} text={s}\n", .{ armed, spec.pattern, text });
                return e;
            };
        }
        try std.testing.expectEqual(oracle_any, any);
        try std.testing.expectEqual(oracle_any, try set.bufAnyMatch(text, &sc, gpa));
    }
}

/// The texts every buffer-face case runs against — each one a place the line
/// model and the buffer model are known to part ways, plus plain content.
const buffer_texts = [_][]const u8{
    "",        "\n",       "abc",       "abc\n",
    "a\nb",    "ab\ncd",   "a\nbc\nd",  "\n\n",
    "cat dog", "cat\ndog", "  spaced ", "x",
};

test "the buffer face answers the library question, not the line question" {
    // The four shapes that separate the models, in one slate: a class that can
    // consume the terminator, both line anchors, and a nullable pattern (whose
    // only match in an empty text is zero-width at 0).
    const specs = [_]Spec{
        .{ .pattern = "a\\sb" },
        .{ .pattern = "^b" },
        .{ .pattern = "c$" },
        .{ .pattern = "x*" },
    };
    for (buffer_texts) |text| try expectBufParity(&specs, text);
}

test "a buffer-face slate is exact across body kinds, flags and engines" {
    // Every compile route the set can take, mixed so no gate is built and the
    // muster has to carry heterogeneous covers: literal, caseless literal,
    // word, regex, alternation (an `equivalence` — settled by the roll), a
    // pattern with no derivable literal (permanently in play), and PCRE.
    const specs = [_]Spec{
        .{ .pattern = "cat", .fixed = true },
        .{ .pattern = "DOG", .fixed = true, .ignore_case = true },
        .{ .pattern = "cat", .word = true },
        .{ .pattern = "c.t" },
        .{ .pattern = "cat|dog" },
        .{ .pattern = ".*" },
        .{ .pattern = "c(?=at)", .pcre = true },
    };
    for (buffer_texts) |text| try expectBufParity(&specs, text);
}

test "the line face and the buffer face disagree, on purpose" {
    // The reason this face exists, pinned as a fact rather than left implied: a
    // set built on `docMask` would answer a library host's question wrongly in
    // both directions — no for a match that crosses a terminator, yes for a
    // line anchor that is not the buffer's edge.
    const specs = [_]Spec{ .{ .pattern = "a\\sb" }, .{ .pattern = "^b" } };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(mask);

    // "a\nb": `a\sb` spans the terminator (buffer yes, line no); `^b` is at a
    // line head but not at the buffer's start (line yes, buffer no).
    try std.testing.expect(set.docMask("a\nb", &sc, mask));
    try std.testing.expect(!patterns.maskHas(mask, 0));
    try std.testing.expect(patterns.maskHas(mask, 1));

    try std.testing.expect(try set.bufMask("a\nb", &sc, gpa, mask));
    try std.testing.expect(patterns.maskHas(mask, 0));
    try std.testing.expect(!patterns.maskHas(mask, 1));
}

test "a buffer-face differential over random haystacks" {
    // The fuzz that found the line/buffer split in the first place. Random
    // bytes over an alphabet dense in terminators and in the letters the
    // patterns use, so anchors and terminator-crossing matches both come up
    // often rather than by luck.
    const specs = [_]Spec{
        .{ .pattern = "ab" },
        .{ .pattern = "a\\sb" },
        .{ .pattern = "^ab" },
        .{ .pattern = "ab$" },
        .{ .pattern = "a.b" },
        .{ .pattern = "b*" },
        .{ .pattern = "ab|ba", .fixed = false },
        .{ .pattern = "A", .fixed = true, .ignore_case = true },
    };
    var prng = std.Random.DefaultPrng.init(0x5c1a7e);
    const rand = prng.random();
    const alphabet = "ab\n c";
    var buf: [48]u8 = undefined;
    for (0..300) |_| {
        const n = rand.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        try expectBufParity(&specs, buf[0..n]);
    }
}

test "the buffer face allocates its span scratch once, and only when asked" {
    const specs = [_]Spec{ .{ .pattern = "a" }, .{ .pattern = "b*" } };
    var set = try PatternSet.compile(gpa, &specs);
    defer set.deinit(gpa);
    var sc = try set.scratch(gpa);
    defer sc.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(specs.len));
    defer gpa.free(mask);

    // The line face never pays for it — the whole reason it is lazy.
    _ = set.docMask("abc", &sc, mask);
    try std.testing.expectEqual(@as(usize, 0), sc.spans.len);

    _ = try set.bufMask("abc", &sc, gpa, mask);
    try std.testing.expectEqual(specs.len, sc.spans.len);
    const first = sc.spans.ptr;
    _ = try set.bufMask("abc", &sc, gpa, mask);
    _ = try set.bufAnyMatch("abc", &sc, gpa);
    try std.testing.expectEqual(first, sc.spans.ptr); // reused, not rebuilt
}

test "a slate compiled for the buffer does not build the line's gate" {
    // The gate is an alternation over every pattern, so a slate pays for it once
    // at compile time in proportion to the WHOLE slate. The buffer face cannot
    // use it at any price (it over-approximates per line and is unsound per
    // buffer), so a buffer caller must not be charged for one — and the answers
    // have to come out the same either way, since a gate can only skip work.
    const specs = [_]Spec{ .{ .pattern = "a\\sb" }, .{ .pattern = "^b" }, .{ .pattern = "x*" } };

    var lined = try PatternSet.compileFor(gpa, &specs, .line);
    defer lined.deinit(gpa);
    try std.testing.expect(lined.gate != null);

    var buffered = try PatternSet.compileFor(gpa, &specs, .buffer);
    defer buffered.deinit(gpa);
    try std.testing.expect(buffered.gate == null);
    try std.testing.expect(buffered.muster != null); // this one it DOES use

    // `compile` is the line face's constructor, unchanged for every caller that
    // walks a corpus.
    var plain = try PatternSet.compile(gpa, &specs);
    defer plain.deinit(gpa);
    try std.testing.expect(plain.gate != null);

    for (buffer_texts) |body| {
        var want: [1]u64 = .{0};
        var got: [1]u64 = .{0};
        var sc_a = try lined.scratch(gpa);
        defer sc_a.deinit(gpa);
        var sc_b = try buffered.scratch(gpa);
        defer sc_b.deinit(gpa);
        _ = try lined.bufMask(body, &sc_a, gpa, &want);
        _ = try buffered.bufMask(body, &sc_b, gpa, &got);
        try std.testing.expectEqual(want[0], got[0]);
        try expectBufParity(&specs, body);
    }
}
