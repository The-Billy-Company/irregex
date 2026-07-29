//! gist — the composition rung under the Pike VM, which is the oracle.
//!
//! Four layers, in increasing order of how much they would have caught:
//!   1. **kernel ≡ definition** — the vector fold against `lanes.reference`, the
//!      scalar statement of the same fold, on the SAME target. Isolates a
//!      shuffle bug from a lowering bug, which a pattern-level differential
//!      alone cannot do.
//!   2. **the gates** — every refusal is fail-closed and asserted to actually
//!      refuse: >31 states, an armed literal skip, `\b` word context, and a
//!      start closure that already accepts.
//!   3. **targeted units** — the anchor shapes (`^`, `$`, `^…$`, empty line)
//!      where the end-of-line axis lives, and the overlapping-start hazards.
//!   4. **differential fuzz** — random patterns × random haystacks, line level
//!      and doc level, against `lineMatchPike` / per-line Pike. Any divergence
//!      is a bug in this rung, never in the test.

const std = @import("std");
const regex = @import("../program/core.zig");
const lanes = @import("../../../scan/lanes.zig");
const compose = @import("shuffle.zig");
const Compose = compose.Compose;
const Regex = regex.Regex;

const a = std.testing.allocator;

/// Compile `pattern` and lower it, or null when the rung declines. `force_dfa`
/// keeps class-run-shaped patterns in coverage, exactly as `dfa_test.zig` does.
fn lower(pattern: []const u8) !?struct { re: Regex, cx: *Compose } {
    var re = try Regex.compileOpts(a, pattern, .{ .force_dfa = true });
    errdefer re.deinit();
    const dfa = re.dfa orelse {
        re.deinit();
        return null;
    };
    const cx = (try Compose.build(a, dfa)) orelse {
        re.deinit();
        return null;
    };
    return .{ .re = re, .cx = cx };
}

/// The rung's verdict for one line, asserting it actually armed.
fn composeMatch(pattern: []const u8, line: []const u8) !bool {
    var got = (try lower(pattern)) orelse return error.RungDeclined;
    defer got.re.deinit();
    defer got.cx.deinit();
    return got.cx.match(line);
}

// ───────────────────────────── 1. kernel ≡ definition ─────────────────────────

test "compose: the vector fold equals the scalar definition of the same fold" {
    // Random tables with an absorbing top lane — the kernel's one precondition —
    // driven over random bytes. This is the shuffle itself under test, with no
    // regex anywhere near it, so a divergence localizes to `lanes.zig`.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = prng.random();
    var bytes: [512]u8 = undefined;
    var checked: usize = 0;

    inline for (.{ lanes.Width.lanes16, lanes.Width.lanes32 }) |w| {
        inline for (.{ lanes.Index.byte, lanes.Index.byte_eol }) |ix| {
            const stride = comptime w.stride();
            const table = try a.alloc(u8, lanes.tableBytes(w, ix));
            defer a.free(table);
            const match_lane: u8 = stride - 1;
            for (0..500) |_| {
                for (0..table.len / stride) |row| {
                    const cells = table[row * stride ..][0..stride];
                    // Bias toward staying live so MATCH is reached sometimes but
                    // not immediately; MATCH must be a fixed point of every row.
                    for (cells) |*c| c.* = r.uintLessThan(u8, stride);
                    cells[match_lane] = match_lane;
                }
                const n = r.uintLessThan(usize, bytes.len + 1);
                for (bytes[0..n]) |*b| b.* = r.int(u8);
                const hay = bytes[0..n];
                const got = lanes.run(w, ix, hay, table, 0, match_lane);
                const want = lanes.reference(w, ix, hay, table, 0, match_lane);
                if (got != want) {
                    std.debug.print("KERNEL DIVERGENCE w={} ix={} len={}\n", .{ w, ix, n });
                    return error.KernelReferenceDivergence;
                }
                checked += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2000), checked);
}

// ─────────────────────────────── 2. the gates ─────────────────────────────────

test "compose: gate — an armed literal skip stands the rung down" {
    // `qzx.*jvw.*mkp` is the honest-boundary case: composition retires every
    // byte where the DFA skips ~19 in 20 out of its start dwell, and was measured
    // 6× SLOWER. The gate is what makes that measurement irrelevant.
    var re = try Regex.compileOpts(a, "qzx.*jvw.*mkp", .{ .force_dfa = true });
    defer re.deinit();
    const dfa = re.dfa.?;
    try std.testing.expect(dfa.start_dwell != null); // the skip really is armed
    try std.testing.expectEqual(@as(?*Compose, null), try Compose.build(a, dfa));
}

test "compose: gate — more than 31 non-accepting states stands the rung down" {
    // A fixed-length run of a wide class determinizes to one state per position,
    // so `{40}` is comfortably past the 31-lane ceiling while `{8}` is not.
    var wide = try Regex.compileOpts(a, "^[a-z]{40}$", .{ .force_dfa = true });
    defer wide.deinit();
    if (wide.dfa) |d| {
        try std.testing.expect(d.nstates > compose.max_states);
        try std.testing.expectEqual(@as(?*Compose, null), try Compose.build(a, d));
    }
    var narrow = try Regex.compileOpts(a, "^[a-z]{8}$", .{ .force_dfa = true });
    defer narrow.deinit();
    const cx = (try Compose.build(a, narrow.dfa.?)) orelse return error.RungDeclined;
    defer cx.deinit();
    try std.testing.expect(cx.match("abcdefgh"));
    try std.testing.expect(!cx.match("abcdefg"));
}

test "compose: gate — word context and an already-accepting start stand it down" {
    var wordy = try Regex.compileOpts(a, "\\bfoo", .{ .force_dfa = true });
    defer wordy.deinit();
    if (wordy.dfa) |d| {
        try std.testing.expect(d.word_ctx);
        try std.testing.expectEqual(@as(?*Compose, null), try Compose.build(a, d));
    }
    // `a*` matches the empty string at every position, so its start closure is
    // already accepting: START and MATCH would have to be the same lane.
    var nullable = try Regex.compileOpts(a, "a*", .{ .force_dfa = true });
    defer nullable.deinit();
    if (nullable.dfa) |d| {
        try std.testing.expect(d.isMatch(d.start));
        try std.testing.expectEqual(@as(?*Compose, null), try Compose.build(a, d));
    }
}

test "compose: gate — a non-AArch64 target leaves the field null" {
    // `native` is the compile-time predicate the rung is gated on; on a target
    // without it, `build` returns null before touching the DFA at all. Here we
    // can only assert the two agree — the x86 build is proven by compiling the
    // package for `x86_64-linux` in CI, where this rung is unreachable code.
    var re = try Regex.compileOpts(a, "^[a-z]{8}$", .{ .force_dfa = true });
    defer re.deinit();
    const built = try Compose.build(a, re.dfa.?);
    if (built) |cx| {
        defer cx.deinit();
        try std.testing.expect(lanes.native);
    } else try std.testing.expect(!lanes.native or re.dfa.?.start_dwell != null);
}

// ───────────────────────────── 3. targeted units ──────────────────────────────

// Every pattern below is one this rung actually arms on, and `composeMatch`
// fails rather than skipping when it does not — the population is anchored
// patterns (whose start dwell is never skippable) plus unanchored ones whose
// start state exits on more than `dwell.max_exit_bytes` = 3 distinct bytes. A
// literal like `ab` or `;$` exits on one byte, so the shared armed-skip gate
// takes it and the dwell gate test above is where it belongs.

test "compose: line anchors — the end-of-line axis the table index carries" {
    try std.testing.expect(try composeMatch("^func", "func main"));
    try std.testing.expect(!try composeMatch("^func", "  func main"));
    try std.testing.expect(try composeMatch("^abc$", "abc"));
    try std.testing.expect(!try composeMatch("^abc$", "abcd"));
    try std.testing.expect(!try composeMatch("^abc$", "xabc"));
    try std.testing.expect(try composeMatch("^$", ""));
    try std.testing.expect(!try composeMatch("^$", "x"));
    // `$` where the interior step does NOT already accept — the case that
    // forces the 512-row lookahead index rather than the 256-row fast path.
    try std.testing.expect(try composeMatch("[0-9]$", "abc1"));
    try std.testing.expect(!try composeMatch("[0-9]$", "1abc"));
    try std.testing.expect(try composeMatch("[0-9]{4}$", "year 2026"));
    try std.testing.expect(!try composeMatch("[0-9]{4}$", "2026 year"));
}

test "compose: overlapping starts, classes, and the 512-byte-plus vector body" {
    try std.testing.expect(try composeMatch("[a-e]b", "aab")); // match begins where an earlier thread died
    try std.testing.expect(try composeMatch("[a-e]bc", "ababc"));
    try std.testing.expect(!try composeMatch("[v-z]{5}", "xyxy")); // only four in the class
    try std.testing.expect(try composeMatch("[a-e].c", "aaac")); // match at offset 1
    try std.testing.expect(try composeMatch("[0-9]{4}", "year 2026 ok"));
    try std.testing.expect(!try composeMatch("[0-9]{4}", "12 34 5"));
    try std.testing.expect(try composeMatch("\\w{3,8}", "a_b9XY"));
    try std.testing.expect(!try composeMatch("\\w{3,8}", "ab"));
    // Long enough to run the full chunked body plus a ragged scalar tail.
    var long: [1000]u8 = @splat('z');
    long[777] = 'q';
    try std.testing.expect(try composeMatch("[p-u]", &long));
    try std.testing.expect(!try composeMatch("[c-g]", &long));
}

test "compose: docMatch — empty lines, terminators, and no phantom trailing line" {
    var m = (try lower("^$")) orelse return error.RungDeclined;
    defer m.re.deinit();
    defer m.cx.deinit();
    try std.testing.expect(m.cx.empty_match);
    try std.testing.expect(m.cx.docMatch("\n")); // one empty line
    try std.testing.expect(m.cx.docMatch("abc\n\ndef")); // an empty line between two
    try std.testing.expect(m.cx.docMatch("\nabc")); // a leading empty line
    try std.testing.expect(!m.cx.docMatch("abc\ndef")); // …and none here
    try std.testing.expect(!m.cx.docMatch("abc\n")); // a trailing `\n` is a terminator, not a line
    try std.testing.expect(!m.cx.docMatch(""));

    var n = (try lower("^abc$")) orelse return error.RungDeclined;
    defer n.re.deinit();
    defer n.cx.deinit();
    try std.testing.expect(n.cx.docMatch("xx\nabc\nyy"));
    try std.testing.expect(n.cx.docMatch("abc"));
    try std.testing.expect(n.cx.docMatch("xx\nabc"));
    try std.testing.expect(!n.cx.docMatch("xx\nabcd\nyy"));
    try std.testing.expect(!n.cx.docMatch("xxabc\nyy"));
}

// ─────────────────────────── 4. differential fuzz ─────────────────────────────

/// Random patterns over the supported subset with optional line anchors — the
/// same generator shape `dfa_test.zig` fuzzes the DFA with, so the two rungs are
/// held to the oracle over the same population.
const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),

    const E = std.mem.Allocator.Error;

    fn atom(g: *Gen, depth: u8) E!void {
        switch (g.r.uintLessThan(u8, if (depth > 0) 7 else 6)) {
            0 => try g.buf.append(a, "abc"[g.r.uintLessThan(usize, 3)]),
            1 => try g.buf.append(a, '.'),
            2 => try g.buf.appendSlice(a, "[a-c]"),
            3 => try g.buf.appendSlice(a, "[^a-c]"),
            4 => try g.buf.appendSlice(a, "\\d"),
            5 => try g.buf.appendSlice(a, "\\w"),
            else => {
                try g.buf.append(a, '(');
                try g.alt(depth - 1);
                try g.buf.append(a, ')');
            },
        }
    }
    fn quant(g: *Gen, depth: u8) E!void {
        try g.atom(depth);
        switch (g.r.uintLessThan(u8, 7)) {
            0 => try g.buf.append(a, '*'),
            1 => try g.buf.append(a, '+'),
            2 => try g.buf.append(a, '?'),
            3 => try g.buf.appendSlice(a, "{2}"),
            4 => try g.buf.appendSlice(a, "{1,3}"),
            5 => try g.buf.appendSlice(a, "{0,2}"),
            else => {},
        }
    }
    fn concat(g: *Gen, depth: u8) E!void {
        for (0..1 + g.r.uintLessThan(usize, 3)) |_| try g.quant(depth);
    }
    fn alt(g: *Gen, depth: u8) E!void {
        try g.concat(depth);
        for (0..g.r.uintLessThan(usize, 3)) |_| {
            try g.buf.append(a, '|');
            try g.concat(depth);
        }
    }
    fn pattern(g: *Gen) E!void {
        if (g.r.boolean()) try g.buf.append(a, '^');
        try g.alt(2);
        if (g.r.boolean()) try g.buf.append(a, '$');
    }
};

/// Per-line Pike verdict over a whole buffer — the proven reference for the
/// single fused `docMatch` pass. No phantom line after a trailing `\n`.
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

/// How many verdicts each level cross-checked, so the report can cite a number
/// the test actually produced rather than one the prose remembers.
var line_cases: usize = 0;
var doc_cases: usize = 0;

test "compose: line-level differential vs the Pike VM (0 divergences), anchors included" {
    const alphabet = "abcd01_ xy";
    var line_buf: [40]u8 = undefined;
    var armed: usize = 0;

    var seed: u64 = 0;
    while (seed < 5000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat };
        try g.pattern();

        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const dfa = re.dfa orelse continue;
        const cx = (try Compose.build(a, dfa)) orelse continue; // declined ⇒ not this rung's line
        defer cx.deinit();
        armed += 1;
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..80) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (line_buf[0..len]) |*b| b.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            const line = line_buf[0..len];
            const got = cx.match(line);
            const want = re.lineMatchPike(&sim, line); // proven reference
            if (got != want) {
                std.debug.print("LINE DIVERGENCE pat=/{s}/ line=\"{s}\" compose={} pike={}\n", .{ pat.items, line, got, want });
                return error.ComposePikeDivergence;
            }
            line_cases += 1;
        }
    }
    try std.testing.expect(armed > 1000); // the gates are not swallowing the population
    // High enough that this floor plus the doc level's carries the total the
    // report cites, WITHOUT either test having to see the other's counter — see
    // the scale test below, which cannot see it under a sharded run.
    try std.testing.expect(line_cases > 225_000);
}

test "compose: docMatch single-pass scan ≡ per-line Pike over multi-line buffers" {
    const alphabet = "abcd01_ xy\n\n"; // `\n` twice ⇒ empty lines are common
    var doc_buf: [96]u8 = undefined;

    var seed: u64 = 0;
    while (seed < 5000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 2654435761);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat };
        try g.pattern();

        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const dfa = re.dfa orelse continue;
        const cx = (try Compose.build(a, dfa)) orelse continue;
        defer cx.deinit();
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..40) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, doc_buf.len + 1);
            for (doc_buf[0..len]) |*b| b.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            const doc = doc_buf[0..len];
            const got = cx.docMatch(doc); // one fused pass
            const want = pikeDoc(&re, &sim, doc); // per-line proven reference
            if (got != want) {
                std.debug.print("DOC DIVERGENCE pat=/{s}/ doc=\"{s}\" compose={} pike={}\n", .{ pat.items, doc, got, want });
                return error.ComposePikeDocDivergence;
            }
            doc_cases += 1;
        }
    }
    try std.testing.expect(doc_cases > 110_000);
}

/// Armed instances split by whether `lower` proved them `sliceSafe`, so the
/// test below can refuse to pass on a vacuous population.
var slice_yes: usize = 0;
var slice_no: usize = 0;
var slice_cases: usize = 0;

test "compose: the sliceSafe proof, through the ladder, on haystacks full of newlines" {
    // The one axis where being wrong yields a WRONG ANSWER rather than a crash,
    // and the reason it is exercised HERE rather than against `cx.match`: this
    // rung answers the per-line question, `verdict.lineMatch` asks the slice
    // question, and `lower` decides per instance which of those two this machine
    // happens to answer. The fuzzes above feed `\n`-free lines and so cannot see
    // the disagreement at all — an earlier build shipped a rung that read
    // `^x|y$` against a raw `"barbar\nfoo\n"` as if the newline were a line
    // break, and every test in this file stayed green.
    //
    // So: drive the PRODUCTION entry point, feed it buffers dense in `\n`, and
    // hold it to the Pike VM's answer for that exact slice. A `sliceSafe` proof
    // that is too generous diverges here on the first anchored pattern.
    const alphabet = "abcd01_ xy\n\n";
    var hay_buf: [96]u8 = undefined;

    var seed: u64 = 0;
    while (seed < 4000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat };
        try g.pattern();

        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue;
        defer re.deinit();
        const cx = re.rungs.compose orelse continue; // the tier as the engine built it
        if (cx.sliceSafe()) slice_yes += 1 else slice_no += 1;
        var sim = try Regex.Sim.init(a, &re);
        defer sim.deinit();

        for (0..40) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, hay_buf.len + 1);
            for (hay_buf[0..len]) |*b| b.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            const hay = hay_buf[0..len];
            const got = re.lineMatch(&sim, hay); // ladder, tier consulted
            const want = re.lineMatchPike(&sim, hay); // proven reference
            if (got != want) {
                std.debug.print("SLICE DIVERGENCE pat=/{s}/ safe={} hay=\"{f}\" ladder={} pike={}\n", .{ pat.items, cx.sliceSafe(), std.zig.fmtString(hay), got, want });
                return error.ComposeSliceDivergence;
            }
            slice_cases += 1;
        }
    }
    // Both populations must be represented or the run proves nothing: all-safe
    // would mean the guard never fired, all-unsafe would mean the refinement is
    // dead and the throughput it buys is imaginary.
    try std.testing.expect(slice_yes > 100);
    try std.testing.expect(slice_no > 100);
    try std.testing.expect(slice_cases > 50_000);
}

test "compose: differential scale (the number the report cites)" {
    // Ordered last so both fuzzes above have run, and it reads their totals
    // rather than recomputing them — which makes this the one test in the file
    // that depends on a SIBLING having executed in the same process.
    //
    // Under the shard runner that is not guaranteed and cannot be arranged: a
    // shard owns the residues `i, i+n, …` of the declaration order, so three
    // consecutive tests land in three different shards, and this one runs with
    // both counters at zero. Skipping is the honest answer there, and it costs
    // no coverage: each producer now asserts a floor of its own, and those two
    // floors already carry the cited total. This test is what makes the number
    // quotable, not what makes it true.
    if (line_cases == 0 or doc_cases == 0) return error.SkipZigTest;
    const total = line_cases + doc_cases;
    std.debug.print("compose differential: {d} line + {d} doc = {d} cases, 0 divergences\n", .{ line_cases, doc_cases, total });
    try std.testing.expect(total >= 317_940);
}
