//! gist T2 bit-parallel engine tests — split from `regex_bitparallel.zig` to keep
//! the engine under the shape cap. Two layers:
//!   1. targeted unit cases (the dense floor patterns + the Glushkov edge shapes:
//!      nullable roots, alternation, repeats, optional tails);
//!   2. a **differential fuzz** that compiles thousands of random anchor-free
//!      patterns and asserts the bit engine agrees with the proven Pike VM on
//!      every random input — the divergence-free oracle that makes a half-correct
//!      engine impossible to ship (any disagreement is a real bug, no rg needed).

const std = @import("std");
const regex = @import("regex.zig");
const bitp = @import("regex_bitparallel.zig");
const syn = @import("regex_syntax.zig");
const Regex = regex.Regex;

/// Compile, assert a bit engine was actually built, and return its verdict for
/// `line`. Fails the test if the pattern fell back to Pike (so the unit cases
/// below genuinely exercise the bit path, not the fallback).
fn bitMatch(pattern: []const u8, line: []const u8) !bool {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    try std.testing.expect(re.bit != null); // must take the bit-parallel path
    return re.bit.?.match(line);
}

test "bitparallel: dense floor patterns match the spec" {
    // \w{3,8}: 3–8 word chars. The headline floor the engine exists to close.
    try std.testing.expect(try bitMatch("\\w{3,8}", "abc"));
    try std.testing.expect(try bitMatch("\\w{3,8}", "a_b9XY"));
    try std.testing.expect(!try bitMatch("\\w{3,8}", "ab")); // only 2 word chars
    try std.testing.expect(!try bitMatch("\\w{3,8}", "!! ?")); // none are \w
    try std.testing.expect(try bitMatch("\\w{3,8}", "  hello  ")); // unanchored run
    // [0-9]{4} and [a-f0-9]{2,}: the other no-prefilter scan-tail shapes.
    try std.testing.expect(try bitMatch("[0-9]{4}", "year 2026 ok"));
    try std.testing.expect(!try bitMatch("[0-9]{4}", "12 34 5"));
    try std.testing.expect(try bitMatch("[a-f0-9]{2,}", "v := 0xdead")); // lowercase hex run
    try std.testing.expect(!try bitMatch("[a-f0-9]{2,}", "0xFF")); // uppercase ∉ [a-f], no run
    try std.testing.expect(!try bitMatch("[a-f0-9]{2,}", "z g h")); // single hexits, gapped
}

test "bitparallel: Glushkov edge shapes (nullable, alt, repeats, optional tail)" {
    try std.testing.expect(try bitMatch("a*", "")); // nullable root ⇒ matches empty line
    try std.testing.expect(try bitMatch("a*", "zzz")); // …and any line (empty substring)
    try std.testing.expect(try bitMatch("ab*c", "ac"));
    try std.testing.expect(try bitMatch("ab*c", "abbbc"));
    try std.testing.expect(try bitMatch("ab+c", "abc"));
    try std.testing.expect(!try bitMatch("ab+c", "ac"));
    try std.testing.expect(try bitMatch("colou?r", "color"));
    try std.testing.expect(try bitMatch("colou?r", "colour")); // spellchecker:disable-line
    try std.testing.expect(try bitMatch("cat|dog", "the dog ran"));
    try std.testing.expect(try bitMatch("(foo|bar)baz", "xxbarbazyy"));
    try std.testing.expect(!try bitMatch("(foo|bar)baz", "bazonly"));
    try std.testing.expect(try bitMatch("a.c", "xxabcyy"));
    try std.testing.expect(!try bitMatch("a.c", "a\nb")); // '.' never crosses newline
    // Overlapping-start hazard: the real match begins where an earlier thread died.
    try std.testing.expect(try bitMatch("ab", "aab"));
    try std.testing.expect(try bitMatch("abc", "ababc"));
    try std.testing.expect(!try bitMatch("xyz", "xyxy"));
}

test "bitparallel: anchored / oversized programs fall back to Pike (no engine)" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "^func", "nil$", "^$", "^a|b", "a{40}b{40}" }) |p| {
        var re = try Regex.compile(a, p);
        defer re.deinit();
        try std.testing.expect(re.bit == null); // anchored or > word-sized ⇒ Pike
    }
}

// ─────────────────────────── differential fuzz ───────────────────────────

/// A random anchor-free pattern generator over the supported subset, emitting
/// always-valid syntax (atoms then quantifiers, valid `{n,m}` only) into `buf`.
/// Anchor-free by construction so the bit engine is the thing under test; a small
/// alphabet keeps position counts modest and match rates high.
const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,

    const E = std.mem.Allocator.Error;

    fn lit(g: *Gen) E!void {
        try g.buf.append(g.a, "abc"[g.r.uintLessThan(usize, 3)]);
    }
    fn atom(g: *Gen, depth: u8) E!void {
        switch (g.r.uintLessThan(u8, if (depth > 0) 7 else 6)) {
            0 => try g.lit(),
            1 => try g.buf.append(g.a, '.'),
            2 => try g.buf.appendSlice(g.a, "[a-c]"),
            3 => try g.buf.appendSlice(g.a, "[^a-c]"),
            4 => try g.buf.appendSlice(g.a, "\\d"),
            5 => try g.buf.appendSlice(g.a, "\\w"),
            else => { // group
                try g.buf.append(g.a, '(');
                try g.alt(depth - 1);
                try g.buf.append(g.a, ')');
            },
        }
    }
    fn quant(g: *Gen, depth: u8) E!void {
        try g.atom(depth);
        switch (g.r.uintLessThan(u8, 7)) {
            0 => try g.buf.append(g.a, '*'),
            1 => try g.buf.append(g.a, '+'),
            2 => try g.buf.append(g.a, '?'),
            3 => try g.buf.appendSlice(g.a, "{2}"),
            4 => try g.buf.appendSlice(g.a, "{1,3}"),
            5 => try g.buf.appendSlice(g.a, "{0,2}"),
            else => {}, // bare atom
        }
    }
    fn concat(g: *Gen, depth: u8) E!void {
        const n = 1 + g.r.uintLessThan(usize, 3);
        for (0..n) |_| try g.quant(depth);
    }
    fn alt(g: *Gen, depth: u8) E!void {
        try g.concat(depth);
        const n = g.r.uintLessThan(usize, 3);
        for (0..n) |_| {
            try g.buf.append(g.a, '|');
            try g.concat(depth);
        }
    }
};

test "bitparallel: differential fuzz vs the Pike VM (0 divergences)" {
    const a = std.testing.allocator;
    const alphabet = "abcd01_ xy"; // mix of \w, digits, separators, '.'-fodder
    var line_buf: [24]u8 = undefined;

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 4000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.alt(2);

        var re = Regex.compile(a, pat.items) catch continue; // skip rare BadPattern
        defer re.deinit();
        if (re.bit == null) continue; // anchored / oversized ⇒ not under test here
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..10) |_| {
            const len = r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const line = line_buf[0..len];
            const got = re.bit.?.match(line);
            const want = re.lineMatchPike(&sim, line); // proven reference
            if (got != want) {
                std.debug.print("DIVERGENCE pat=/{s}/ line=\"{s}\" bit={} pike={}\n", .{ pat.items, line, got, want });
                return error.BitPikeDivergence;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 10_000); // the fuzz actually ran
}
