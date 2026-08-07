//! Crest kernel unit tests — the DOCUMENT half: the ρ(d) scan, the sieve
//! decision, and the persisted sidecar's semantic schema. The query half (ĝ)
//! is tested against the engine's own AST in
//! `../regex/analysis/swell_test.zig`, which also carries the Sieve
//! Theorem differential; the corpus-scale version is `zig build crest`.

const std = @import("std");
const testing = std.testing;
const crest = @import("crest.zig");
const signet = @import("../../corpus/index/frame/signet.zig");

/// The same statement the sidecar makes about itself, recomputed here over an
/// ALTERED preimage: each case below proves the field it edits is inside the
/// digest, so `SidecarSchema.hash` cannot lose one and stay equal.
fn schemaMark(bytes: []const u8) signet.Signet {
    return signet.of(.schema, bytes);
}

test "crest vector: longest per-class run" {
    const v = crest.crest("ab  12ff  ABCD_ef00");
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.digit)]); // "12"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.hex)]); // "ef00"
    try testing.expectEqual(@as(u16, 4), v[@intFromEnum(crest.Class.upper)]); // "ABCD"
    try testing.expectEqual(@as(u16, 9), v[@intFromEnum(crest.Class.word)]); // "ABCD_ef00"
    try testing.expectEqual(@as(u16, 2), v[@intFromEnum(crest.Class.space)]); // "  "
}

/// ρ(d) straight from the definition: walk the document one byte at a time,
/// extend, HOLD, or reset each member's run. Derived from `crest.membership`
/// plus one further fact (`crest.isContinuation`) — the contract — and from
/// what "longest run" MEANS, so it is an oracle for the vectorized pass rather
/// than a second copy of it.
///
/// Every lane is "extend if membership says so, else reset" EXCEPT a
/// codepoint-run lane meeting a UTF-8 continuation byte, which instead HOLDS
/// — neither extends nor resets (§3.7c, Lemma 2c): the byte is invisible to a
/// codepoint count, not merely non-matching. `membership` alone cannot express
/// a three-way rule, so this is the one place the oracle reads a second fact
/// rather than the bitset alone — everything else about ρ(d) still reduces to it.
fn referenceCrest(doc: []const u8) crest.Vector {
    var best: crest.Vector = @splat(0);
    var cur: [crest.K]u32 = @splat(0);
    for (doc) |b| {
        const m = crest.membership[b];
        const hold = crest.isContinuation(b);
        for (0..crest.K) |i| {
            const is_cp = i >= 2 * crest.base_k;
            if (m & (@as(crest.Mask, 1) << @intCast(i)) != 0) {
                cur[i] += 1;
                best[i] = @intCast(@min(@max(cur[i], best[i]), std.math.maxInt(u16)));
            } else if (!(is_cp and hold)) cur[i] = 0;
        }
    }
    return best;
}

test "the scan is the byte-at-a-time definition, exactly" {
    // Every length from empty upward, so the lead scan's 64-byte stride, the
    // tail, and runs that end flush against either are all crossed many times
    // over. These lengths stay under `interleave_floor`, which makes this the
    // single-piece path; the interleaved one is pinned by the test below.
    var prng = std.Random.DefaultPrng.init(0x0C_2E_57_00);
    const rng = prng.random();
    var doc: [200]u8 = undefined;

    // Alphabets chosen to make runs long and boundaries frequent: pure ASCII
    // (the twins must silently track their base classes), pure non-ASCII (the
    // base classes must all stay 0 while every twin runs), and mixtures that
    // force the twin-adoption seam at every offset.
    const pools = [_][]const u8{
        "0123456789abcdefABCDEF_ ",
        "\xc3\xa9\xd8\xa0\xe2\x82\xac\xf0\x9f\x98\x80",
        "a0\xc3\xa9 \t~_Z\xff\x80",
        "\x00\x7f\x80\xff",
    };
    for (pools) |pool| {
        for (0..doc.len) |len| {
            for (doc[0..len]) |*b| b.* = pool[rng.uintLessThan(usize, pool.len)];
            try testing.expectEqual(referenceCrest(doc[0..len]), crest.crest(doc[0..len]));
        }
    }

    // Uniform random bytes too — no pool can be accused of dodging a case.
    for (0..2000) |_| {
        const len = rng.uintLessThan(usize, doc.len + 1);
        rng.bytes(doc[0..len]);
        try testing.expectEqual(referenceCrest(doc[0..len]), crest.crest(doc[0..len]));
    }
}

test "cutting the document into pieces rejoins to the same answer" {
    // Past `interleave_floor` the scan splits the document, measures the
    // pieces independently, and rejoins them by the run algebra — so a run
    // crossing a cut is the one thing that can be dropped or double-counted,
    // and a piece that never breaks is the one that must carry its neighbor's
    // run through. Both are aimed at directly, against the same oracle.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1E_7E_A7_ED);
    const rng = prng.random();

    const doc = try gpa.alloc(u8, 70_000);
    defer gpa.free(doc);

    // Straddling the floor, then lengths whose remainder past a piece boundary
    // is 0, 1, and large in turn. 70_000 also drives a run past the u16 cap,
    // so saturation is exercised through the joins and not only inside a piece.
    for ([_]usize{ 4095, 4096, 4097, 4099, 8192, 8193, 12_345, 70_000 }) |len| {
        const d = doc[0..len];

        // Every piece unbroken: `whole` propagates end to end, and the answer
        // is the whole document rather than any one piece.
        @memset(d, 'a');
        try testing.expectEqual(referenceCrest(d), crest.crest(d));

        // One break, walked onto and around each cut — the joins' seam.
        for ([_]usize{ 0, 1, len / 4 - 1, len / 4, len / 4 + 1, len / 2, 3 * len / 4, len - 1 }) |cut| {
            @memset(d, 'a');
            d[cut] = ' ';
            try testing.expectEqual(referenceCrest(d), crest.crest(d));
        }

        for ([_][]const u8{
            "0123456789abcdefABCDEF_ ",
            "\xc3\xa9\xd8\xa0\xe2\x82\xac",
            "a0\xc3\xa9 \t~_Z\xff\x80",
            "aaaaaaaaaaaaaaaa ", // long runs, rare breaks: `whole` pieces appear
        }) |pool| {
            for (d) |*b| b.* = pool[rng.uintLessThan(usize, pool.len)];
            try testing.expectEqual(referenceCrest(d), crest.crest(d));
        }

        rng.bytes(d);
        try testing.expectEqual(referenceCrest(d), crest.crest(d));
    }
}

test "scalar-closed members measure runs the ASCII half cannot see" {
    // Six ARABIC-INDIC DIGITs (U+0660…) are twelve bytes, every one ≥ 0x80.
    // No ASCII class may claim them; every twin must.
    const arabic = "\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}";
    const v = crest.crest(arabic);
    try testing.expectEqual(@as(u16, 0), v[crest.lane(.digit, .ascii)]);
    try testing.expectEqual(@as(u16, 12), v[crest.lane(.digit, .scalar)]);
    try testing.expectEqual(@as(u16, 12), v[crest.lane(.punct, .scalar)]);

    // A twin is the UNION, so an ASCII digit continues an Arabic-Indic run
    // while breaking, say, the space twin.
    const mixed = crest.crest("7\u{0660}7");
    try testing.expectEqual(@as(u16, 1), mixed[crest.lane(.digit, .ascii)]);
    try testing.expectEqual(@as(u16, 4), mixed[crest.lane(.digit, .scalar)]);
    try testing.expectEqual(@as(u16, 2), mixed[crest.lane(.space, .scalar)]);

    // Over pure ASCII the two halves are the same set, so every twin must
    // report its base class's answer — including across the block stride,
    // where the twins are not tracked at all until a high byte appears.
    const ascii_only = ("abc123 " ** 40) ++ "ZZZZ";
    const a = crest.crest(ascii_only);
    inline for (std.enums.values(crest.Class)) |c| {
        try testing.expectEqual(a[crest.lane(c, .ascii)], a[crest.lane(c, .scalar)]);
    }
    // …and the moment one appears mid-document, the twins must already carry
    // the run they had been shadowing rather than restarting from zero.
    const late = crest.crest(("0" ** 100) ++ "\u{00e9}");
    try testing.expectEqual(@as(u16, 100), late[crest.lane(.digit, .ascii)]);
    try testing.expectEqual(@as(u16, 102), late[crest.lane(.digit, .scalar)]);
}

test "semantic schema pins class order and byte-boundary memberships" {
    const order = [_]crest.Class{ .digit, .hex, .upper, .lower, .alpha, .word, .space, .punct };
    try testing.expectEqual(crest.base_k, order.len);
    try testing.expectEqual(crest.K, 3 * order.len);
    for (order, 0..) |class, i| try testing.expectEqual(i, @intFromEnum(class));
    // The ASCII half keeps its historical lane indices; scalar and codepoint follow.
    for (order) |class| {
        try testing.expectEqual(@intFromEnum(class), crest.lane(class, .ascii));
        try testing.expectEqual(@intFromEnum(class) + crest.base_k, crest.lane(class, .scalar));
        try testing.expectEqual(@intFromEnum(class) + 2 * crest.base_k, crest.lane(class, .codepoint));
    }
    try testing.expectEqualStrings(
        "digit\x00hex\x00upper\x00lower\x00alpha\x00word\x00space\x00punct" ++
            "\x00digit+u\x00hex+u\x00upper+u\x00lower+u\x00alpha+u\x00word+u\x00space+u\x00punct+u" ++
            "\x00digit+cp\x00hex+cp\x00upper+cp\x00lower+cp\x00alpha+cp\x00word+cp\x00space+cp\x00punct+cp",
        crest.SidecarSchema.class_order,
    );

    // An ASCII byte is in a scalar AND a codepoint twin exactly when it is in
    // the base class, so its mask is the base byte tripled; a bare UTF-8
    // continuation byte is in NO base class, in EVERY scalar twin, and in NO
    // codepoint twin (Lemma 2c's refusal); a UTF-8 lead byte is in every twin
    // of BOTH families. Spelled out rather than derived — deriving it would
    // only restate `crest.zig`'s own closure rule back at itself. Written as
    // (codepoint << 16) | (scalar << 8) | ascii so each 8-bit group reads as
    // the same byte the pre-codepoint table already pinned.
    const cases = [_]struct { byte: u8, bits: u24 }{
        .{ .byte = '/', .bits = 0x808080 },
        .{ .byte = '0', .bits = 0x232323 },
        .{ .byte = '9', .bits = 0x232323 },
        .{ .byte = ':', .bits = 0x808080 },
        .{ .byte = 'A', .bits = 0x363636 },
        .{ .byte = 'F', .bits = 0x363636 },
        .{ .byte = 'G', .bits = 0x343434 },
        .{ .byte = '_', .bits = 0x202020 },
        .{ .byte = '`', .bits = 0x808080 },
        .{ .byte = 'a', .bits = 0x3a3a3a },
        .{ .byte = 'f', .bits = 0x3a3a3a },
        .{ .byte = 'g', .bits = 0x383838 },
        .{ .byte = '\t', .bits = 0x404040 },
        .{ .byte = '\n', .bits = 0x404040 },
        .{ .byte = 0x0B, .bits = 0x404040 },
        .{ .byte = 0x0C, .bits = 0x404040 },
        .{ .byte = '\r', .bits = 0x404040 },
        .{ .byte = ' ', .bits = 0x404040 },
        .{ .byte = 0x7F, .bits = 0 },
        // The alphabet boundary: 0x80 is the first byte no ASCII class may
        // claim, the first every scalar twin must, and — being a bare
        // continuation, not a lead — the first NO codepoint twin may.
        .{ .byte = 0x80, .bits = 0x00FF00 },
        .{ .byte = 0xC3, .bits = 0xFFFF00 }, // a 2-byte UTF-8 LEAD: codepoint twins claim it too
        .{ .byte = 0xA9, .bits = 0x00FF00 }, // …its continuation does not
        .{ .byte = 0xFF, .bits = 0xFFFF00 },
    };
    for (cases) |case| try testing.expectEqual(@as(crest.Mask, case.bits), crest.membership[case.byte]);
}

test "semantic hash binds cap, interpretation, and full membership table" {
    const canonical = &crest.SidecarSchema.canonical_bytes;
    try testing.expect(std.mem.endsWith(u8, canonical, &crest.SidecarSchema.membership_le));
    try testing.expectEqual(4 * crest.membership.len, crest.SidecarSchema.membership_le.len);
    try testing.expectEqual(std.math.maxInt(u16), crest.SidecarSchema.saturation_cap);
    try testing.expectEqual(@as(u16, 4), crest.SidecarSchema.format_version);

    // A captured golden, and only that: it trips the moment this schema's
    // identity moves, which is exactly when every persisted sidecar must be
    // regenerated. That the primitive underneath really is BLAKE3 is proven
    // independently in `signet_test.zig` against the published empty-input
    // vector — this pin is not the place to relitigate the hash function.
    const original = crest.SidecarSchema.hash();
    try testing.expectEqualStrings(
        "5ad9e75b72492c0fca6692362beeb2dcd276d44e7ee86625f7bf27d5bb397efb",
        &original.hex(),
    );

    var altered = crest.SidecarSchema.canonical_bytes;
    const version_marker = "format-version/u16le\x00";
    const version_at = (std.mem.indexOf(u8, &altered, version_marker) orelse return error.TestUnexpectedResult) + version_marker.len;
    altered[version_at] ^= 1;
    try testing.expect(!original.eql(schemaMark(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const order_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.class_order) orelse return error.TestUnexpectedResult;
    altered[order_at] ^= 1;
    try testing.expect(!original.eql(schemaMark(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const cap_marker = "saturation-cap/u16le\x00";
    const cap_at = (std.mem.indexOf(u8, &altered, cap_marker) orelse return error.TestUnexpectedResult) + cap_marker.len;
    altered[cap_at] ^= 1;
    try testing.expect(!original.eql(schemaMark(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const interpretation_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.element_interpretation) orelse return error.TestUnexpectedResult;
    altered[interpretation_at] ^= 1;
    try testing.expect(!original.eql(schemaMark(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    altered[altered.len - 1] ^= 1;
    try testing.expect(!original.eql(schemaMark(&altered)));
}

fn demand(pairs: []const struct { crest.Class, u16 }) crest.Vector {
    var v = crest.zero_vector;
    for (pairs) |p| v[@intFromEnum(p[0])] = p[1];
    return v;
}

test "sieve decision: dominance, componentwise, over the class family" {
    // An 8-byte hex run is the family's motivating query (`[0-9a-f]{8}`).
    const gv = demand(&.{ .{ .hex, 8 }, .{ .word, 8 } });
    try testing.expect(crest.pruned(crest.crest("no hex run here: zz zz"), gv));
    try testing.expect(!crest.pruned(crest.crest("id=0123abcdef more"), gv));
    // Falling short in ANY single class is enough to prune: a 9-byte word run
    // that is only 7 hex bytes long fails the hex component alone.
    try testing.expect(crest.pruned(crest.crest("id=0123abcx more"), gv));
}

test "a swell prunes only what clears none of its alternatives" {
    // `[0-9a-f]{8}|[~]{12}` — the two branches force classes with no common
    // superclass, the case the disjunction exists to survive.
    const hex8 = demand(&.{ .{ .hex, 8 }, .{ .word, 8 } });
    const tilde12 = demand(&.{.{ .punct, 12 }});
    const swell: crest.Swell = .{ .crests = .{ hex8, tilde12 } ++ @as([6]crest.Vector, @splat(crest.zero_vector)), .len = 2 };

    try testing.expect(swell.active());
    // Either alternative on its own is enough to survive…
    try testing.expect(!swell.prunes(crest.crest("id=0123abcdef more")));
    try testing.expect(!swell.prunes(crest.crest("rule: " ++ "~" ** 12)));
    // …and only a document short of BOTH is pruned.
    try testing.expect(swell.prunes(crest.crest("no run of either: zz ~~ Zz")));

    // THE REGRESSION THIS TYPE EXISTS FOR. Componentwise-min folding — what a
    // single-vector ĝ had to do — bottoms out at 0⃗ the moment two alternatives
    // force disjoint classes, and a 0⃗ sieve prunes nothing at all. Multi-`-e`
    // reaches the engine as exactly this shape.
    var folded = crest.zero_vector;
    inline for (0..crest.K) |i| folded[i] = @min(hex8[i], tilde12[i]);
    try testing.expectEqualSlices(u16, &crest.zero_vector, &folded);
    try testing.expect(!crest.pruned(crest.crest("no run of either: zz ~~ Zz"), folded));

    // Fold vs disjunction is a one-way street: min ĝᵢ ≤ ĝⱼ for every branch, so
    // a document short of the fold is short of all of them. The disjunction is
    // therefore weakly more selective on EVERY document, never less sound —
    // checked here over random crest vectors rather than argued.
    //
    // Demands are drawn shorter than documents on purpose. Both are dense over
    // all K members, which is already far harsher than a real ĝ (a pattern
    // forces one or two classes, not sixteen); drawing them from the SAME range
    // on top of that makes the fold prune ~99% of samples, and the sweep stops
    // reaching the region it exists to measure. The two counters below are the
    // guard that this re-aiming stayed honest.
    var prng = std.Random.DefaultPrng.init(0xC4E5_0F0D);
    const rng = prng.random();
    var strictly_better: usize = 0;
    var fold_pruned: usize = 0;
    for (0..8192) |_| {
        var pair: crest.Swell = .{ .len = 2 };
        var min_of_pair = crest.zero_vector;
        for (&pair.crests[0], &pair.crests[1], &min_of_pair) |*a, *b, *m| {
            a.* = rng.uintLessThan(u16, 4);
            b.* = rng.uintLessThan(u16, 4);
            m.* = @min(a.*, b.*);
        }
        var rho = crest.zero_vector;
        for (&rho) |*v| v.* = rng.uintLessThan(u16, 6);
        if (crest.pruned(rho, min_of_pair)) {
            fold_pruned += 1;
            try testing.expect(pair.prunes(rho));
        } else if (pair.prunes(rho)) strictly_better += 1;
    }
    // Both sides of the implication have to fire, or it proved nothing.
    try testing.expect(fold_pruned > 100);
    try testing.expect(strictly_better > 100);
}

test "an inert alternative disarms the whole swell" {
    // A branch forcing nothing admits every document, so its siblings' demands
    // are unreachable — the honest report is that there is nothing to sieve by.
    const hex8 = demand(&.{ .{ .hex, 8 }, .{ .word, 8 } });
    const with_free_branch: crest.Swell = .{ .crests = .{hex8} ++ @as([7]crest.Vector, @splat(crest.zero_vector)), .len = 2 };
    try testing.expect(!with_free_branch.active());
    try testing.expect(!with_free_branch.prunes(crest.crest("nothing at all")));
    // An empty swell analyzed nothing, so it proves nothing.
    try testing.expect(!crest.no_sieve.active());
    try testing.expect(!crest.no_sieve.prunes(crest.crest("")));
}

test "saturation is monotone on both sides of the compare" {
    // A document past the u16 cap saturates, and a saturated ĝ still admits it —
    // saturation may cost pruning, never a match.
    var long_doc: [70_000]u8 = @splat('0');
    const long_crest = crest.crest(&long_doc);
    try testing.expectEqual(std.math.maxInt(u16), long_crest[@intFromEnum(crest.Class.digit)]);
    const saturated = demand(&.{.{ .digit, std.math.maxInt(u16) }});
    try testing.expect(!crest.pruned(long_crest, saturated));
    // A run that merely ends the document still counts (no off-by-one at EOF).
    try testing.expectEqual(@as(u16, 3), crest.crest("xy 123")[@intFromEnum(crest.Class.digit)]);
}
