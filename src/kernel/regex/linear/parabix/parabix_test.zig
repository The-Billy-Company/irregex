//! gist — the Parabix rung held to three oracles, weakest first.
//!
//! 1. `plane.transposeScalar` — the transposition's definition, so the shuffle
//!    ladder is checked against what a basis plane MEANS.
//! 2. `stencil.scalarStream` — `ByteSet.has`, so a compiled class circuit is
//!    checked against membership itself, over random sets rather than the tidy
//!    ranges real patterns use.
//! 3. **The Pike VM** — the engine's proven oracle, over randomized patterns
//!    from the admitted grammar and randomized haystacks, at line grain and at
//!    document grain, with block and stripe boundaries deliberately straddled.
//!
//! And the gate, which is checked FAIL-CLOSED: for each refusal reason there is
//! a pattern that must produce exactly that reason. The nested-Kleene case is
//! asserted twice — that the pattern really is star-height 2, and that the rung
//! refuses it — because "we measured it slow" and "it cannot reach the kernel"
//! are different claims and only the second one is the contract.
//!
//! Every helper below drives the `planFor`/`buildFor` seam with the target
//! predicate forced ON, and that is deliberate. `.target` is a refusal about
//! WHERE the throughput was measured, not about what the pattern means: it is
//! decided first and short-circuits every other verdict, so a suite that went
//! through the production entrance would, off AArch64, assert nothing but a
//! column of `.target`s while its own vacuity floors failed. The lowering and
//! the marker chain are portable Zig, so forcing the predicate runs all three
//! oracles wherever CI runs — which is the only arrangement in which a
//! cross-architecture divergence in this machinery is caught by us and not by a
//! user. The target verdict itself keeps its own test, through the same seam.

const std = @import("std");
const builtin = @import("builtin");
/// brigade, the test runner, is this binary's root module. `note` is its stdout
/// channel — where a green test's verdict counts belong, since Zig renders any
/// step's stderr through its failure printer even when the step passed.
const brigade = @import("root");
const syn = @import("../../syntax/syntax.zig");
const lower = @import("../program/lower.zig");
const core = @import("../program/core.zig");
const search = @import("../pike/search.zig");
const plane = @import("plane.zig");
const stencil = @import("stencil.zig");
const admit = @import("admit.zig");
const parabix = @import("parabix.zig");
const ladder = @import("../ladder/rungs.zig");

const Regex = core.Regex;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Parse `pattern` into an arena-backed AST. The caller owns the arena.
fn ast(arena: std.mem.Allocator, pattern: []const u8) !*syn.Node {
    return lower.parse(arena, pattern, .{});
}

/// Plan a pattern with no rival armed and the target predicate forced on — the
/// gate question we want to isolate is "is this pattern's SHAPE admissible", not
/// "is something cheaper available" and not "was this build's architecture the
/// one the throughput was measured on". `.target` short-circuits every other
/// verdict, so on any non-AArch64 host the shape gates below would read as a
/// row of `.target`s and prove nothing about the shapes. The one test that owns
/// the target verdict asserts it directly, through the same seam.
fn planOf(arena: std.mem.Allocator, pattern: []const u8) !admit.Plan {
    return admit.planFor(true, try ast(arena, pattern), .{});
}

fn declineOf(arena: std.mem.Allocator, pattern: []const u8) !?admit.Decline {
    return switch (try planOf(arena, pattern)) {
        .admitted => null,
        .declined => |d| d,
    };
}

/// Arm the rung regardless of host, for the same reason `planOf` forces the
/// predicate: the marker chain is portable Zig, so a differential run against
/// the Pike VM is meaningful on every architecture the package builds for — and
/// it is the only thing that would catch the machinery answering differently
/// somewhere the rung declines to ship.
fn buildOf(arena: std.mem.Allocator, pattern: []const u8) !?parabix.Parabix {
    return switch (parabix.Parabix.buildFor(true, try ast(arena, pattern), .{})) {
        .armed => |px| px,
        .declined => null,
    };
}

fn buildOpts(arena: std.mem.Allocator, pattern: []const u8, opts: lower.Options) !?parabix.Parabix {
    const model: admit.Model = .{
        .grain = if (opts.multiline) .buffer else .lines,
        .unicode_words = opts.unicode,
    };
    return switch (parabix.Parabix.buildFor(true, try lower.parse(arena, pattern, opts), model)) {
        .armed => |px| px,
        .declined => null,
    };
}

/// The transposition's planes as the integers its scalar definition speaks in.
fn bitsOf(basis: plane.Basis) [8]plane.Block {
    var out: [8]plane.Block = undefined;
    inline for (0..8) |k| out[k] = plane.bits(basis[k]);
    return out;
}

// ── oracle 1: the transposition ──

test "parabix/plane: transpose ≡ its scalar definition over random blocks" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rnd = prng.random();
    for (0..2000) |_| {
        var src: [plane.width]u8 = undefined;
        rnd.bytes(&src);
        try expectEqual(plane.transposeScalar(&src), bitsOf(plane.transpose(&src)));
    }
}

test "parabix/plane: transpose is exact on the adversarial byte patterns" {
    // Single-bit bytes catch a plane swapped with its neighbor; 0x00/0xFF
    // catch a whole plane inverted; a positional ramp catches a lane rotation.
    var src: [plane.width]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    try expectEqual(plane.transposeScalar(&src), bitsOf(plane.transpose(&src)));
    inline for (0..8) |k| {
        @memset(&src, @as(u8, 1) << k);
        try expectEqual(plane.transposeScalar(&src), bitsOf(plane.transpose(&src)));
    }
    @memset(&src, 0);
    try expectEqual(plane.transposeScalar(&src), bitsOf(plane.transpose(&src)));
    @memset(&src, 0xFF);
    try expectEqual(plane.transposeScalar(&src), bitsOf(plane.transpose(&src)));
}

test "parabix/plane: a stripe transposes to its blocks' planes" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0002);
    const rnd = prng.random();
    for (0..200) |_| {
        var src: [plane.stripe_width]u8 = undefined;
        rnd.bytes(&src);
        const wideb = plane.transposeStripe(&src);
        inline for (0..plane.stripe) |b| {
            const one = plane.transposeScalar(src[b * plane.width ..][0..plane.width]);
            inline for (0..8) |k| try expectEqual(one[k], plane.blockOf(wideb[k], b));
        }
    }
}

test "parabix/plane: shift and add thread their carries across the seam" {
    // Two blocks as one 256-bit integer: shifting the pair through `shiftIn`
    // must equal shifting the integer, and likewise for `addIn`.
    var prng = std.Random.DefaultPrng.init(0x5EED_0003);
    const rnd = prng.random();
    for (0..2000) |_| {
        const lo = rnd.int(u128);
        const hi = rnd.int(u128);
        const whole: u256 = (@as(u256, hi) << 128) | lo;
        const s = rnd.intRangeAtMost(u8, 1, 127);

        var carry: u128 = 0;
        const olo = plane.shiftIn(lo, s, &carry);
        const ohi = plane.shiftIn(hi, s, &carry);
        const want: u256 = (whole << s) & std.math.maxInt(u256);
        try expectEqual(@as(u128, @truncate(want)), olo);
        try expectEqual(@as(u128, @truncate(want >> 128)), ohi);

        const blo = rnd.int(u128);
        const bhi = rnd.int(u128);
        const other: u256 = (@as(u256, bhi) << 128) | blo;
        carry = 0;
        const slo = plane.addIn(lo, blo, &carry);
        const shi = plane.addIn(hi, bhi, &carry);
        const sum = whole +% other;
        try expectEqual(@as(u128, @truncate(sum)), slo);
        try expectEqual(@as(u128, @truncate(sum >> 128)), shi);
    }
}

// ── oracle 2: the class circuits ──

test "parabix/stencil: a compiled circuit ≡ ByteSet.has over random sets" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0010);
    const rnd = prng.random();
    var built: usize = 0;
    for (0..400) |_| {
        var set = syn.ByteSet{};
        // A mix of shapes: a few ranges (what real classes are), and scattered
        // members (what stresses the mux tree).
        switch (rnd.intRangeLessThan(u8, 0, 3)) {
            0 => for (0..rnd.intRangeAtMost(u8, 1, 4)) |_| {
                const lo = rnd.int(u8);
                set.setRange(lo, lo +| rnd.intRangeAtMost(u8, 0, 40));
            },
            1 => for (0..rnd.intRangeAtMost(u8, 1, 12)) |_| set.set(rnd.int(u8)),
            else => {
                set.setRange(0, 255);
                for (0..rnd.intRangeAtMost(u8, 1, 6)) |_| set.remove(rnd.int(u8));
            },
        }
        const circuit = stencil.compile(&set) orelse continue;
        built += 1;

        var src: [plane.width]u8 = undefined;
        rnd.bytes(&src);
        var vals: stencil.Scratch(plane.Lane) = undefined;
        const basis = plane.transpose(&src);
        try expectEqual(stencil.scalarStream(&set, &src), plane.bits(circuit.eval(plane.Lane, &basis, &vals)));
    }
    // The scattered/negated shapes must not ALL be declining, or this test
    // would be vacuous.
    try expect(built > 100);
}

test "parabix/stencil: the wide grain agrees with the block grain" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0011);
    const rnd = prng.random();
    var set = syn.ByteSet{};
    set.setRange('a', 'z');
    set.setRange('0', '9');
    const circuit = stencil.compile(&set).?;
    for (0..200) |_| {
        var src: [plane.stripe_width]u8 = undefined;
        rnd.bytes(&src);
        var vals: stencil.Scratch(plane.Wide) = undefined;
        const basis = plane.transposeStripe(&src);
        const got = circuit.eval(plane.Wide, &basis, &vals);
        inline for (0..plane.stripe) |b| {
            const chunk = src[b * plane.width ..][0..plane.width];
            try expectEqual(stencil.scalarStream(&set, chunk), plane.blockOf(got, b));
        }
    }
}

test "parabix/stencil: the degenerate sets compile to constants" {
    var empty = syn.ByteSet{};
    const ec = stencil.compile(&empty).?;
    try expectEqual(@as(u8, 0), ec.n);
    var full = syn.ByteSet{};
    full.setRange(0, 255);
    const fc = stencil.compile(&full).?;
    try expectEqual(@as(u8, 0), fc.n);

    var src: [plane.width]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var vals: stencil.Scratch(plane.Lane) = undefined;
    const basis = plane.transpose(&src);
    try expectEqual(@as(plane.Block, 0), plane.bits(ec.eval(plane.Lane, &basis, &vals)));
    try expectEqual(~@as(plane.Block, 0), plane.bits(fc.eval(plane.Lane, &basis, &vals)));
}

// ── the gate, fail-closed ──

test "parabix/gate: nested Kleene is star-height 2 AND is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The published collapse case, in the three spellings a real query uses.
    for ([_][]const u8{ "(a*)*", "(a*)+", "([a-z]+)+", "(\\w*)*b" }) |p| {
        try expect(admit.starHeight(try ast(a, p)) >= 2);
        try expectEqual(admit.Decline.star_height, (try declineOf(a, p)).?);
    }
    // And the flat spellings that must still be admitted, so the gate is not
    // simply refusing everything with a star in it.
    for ([_][]const u8{ "[a-z]*x", "[a-z]+[0-9]", "a[a-z]*b" }) |p| {
        try expectEqual(@as(?admit.Decline, null), try declineOf(a, p));
    }
}

test "parabix/gate: admission publishes its own economics without rival booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast(arena.allocator(), "[a-z]+[0-9]");
    const candidate = admit.planFor(true, node, .{}).admitted;
    try expect(candidate.economics.stripe_ops > 0);
    try expect(candidate.economics.catalogue_classes == 2);
    try expect(candidate.economics.fallback_classes == 0);
    try expectEqual(candidate.program.stripeOps(), candidate.economics.stripe_ops);
}

test "parabix/gate: a build with no shuffle unit leaves the field null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast(arena.allocator(), "[a-z]+[0-9]");
    try expectEqual(admit.Decline.target, admit.planFor(false, node, .{}).declined);
    try expect(admit.planFor(true, node, .{}) == .admitted);
}

test "parabix/gate: the target refusal is about the shuffle unit, not the architecture" {
    // The predicate this pins used to read `arch == .aarch64`, which refused
    // every x86-64 host for a reason that was never about x86: the comment
    // defending it cited a THROUGHPUT measurement, and an unmeasured target is
    // the price plane's business, not the instruction set's. Asserting the two
    // conjuncts separately is what keeps them from re-merging — a future edit
    // that folds pricing back into the capability fails here rather than
    // quietly switching a whole architecture off again.
    try expectEqual(
        builtin.cpu.arch.endian() == .little and
            (builtin.cpu.has(.aarch64, .neon) or builtin.cpu.has(.x86, .ssse3)),
        parabix.vectorized,
    );

    // Little-endian is CORRECTNESS, not speed: `plane.bits` reinterprets a lane
    // vector as the marker chain's `u128` and needs lane i bit g to be position
    // 8i+g. A big-endian build must decline however many shuffle units it has.
    if (comptime builtin.cpu.arch.endian() == .big) try expect(!parabix.vectorized);

    // And the capability alone never arms the rung. On a target with the
    // instruction but no minted price, the ladder still withholds it — the
    // conjunction lives in `rungs.zig` precisely so this file cannot claim
    // otherwise.
    if (comptime !ladder.price.calibrated) try expect(!ladder.parabix_armable);
}

test "parabix/gate: every other refusal reason has a witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { pat: []const u8, why: admit.Decline }{
        .{ .pat = "[a-z]*", .why = .nullable }, // `eol_empty` owns this
        .{ .pat = "[a-z][\\n]x", .why = .newline_class },
        .{ .pat = "(ab)+c", .why = .group_repeat },
        .{ .pat = "[a-z](b|c)d", .why = .nested_alt },
    };
    for (cases) |c| try expectEqual(c.why, (try declineOf(a, c.pat)).?);

    // A codepoint class is multi-byte, so membership is not a function of one
    // byte's eight bits and the basis-plane model does not apply at all.
    const uni = try lower.parse(a, "é+x", .{ .unicode = true });
    try expectEqual(admit.Decline.unicode, admit.planFor(true, uni, admit.Model{ .unicode_words = true }).declined);
}

test "parabix/assertions: Unicode word gaps, malformed UTF-8, anchors, and seams match Pike" {
    const gpa = std.testing.allocator;
    var unicode_arena = std.heap.ArenaAllocator.init(gpa);
    defer unicode_arena.deinit();
    const unicode_word = try lower.parse(unicode_arena.allocator(), "\\bfoo\\b", .{ .unicode = true });
    try expectEqual(
        admit.Decline.unicode_assertion,
        admit.planFor(true, unicode_word, .{ .unicode_words = true }).declined,
    );

    const Case = struct {
        pattern: []const u8,
        hay: []const u8,
        opts: lower.Options = .{},
        linewise: bool = false,
    };
    const malformed = [_]u8{ 0x80, 'f', 'o', 'o', 0xC3 };
    const cases = [_]Case{
        .{ .pattern = "\\bfoo\\b", .hay = " foo " },
        .{ .pattern = "\\bfoo\\b", .hay = "αfooβ" },
        .{ .pattern = "\\bfoo\\b", .hay = &malformed },
        .{ .pattern = "^foo$", .hay = "no\nfoo\nno", .linewise = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const px = (try buildOpts(arena.allocator(), case.pattern, case.opts)).?;
        var re = try Regex.compileOpts(gpa, case.pattern, case.opts);
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        var want = false;
        if (case.linewise) {
            var start: usize = 0;
            while (start <= case.hay.len) {
                const end = std.mem.indexOfScalarPos(u8, case.hay, start, '\n') orelse case.hay.len;
                if (search.lineMatchPike(&re, &sim, case.hay[start..end])) {
                    want = true;
                    break;
                }
                if (end == case.hay.len) break;
                start = end + 1;
            }
        } else want = search.lineMatchPike(&re, &sim, case.hay);
        const got = px.match(case.hay);
        if (want != got) std.debug.print(
            "assertion differential: /{s}/ on {d} bytes — pike {} parabix {}\n",
            .{ case.pattern, case.hay.len, want, got },
        );
        try expectEqual(want, got);
        try expectEqual(parabix.matchScalar(&px.prog, case.hay), px.match(case.hay));
    }

    // Put both assertions and their consuming bytes across the 128-bit seam.
    var seam: [260]u8 = @splat('!');
    @memcpy(seam[126..131], "\nfoo\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const px = (try buildOpts(arena.allocator(), "^foo$", .{ .multiline = true })).?;
    try expect(px.match(&seam));
    try expectEqual(parabix.matchScalar(&px.prog, &seam), px.match(&seam));

    const begin = (try buildOpts(arena.allocator(), "\\Afoo", .{ .multiline = true })).?;
    try expect(begin.match("foo\nfoo"));
    try expect(!begin.match("xfoo\nfoo"));
    const finish = (try buildOpts(arena.allocator(), "foo\\z", .{ .multiline = true })).?;
    try expect(finish.match("foo\nfoo"));
    try expect(!finish.match("foo\nfoox"));
    try expectEqual(parabix.matchScalar(&finish.prog, "foo\nfoo"), finish.match("foo\nfoo"));
}

test "parabix/gate: {n,m} fuses instead of exhausting the term budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const px = (try buildOf(arena.allocator(), "[a-z]{4,9}_[a-z]+")).?;
    // Nine desugared class copies plus the separator plus the tail collapse to
    // step(4) · opt(5) · step(1) · step(1) · star.
    try expectEqual(@as(u8, 5), px.prog.ninstrs);
    try expectEqual(@as(u8, 2), px.prog.nclasses); // [a-z] interned once, `_` once
}

// ── oracle 3: the Pike VM ──

/// Compile both engines from the same pattern and hold them to the same
/// haystacks. Returns false when the gate declined, so a caller can count how
/// much of its generated grammar actually reached the kernel.
fn differential(gpa: std.mem.Allocator, pattern: []const u8, hays: []const []const u8, checked: *usize) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const px = (try buildOf(arena.allocator(), pattern)) orelse return false;

    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    var sim = try Regex.Sim.init(gpa, &re);
    defer sim.deinit();

    for (hays) |hay| {
        const want = search.lineMatchPike(&re, &sim, hay);
        const got = px.match(hay);
        if (want != got) {
            std.debug.print("parabix disagrees: /{s}/ on {d} bytes — pike {} parabix {}\n", .{ pattern, hay.len, want, got });
            return error.ParabixDisagrees;
        }
        checked.* += 1;
    }
    return true;
}

/// Random patterns from the admitted grammar: classes drawn from the shapes
/// real queries use, quantified at most one level deep.
fn randomPattern(rnd: std.Random, buf: []u8) []const u8 {
    const atoms = [_][]const u8{ "[a-z]", "[0-9]", "[a-c]", "\\w", "[a-z0-9]", "x", "_", "[^a-z]", "." };
    const quants = [_][]const u8{ "", "", "", "*", "+", "?", "{2}", "{1,3}" };
    var n: usize = 0;
    const terms = rnd.intRangeAtMost(usize, 1, 4);
    for (0..terms) |_| {
        const atom = atoms[rnd.uintLessThan(usize, atoms.len)];
        const q = quants[rnd.uintLessThan(usize, quants.len)];
        if (n + atom.len + q.len > buf.len) break;
        @memcpy(buf[n..][0..atom.len], atom);
        n += atom.len;
        @memcpy(buf[n..][0..q.len], q);
        n += q.len;
    }
    return buf[0..n];
}

test "parabix/differential: randomized patterns ≡ the Pike VM, line grain" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0100);
    const rnd = prng.random();

    // Haystacks that deliberately straddle every boundary the engine has: the
    // 128-byte block, the 512-byte stripe, and the padded final block.
    const alphabet = "abcxyz019_ -.@ABZ";
    var pool: [40][]u8 = undefined;
    var nlen: usize = 0;
    const lens = [_]usize{ 0, 1, 2, 3, 7, 15, 16, 31, 63, 64, 100, 126, 127, 128, 129, 130, 200, 255, 256, 383, 384, 400, 511, 512, 513, 600, 640, 767, 768, 900, 1023, 1024, 1025, 1200, 1536, 1600, 2000, 2048, 2049, 3000 };
    for (lens) |l| {
        pool[nlen] = try gpa.alloc(u8, l);
        nlen += 1;
    }
    defer for (pool[0..nlen]) |p| gpa.free(p);

    var checked: usize = 0;
    var admitted: usize = 0;
    var declined: usize = 0;
    var pbuf: [64]u8 = undefined;
    for (0..600) |_| {
        const pattern = randomPattern(rnd, &pbuf);
        if (pattern.len == 0) continue;
        for (pool[0..nlen]) |p| {
            for (p) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        }
        var hays: [40][]const u8 = undefined;
        for (pool[0..nlen], 0..) |p, i| hays[i] = p;
        if (try differential(gpa, pattern, hays[0..nlen], &checked)) admitted += 1 else declined += 1;
    }
    // A differential that admitted nothing proves nothing.
    try expect(admitted > 100);
    try expect(checked > 5000);
    brigade.note("\n  parabix line differential: {d} verdicts over {d} admitted patterns ({d} declined)\n", .{ checked, admitted, declined });
}

test "parabix/differential: hand-picked patterns ≡ the Pike VM on shaped text" {
    const gpa = std.testing.allocator;
    // The family the rung exists for, plus the boundary shapes: a match ending
    // exactly at the last byte, one straddling a block seam, one that only
    // exists across a stripe seam.
    const pats = [_][]const u8{
        "\\w+@\\w+\\.\\w+",
        "[a-z]+[0-9]+",
        "[a-z]{3}_[a-z]+",
        "[a-z]+ [a-z]+ [a-z]+",
        ".[a-z]+.",
        "[a-z]?[0-9]{2,4}[a-z]",
        "[a-z]+x|[0-9]+y",
        "\\w{8}",
    };
    var bodies = std.ArrayList([]u8).empty;
    defer {
        for (bodies.items) |b| gpa.free(b);
        bodies.deinit(gpa);
    }
    // A match placed at every interesting offset, in a filler that cannot match.
    const needles = [_][]const u8{ "ab@cd.ef", "abc123", "abc_defg", "one two three", ".abc.", "a123x", "abcx", "abcdefgh" };
    for ([_]usize{ 0, 1, 120, 124, 126, 127, 128, 250, 380, 505, 508, 511, 512, 1020, 1024 }) |at| {
        for (needles) |nd| {
            const body = try gpa.alloc(u8, at + nd.len + 37);
            @memset(body, '!');
            @memcpy(body[at..][0..nd.len], nd);
            try bodies.append(gpa, body);
        }
    }
    var hays = try gpa.alloc([]const u8, bodies.items.len);
    defer gpa.free(hays);
    for (bodies.items, 0..) |b, i| hays[i] = b;

    var checked: usize = 0;
    var admitted: usize = 0;
    for (pats) |p| {
        if (try differential(gpa, p, hays, &checked)) admitted += 1;
    }
    try expect(admitted >= 6);
    brigade.note("  parabix shaped differential: {d} verdicts over {d} admitted patterns\n", .{ checked, admitted });
}

test "parabix/differential: document grain ≡ the per-line Pike loop" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0200);
    const rnd = prng.random();

    var doc = try gpa.alloc(u8, 5000);
    defer gpa.free(doc);

    var checked: usize = 0;
    var pbuf: [64]u8 = undefined;
    for (0..200) |_| {
        const pattern = randomPattern(rnd, &pbuf);
        if (pattern.len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const px = (try buildOf(arena.allocator(), pattern)) orelse continue;

        var re = try Regex.compile(gpa, pattern);
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();

        for (doc) |*b| {
            // Newline-dense enough that lines straddle blocks both ways.
            b.* = if (rnd.uintLessThan(u8, 40) == 0) '\n' else "abcxyz019_ -.@"[rnd.uintLessThan(usize, 14)];
        }
        // The whole-buffer scan must equal "some line matches" — the property
        // that licenses skipping the line split (no admitted class holds `\n`).
        var want = false;
        var i: usize = 0;
        while (i < doc.len) {
            const end = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse doc.len;
            if (search.lineMatchPike(&re, &sim, doc[i..end])) {
                want = true;
                break;
            }
            i = end + 1;
        }
        try expectEqual(want, px.match(doc));
        checked += 1;
    }
    try expect(checked > 50);
    brigade.note("  parabix doc differential: {d} documents\n", .{checked});
}

test "parabix/differential: the block machinery ≡ the scalar marker walk" {
    // Below the Pike differential: holds the bit-parallel chain to the marker
    // semantics read straight off the instruction list, so a disagreement
    // localizes to the block machinery rather than to the lowering.
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED_0300);
    const rnd = prng.random();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var hay: [300]u8 = undefined;
    var pbuf: [64]u8 = undefined;
    var checked: usize = 0;
    for (0..300) |_| {
        const pattern = randomPattern(rnd, &pbuf);
        if (pattern.len == 0) continue;
        const px = (try buildOf(arena.allocator(), pattern)) orelse continue;
        for (0..20) |_| {
            const n = rnd.uintLessThan(usize, hay.len);
            for (hay[0..n]) |*b| b.* = "abc019_x"[rnd.uintLessThan(usize, 8)];
            try expectEqual(parabix.matchScalar(&px.prog, hay[0..n]), px.match(hay[0..n]));
            checked += 1;
        }
    }
    try expect(checked > 1000);
}
