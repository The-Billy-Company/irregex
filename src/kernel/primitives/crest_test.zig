//! Crest kernel unit tests — deterministic calculus checks with hand-computed
//! expected ĝ, plus the sieve decision and the soundness-by-degradation edges.
//! The randomized corpus-scale soundness proof against the REAL matcher lives
//! in `bench/crest/bench.zig` (fail-closed, `zig build crest`).

const std = @import("std");
const testing = std.testing;
const crest = @import("crest.zig");

const ascii: crest.Opts = .{ .unicode = false };
const uni: crest.Opts = .{ .unicode = true };

fn g(pattern: []const u8, opts: crest.Opts, c: crest.Class) u16 {
    return crest.ghat(pattern, opts)[@intFromEnum(c)];
}

fn sha256(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
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

    const original = crest.SidecarSchema.hash();
    const pinned = [_]u8{
        0x8a, 0x37, 0xaa, 0xc5, 0xf8, 0xcc, 0x50, 0x11,
        0x8b, 0xd3, 0xd9, 0x29, 0x53, 0xfb, 0x0a, 0x52,
        0xad, 0xb7, 0xa0, 0x4c, 0x8f, 0x9c, 0xf3, 0xad,
        0x42, 0x8d, 0xf9, 0x5b, 0x34, 0x52, 0xe4, 0xbe,
    };
    try testing.expectEqualSlices(u8, &pinned, &original);

    var altered = crest.SidecarSchema.canonical_bytes;
    const version_marker = "format-version/u16le\x00";
    const version_at = (std.mem.indexOf(u8, &altered, version_marker) orelse return error.TestUnexpectedResult) + version_marker.len;
    altered[version_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const order_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.class_order) orelse return error.TestUnexpectedResult;
    altered[order_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const cap_marker = "saturation-cap/u16le\x00";
    const cap_at = (std.mem.indexOf(u8, &altered, cap_marker) orelse return error.TestUnexpectedResult) + cap_marker.len;
    altered[cap_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    const interpretation_at = std.mem.indexOf(u8, &altered, crest.SidecarSchema.element_interpretation) orelse return error.TestUnexpectedResult;
    altered[interpretation_at] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));

    altered = crest.SidecarSchema.canonical_bytes;
    altered[altered.len - 1] ^= 1;
    try testing.expect(!std.mem.eql(u8, &original, &sha256(&altered)));
}

test "forced-crest: class repetition is the whole point" {
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .hex));
    try testing.expectEqual(@as(u16, 8), g("[0-9a-f]{8}", uni, .word)); // hex ⊂ word
    try testing.expectEqual(@as(u16, 6), g("[0-9]{6}", uni, .digit));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", uni, .upper));
    // \d certifies in ASCII mode only (Alphabet Contract).
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

test "optional profiles preserve only-class certificates without joining separators" {
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]?[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][0-9]?[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]*[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][0-9]*[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 2), g("[0-9][a-z]{0,0}[0-9]", uni, .digit));
    try testing.expectEqual(@as(u16, 1), g("[0-9][a-z]{0,1}[0-9]", uni, .digit));
    try testing.expect(!crest.pruned(crest.crest("1a2"), crest.ghat("[0-9][a-z]?[0-9]", uni)));
    try testing.expect(crest.pruned(crest.crest("1a2"), crest.ghat("[0-9][0-9]?[0-9]", uni)));
}

test "epsilon and unknown profiles cannot be confused" {
    const epsilon = crest.Profile.epsilon();
    const unknown = crest.Profile.unknown();
    inline for (0..crest.K) |i| {
        try testing.expect(epsilon.only_c_cert[i]);
        try testing.expect(!unknown.only_c_cert[i]);
    }
}

test "forced-crest: alternation takes the adversary's cheaper branch" {
    try testing.expectEqual(@as(u16, 2), g("[0-9]{4}|[0-9]{2}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{4}|abcd", uni, .digit));
    // ghatMany ≡ multi -e alternation semantics.
    const many = crest.ghatMany(&.{ "[0-9]{4}", "[0-9]{2}" }, uni);
    try testing.expectEqual(@as(u16, 2), many[@intFromEnum(crest.Class.digit)]);
}

test "soundness by degradation: unsupported or caseless ⇒ zero ⇒ no prune" {
    try testing.expectEqual(@as(u16, 0), g("(?=foo)[0-9]{8}", uni, .digit)); // lookahead
    try testing.expectEqual(@as(u16, 0), g("(\\d)\\1{7}", ascii, .digit)); // backreference
    try testing.expectEqual(@as(u16, 0), g("[0-9]*", uni, .digit)); // star forces nothing
    try testing.expectEqual(@as(u16, 0), g("[0-9]{0,8}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("\\p{L}{4}", uni, .alpha)); // \p unsupported
    try testing.expectEqual(@as(u16, 0), g("\\x41{4}", uni, .upper)); // \x unsupported
    try testing.expectEqual(@as(u16, 0), g("[0-9]{3,x}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{3,2}", uni, .digit));
    try testing.expectEqual(@as(u16, 0), g("[0-9]{,3}", uni, .digit));
}

test "caseless: case-closed classes still sieve; upper/lower self-decline" {
    const ci: crest.Opts = .{ .unicode = true, .caseless = true };
    const ci_ascii: crest.Opts = .{ .unicode = false, .caseless = true };
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
    // Unicode escape guard: k/K→KELVIN, s/S→LONG S leave ASCII, so an atom that
    // can match them certifies nothing under Unicode `-i` — but is sound in the
    // pure-byte ASCII mode where the fold stays within ASCII. `[A-Z]` contains
    // S and K, so it declines under Unicode yet forces alpha/word in ASCII mode.
    try testing.expectEqual(@as(u16, 0), g("[A-Z]{4}", ci, .alpha));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", ci_ascii, .alpha));
    try testing.expectEqual(@as(u16, 4), g("[A-Z]{4}", ci_ascii, .word));
    try testing.expectEqual(@as(u16, 0), g("[A-Z]{4}", ci_ascii, .upper)); // fold ⊄ upper
    try testing.expectEqual(@as(u16, 0), g("[a-z]{5}", ci, .word)); // contains k,s
    try testing.expectEqual(@as(u16, 5), g("[a-z]{5}", ci_ascii, .word));
    try testing.expectEqual(@as(u16, 0), g("[s-z]{5}", ci, .word)); // contains s
    try testing.expectEqual(@as(u16, 4), g("[g-j]{4}", ci, .word)); // no k/s: safe
    // The sieve engages and prunes a doc lacking the run — proven not to drop a
    // real caseless hit (the fail-closed corpus sweep is `zig build crest`).
    try testing.expect(crest.pruned(crest.crest("no hex zz"), crest.ghat("[0-9a-f]{8}", ci)));
    try testing.expect(!crest.pruned(crest.crest("v=DEADBEEF n"), crest.ghat("[0-9a-f]{8}", ci)));
}

test "escapes carry their real bytes (\\n is newline, not 'n')" {
    // \n{5}: five newlines — a SPACE run of 5, and no word run at all. Getting
    // this wrong (treating \n as the byte 'n') would manufacture false negatives.
    try testing.expectEqual(@as(u16, 5), g("\\n{5}", uni, .space));
    try testing.expectEqual(@as(u16, 0), g("\\n{5}", uni, .word));
    try testing.expectEqual(@as(u16, 2), g("\\t\\t", uni, .space));
    // escaped metachar is itself: \. is the punct byte '.'.
    try testing.expectEqual(@as(u16, 3), g("\\.{3}", uni, .punct));
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
    const gv = crest.ghat("[0-9a-f]{8}", uni);
    try testing.expect(crest.active(gv));
    try testing.expect(crest.pruned(crest.crest("no hex run here: zz zz"), gv));
    try testing.expect(!crest.pruned(crest.crest("id=0123abcdef more"), gv));
    try testing.expect(!crest.active(crest.ghat("\\w+", uni)));
    // Both query and document values share the saturated u16 domain.
    const big = crest.ghat("[0-9]{70000}", uni);
    try testing.expectEqual(std.math.maxInt(u16), big[@intFromEnum(crest.Class.digit)]);
    var long_doc: [70_000]u8 = @splat('0');
    const long_crest = crest.crest(&long_doc);
    try testing.expectEqual(std.math.maxInt(u16), long_crest[@intFromEnum(crest.Class.digit)]);
    try testing.expect(!crest.pruned(long_crest, big));
}
