//! Crest kernel unit tests — the DOCUMENT half: the ρ(d) scan, the sieve
//! decision, and the persisted sidecar's semantic schema. The query half (ĝ)
//! is tested against the engine's own AST in
//! `../match/regex/analysis/swell_test.zig`, which also carries the Sieve
//! Theorem differential; the corpus-scale version is `zig build crest`.

const std = @import("std");
const testing = std.testing;
const crest = @import("crest.zig");
const signet = @import("signet.zig");

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

test "semantic schema pins class order and byte-boundary memberships" {
    const order = [_]crest.Class{ .digit, .hex, .upper, .lower, .alpha, .word, .space, .punct };
    try testing.expectEqual(crest.K, order.len);
    for (order, 0..) |class, i| try testing.expectEqual(i, @intFromEnum(class));
    try testing.expectEqualStrings("digit\x00hex\x00upper\x00lower\x00alpha\x00word\x00space\x00punct", crest.SidecarSchema.class_order);

    const cases = [_]struct { byte: u8, bits: u8 }{
        .{ .byte = '/', .bits = 0x80 },
        .{ .byte = '0', .bits = 0x23 },
        .{ .byte = '9', .bits = 0x23 },
        .{ .byte = ':', .bits = 0x80 },
        .{ .byte = 'A', .bits = 0x36 },
        .{ .byte = 'F', .bits = 0x36 },
        .{ .byte = 'G', .bits = 0x34 },
        .{ .byte = '_', .bits = 0x20 },
        .{ .byte = '`', .bits = 0x80 },
        .{ .byte = 'a', .bits = 0x3a },
        .{ .byte = 'f', .bits = 0x3a },
        .{ .byte = 'g', .bits = 0x38 },
        .{ .byte = '\t', .bits = 0x40 },
        .{ .byte = '\n', .bits = 0x40 },
        .{ .byte = 0x0B, .bits = 0x40 },
        .{ .byte = 0x0C, .bits = 0x40 },
        .{ .byte = '\r', .bits = 0x40 },
        .{ .byte = ' ', .bits = 0x40 },
        .{ .byte = 0x7F, .bits = 0 },
        .{ .byte = 0x80, .bits = 0 },
    };
    for (cases) |case| try testing.expectEqual(case.bits, crest.membership[case.byte]);
}

test "semantic hash binds cap, interpretation, and full membership table" {
    const canonical = &crest.SidecarSchema.canonical_bytes;
    try testing.expect(std.mem.endsWith(u8, canonical, &crest.membership));
    try testing.expectEqual(std.math.maxInt(u16), crest.SidecarSchema.saturation_cap);
    try testing.expectEqual(@as(u16, 2), crest.SidecarSchema.format_version);

    // A captured golden, and only that: it trips the moment this schema's
    // identity moves, which is exactly when every persisted sidecar must be
    // regenerated. That the primitive underneath really is BLAKE3 is proven
    // independently in `signet_test.zig` against the published empty-input
    // vector — this pin is not the place to relitigate the hash function.
    const original = crest.SidecarSchema.hash();
    try testing.expectEqualStrings(
        "4d292c119108c904f65e5f47827e9366a321605a7ab2cfcd496e7d5fe7f2bd36",
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
    var prng = std.Random.DefaultPrng.init(0xC4E5_0F0D);
    const rng = prng.random();
    var strictly_better: usize = 0;
    var fold_pruned: usize = 0;
    for (0..8192) |_| {
        var pair: crest.Swell = .{ .len = 2 };
        var min_of_pair = crest.zero_vector;
        for (&pair.crests[0], &pair.crests[1], &min_of_pair) |*a, *b, *m| {
            a.* = rng.uintLessThan(u16, 6);
            b.* = rng.uintLessThan(u16, 6);
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
