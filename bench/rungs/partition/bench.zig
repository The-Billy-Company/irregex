//! irregex bench — the PARTITION rung: the math floor's two collapse
//! primitives, each measured on the shape it is good at and the shape it is bad
//! at.
//!
//! Both boards here measure one idea. `refine` computes the coarsest stable
//! partition of a transition table; a DAFSA *is* a trie quotiented by that same
//! equivalence. So the rung's question is not "how fast" in the abstract but
//! **which regime**, because both primitives have one regime where they win
//! outright and one where the obvious alternative wins — and neither boundary
//! is visible from the complexity class.
//!
//! For `refine` that boundary is the reason both engines ship. Moore is O(n²·k)
//! and Hopcroft O(n·k·log n), which reads as a settled argument until you
//! measure it: on a blown-up quotient — the shape a determinizer actually hands
//! you, wide and shallow — Moore finishes in 2-6 passes and beats Hopcroft by
//! 3-4×, because Hopcroft's splitter queue and inverted delta are overhead that
//! a shallow partition never amortizes. On a chain, Moore pays one full n·k
//! sweep per state and loses by three orders of magnitude. `auto` exists to sit
//! on the right side of that line without the caller knowing where it is, and
//! the chain board is what proves it does.
//!
//! For `dafsa` the boundary is suffix sharing. A DAFSA's compression is
//! entirely the tails its keys have in common, so this board holds the key
//! count fixed and varies only how much sharing exists — which separates the
//! structure's real product (an order-preserving minimal perfect hash, O(len)
//! and pointer-free) from the compression it is usually sold on, and which it
//! does not always deliver.
//!
//! Reads only; it builds its own inputs and touches nothing shipped.

const std = @import("std");
const irregex = @import("irregex");

const refine = irregex.math.refine;
const dafsa = irregex.math.dafsa;

fn nanos() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

// ── refine ──────────────────────────────────────────────────────────────────

/// A table with a quotient known by construction: `classes` behaviour classes,
/// every state one blown-up copy of a class. A *random* delta is the degenerate
/// benchmark and the trap worth naming — nothing merges there, so refinement
/// never does any work and the board measures only queue overhead.
fn blowUp(gpa: std.mem.Allocator, n: u32, k: u32, classes: u32, rnd: std.Random) ![]u32 {
    const spec = try gpa.alloc(u32, @as(usize, classes) * k);
    defer gpa.free(spec);
    for (spec) |*s| s.* = rnd.uintLessThan(u32, classes);
    const delta = try gpa.alloc(u32, @as(usize, n) * k);
    const copies = n / classes;
    for (0..n) |s| for (0..k) |a| {
        const want = spec[@as(usize, s % classes) * k + a];
        // Any state of the target class will do, and picking a random one is
        // what makes the copies genuinely equivalent rather than merely
        // identically coloured — equivalence has to survive the successor.
        delta[s * k + a] = want + classes * rnd.uintLessThan(u32, copies);
    };
    return delta;
}

/// `s -> s-1`, and `0 -> nowhere`. Every state's distance to the end differs, so
/// the coarsest stable partition is the discrete one and it can only be reached
/// one state at a time. This is Moore's worst case stated as directly as it can
/// be stated.
fn chain(gpa: std.mem.Allocator, n: u32) ![]u32 {
    const delta = try gpa.alloc(u32, n);
    for (delta, 0..) |*d, s| d.* = if (s == 0) refine.nowhere else @intCast(s - 1);
    return delta;
}

/// Every plan over one table, with the engines checked against each other. They
/// are each other's oracle here exactly as they are in `refine_test.zig`; a
/// disagreement is a failure of the rung, not a slow row.
const Race = struct {
    moore: u64,
    hopcroft: u64,
    auto: u64,
    blocks: u32,
    passes: u32,

    fn run(gpa: std.mem.Allocator, tab: refine.Table, colour: []const u32, block: []u32) !Race {
        var a = nanos();
        const m = try refine.refine(gpa, tab, colour, block, .moore);
        const moore = nanos() - a;
        a = nanos();
        const h = try refine.refine(gpa, tab, colour, block, .hopcroft);
        const hopcroft = nanos() - a;
        a = nanos();
        const u = try refine.refine(gpa, tab, colour, block, .auto);
        const auto = nanos() - a;
        if (m.blocks != h.blocks or m.blocks != u.blocks) {
            std.debug.print(
                "FAIL: engines disagreed on {d} states — moore={d} hopcroft={d} auto={d}\n",
                .{ tab.states, m.blocks, h.blocks, u.blocks },
            );
            return error.EnginesDisagreed;
        }
        return .{ .moore = moore, .hopcroft = hopcroft, .auto = auto, .blocks = m.blocks, .passes = m.passes };
    }
};

fn quotientBoard(gpa: std.mem.Allocator) !void {
    std.debug.print(
        \\
        \\-- refine: a blown-up quotient, k=16 (the determinizer's shape) --
        \\
    , .{});
    std.debug.print("{s:>8} {s:>9} {s:>10} {s:>12} {s:>10} {s:>9} {s:>8} {s:>8}\n", .{
        "states", "classes", "moore ms", "hopcroft ms", "auto ms", "m/h", "blocks", "passes",
    });
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    const k: u32 = 16;
    for ([_]u32{ 1024, 8192, 65536 }) |n| {
        for ([_]u32{ 8, 512, n / 2 }) |classes| {
            const delta = try blowUp(gpa, n, k, classes, rnd);
            defer gpa.free(delta);
            const colour = try gpa.alloc(u32, n);
            defer gpa.free(colour);
            for (colour, 0..) |*c, s| c.* = @intFromBool(s % classes == 0);
            const block = try gpa.alloc(u32, n);
            defer gpa.free(block);

            const r = try Race.run(gpa, .{ .states = n, .symbols = k, .delta = delta }, colour, block);
            std.debug.print("{d:>8} {d:>9} {d:>10.2} {d:>12.2} {d:>10.2} {d:>9.2} {d:>8} {d:>8}\n", .{
                n,        classes,   ms(r.moore), ms(r.hopcroft),
                ms(r.auto), ms(r.moore) / ms(r.hopcroft), r.blocks, r.passes,
            });
        }
    }
}

fn chainBoard(gpa: std.mem.Allocator) !void {
    std.debug.print(
        \\
        \\-- refine: a chain, k=1 (Moore's adversary — why `auto` exists) --
        \\
    , .{});
    std.debug.print("{s:>8} {s:>10} {s:>12} {s:>10} {s:>9} {s:>9} {s:>8}\n", .{
        "states", "moore ms", "hopcroft ms", "auto ms", "m/h", "auto/h", "passes",
    });
    for ([_]u32{ 256, 1024, 4096, 16384 }) |n| {
        const delta = try chain(gpa, n);
        defer gpa.free(delta);
        const colour = try gpa.alloc(u32, n);
        defer gpa.free(colour);
        @memset(colour, 0);
        colour[0] = 1;
        const block = try gpa.alloc(u32, n);
        defer gpa.free(block);

        const r = try Race.run(gpa, .{ .states = n, .symbols = 1, .delta = delta }, colour, block);
        std.debug.print("{d:>8} {d:>10.2} {d:>12.2} {d:>10.2} {d:>9.0} {d:>9.1} {d:>8}\n", .{
            n,                            ms(r.moore), ms(r.hopcroft), ms(r.auto),
            ms(r.moore) / ms(r.hopcroft), ms(r.auto) / ms(r.hopcroft), r.passes,
        });
    }
}

// ── dafsa ───────────────────────────────────────────────────────────────────

/// One row's corpus shape. `prefixes × suffixes` keys of `head + 1 + tail`
/// bytes, so a board can hold the key count fixed and move exactly one of the
/// two things a DAFSA's size depends on: how many tails are shared, and how long
/// the unshared part is.
const Shape = struct { head: usize, tail: usize, prefixes: u32, suffixes: u32 };

fn crossKeys(gpa: std.mem.Allocator, sh: Shape) ![][]const u8 {
    const keys = try gpa.alloc([]const u8, @as(usize, sh.prefixes) * sh.suffixes);
    var buf: [64]u8 = undefined;
    const hd = digits(sh.prefixes);
    const td = digits(sh.suffixes);
    var w: usize = 0;
    for (0..sh.prefixes) |p| {
        word(p, buf[0..sh.head], hd);
        buf[sh.head] = '/';
        for (0..sh.suffixes) |s| {
            word(s, buf[sh.head + 1 ..][0..sh.tail], td);
            keys[w] = try gpa.dupe(u8, buf[0 .. sh.head + 1 + sh.tail]);
            w += 1;
        }
    }
    // Scrambled indices do not come out in byte order, and `build` requires
    // strictly increasing keys rather than sorting behind the caller's back.
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return keys;
}

/// How many base-26 positions it takes to name `n` things. Capped implicitly by
/// the caller: 26¹³ is the last power that fits a `usize`, and no row is close.
fn digits(n: u32) usize {
    var d: usize = 1;
    var span: usize = 26;
    while (span < n) : (d += 1) span *= 26;
    return d;
}

/// `out.len` lowercase letters naming `i`: the low `lo` positions carry the index
/// and the rest are stem.
///
/// Both halves are load-bearing, and each one silently ruined a version of this
/// board. The index half is `i · 3⁷ mod 26^lo`, a bijection because 3⁷ is coprime
/// to 26 — so keys are distinct and countable. Rendering `i` *unscrambled* gives
/// the cube `aaaaa, aaaab, …`, and a cube is a DAFSA's best case by two orders of
/// magnitude however the factors are split, which made the sharing axis vanish.
/// The stem half is hashed rather than left as leading zeros, because base-26 of
/// a small number is mostly `'a'`: a 25-letter key would have carried a shared
/// 19-letter run and read as an *unshared*-stem row while being the most shared
/// corpus on the board.
fn word(i: usize, out: []u8, lo: usize) void {
    var span: usize = 1;
    for (0..lo) |_| span *= 26;
    var v = (i *% 2187) % span;
    var j: usize = out.len;
    while (j > out.len - lo) : (j -= 1) {
        out[j - 1] = 'a' + @as(u8, @intCast(v % 26));
        v /= 26;
    }
    var prng: std.Random.DefaultPrng = .init(i);
    const rnd = prng.random();
    while (j > 0) : (j -= 1) out[j - 1] = 'a' + rnd.uintLessThan(u8, 26);
}

/// The DAFSA's resident bytes in the representation it actually ships: `u8`
/// label and `u8` accept per edge/state, `u32` for every start offset, target,
/// and subtree count. Quoting a packed-representation figure here would be
/// quoting a structure this package does not have.
fn held(d: *const dafsa.Dafsa) usize {
    return d.states() * 1 + (d.states() + 1) * 4 + d.edges() * 1 + d.edges() * 4 + d.states() * 4;
}

fn dafsaBoard(gpa: std.mem.Allocator, title: []const u8, shapes: []const Shape) !void {
    std.debug.print("\n-- dafsa: {s} --\n", .{title});
    std.debug.print("{s:>5} {s:>9} {s:>9} {s:>7} {s:>7} {s:>9} {s:>10} {s:>8} {s:>8}\n", .{
        "head", "prefixes", "suffixes", "states", "edges", "build ms", "held B", "vs flat", "rank ns",
    });
    for (shapes) |shape| {
        const keys = try crossKeys(gpa, shape);
        defer {
            for (keys) |k| gpa.free(k);
            gpa.free(keys);
        }
        var bytes: usize = 0;
        for (keys) |k| bytes += k.len;

        const a = nanos();
        const d = try dafsa.build(gpa, keys);
        const build_ns = nanos() - a;
        defer d.deinit(gpa);

        // A sorted array of the same keys: the bytes, plus one u32 offset each.
        // It answers membership in O(len·log n) and has no rank at all, so this
        // is a floor on the space a rank would cost, not a like-for-like rival.
        const flat = bytes + keys.len * 4;

        const probe = nanos();
        var sum: u64 = 0;
        for (0..20) |_| for (keys) |k| {
            sum += d.rank(k) orelse return error.RankLostAKey;
        };
        const rank_ns = nanos() - probe;
        if (d.count() != keys.len) return error.CountDisagreed;

        std.debug.print("{d:>5} {d:>9} {d:>9} {d:>7} {d:>7} {d:>9.2} {d:>10} {d:>8.2} {d:>8.1}\n", .{
            shape.head,
            shape.prefixes,
            shape.suffixes,
            d.states(),
            d.edges(),
            ms(build_ns),
            held(&d),
            @as(f64, @floatFromInt(flat)) / @as(f64, @floatFromInt(held(&d))),
            @as(f64, @floatFromInt(rank_ns)) / @as(f64, @floatFromInt(keys.len * 20)),
        });
        std.mem.doNotOptimizeAway(sum);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try quotientBoard(gpa);
    try chainBoard(gpa);
    // 4096 keys throughout, so only the sharing moves: 4096 distinct tails down
    // to 64 tails shared 64 ways.
    try dafsaBoard(gpa, "4096 keys, sharing varied", &.{
        .{ .head = 5, .tail = 5, .prefixes = 4096, .suffixes = 1 },
        .{ .head = 5, .tail = 5, .prefixes = 256, .suffixes = 16 },
        .{ .head = 5, .tail = 5, .prefixes = 64, .suffixes = 64 },
    });
    // The axis that actually decides the space verdict. These keys are 34 bytes
    // with an unshared 25-byte stem — a list of file paths, which is where the
    // structure is weakest — and the sweep is over how many of them there are.
    // A sorted array's cost is linear in the keys; the DAFSA's is linear in
    // *distinct* structure, so the two cross, and the crossing is the fact worth
    // knowing before reaching for one.
    try dafsaBoard(gpa, "path-shaped keys (34 B, unshared stems), count swept", &.{
        .{ .head = 25, .tail = 8, .prefixes = 128, .suffixes = 1 },
        .{ .head = 25, .tail = 8, .prefixes = 512, .suffixes = 1 },
        .{ .head = 25, .tail = 8, .prefixes = 2048, .suffixes = 1 },
        .{ .head = 25, .tail = 8, .prefixes = 8192, .suffixes = 1 },
        .{ .head = 25, .tail = 8, .prefixes = 32768, .suffixes = 1 },
    });
}

// ── the rung's own inputs, checked ───────────────────────────────────────────
//
// A board is only evidence if its input is the shape it claims. Both generators
// have a stated quotient, so both can be held to it — and a generator that
// silently stopped producing sharing would otherwise read as a result.

const t = std.testing;

test "blowUp's quotient is exactly the class count" {
    var prng: std.Random.DefaultPrng = .init(3);
    const gpa = t.allocator;
    for ([_]u32{ 4, 16, 64 }) |classes| {
        const n: u32 = classes * 8;
        const k: u32 = 4;
        const delta = try blowUp(gpa, n, k, classes, prng.random());
        defer gpa.free(delta);
        const colour = try gpa.alloc(u32, n);
        defer gpa.free(colour);
        for (colour, 0..) |*c, s| c.* = @intFromBool(s % classes == 0);
        const block = try gpa.alloc(u32, n);
        defer gpa.free(block);
        const r = try refine.refine(gpa, .{ .states = n, .symbols = k, .delta = delta }, colour, block, .auto);
        // At most `classes`, because the copies are equivalent by construction.
        // Fewer is legal — a random class spec may itself be non-minimal — so
        // the assertion is the ceiling, which is what the board's claim needs.
        try t.expect(r.blocks <= classes);
        // And the copies really did collapse: the discrete partition would be
        // `n`, which is the reading a broken generator would produce.
        try t.expect(r.blocks < n);
    }
}

test "the chain forces one pass per state" {
    const gpa = t.allocator;
    const n: u32 = 64;
    const delta = try chain(gpa, n);
    defer gpa.free(delta);
    const colour = try gpa.alloc(u32, n);
    defer gpa.free(colour);
    @memset(colour, 0);
    colour[0] = 1;
    const block = try gpa.alloc(u32, n);
    defer gpa.free(block);
    const r = try refine.refine(gpa, .{ .states = n, .symbols = 1, .delta = delta }, colour, block, .moore);
    try t.expectEqual(n, r.blocks);
    try t.expectEqual(n - 1, r.passes);
}

test "crossKeys are strictly sorted and share their tails" {
    const gpa = t.allocator;
    const keys = try crossKeys(gpa, .{ .head = 5, .tail = 5, .prefixes = 8, .suffixes = 4 });
    defer {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }
    try t.expectEqual(@as(usize, 32), keys.len);
    for (keys[1..], 0..) |k, i| try t.expect(std.mem.lessThan(u8, keys[i], k));
    // The sharing the board varies: 8 prefixes over 4 tails must beat the trie,
    // whose state count is one per distinct prefix of a key.
    const d = try dafsa.build(gpa, keys);
    defer d.deinit(gpa);
    try t.expectEqual(@as(u32, 32), d.count());
    try t.expect(d.states() < 32 * 11);
}
