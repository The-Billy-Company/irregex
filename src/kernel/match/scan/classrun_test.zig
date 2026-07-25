//! gist — SIMD class-run kernel tests: a byte-at-a-time scalar oracle, edge
//! geometry (block seams, tails, carries), and the two-backend parity fuzz.
//!
//! The kernel's contract is exact three-valued equivalence with the obvious
//! scalar scan: `.hit` ⟺ ≥ min consecutive members of S, `.miss` final, and
//! `.unproven` exactly when a codepoint-projection set met a ≥ 0x80 byte with
//! no ASCII run sufficing. Every test here asserts against that oracle — the
//! SIMD lanes, the shift-AND fold, and the cross-block carry never appear in
//! an expectation, only in the code under test. The fuzz plants runs ON the
//! 64-byte seams deliberately: the carry arithmetic is the part a uniform
//! random haystack exercises most rarely.

const std = @import("std");
const classrun = @import("classrun.zig");
const bitsmod = @import("../../primitives/bits.zig");

const B64 = bitsmod.Field(u64);
const ClassRun = classrun.ClassRun;
const Verdict = classrun.Verdict;

/// The semantic ground truth, one byte at a time. Any divergence from this is
/// a kernel bug by definition.
fn oracle(bits: [4]u64, min: u32, exact: bool, hay: []const u8) Verdict {
    var run: u64 = 0;
    var high = false;
    for (hay) |b| {
        if (b >= 0x80) high = true;
        if (B64.get(&bits, b)) {
            run += 1;
            if (run >= min) return .hit;
        } else run = 0;
    }
    return if (!exact and high) .unproven else .miss;
}

/// Assert kernel == oracle for one (set, min, exact, hay) point — on the
/// backend `build` chose AND on the forced truffle backend, so every case
/// doubles as a range-vs-nibble parity check.
fn check(bits: [4]u64, min: u32, exact: bool, hay: []const u8) !void {
    const want = oracle(bits, min, exact, hay);
    var cr = ClassRun.build(bits, min, exact, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(want, cr.scan(hay));
    cr.backend = .{ .nibbles = classrun.nibbleTables(bits) };
    try std.testing.expectEqual(want, cr.scan(hay));
}

fn setOf(comptime members: []const u8) [4]u64 {
    var bits: [4]u64 = @splat(0);
    for (members) |b| B64.set(&bits, b);
    return bits;
}

fn rangeSet(lo: u8, hi: u8) [4]u64 {
    var bits: [4]u64 = @splat(0);
    var b: usize = lo;
    while (b <= hi) : (b += 1) B64.set(&bits, b);
    return bits;
}

// ── construction ─────────────────────────────────────────────────────────────

test "classrun: min 0 declines (nullable patterns belong to eol_empty)" {
    try std.testing.expectEqual(@as(?ClassRun, null), ClassRun.build(setOf("a"), 0, true, null));
}

test "classrun: backend choice — few ranges take lanes, scattered takes truffle" {
    const digits = ClassRun.build(rangeSet('0', '9'), 1, true, null).?;
    try std.testing.expect(digits.backend == .ranges);
    // 5 disjoint singletons > max_ranges ⇒ truffle.
    const scattered = ClassRun.build(setOf("aeiou"), 1, true, null).?;
    try std.testing.expect(scattered.backend == .nibbles);
}

test "classrun: nl_free reflects newline membership" {
    try std.testing.expect(ClassRun.build(rangeSet('a', 'z'), 1, true, null).?.nl_free);
    try std.testing.expect(!ClassRun.build(setOf("a\n"), 1, true, null).?.nl_free);
}

// ── verdict semantics ────────────────────────────────────────────────────────

test "classrun: hit / miss on plain ASCII, both backends" {
    const w = blk: { // \w = [0-9A-Za-z_], 4 ranges — the dense flagship
        var bits = rangeSet('0', '9');
        for ([_][2]u8{ .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ '_', '_' } }) |r| {
            var b: usize = r[0];
            while (b <= r[1]) : (b += 1) B64.set(&bits, b);
        }
        break :blk bits;
    };
    try check(w, 3, true, "ab cd efg hi");
    try check(w, 4, true, "ab cd efg hi");
    try check(w, 1, true, "   ...   ");
    try check(w, 8, true, "under_score more");
    try check(rangeSet('0', '9'), 4, true, "port 8080 open");
    try check(rangeSet('0', '9'), 5, true, "port 8080 open");
}

test "classrun: empty set never hits; empty haystack never hits" {
    try check(@splat(0), 1, true, "anything at all");
    try check(rangeSet('a', 'z'), 1, true, "");
    try check(rangeSet('a', 'z'), 1, true, "Z9 ?");
}

test "classrun: unproven only for a projection meeting a high byte" {
    const az = rangeSet('a', 'z');
    // Exact set: high bytes are just non-members — verdicts stay final.
    try check(az, 3, true, "\xc3\xa9\xc3\xa9\xc3\xa9");
    // Projection, high byte present, no ASCII run ⇒ oracle says unproven.
    try check(az, 3, false, "\xc3\xa9 ab \xc3\xa9");
    // Projection but an ASCII run suffices ⇒ hit (accept never defers).
    try check(az, 3, false, "\xc3\xa9 abc");
    // Projection over pure ASCII ⇒ miss is final.
    try check(az, 3, false, "AB CD 99");
}

// ── run geometry: seams, carries, tails ──────────────────────────────────────

test "classrun: run straddling the 64-byte block seam" {
    const az = rangeSet('a', 'z');
    var buf = [_]u8{'.'} ** 200;
    // 10-byte run at bytes 60..69 — 4 in block 0, 6 in block 1.
    @memset(buf[60..70], 'q');
    try check(az, 10, true, &buf);
    try check(az, 11, true, &buf);
    // Run entirely inside one block, ending exactly at the seam.
    @memset(&buf, '.');
    @memset(buf[54..64], 'q');
    try check(az, 10, true, &buf);
    try check(az, 11, true, &buf);
}

test "classrun: min beyond one block rides the carry across whole blocks" {
    const az = rangeSet('a', 'z');
    var buf = [_]u8{'.'} ** 400;
    @memset(buf[10..217], 'm'); // 207-byte run spanning 4 seams
    try check(az, 200, true, &buf);
    try check(az, 207, true, &buf);
    try check(az, 208, true, &buf);
    try check(az, 65, true, &buf);
}

test "classrun: run living entirely in the scalar tail" {
    const az = rangeSet('a', 'z');
    var buf = [_]u8{'.'} ** 100; // 64-byte block + 36-byte tail
    @memset(buf[70..75], 'k');
    try check(az, 5, true, &buf);
    try check(az, 6, true, &buf);
}

test "classrun: vector carry continues into the tail" {
    const az = rangeSet('a', 'z');
    var buf = [_]u8{'.'} ** 70;
    @memset(buf[60..70], 'k'); // 4 vector bytes + 6 tail bytes
    try check(az, 10, true, &buf);
    try check(az, 11, true, &buf);
}

test "classrun: sub-block haystack takes the pure scalar path" {
    const az = rangeSet('a', 'z');
    try check(az, 3, true, "xy");
    try check(az, 3, true, "xyz");
    try check(az, 63, true, "a" ** 63);
}

test "classrun: all-member haystack at exact multiples of the block" {
    const az = rangeSet('a', 'z');
    try check(az, 64, true, "a" ** 64);
    try check(az, 65, true, "a" ** 64);
    try check(az, 128, true, "a" ** 128);
    try check(az, 129, true, "a" ** 128);
}

// ── whole-buffer line count (rg `-c` model) ──────────────────────────────────

/// The count ground truth: split on `\n` (terminator model — no phantom final
/// line), tally lines whose scalar scan hits. Valid only for the counting
/// regime (`exact` + `nl_free`), which is all `countLines` accepts.
fn oracleCount(bits: [4]u64, min: u32, hay: []const u8) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < hay.len) {
        const end = std.mem.indexOfScalarPos(u8, hay, i, '\n') orelse hay.len;
        if (oracle(bits, min, true, hay[i..end]) == .hit) n += 1;
        i = end + 1;
    }
    return n;
}

fn checkCount(bits: [4]u64, min: u32, hay: []const u8) !void {
    const want = oracleCount(bits, min, hay);
    var cr = ClassRun.build(bits, min, true, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(want, cr.countLines(hay));
    cr.backend = .{ .nibbles = classrun.nibbleTables(bits) };
    try std.testing.expectEqual(want, cr.countLines(hay));
}

test "classrun countLines: line model — terminator, tail line, empty lines" {
    const az = rangeSet('a', 'z');
    try checkCount(az, 3, "abc\n..\nxyz\n");
    try checkCount(az, 3, "abc\n..\nxyz"); // unterminated tail line counts
    try checkCount(az, 3, "abc\n\n\nabc\n"); // empty lines never count (min ≥ 1)
    try checkCount(az, 1, "");
    try checkCount(az, 4, "abc\nabcd\nab\nabcde\n");
}

test "classrun countLines: hit jump lands mid-block and resumes cleanly" {
    const az = rangeSet('a', 'z');
    // Long lines where the run completes early — the jump skips the rest.
    var buf: [300]u8 = @splat('.');
    @memset(buf[2..12], 'q');
    buf[150] = '\n';
    @memset(buf[151..161], 'q');
    try checkCount(az, 5, &buf);
    try checkCount(az, 11, &buf);
}

test "classrun countLines: differential fuzz vs per-line oracle" {
    var prng = std.Random.DefaultPrng.init(0xc0_57_5eed);
    const rnd = prng.random();
    var buf: [768]u8 = undefined;

    for (0..2000) |_| {
        var bits: [4]u64 = @splat(0);
        for (0..rnd.intRangeAtMost(usize, 1, 3)) |_| {
            const lo = rnd.int(u8);
            const hi = lo +| rnd.intRangeAtMost(u8, 0, 40);
            var b: usize = lo;
            while (b <= hi) : (b += 1) B64.set(&bits, b);
        }
        if (rnd.boolean()) for (0..8) |_| B64.set(&bits, rnd.int(u8));
        B64.clear(&bits, '\n'); // counting regime: nl_free by construction

        const min = rnd.intRangeAtMost(u32, 1, 90);
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        const hay = buf[0..len];
        for (hay) |*b| b.* = rnd.int(u8);
        // Sprinkle newlines so the corpus has real lines, then plant a
        // member run biased onto a 64-byte seam (same geometry as the
        // boolean fuzz — the carry+jump interplay is what's under test).
        for (0..len / 24) |_| buf[rnd.intRangeAtMost(usize, 0, len - 1)] = '\n';
        if (len > 0 and rnd.boolean()) {
            const member: ?u8 = blk: {
                const start = rnd.int(u8);
                for (0..256) |k| {
                    const b: u8 = start +% @as(u8, @intCast(k));
                    if (B64.get(&bits, b)) break :blk b;
                }
                break :blk null;
            };
            if (member) |m| {
                const want: usize = @max(1, @min(len, min + rnd.intRangeAtMost(u32, 0, 2) -| rnd.intRangeAtMost(u32, 0, 2)));
                const seam = (rnd.intRangeAtMost(usize, 0, len / 64) * 64) -| rnd.intRangeAtMost(usize, 0, want);
                const at = @min(seam, len - want);
                @memset(buf[at..][0..want], m);
            }
        }
        try checkCount(bits, min, hay);
    }
}

// ── codepoint mode: full-class resolution (no `.unproven`) ───────────────────

/// Codepoint-level ground truth: decode UTF-8 one codepoint at a time (ASCII
/// consults the byte set, higher codepoints the ranges; anything undecodable
/// breaks the run and advances one byte) and ask for a ≥ `min` codepoint run.
fn oracleCp(bits: [4]u64, ranges: []const [2]u21, min: u32, hay: []const u8) bool {
    var run: u64 = 0;
    var i: usize = 0;
    while (i < hay.len) {
        var member = false;
        var step: usize = 1;
        const b = hay[i];
        if (b < 0x80) {
            member = B64.get(&bits, b);
        } else if (std.unicode.utf8ByteSequenceLength(b) catch null) |n| {
            if (i + n <= hay.len) {
                if (std.unicode.utf8Decode(hay[i..][0..n]) catch null) |c| {
                    step = n;
                    for (ranges) |r| {
                        if (c >= r[0] and c <= r[1]) member = true;
                    }
                }
            }
        }
        run = if (member) run + 1 else 0;
        if (run >= min) return true;
        i += step;
    }
    return false;
}

/// Codepoint-mode line-count ground truth (rg `-c` model over `oracleCp`).
fn oracleCpCount(bits: [4]u64, ranges: []const [2]u21, min: u32, hay: []const u8) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < hay.len) {
        const end = std.mem.indexOfScalarPos(u8, hay, i, '\n') orelse hay.len;
        n += @intFromBool(oracleCp(bits, ranges, min, hay[i..end]));
        i = end + 1;
    }
    return n;
}

/// Assert the cp-carrying kernel is FINAL and right on both backends: `scan`
/// never answers `.unproven`, and `countLines` matches the per-line oracle.
fn checkCp(bits: [4]u64, ranges: []const [2]u21, min: u32, hay: []const u8) !void {
    const want: Verdict = if (oracleCp(bits, ranges, min, hay)) .hit else .miss;
    var cr = ClassRun.build(bits, min, false, ranges) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(want, cr.scan(hay));
    cr.backend = .{ .nibbles = classrun.nibbleTables(bits) };
    try std.testing.expectEqual(want, cr.scan(hay));
    if (cr.nl_free) {
        const wc = oracleCpCount(bits, ranges, min, hay);
        errdefer std.debug.print("cpcount bits={any} min={d} ranges={any}\nhay={x}\n", .{ bits, min, ranges, hay });
        try std.testing.expectEqual(wc, cr.countLines(hay));
    }
}

test "classrun cp: high codepoints extend runs the projection can't see" {
    // [a-zé] under Unicode: ASCII projection is [a-z]; é (U+00E9) is a member.
    const az = rangeSet('a', 'z');
    const ranges: []const [2]u21 = &.{ .{ 'a', 'z' }, .{ 0xE9, 0xE9 } };
    try checkCp(az, ranges, 3, "ab\xc3\xa9 ..."); // a b é — 3 codepoints
    try checkCp(az, ranges, 4, "ab\xc3\xa9 ..."); // only 3
    try checkCp(az, ranges, 3, "\xc3\xa9\xc3\xa9\xc3\xa9"); // £ééé alone
    try checkCp(az, ranges, 1, "\xc3\xa8"); // è: high byte, NON-member — final miss
    try checkCp(az, ranges, 2, "x\xc3\xa9y\n\xc3\xa9\xc3\xa9\n..\n");
}

test "classrun cp: invalid UTF-8 breaks the run like the automaton would" {
    const az = rangeSet('a', 'z');
    const ranges: []const [2]u21 = &.{ .{ 'a', 'z' }, .{ 0x80, 0x10FFFF } };
    try checkCp(az, ranges, 3, "ab\xc3(cd"); // truncated é splits ab / cd
    try checkCp(az, ranges, 2, "ab\xc3(cd");
    try checkCp(az, ranges, 1, "\xff\xfe\x80"); // nothing decodable
    try checkCp(az, ranges, 2, "a\x80b"); // bare continuation byte
}

test "classrun cp: surrogate-touching ranges decline resolution" {
    try std.testing.expect(!ClassRun.cpResolvable(&.{.{ 0xD800, 0xDFFF }}));
    try std.testing.expect(!ClassRun.cpResolvable(&.{.{ 0x20, 0xE000 }}));
    try std.testing.expect(ClassRun.cpResolvable(&.{ .{ 'a', 'z' }, .{ 0xE000, 0x10FFFF } }));
}

test "classrun cp: differential fuzz — mixed ASCII, UTF-8, and junk bytes" {
    var prng = std.Random.DefaultPrng.init(0xc0de_9017_5eed);
    const rnd = prng.random();
    var buf: [768]u8 = undefined;

    for (0..2000) |_| {
        // ASCII half of the class: a couple of ranges.
        var bits: [4]u64 = @splat(0);
        var lo0: u8 = rnd.intRangeAtMost(u8, 0, 0x7F);
        for (0..rnd.intRangeAtMost(usize, 1, 2)) |_| {
            const hi0 = @min(0x7F, lo0 +| rnd.intRangeAtMost(u8, 0, 30));
            var b: usize = lo0;
            while (b <= hi0) : (b += 1) B64.set(&bits, b);
            lo0 = hi0 +| 1;
        }
        B64.clear(&bits, '\n');
        // Codepoint half: the matching ASCII ranges plus 1–2 high ranges.
        var ranges_buf: [8][2]u21 = undefined;
        var nr: usize = 0;
        for (0..0x80) |c| {
            if (!B64.get(&bits, @intCast(c))) continue;
            const start: u21 = @intCast(c);
            var end = start;
            var cc = c + 1;
            while (cc < 0x80 and B64.get(&bits, @intCast(cc))) : (cc += 1) end = @intCast(cc);
            ranges_buf[nr] = .{ start, end };
            nr += 1;
            if (nr == 6) break;
        }
        for (0..rnd.intRangeAtMost(usize, 1, 2)) |_| {
            if (nr == 8) break;
            const lo: u21 = rnd.intRangeAtMost(u21, 0x80, 0x2FFF);
            ranges_buf[nr] = .{ lo, lo +| rnd.intRangeAtMost(u21, 0, 0x400) };
            nr += 1;
        }
        // The kernel requires the parser's invariant: sorted + coalesced.
        std.mem.sort([2]u21, ranges_buf[0..nr], {}, struct {
            fn lt(_: void, a: [2]u21, b: [2]u21) bool {
                return a[0] < b[0];
            }
        }.lt);
        var w: usize = 0;
        for (ranges_buf[0..nr]) |r| {
            if (w > 0 and r[0] <= ranges_buf[w - 1][1] +| 1) {
                ranges_buf[w - 1][1] = @max(ranges_buf[w - 1][1], r[1]);
            } else {
                ranges_buf[w] = r;
                w += 1;
            }
        }
        const ranges = ranges_buf[0..w];

        const min = rnd.intRangeAtMost(u32, 1, 20);
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        var i: usize = 0;
        while (i < len) {
            switch (rnd.intRangeAtMost(u8, 0, 9)) {
                0...5 => { // plain ASCII (bias toward members for real runs)
                    buf[i] = if (rnd.boolean()) rnd.intRangeAtMost(u8, 0x20, 0x7E) else blk: {
                        for (0..0x80) |k| {
                            const b: u8 = @intCast((k + rnd.intRangeAtMost(usize, 0, 0x7F)) % 0x80);
                            if (B64.get(&bits, b)) break :blk b;
                        }
                        break :blk 'q';
                    };
                    i += 1;
                },
                6, 7 => { // a valid codepoint, member-biased, near range edges
                    const pick = ranges[rnd.intRangeAtMost(usize, 0, ranges.len - 1)];
                    const c: u21 = if (rnd.boolean()) pick[rnd.intRangeAtMost(usize, 0, 1)] else rnd.intRangeAtMost(u21, 0x80, 0x3FFF);
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &tmp) catch 1;
                    if (i + n > len) {
                        buf[i] = '.';
                        i += 1;
                    } else {
                        @memcpy(buf[i..][0..n], tmp[0..n]);
                        i += n;
                    }
                },
                8 => { // raw junk: continuations, truncations, 0xFF
                    buf[i] = rnd.intRangeAtMost(u8, 0x80, 0xFF);
                    i += 1;
                },
                else => {
                    buf[i] = '\n';
                    i += 1;
                },
            }
        }
        try checkCp(bits, ranges, min, buf[0..len]);
    }
}

// ── span extraction (`-o` window rule) ───────────────────────────────────────

/// Span ground truth, straight from the window rule: at each position the
/// run length decides existence (≥ min) and the cut (lazy ? min : min(run,
/// max)), and iteration resumes at the cut — rust-regex `find_iter` over a
/// class-repetition pattern. Byte mode.
fn oracleSpans(a: std.mem.Allocator, bits: [4]u64, min: u32, max: u32, lazy: bool, hay: []const u8) ![]classrun.Span {
    var out: std.ArrayList(classrun.Span) = .empty;
    var p: usize = 0;
    while (p < hay.len) {
        var e = p;
        while (e < hay.len and B64.get(&bits, hay[e])) e += 1;
        const avail = e - p;
        if (avail >= min) {
            const cut: usize = if (lazy) min else @min(avail, max);
            try out.append(a, .{ .start = p, .end = p + cut });
            p += cut;
        } else p = e + 1;
    }
    return out.toOwnedSlice(a);
}

fn checkSpans(bits: [4]u64, min: u32, max: u32, lazy: bool, hay: []const u8) !void {
    const a = std.testing.allocator;
    const want = try oracleSpans(a, bits, min, max, lazy, hay);
    defer a.free(want);
    var cr = ClassRun.build(bits, min, true, null) orelse return error.TestUnexpectedResult;
    cr.span = true;
    cr.max = max;
    cr.lazy = lazy;
    for ([_]bool{ false, true }) |truffle| {
        if (truffle) cr.backend = .{ .nibbles = classrun.nibbleTables(bits) };
        var from: usize = 0;
        var k: usize = 0;
        while (cr.nextSpan(hay, from)) |sp| {
            errdefer std.debug.print("span #{d}: got {d}..{d}\n", .{ k, sp.start, sp.end });
            try std.testing.expect(k < want.len);
            try std.testing.expectEqual(want[k], sp);
            from = sp.end;
            k += 1;
        }
        try std.testing.expectEqual(want.len, k);
    }
}

test "classrun nextSpan: greedy chunking, bounded and unbounded" {
    const az = rangeSet('a', 'z');
    try checkSpans(az, 1, classrun.no_max, false, "foo bar..baz"); // \w+-style
    try checkSpans(az, 3, 8, false, "abcdefghijklmnopqrst x yz"); // {3,8}: 8+8+4
    try checkSpans(az, 2, 2, false, "abcde"); // {2}: 2+2, tail 1 dropped
    try checkSpans(az, 3, 8, false, "abcdefghijklmnopq"); // 17 = 8+8+1: tail < min dropped
    try checkSpans(az, 1, 1, false, "ab c");
}

test "classrun nextSpan: lazy cuts at the floor" {
    const az = rangeSet('a', 'z');
    try checkSpans(az, 2, 4, true, "aaaa"); // a{2,4}? → aa|aa
    try checkSpans(az, 1, classrun.no_max, true, "abc d"); // \w+? → a|b|c|d
    try checkSpans(az, 3, classrun.no_max, true, "ab abcde");
}

test "classrun nextSpan: runs across block seams keep exact offsets" {
    const az = rangeSet('a', 'z');
    var buf = [_]u8{'.'} ** 200;
    @memset(buf[60..75], 'q'); // straddles the 64-byte seam
    try checkSpans(az, 1, classrun.no_max, false, &buf);
    try checkSpans(az, 4, 6, false, &buf); // chunk boundary lands past the seam
    try checkSpans(az, 16, classrun.no_max, false, &buf); // run too short: no span
    @memset(&buf, 'm'); // one 200-byte run
    try checkSpans(az, 1, classrun.no_max, false, &buf);
    try checkSpans(az, 3, 64, false, &buf); // cut exactly at block width
    try checkSpans(az, 3, 65, false, &buf);
}

test "classrun nextSpan: differential fuzz vs window oracle" {
    var prng = std.Random.DefaultPrng.init(0x59a2_5eed);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    for (0..2000) |_| {
        var bits: [4]u64 = @splat(0);
        for (0..rnd.intRangeAtMost(usize, 1, 3)) |_| {
            const lo = rnd.int(u8);
            const hi = lo +| rnd.intRangeAtMost(u8, 0, 40);
            var b: usize = lo;
            while (b <= hi) : (b += 1) B64.set(&bits, b);
        }
        if (rnd.boolean()) for (0..8) |_| B64.set(&bits, rnd.int(u8));

        const min = rnd.intRangeAtMost(u32, 1, 80);
        const max = if (rnd.boolean()) classrun.no_max else min + rnd.intRangeAtMost(u32, 0, 80);
        const lazy = rnd.boolean();
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        const hay = buf[0..len];
        for (hay) |*b| b.* = rnd.int(u8);
        if (len > 0 and rnd.boolean()) { // plant a member run biased onto a seam
            const member: ?u8 = blk: {
                const start = rnd.int(u8);
                for (0..256) |k| {
                    const b: u8 = start +% @as(u8, @intCast(k));
                    if (B64.get(&bits, b)) break :blk b;
                }
                break :blk null;
            };
            if (member) |m| {
                const want: usize = @max(1, @min(len, min + rnd.intRangeAtMost(u32, 0, 2) -| rnd.intRangeAtMost(u32, 0, 2)));
                const seam = (rnd.intRangeAtMost(usize, 0, len / 64) * 64) -| rnd.intRangeAtMost(usize, 0, want);
                const at = @min(seam, len - want);
                @memset(buf[at..][0..want], m);
            }
        }
        try checkSpans(bits, min, max, lazy, hay);
    }
}

/// Codepoint-mode span ground truth: the same window rule with runs counted
/// in decoded codepoints (invalid UTF-8 breaks and advances one byte).
fn oracleSpansCp(a: std.mem.Allocator, bits: [4]u64, ranges: []const [2]u21, min: u32, max: u32, lazy: bool, hay: []const u8) ![]classrun.Span {
    var out: std.ArrayList(classrun.Span) = .empty;
    var p: usize = 0;
    while (p < hay.len) {
        // Walk the run from p, tracking the byte end of the cut-length prefix.
        var e = p;
        var n: u64 = 0;
        const cap: u64 = if (lazy) min else if (max == classrun.no_max) std.math.maxInt(u64) else max;
        var cut_end: usize = p;
        while (e < hay.len and n < cap) {
            const b = hay[e];
            var member = false;
            var step: usize = 1;
            if (b < 0x80) {
                member = B64.get(&bits, b);
            } else if (std.unicode.utf8ByteSequenceLength(b) catch null) |sl| {
                if (e + sl <= hay.len) {
                    if (std.unicode.utf8Decode(hay[e..][0..sl]) catch null) |c| {
                        step = sl;
                        for (ranges) |r| {
                            if (c >= r[0] and c <= r[1]) member = true;
                        }
                    }
                }
            }
            if (!member) break;
            e += step;
            n += 1;
            cut_end = e;
        }
        if (n >= min) {
            try out.append(a, .{ .start = p, .end = cut_end });
            p = cut_end;
        } else {
            // Advance one codepoint (or one byte on junk) past p.
            const b = hay[p];
            const sl = if (b < 0x80) 1 else std.unicode.utf8ByteSequenceLength(b) catch 1;
            // A non-member decodable codepoint skips whole; junk skips a byte.
            p += if (p + sl <= hay.len and (std.unicode.utf8ValidateSlice(hay[p..][0..@min(sl, hay.len - p)]))) sl else 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn checkSpansCp(bits: [4]u64, ranges: []const [2]u21, min: u32, max: u32, lazy: bool, hay: []const u8) !void {
    const a = std.testing.allocator;
    const want = try oracleSpansCp(a, bits, ranges, min, max, lazy, hay);
    defer a.free(want);
    var cr = ClassRun.build(bits, min, false, ranges) orelse return error.TestUnexpectedResult;
    cr.span = true;
    cr.max = max;
    cr.lazy = lazy;
    for ([_]bool{ false, true }) |truffle| {
        if (truffle) cr.backend = .{ .nibbles = classrun.nibbleTables(bits) };
        var from: usize = 0;
        var k: usize = 0;
        while (cr.nextSpan(hay, from)) |sp| {
            errdefer std.debug.print("cp span #{d}: got {d}..{d} want {any}\n", .{ k, sp.start, sp.end, if (k < want.len) want[k] else null });
            try std.testing.expect(k < want.len);
            try std.testing.expectEqual(want[k], sp);
            from = sp.end;
            k += 1;
        }
        try std.testing.expectEqual(want.len, k);
    }
}

test "classrun nextSpan cp: codepoint counts, byte offsets" {
    const az = rangeSet('a', 'z');
    const ranges: []const [2]u21 = &.{ .{ 'a', 'z' }, .{ 0xE9, 0xE9 } };
    try checkSpansCp(az, ranges, 1, classrun.no_max, false, "ab\xc3\xa9 x\xc3\xa8y"); // abé | x | y (è non-member)
    try checkSpansCp(az, ranges, 2, 3, false, "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9"); // éééé: 3 cp + tail 1 < 2
    try checkSpansCp(az, ranges, 1, 2, true, "ab\xc3\xa9cd"); // lazy singles
    try checkSpansCp(az, ranges, 2, classrun.no_max, false, "a\xffb\xc3\xa9"); // junk splits
}

// ── differential fuzz: random sets × plants on the seams ─────────────────────

test "classrun: differential fuzz vs scalar oracle, both backends" {
    var prng = std.Random.DefaultPrng.init(0x5eed_c1a5_5e75);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    for (0..2000) |_| {
        // A random set: sometimes a few ranges (lane backend), sometimes salt
        // (truffle) — `check` forces truffle on every case anyway.
        var bits: [4]u64 = @splat(0);
        for (0..rnd.intRangeAtMost(usize, 1, 3)) |_| {
            const lo = rnd.int(u8);
            const hi = lo +| rnd.intRangeAtMost(u8, 0, 40);
            var b: usize = lo;
            while (b <= hi) : (b += 1) B64.set(&bits, b);
        }
        if (rnd.boolean()) for (0..8) |_| B64.set(&bits, rnd.int(u8));

        const min = rnd.intRangeAtMost(u32, 1, 100);
        const exact = rnd.boolean();
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        const hay = buf[0..len];
        for (hay) |*b| b.* = rnd.int(u8);
        // Plant a member run of a length near `min` at a position biased onto
        // a block seam — the geometry uniform noise almost never produces.
        if (len > 0 and rnd.boolean()) {
            const member: ?u8 = blk: {
                const start = rnd.int(u8);
                for (0..256) |k| {
                    const b: u8 = start +% @as(u8, @intCast(k));
                    if (B64.get(&bits, b)) break :blk b;
                }
                break :blk null;
            };
            if (member) |m| {
                const want: usize = @max(1, @min(len, min + rnd.intRangeAtMost(u32, 0, 2) -| rnd.intRangeAtMost(u32, 0, 2)));
                const seam = (rnd.intRangeAtMost(usize, 0, len / 64) * 64) -| rnd.intRangeAtMost(usize, 0, want);
                const at = @min(seam, len - want);
                @memset(buf[at..][0..want], m);
            }
        }
        try check(bits, min, exact, hay);
    }
}
