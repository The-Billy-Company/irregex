//! gist T2 byte-class DFA tests — split from `dfa.zig` to keep the engine
//! under the shape cap. Two layers:
//!   1. targeted unit cases — the no-prefilter scan-tail patterns the DFA exists
//!      to win (`;$`, `[0-9]{4}`, `panic|0x`, `\w{3,8}`), the line-anchor shapes
//!      (`^`, `$`, `^…$`, empty line), and the byte-class / overlapping-start
//!      hazards;
//!   2. two **differential fuzzes** that compile thousands of random patterns —
//!      crucially *including line anchors* — and assert the DFA agrees with the
//!      proven Pike VM: one at the line level (`match`), one over multi-line
//!      buffers (`docMatch`, the single-pass scan). Empty lines and trailing
//!      newlines included. Any divergence is a real bug (no rg needed).

const std = @import("std");
const regex = @import("core.zig");
const Regex = regex.Regex;

/// Compile, assert a DFA was actually built (not a powerset-cap fallback), and
/// return its verdict for `line`. Fails the test if the pattern fell back to
/// Pike, so the unit cases genuinely exercise the DFA. `force_dfa`: several
/// slate patterns are byte-exact class runs, whose production compile now
/// skips the (dead-weight) determinization — this harness tests the DFA itself.
fn dfaMatch(pattern: []const u8, line: []const u8) !bool {
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .force_dfa = true });
    defer re.deinit();
    try std.testing.expect(re.dfa != null);
    return re.dfa.?.match(line);
}

test "dfa: no-prefilter scan-tail patterns (the ones it exists to win)" {
    try std.testing.expect(try dfaMatch(";$", "x := 1;"));
    try std.testing.expect(!try dfaMatch(";$", "x := 1; y"));
    try std.testing.expect(try dfaMatch("[0-9]{4}", "year 2026 ok"));
    try std.testing.expect(!try dfaMatch("[0-9]{4}", "12 34 5")); // no run of 4
    try std.testing.expect(try dfaMatch("panic|0x", "v := 0xFF"));
    try std.testing.expect(try dfaMatch("panic|0x", "panic()"));
    try std.testing.expect(!try dfaMatch("panic|0x", "calm 1y")); // neither branch
    try std.testing.expect(try dfaMatch("\\w{3,8}", "a_b9XY"));
    try std.testing.expect(!try dfaMatch("\\w{3,8}", "ab")); // only 2 word chars
    try std.testing.expect(try dfaMatch("[a-f0-9]{2,}", "v := 0xdead"));
    try std.testing.expect(!try dfaMatch("[a-f0-9]{2,}", "z g h")); // single hexits
}

test "dfa: line anchors (^, $, ^…$, empty line)" {
    try std.testing.expect(try dfaMatch("^func", "func main"));
    try std.testing.expect(!try dfaMatch("^func", "  func main")); // not at start
    try std.testing.expect(try dfaMatch("nil$", "return nil"));
    try std.testing.expect(!try dfaMatch("nil$", "nil pointer")); // not at end
    try std.testing.expect(try dfaMatch("^\\}$", "}"));
    try std.testing.expect(!try dfaMatch("^\\}$", " }")); // leading byte breaks ^
    try std.testing.expect(!try dfaMatch("^\\}$", "}}")); // trailing byte breaks $
    try std.testing.expect(try dfaMatch("^$", "")); // empty line matches ^$
    try std.testing.expect(!try dfaMatch("^$", "x")); // non-empty does not
    try std.testing.expect(try dfaMatch("^abc$", "abc"));
    try std.testing.expect(!try dfaMatch("^abc$", "abcd"));
    try std.testing.expect(!try dfaMatch("^abc$", "xabc"));
    // Mixed-anchor alternation: only the `^`-branch must anchor.
    try std.testing.expect(try dfaMatch("import|^package", "package main"));
    try std.testing.expect(!try dfaMatch("import|^package", "  package main"));
    try std.testing.expect(try dfaMatch("import|^package", "  import x"));
}

test "dfa: classes, repeats, alternation, overlapping starts" {
    try std.testing.expect(try dfaMatch("a.c", "xxabcyy"));
    try std.testing.expect(!try dfaMatch("a.c", "a\nb")); // '.' never crosses newline
    try std.testing.expect(try dfaMatch("ab*c", "ac"));
    try std.testing.expect(try dfaMatch("ab*c", "abbbc"));
    try std.testing.expect(try dfaMatch("ab+c", "abc"));
    try std.testing.expect(!try dfaMatch("ab+c", "ac"));
    try std.testing.expect(try dfaMatch("colou?r", "colour")); // spellchecker:disable-line
    try std.testing.expect(try dfaMatch("(foo|bar)baz", "xxbarbazyy"));
    try std.testing.expect(!try dfaMatch("(foo|bar)baz", "bazonly"));
    try std.testing.expect(try dfaMatch("a*", "")); // nullable ⇒ matches empty line
    try std.testing.expect(try dfaMatch("a*", "zzz")); // …and any line
    // Overlapping-start hazard: the real match begins where an earlier thread died.
    try std.testing.expect(try dfaMatch("ab", "aab"));
    try std.testing.expect(try dfaMatch("abc", "ababc"));
    try std.testing.expect(!try dfaMatch("xyz", "xyxy"));
    try std.testing.expect(try dfaMatch("a.c", "aaac")); // match at offset 1
}

test "dfa: optional class preserves both concatenation seams" {
    const pattern = "[0-9][a-z]?[0-9]";
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .force_dfa = true });
    defer re.deinit();
    try std.testing.expect(re.dfa != null);
    try std.testing.expect(re.dfa.?.match("1a2"));
    try std.testing.expect(re.dfa.?.match("12"));
    try std.testing.expect(re.dfa.?.docMatch("before\n1a2\nafter"));
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "before\n1a2\nafter"));
}

// ─────────────────────────── differential fuzz ───────────────────────────

/// A random pattern generator over the supported subset, with an optional leading
/// `^` and/or trailing `$` — the realistic anchor placement that the gist≡rg
/// equality oracle also tests. Anchors are deliberately NOT quantifiable atoms:
/// `rg`/rust-regex reject a repeated anchor (`^*`, `${1,3}` ⇒ "nothing to
/// repeat"), so manufacturing one would test a pattern outside the supported
/// grammar — where the Pike oracle itself has no rg-defined truth to agree with.
/// Emits always-valid syntax (atoms then quantifiers, valid `{n,m}` only); small
/// alphabet ⇒ modest programs and high match rates.
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
    /// Top level: optional `^`, a body, optional `$`.
    fn pattern(g: *Gen) E!void {
        if (g.r.boolean()) try g.buf.append(g.a, '^');
        try g.alt(2);
        if (g.r.boolean()) try g.buf.append(g.a, '$');
    }
};

test "dfa: differential fuzz vs the Pike VM (0 divergences), anchors included" {
    const a = std.testing.allocator;
    const alphabet = "abcd01_ xy"; // mix of \w, digits, separators, '.'-fodder
    var line_buf: [24]u8 = undefined;

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 6000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        // `force_dfa`: keep class-run-shaped random patterns in DFA coverage
        // (production compile skips their dead-weight determinization).
        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue; // skip rare BadPattern
        defer re.deinit();
        if (re.dfa == null) continue; // powerset cap ⇒ Pike serves; not under test
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..10) |trial| {
            // Trial 0 is always the empty line (exercises the empty-match verdict).
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const line = line_buf[0..len];
            const got = re.dfa.?.match(line);
            const want = re.lineMatchPike(&sim, line); // proven reference
            if (got != want) {
                std.debug.print("DIVERGENCE pat=/{s}/ line=\"{s}\" dfa={} pike={}\n", .{ pat.items, line, got, want });
                return error.DfaPikeDivergence;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 20_000); // the fuzz actually ran
}

/// Per-line Pike verdict over a whole buffer — the proven reference for the
/// single-pass `Dfa.docMatch` (mirrors the Pike fallback in `Regex.docMatch`):
/// `\n`-split, OR of `lineMatchPike` over each line, no phantom trailing line.
fn pikeDoc(re: *Regex, sim: *Regex.Sim, doc: []const u8) bool {
    var rest = doc;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        if (re.lineMatchPike(sim, rest[0..end])) return true;
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
    return false;
}

test "dfa: assertion-free multiline bufMatch ≡ whole-buffer Pike (matches cross \\n)" {
    const a = std.testing.allocator;
    const alphabet = "abcd01_ xy\n"; // '\n' included: matches may cross lines under -U
    var buf_bytes: [40]u8 = undefined;

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 6000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();

        // Assertion-free body only (no optional `^`/`$` — the DFA admission
        // under multiline is exactly the assertion-free class).
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.alt(2);

        var re = Regex.compileOpts(a, pat.items, .{ .multiline = true, .dotall = r.boolean(), .force_dfa = true }) catch continue;
        defer re.deinit();
        try std.testing.expect(re.assert_free); // the generator emits no anchors
        if (re.dfa == null) continue; // powerset cap ⇒ Pike serves; not under test
        // This differential targets the DFA-vs-Pike seam; a class-run shape
        // would answer both calls from the kernel and test nothing here (it
        // has its own oracle + integration differentials).
        re.classrun = null;
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..8) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, buf_bytes.len + 1);
            for (0..len) |i| buf_bytes[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const buf = buf_bytes[0..len];
            const got = re.bufMatch(&sim, buf); // dispatches to the DFA
            // Force the Pike whole-buffer scan (the proven reference) by
            // hiding the DFA for one call; restore before deinit.
            const stashed = re.dfa;
            re.dfa = null;
            const want = re.bufMatch(&sim, buf);
            re.dfa = stashed;
            if (got != want) {
                std.debug.print("BUF DIVERGENCE pat=/{s}/ buf=\"{s}\" dfa={} pike={}\n", .{ pat.items, buf, got, want });
                return error.DfaPikeBufDivergence;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 20_000);
}

test "dfa: docMatch single-pass scan ≡ per-line Pike over multi-line buffers" {
    const a = std.testing.allocator;
    const alphabet = "abcd01_ xy\n"; // include '\n' so docs span lines, empty lines, runs
    var doc_buf: [40]u8 = undefined;

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 6000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 2654435761);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        // `force_dfa`: class-run-shaped random patterns keep DFA coverage here
        // (this differential calls `re.dfa.?.docMatch` directly, so the live
        // classrun dispatch never interposes).
        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue; // skip rare BadPattern
        defer re.deinit();
        if (re.dfa == null) continue; // powerset cap ⇒ Pike serves; not under test
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..8) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, doc_buf.len + 1);
            for (0..len) |i| doc_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const doc = doc_buf[0..len];
            const got = re.dfa.?.docMatch(doc); // single fused pass
            const want = pikeDoc(&re, &sim, doc); // per-line proven reference
            if (got != want) {
                std.debug.print("DOC DIVERGENCE pat=/{s}/ doc=\"{s}\" dfa={} pike={}\n", .{ pat.items, doc, got, want });
                return error.DfaPikeDocDivergence;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 20_000);
}
