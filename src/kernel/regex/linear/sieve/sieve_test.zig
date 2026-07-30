//! gist — quotient-sieve tests. The sieve's whole contract is one implication:
//!
//!     scan(hay) == .miss  ⟹  the real matcher finds nothing in `hay`
//!
//! so that is what these differentials assert, against the **Pike VM** rather
//! than against the DFA the sieve was built from — a shared bug in the
//! determinizer would otherwise be invisible. A `.miss` on a line the Pike VM
//! matches is a missed match: the worst failure this engine has, and never a
//! test to weaken.
//!
//! Four layers:
//!   1. the shipped slate — the ten research-lane patterns, each checked for
//!      over-approximation over random lines;
//!   2. kernel ≡ scalar oracle, so the shuffle chain is not the thing being
//!      trusted;
//!   3. two differential fuzzes over thousands of random patterns — per line,
//!      and (under the `nl_reset` license) per multi-line buffer;
//!   4. the compile-time gates: the worthless pattern must leave the field
//!      null, and each soundness precondition must decline.
//!
//! Layers 1–3 build with `.ungated`, because soundness is a property of the
//! quotient construction and has to hold on every pattern that harvests one,
//! not only on the ones the cost policy happens to admit.

const std = @import("std");
const regex = @import("../program/core.zig");
const sieve = @import("sieve.zig");
const quotient = @import("quotient.zig");
const sheng = @import("sheng.zig");

const Regex = regex.Regex;
const Sieve = sieve.Sieve;
const ByteSet = sieve.Class;

/// The research lane's slate, most selective first (see `research/…/REPORT.md`).
/// `\p{Greek}{3}` is dropped: the harvest runs on the ASCII byte-class DFA.
const slate = [_][]const u8{
    "[0-9]{40,}",
    "[A-Za-z]+[0-9]+[A-Za-z]+",
    "[0-9]{4}-[0-9]{2}-[0-9]{2}",
    "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    "[A-Z][a-z]+ [A-Z][a-z]+",
    "\\w+\\s+\\w+",
    "[A-Za-z]+[0-9]+",
    "[A-Za-z0-9+/]{40,}={0,2}",
    "0x[0-9a-fA-F]{8,16}",
};

/// A compiled pattern plus the sieve harvested from its DFA. The sieve copies
/// its quotients by value, so it outlives nothing — but the Pike reference
/// needs the `Regex`, so they are carried together.
const Fixture = struct {
    re: Regex,
    sim: Regex.Sim,
    s: *Sieve,

    fn init(pattern: []const u8, gate: sieve.Gate) !?Fixture {
        const a = std.testing.allocator;
        var re = Regex.compileOpts(a, pattern, .{ .force_dfa = true }) catch return null;
        errdefer re.deinit();
        const d = re.dfa orelse {
            re.deinit();
            return null;
        };
        const s = (try Sieve.build(a, d, .{}, gate)) orelse {
            re.deinit();
            return null;
        };
        errdefer s.deinit();
        return .{ .re = re, .sim = try Regex.Sim.init(a, &re), .s = s };
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        f.sim.deinit();
        f.re.deinit();
    }

    /// The proven per-line reference.
    fn truth(f: *Fixture, line: []const u8) bool {
        return f.re.lineMatchPike(&f.sim, line);
    }
};

/// Per-line Pike verdict over a whole buffer — the reference for a `doc_ok`
/// whole-buffer sieve pass.
fn truthDoc(f: *Fixture, doc: []const u8) bool {
    var rest = doc;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        if (f.truth(rest[0..end])) return true;
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
    return false;
}

test "sieve: the slate's quotients over-approximate their patterns" {
    const alphabet = "abZ019 -+/=x\tHello";
    var line: [48]u8 = undefined;
    var armed: usize = 0;
    var checked: usize = 0;
    for (slate, 0..) |pat, pi| {
        var f = (try Fixture.init(pat, .ungated)) orelse continue;
        defer f.deinit();
        armed += 1;
        var prng = std.Random.DefaultPrng.init(0xA5A5 +% pi);
        const r = prng.random();
        for (0..4000) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line.len + 1);
            for (0..len) |i| line[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const hay = line[0..len];
            if (f.s.scan(hay) == .miss and f.truth(hay)) {
                std.debug.print("FALSE MISS pat=/{s}/ line=\"{s}\"\n", .{ pat, hay });
                return error.SieveRejectedARealMatch;
            }
            checked += 1;
        }
    }
    try std.testing.expect(armed >= 6); // the slate is meant to harvest
    try std.testing.expect(checked > 20_000);
}

test "sieve: the slate's exact rows — a quotient that loses nothing" {
    // Three research-lane patterns are *exact*: their ≤16-block quotient
    // accepts precisely their language, so `.miss` and "no match" coincide on
    // every line. When that is true the sieve is not an approximation at all,
    // and a regression to a coarser harvest would show up here as a survivor
    // on a non-matching line rather than as a soundness failure.
    const alphabet = "abZ019 x_\t";
    var line: [32]u8 = undefined;
    var f = (try Fixture.init("[A-Za-z]+[0-9]+[A-Za-z]+", .ungated)) orelse return error.SkipZigTest;
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var exact: usize = 0;
    for (0..4000) |_| {
        const len = r.uintLessThan(usize, line.len + 1);
        for (0..len) |i| line[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
        const hay = line[0..len];
        const survived = f.s.scan(hay) == .unproven;
        if (f.truth(hay)) {
            try std.testing.expect(survived); // soundness
        } else if (!survived) exact += 1;
    }
    try std.testing.expect(exact > 1000); // it really is retiring non-matches
}

/// Random-pattern generator: assertion-free bodies (the sieve's admission
/// class), classes and repeats deep enough to make the powerset non-trivial.
const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,

    const E = std.mem.Allocator.Error;
    const atoms = [_][]const u8{ "a", "b", "c", "0", "1", "_", " ", ".", "\\w", "\\d", "\\s", "[a-c]", "[0-9]", "[a-z0-9_]", "[^ab]", "x" };

    fn atom(g: *Gen, depth: u8) E!void {
        if (depth > 0 and g.r.uintLessThan(u8, 5) == 0) {
            try g.buf.append(g.a, '(');
            try g.alt(depth - 1);
            try g.buf.append(g.a, ')');
            return;
        }
        try g.buf.appendSlice(g.a, atoms[g.r.uintLessThan(usize, atoms.len)]);
    }
    fn quant(g: *Gen, depth: u8) E!void {
        try g.atom(depth);
        switch (g.r.uintLessThan(u8, 8)) {
            0 => try g.buf.append(g.a, '*'),
            1 => try g.buf.append(g.a, '+'),
            2 => try g.buf.append(g.a, '?'),
            3 => {
                // Both bounds stay in 1..8, so `{n,m}` is five bytes and the
                // digits are their own ASCII — no format buffer to size wrong.
                const lo = 1 + g.r.uintLessThan(u8, 3);
                try g.buf.appendSlice(g.a, &[_]u8{ '{', '0' + lo, ',', '0' + lo + 2 + g.r.uintLessThan(u8, 4), '}' });
            },
            else => {},
        }
    }
    fn concat(g: *Gen, depth: u8) E!void {
        for (0..1 + g.r.uintLessThan(usize, 4)) |_| try g.quant(depth);
    }
    fn alt(g: *Gen, depth: u8) E!void {
        try g.concat(depth);
        for (0..g.r.uintLessThan(usize, 3)) |_| {
            try g.buf.append(g.a, '|');
            try g.concat(depth);
        }
    }
};

test "sieve: differential fuzz vs the Pike VM — no .miss on a matching line" {
    const a = std.testing.allocator;
    const alphabet = "abc01_ x.\ty";
    var line_buf: [28]u8 = undefined;
    var checked: usize = 0;
    var misses: usize = 0;
    var armed: usize = 0;

    var seed: u64 = 0;
    while (seed < 4000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.alt(2);

        var f = (try Fixture.init(pat.items, .ungated)) orelse continue;
        defer f.deinit();
        armed += 1;

        for (0..12) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const hay = line_buf[0..len];
            const verdict = f.s.scan(hay);
            if (verdict == .miss) {
                misses += 1;
                if (f.truth(hay)) {
                    std.debug.print("FALSE MISS pat=/{s}/ line=\"{s}\"\n", .{ pat.items, hay });
                    return error.SieveRejectedARealMatch;
                }
            }
            checked += 1;
        }
    }
    try std.testing.expect(armed > 200); // the harvest fires on random patterns
    try std.testing.expect(checked > 3_000);
    try std.testing.expect(misses > 500); // …and `.miss` is genuinely exercised
}

test "sieve: doc_ok licenses one continuous pass over a multi-line buffer" {
    // `nl_reset` says every state steps back to start on `\n`, so a single
    // uninterrupted run over a buffer IS the per-line model. The reference is
    // the per-line Pike verdict; a `.miss` must mean no line matches.
    const a = std.testing.allocator;
    const alphabet = "abc01_ x\n\ny";
    var doc_buf: [64]u8 = undefined;
    var checked: usize = 0;
    var misses: usize = 0;

    var seed: u64 = 0;
    while (seed < 3000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 2654435761);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.alt(2);

        var f = (try Fixture.init(pat.items, .ungated)) orelse continue;
        defer f.deinit();
        // `.ungated` above already dropped the worth half of this flag, so what
        // survives here is the `nl_reset` LICENSE — which is exactly the
        // property under test, and the reason this layer is `.ungated` at all.
        if (!f.s.doc_ok) continue;

        for (0..10) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, doc_buf.len + 1);
            for (0..len) |i| doc_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const doc = doc_buf[0..len];
            if (f.s.scan(doc) == .miss) {
                misses += 1;
                if (truthDoc(&f, doc)) {
                    std.debug.print("FALSE DOC MISS pat=/{s}/ doc=\"{s}\"\n", .{ pat.items, doc });
                    return error.SieveRejectedARealMatch;
                }
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 2_000);
    try std.testing.expect(misses > 200);
}

test "sieve: the shuffle kernel ≡ the scalar oracle, byte for byte" {
    const a = std.testing.allocator;
    const alphabet = "abc01_ x.y";
    var line_buf: [40]u8 = undefined;
    var checked: usize = 0;

    var seed: u64 = 0;
    while (seed < 1500) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0xD1B54A32D192ED03);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.alt(2);
        var f = (try Fixture.init(pat.items, .ungated)) orelse continue;
        defer f.deinit();

        for (0..10) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            const hay = line_buf[0..len];
            if (f.s.scan(hay) != f.s.scanScalar(hay)) {
                std.debug.print("KERNEL DIVERGENCE pat=/{s}/ n={d} line=\"{s}\"\n", .{ pat.items, f.s.n, hay });
                return error.ShuffleScalarDivergence;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked > 3_000);
}

test "sieve: the two-quotient conjunction is a real conjunction" {
    // `survives2` must be ∃position(A ∧ B), not (∃A) ∧ (∃B) — the weaker form
    // would still be sound but strictly less selective, so this is a
    // performance contract with a correctness smell if it ever inverts.
    var a: quotient.Quotient = .{ .nb = 2, .th = 1, .start = 0, .rows = undefined };
    var b: quotient.Quotient = .{ .nb = 2, .th = 1, .start = 0, .rows = undefined };
    for (0..256) |c| {
        // A accepts only after 'x'; B accepts only after 'y'. No position can
        // satisfy both, so the conjunction must reject a haystack holding both.
        a.rows[c] = @splat(@intFromBool(c == 'x'));
        b.rows[c] = @splat(@intFromBool(c == 'y'));
    }
    try std.testing.expect(!sheng.survives2(&a, &b, "xy"));
    try std.testing.expect(sheng.survives1(&a, "xy"));
    try std.testing.expect(sheng.survives1(&b, "xy"));
    try std.testing.expect(!sheng.survivesScalar(&.{ a, b }, "xy"));
}

test "sieve: the worthless pattern leaves the field null (compile-time abort)" {
    // The research lane measured `0x[0-9a-fA-F]{8,16}` at 99.8% fallthrough —
    // a filter that rejects nothing, i.e. pure overhead on every byte. The
    // structural estimate has to see that WITHOUT a calibration haystack and
    // decline, while the selective rows still arm.
    const worthless = try Fixture.init("0x[0-9a-fA-F]{8,16}", .worth);
    if (worthless) |*f| {
        var g = f.*;
        defer g.deinit();
        std.debug.print("worthless pattern armed with fallthrough {d:.4}\n", .{g.s.fallthrough});
        return error.WorthlessSieveArmed;
    }
    // …and it is not a blanket refusal: the selective rows survive the gate.
    //
    // The assertion is the inequality the gate itself applies, not a proxy for
    // it. It used to read `fallthrough < 1 - speed_ratio`, which was the right
    // shape only while one constant stood for both the sieve's price and the
    // decider's; now that each side is its own measured number, an armed sieve
    // must be a win at its own grain — pre-pass plus surviving verifications
    // strictly under what the decider costs alone.
    var armed: usize = 0;
    for (slate) |pat| {
        var f = (try Fixture.init(pat, .worth)) orelse continue;
        defer f.deinit();
        try std.testing.expect(f.s.cost.total(.line) < f.s.cost.exact(.line));
        try std.testing.expect(f.s.cost.pays(.line));
        armed += 1;
    }
    if (sheng.resident) try std.testing.expect(armed >= 2);
}

test "sieve: every soundness precondition declines rather than approximating" {
    // Each of these breaks the single-continuous-interior-run model the sieve's
    // superset argument rests on, so `project` must refuse it outright. A
    // regression here would not show up as a bad verdict on these patterns —
    // it would show up as a rare false `.miss` somewhere else entirely.
    const refused = [_][]const u8{
        "^[0-9]{4}-[0-9]{2}", // `^`-anchored: never re-seeds
        "[0-9]{4}-[0-9]{2}$", // `$` needs the final transition table
        "\\A[0-9]{4}-[0-9]{2}", // buffer-start assertion
        "[0-9]{4}-[0-9]{2}\\z", // buffer-end assertion
        "\\b[0-9]{4}-[0-9]{2}\\b", // word context: a second determinization axis
        "[0-9]*", // nullable: matches at every position anyway
        "\\w{3,8}", // no `$`-free interior superset to speak of / accepts broadly
    };
    for (refused) |pat| {
        const a = std.testing.allocator;
        var re = Regex.compileOpts(a, pat, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const d = re.dfa orelse continue;
        if (try Sieve.build(a, d, .{}, .ungated)) |s| {
            defer s.deinit();
            // Only the last row is allowed to harvest (it is merely *bad*, not
            // unsound); the first three must be refused by `project`.
            if (!std.mem.eql(u8, pat, "\\w{3,8}")) {
                std.debug.print("UNSOUND ADMISSION pat=/{s}/\n", .{pat});
                return error.SieveAdmittedARefusedShape;
            }
        }
    }
}

test "sieve: the selectivity model brackets the measured rate on the slate" {
    // The gate is only as good as its estimate, so hold the estimate to
    // reality on a synthetic text-shaped haystack: the structural fallthrough
    // must not be wildly optimistic (which would arm a worthless sieve).
    const a = std.testing.allocator;
    var hay: std.ArrayList(u8) = .empty;
    defer hay.deinit(a);
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    const words = [_][]const u8{ "const ", "fn ", "value ", "0x1f ", "2026-07-26 ", "Hello World ", "x9y ", "\n" };
    while (hay.items.len < 200_000) try hay.appendSlice(a, words[r.uintLessThan(usize, words.len)]);

    for (slate) |pat| {
        var f = (try Fixture.init(pat, .ungated)) orelse continue;
        defer f.deinit();
        // Measured per-position fallthrough over the synthetic corpus.
        var survivors: usize = 0;
        var st: [quotient.max_conjuncts]u8 = undefined;
        for (f.s.q[0..f.s.n], 0..) |*q, i| st[i] = q.start;
        for (hay.items) |b| {
            var all = true;
            for (f.s.q[0..f.s.n], 0..) |*q, i| {
                st[i] = q.rows[b][st[i]];
                all = all and st[i] >= q.th;
            }
            survivors += @intFromBool(all);
        }
        const measured = @as(f64, @floatFromInt(survivors)) / @as(f64, @floatFromInt(hay.items.len));
        // The estimate is allowed to be pessimistic without limit; it is only
        // an error for it to under-predict fallthrough by more than an order of
        // magnitude, since that is the direction that arms a bad sieve.
        if (measured > 0.05 and f.s.fallthrough * 10 < measured) {
            std.debug.print("OPTIMISTIC ESTIMATE pat=/{s}/ est={d:.5} measured={d:.5}\n", .{ pat, f.s.fallthrough, measured });
            return error.SelectivityModelTooOptimistic;
        }
    }
}

fn bytes(chars: []const u8) ByteSet {
    var set: ByteSet = .{};
    for (chars) |b| set.set(b);
    return set;
}

fn range(lo: u8, hi: u8) ByteSet {
    var set: ByteSet = .{};
    set.setRange(lo, hi);
    return set;
}

fn buildWindows(windows: []const sieve.Window, gate: sieve.Gate) !sieve.BuildResult {
    return Sieve.buildWindows(std.testing.allocator, windows, .{}, gate);
}

test "sieve window: UUID-like heterogeneous q-gram is a sound necessary filter" {
    var hex = range('0', '9');
    hex.setRange('a', 'f');
    hex.setRange('A', 'F');
    const dash = bytes("-");
    const classes = [_]ByteSet{ hex, hex, hex, hex, dash, hex, hex, hex, hex };
    const built = try buildWindows(&.{.{ .classes = &classes }}, .ungated);
    const s = built.sieve orelse return error.UUIDWindowDeclined;
    defer s.deinit();
    try std.testing.expectEqual(sieve.Source.byte_window, s.source);

    const matching = [_][]const u8{
        "dead-beef",
        "prefix 0123-ABcd suffix",
        "xxxxxxxxxxxxxxxdead-beef", // begins at the 16-byte block seam
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxdead-beef", // 64-byte seam
        "\xff\x80 dead-beef \xc3\x28", // malformed UTF-8 remains ordinary bytes
    };
    for (matching) |hay| try std.testing.expectEqual(sieve.Verdict.unproven, s.scan(hay));

    const misses = [_][]const u8{ "", "dead beef", "dea-beef", "gggg-beef", "dead-bee" };
    for (misses) |hay| try std.testing.expectEqual(sieve.Verdict.miss, s.scan(hay));
}

test "sieve window: fixed tails align two register filters at one endpoint" {
    const ab = [_]ByteSet{ bytes("a"), bytes("b") };
    const cd = [_]ByteSet{ bytes("c"), bytes("d") };
    const built = try buildWindows(&.{
        .{ .classes = &ab, .tail = 2 },
        .{ .classes = &cd },
    }, .ungated);
    const s = built.sieve orelse return error.AlignedWindowsDeclined;
    defer s.deinit();
    try std.testing.expectEqual(@as(u8, 2), s.n);
    try std.testing.expectEqual(sieve.Verdict.unproven, s.scan("--abcd--"));
    try std.testing.expectEqual(sieve.Verdict.miss, s.scan("--abxxcd--"));
}

test "sieve window: random differential never rejects an injected q-gram" {
    const classes = [_]ByteSet{ range('0', '9'), bytes("-"), range('A', 'F'), range('a', 'f') };
    const built = try buildWindows(&.{.{ .classes = &classes }}, .ungated);
    const s = built.sieve orelse return error.DifferentialWindowDeclined;
    defer s.deinit();

    var prng = std.Random.DefaultPrng.init(0x51E7E);
    const r = prng.random();
    const alphabet = "01-ABafxyz\n";
    var hay: [96]u8 = undefined;
    for (0..4000) |trial| {
        const len = 4 + r.uintLessThan(usize, hay.len - 3);
        for (hay[0..len]) |*b| b.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const at = r.uintLessThan(usize, len - 3);
        hay[at..][0..4].* = .{ '7', '-', 'B', 'e' };
        if (s.scan(hay[0..len]) == .miss) {
            std.debug.print("FALSE WINDOW MISS trial={d} at={d}\n", .{ trial, at });
            return error.WindowRejectedInjectedMatch;
        }
    }
}

test "sieve window: newline, broad survival, and malformed shapes fail safely" {
    var any: ByteSet = .{};
    any.negate();
    const broad = [_]ByteSet{any};
    const all = try buildWindows(&.{.{ .classes = &broad }}, .ungated);
    const broad_sieve = all.sieve orelse return error.BroadWindowDeclined;
    defer broad_sieve.deinit();
    try std.testing.expectEqual(sieve.Verdict.unproven, broad_sieve.scan("all-survive\xff\x80"));

    const with_tail = [_]ByteSet{bytes("x")};
    const tailed = try buildWindows(&.{.{ .classes = &with_tail, .tail = 1 }}, .ungated);
    const tail_sieve = tailed.sieve orelse return error.TailedWindowDeclined;
    defer tail_sieve.deinit();
    try std.testing.expect(!tail_sieve.doc_ok); // wildcard tail can cross newline; no split license
    try std.testing.expectEqual(sieve.Verdict.unproven, tail_sieve.scan("x\n"));

    const none: [0]ByteSet = .{};
    const empty = try buildWindows(&.{.{ .classes = &none }}, .ungated);
    try std.testing.expectEqual(sieve.Decline.malformed_window, empty.decline.?);
    const too_wide = [_]ByteSet{any} ** (sieve.max_window_width + 1);
    const wide = try buildWindows(&.{.{ .classes = &too_wide }}, .ungated);
    try std.testing.expectEqual(sieve.Decline.malformed_window, wide.decline.?);
}

test "sieve window: cost fact prices the selected decider, including cheap paths" {
    const classes = [_]ByteSet{ bytes("Q"), bytes("7"), bytes("-"), bytes("Z") };
    const cheap: sieve.Above = .{ .decider_cost = 1_000 };
    const declined = try Sieve.buildWindows(std.testing.allocator, &.{.{ .classes = &classes }}, cheap, .worth);
    try std.testing.expectEqual(sieve.Decline.unprofitable, declined.decline.?);
    try std.testing.expectEqual(@as(u32, 1_000), declined.cost.?.decider_cost);

    const ungated = try Sieve.buildWindows(std.testing.allocator, &.{.{ .classes = &classes }}, cheap, .ungated);
    const s = ungated.sieve orelse return error.UngatedWindowDeclined;
    defer s.deinit();
    try std.testing.expect(s.cost.total(.line) > s.cost.decider_cost);
}
