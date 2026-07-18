//! irregex sketch — adversarial tests for the compression-kinship primitive.
//!
//! The contract under test is the DISTANCE's semantics, not the parse's
//! internals: identity → 0, disjoint → ~1, symmetry, determinism, robustness
//! to edits (a small edit moves the distance a little, not to 1), and the
//! load-bearing claim from the source papers — bytes cluster by KIND. The
//! fixtures are embedded (never the live tree) so the suite is deterministic
//! under ~10 agents editing the checkout concurrently.

const std = @import("std");
const sketch = @import("sketch.zig");
const Sketch = sketch.Sketch;

const gpa = std.testing.allocator;

// ── deterministic fixture text, embedded ──
// Two "languages": Zig-flavored and Python-flavored source, two samples each,
// plus an English prose sample. Kinship must pair like with like.

const zig_a =
    \\const std = @import("std");
    \\pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Sketch {
    \\    var seen = try PhraseSet.init(gpa, bytes.len / 8);
    \\    defer seen.deinit(gpa);
    \\    for (bytes) |b| { h = (h ^ b) *% fnv_prime; }
    \\    return out;
    \\}
;

const zig_b =
    \\const std = @import("std");
    \\pub fn distance(a: *const Sketch, b: *const Sketch) f64 {
    \\    const as = a.slots();
    \\    const bs = b.slots();
    \\    if (as.len == 0 or bs.len == 0) return 1.0;
    \\    return 1.0 - jaccard;
    \\}
;

const py_a =
    \\import pathlib
    \\def candidate_files(repo, literals):
    \\    rows = [rel.removeprefix("./") for rel in scan(repo, literals).split("\0") if rel]
    \\    return sorted(set(rows))
;

const py_b =
    \\import itertools
    \\def lzset(data):
    \\    seen, cur = set(), b''
    \\    for ch in data:
    \\        cur += bytes([ch])
    \\        if cur not in seen:
    \\            seen.add(cur); cur = b''
    \\    return seen
;

const prose =
    \\In this letter we present a very general method to extract information
    \\from a generic string of characters, based on data-compression techniques,
    \\whose key point is a suitable measure of the remoteness of two bodies of
    \\knowledge. The zipper learns the language and changes its rules.
;

fn dist(x: []const u8, y: []const u8) !f64 {
    var sx = try sketch.build(gpa, x);
    var sy = try sketch.build(gpa, y);
    return sketch.distance(&sx, &sy);
}

test "identity is zero; symmetry holds; range is [0,1]" {
    const fixtures = [_][]const u8{ zig_a, zig_b, py_a, py_b, prose };
    for (fixtures) |x| {
        try std.testing.expectEqual(@as(f64, 0.0), try dist(x, x));
        for (fixtures) |y| {
            const dxy = try dist(x, y);
            const dyx = try dist(y, x);
            try std.testing.expectEqual(dxy, dyx);
            try std.testing.expect(dxy >= 0.0 and dxy <= 1.0);
        }
    }
}

test "determinism: the same bytes always sketch identically" {
    var first = try sketch.build(gpa, zig_a);
    var again = try sketch.build(gpa, zig_a);
    try std.testing.expectEqualSlices(u64, first.slots(), again.slots());
}

test "kinship clusters by kind: every fixture's nearest neighbor shares its language" {
    // The paper's claim, as a fail-closed precision@1 gate over the embedded
    // corpus: for each sample, the closest OTHER sample must be its same-kind
    // sibling — zig pairs with zig, python with python.
    const corpus = [_]struct { text: []const u8, kind: u8 }{
        .{ .text = zig_a, .kind = 'z' },
        .{ .text = zig_b, .kind = 'z' },
        .{ .text = py_a, .kind = 'p' },
        .{ .text = py_b, .kind = 'p' },
        .{ .text = prose, .kind = 'e' },
    };
    var sketches: [corpus.len]Sketch = undefined;
    for (&sketches, corpus) |*s, c| s.* = try sketch.build(gpa, c.text);

    for (corpus, 0..) |c, i| {
        if (c.kind == 'e') continue; // prose has no sibling in this corpus
        var best: usize = undefined;
        var best_d: f64 = 2.0;
        for (corpus, 0..) |_, j| {
            if (j == i) continue;
            const d = sketch.distance(&sketches[i], &sketches[j]);
            if (d < best_d) {
                best_d = d;
                best = j;
            }
        }
        try std.testing.expectEqual(c.kind, corpus[best].kind);
    }
}

test "a small edit is a small move — never a cliff" {
    // Rename one identifier in zig_a; the edited text must stay far closer to
    // the original than to a different-language file.
    const edited = try std.mem.replaceOwned(u8, gpa, zig_a, "PhraseSet", "LexiconSet");
    defer gpa.free(edited);
    const d_self = try dist(zig_a, edited);
    const d_cross = try dist(zig_a, py_b);
    try std.testing.expect(d_self < d_cross);
    try std.testing.expect(d_self < 0.5); // an edit is kinship, not estrangement
}

test "disjoint alphabets are near-maximally distant" {
    // Two texts sharing no byte vocabulary: dictionaries cannot overlap.
    var upper: [4096]u8 = undefined;
    var digit: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (&upper) |*b| b.* = 'A' + r.uintLessThan(u8, 26);
    for (&digit) |*b| b.* = '0' + r.uintLessThan(u8, 10);
    const d = try dist(&upper, &digit);
    try std.testing.expect(d > 0.95);
}

test "empty and tiny inputs are total, not panics" {
    var e = try sketch.build(gpa, "");
    var one = try sketch.build(gpa, "x");
    try std.testing.expectEqual(@as(f64, 0.0), sketch.distance(&e, &e));
    try std.testing.expectEqual(@as(f64, 1.0), sketch.distance(&e, &one));
    try std.testing.expect(one.len >= 1);
}

test "sketch is bounded and sorted regardless of input size" {
    // 256 KiB of pseudo-random bytes — worst-case incompressible input still
    // yields exactly k ascending slots and touches no more memory than scratch.
    const big = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(big);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(big);
    var s = try sketch.build(gpa, big);
    try std.testing.expectEqual(@as(u16, sketch.k), s.len);
    for (s.slots()[1..], s.slots()[0 .. s.len - 1]) |next, prev|
        try std.testing.expect(prev < next);
}
