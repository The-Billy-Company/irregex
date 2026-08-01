//! codex adversarial suite — every layer differential against a naive oracle.
//!
//! Nothing here asserts a value the implementation produced for itself
//! (oracle discipline — expected values from an independent oracle, never from the code under test): suffix arrays are checked against a
//! comparison-sort oracle, ranks against prefix popcounts, occ/access against
//! literal scans, and the index's count/find/restore against std.mem searches
//! of the original text — across random, degenerate, binary, and highly
//! repetitive corpora, plus a seeded property-fuzz loop.

const std = @import("std");
const fault = @import("../../fault.zig");
const sais = @import("../math/succinct/sais.zig");
const rrr = @import("../math/succinct/rrr.zig");
const wavelet = @import("../math/succinct/wavelet.zig");
const codex = @import("codex.zig");

const testing = std.testing;

// ── oracles ──

/// O(n² log n) suffix array by direct suffix comparison (with sentinel).
fn oracleSuffixArray(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    const n = text.len + 1;
    const sa = try gpa.alloc(u32, n);
    for (sa, 0..) |*v, i| v.* = @intCast(i);
    const Ctx = struct {
        text: []const u8,
        fn lt(self: @This(), a: u32, b: u32) bool {
            // sentinel: the shorter suffix wins when one is a prefix of the other
            const sa_ = self.text[a..];
            const sb_ = self.text[b..];
            return switch (std.mem.order(u8, sa_, sb_)) {
                .lt => true,
                .gt => false,
                .eq => sa_.len < sb_.len,
            };
        }
    };
    std.mem.sort(u32, sa, Ctx{ .text = text }, Ctx.lt);
    return sa;
}

fn oracleCount(text: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    var c: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, pattern)) |p| {
        c += 1;
        i = p + 1;
    }
    return c;
}

fn oracleFind(gpa: std.mem.Allocator, text: []const u8, pattern: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    if (pattern.len > 0) while (std.mem.indexOfPos(u8, text, i, pattern)) |p| {
        try out.append(gpa, @intCast(p));
        i = p + 1;
    };
    return out.toOwnedSlice(gpa);
}

fn expectSaisMatchesOracle(text: []const u8) !void {
    const gpa = testing.allocator;
    const got = try sais.build(gpa, text);
    defer gpa.free(got);
    const want = try oracleSuffixArray(gpa, text);
    defer gpa.free(want);
    try testing.expectEqualSlices(u32, want, got);
}

/// O(n) suffix-array verification, independent of how the array was built: it
/// must be a permutation of `0..=text.len`, and every adjacent pair must be in
/// order. Adjacency is decided in O(1) from the rank of the NEXT suffix rather
/// than by comparing bytes, so this stays linear on exactly the repetitive
/// corpora that make the comparison-sort oracle above quadratic — which is
/// what lets it run at a megabyte, where the construction takes code paths a
/// 400-byte text never reaches.
fn expectValidSuffixArray(text: []const u8) !void {
    const gpa = testing.allocator;
    const sa = try sais.build(gpa, text);
    defer gpa.free(sa);
    const n = text.len + 1;
    try testing.expectEqual(n, sa.len);

    const rank = try gpa.alloc(u32, n);
    defer gpa.free(rank);
    @memset(rank, std.math.maxInt(u32));
    for (sa, 0..) |p, r| {
        try testing.expect(p < n);
        try testing.expectEqual(std.math.maxInt(u32), rank[p]); // no repeats
        rank[p] = @intCast(r);
    }

    // symbol(i): the lifted alphabet the codex indexes — byte c ↦ c+1, with a
    // unique smallest sentinel 0 at text.len.
    const sym = struct {
        fn at(t: []const u8, i: usize) u16 {
            return if (i == t.len) 0 else @as(u16, t[i]) + 1;
        }
    }.at;
    for (1..n) |r| {
        const a = sa[r - 1];
        const b = sa[r];
        const ca = sym(text, a);
        const cb = sym(text, b);
        // Equal symbols mean neither is the sentinel, so both successors exist.
        const ordered = if (ca != cb) ca < cb else rank[a + 1] < rank[b + 1];
        try testing.expect(ordered);
    }
}

// ── sais ──

test "sais: degenerate and adversarial texts match the sort oracle" {
    try expectSaisMatchesOracle("");
    try expectSaisMatchesOracle("a");
    try expectSaisMatchesOracle("aaaaaaaaaaaaaaaa"); // single-class runs
    try expectSaisMatchesOracle("abababababababab"); // period 2 — LMS naming collisions
    try expectSaisMatchesOracle("banana");
    try expectSaisMatchesOracle("mississippi");
    try expectSaisMatchesOracle("abaababaabaababaababa"); // Fibonacci word — worst-case LMS recursion
    try expectSaisMatchesOracle("zyxwvutsrqponmlkjihgfedcba"); // strictly descending: all L
    try expectSaisMatchesOracle("abcdefghijklmnopqrstuvwxyz"); // strictly ascending: all S
    try expectSaisMatchesOracle("\x00\x00\x01\x00\x00"); // NUL is ordinary content
    try expectSaisMatchesOracle("\xff\xfe\xff\xfe\x00\xff");
}

test "sais: all 256 byte values, forwards and backwards" {
    var buf: [512]u8 = undefined;
    for (0..256) |i| {
        buf[i] = @intCast(i);
        buf[511 - i] = @intCast(i);
    }
    try expectSaisMatchesOracle(buf[0..256]);
    try expectSaisMatchesOracle(&buf);
}

test "sais: property — random texts across alphabet sizes match the oracle" {
    var prng = std.Random.DefaultPrng.init(0x5a15);
    const rand = prng.random();
    const gpa = testing.allocator;
    for (0..60) |round| {
        const sigma: u8 = ([_]u8{ 1, 2, 3, 8, 255 })[round % 5];
        const len = rand.intRangeAtMost(usize, 0, 400);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 0, sigma);
        try expectSaisMatchesOracle(text);
    }
}

test "sais: megabyte corpora stay valid where the construction changes strategy" {
    // Every text above is small enough to sort naively, and a suffix sort does
    // not do at 400 bytes what it does at a megabyte: the LMS recursion goes
    // several levels deep, the bucket arrays stop fitting in cache, and the
    // scale-tuned paths of the vendored constructor take over. These shapes are
    // the ones that break induced sorting when it breaks — a binary alphabet
    // (maximal recursion depth), a pure run (every suffix in one bucket), a
    // period-2 string (LMS substrings that all name equal), and the Fibonacci
    // word (the classic worst case for LMS naming) — each checked by the linear
    // oracle rather than trusted.
    const gpa = testing.allocator;
    const mib = 1 << 20;

    var prng = std.Random.DefaultPrng.init(0x5a15_1a26);
    const binary = try gpa.alloc(u8, mib);
    defer gpa.free(binary);
    for (binary) |*c| c.* = prng.random().intRangeAtMost(u8, 0, 1);
    try expectValidSuffixArray(binary);

    const run = try gpa.alloc(u8, mib);
    defer gpa.free(run);
    @memset(run, 'a');
    try expectValidSuffixArray(run);
    for (run, 0..) |*c, i| c.* = if (i % 2 == 0) 'a' else 'b';
    try expectValidSuffixArray(run);

    // Fibonacci word: S(k) = S(k-1) ++ S(k-2), grown past a megabyte.
    var fib: std.ArrayList(u8) = .empty;
    defer fib.deinit(gpa);
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(gpa);
    try fib.appendSlice(gpa, "ab");
    try prev.append(gpa, 'a');
    while (fib.items.len < mib) {
        const next = try gpa.dupe(u8, fib.items);
        defer gpa.free(next);
        try fib.appendSlice(gpa, prev.items);
        prev.clearRetainingCapacity();
        try prev.appendSlice(gpa, next);
    }
    try expectValidSuffixArray(fib.items);
}

// ── rrr ──

fn expectBitsMatchOracle(bits: anytype, want: []const u1) !void {
    var ones: usize = 0;
    for (want, 0..) |b, i| {
        try testing.expectEqual(ones, bits.rank1(i));
        try testing.expectEqual(b, bits.get(i));
        ones += b;
    }
    try testing.expectEqual(ones, bits.rank1(want.len));
}

test "rrr: rank/get at every position, all densities, boundary lengths" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xb17);
    const rand = prng.random();
    // lengths straddle block (63) and superblock (1008) boundaries
    for ([_]usize{ 1, 62, 63, 64, 126, 127, 512, 1007, 1008, 1009, 5000 }) |len| {
        for ([_]f64{ 0.0, 0.01, 0.5, 0.99, 1.0 }) |density| {
            const want = try gpa.alloc(u1, len);
            defer gpa.free(want);
            var plain = try rrr.Plain.initEmpty(gpa, len);
            defer plain.deinit(gpa);
            for (want, 0..) |*b, i| {
                b.* = @intFromBool(rand.float(f64) < density);
                if (b.* == 1) plain.set(i);
            }
            try plain.finalize(gpa);
            // check the plain encoding, then force-transcode and check RRR too:
            // both encodings must agree with the oracle bit-for-bit
            try expectBitsMatchOracle(&plain, want);
            var enc = try rrr.Rrr.fromPlain(gpa, &plain);
            defer enc.deinit(gpa);
            try expectBitsMatchOracle(&enc, want);
        }
    }
}

test "rrr: adopt never loses space and compresses runs hard" {
    const gpa = testing.allocator;
    // run-heavy vector (BWT-shaped): RRR must win and stay correct
    const len = 100_000;
    var plain = try rrr.Plain.initEmpty(gpa, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if ((i / 3000) % 2 == 1) plain.set(i);
    }
    try plain.finalize(gpa);
    const plain_bytes = plain.sizeBytes();
    var bits = try rrr.Bits.adopt(gpa, plain);
    defer bits.deinit(gpa);
    try testing.expect(bits.sizeBytes() <= plain_bytes);
    try testing.expect(bits == .rrr or bits.sizeBytes() == plain_bytes);
    try testing.expect(bits.sizeBytes() < plain_bytes / 4); // runs price near zero
    // spot-verify semantics survived the transcode
    try testing.expectEqual(@as(usize, 0), bits.rank1(3000));
    try testing.expectEqual(@as(usize, 3000), bits.rank1(6000));
    try testing.expectEqual(@as(u1, 1), bits.get(3000));
    try testing.expectEqual(@as(u1, 0), bits.get(2999));
}

// ── wavelet ──

test "wavelet: occ and access match literal scans across alphabet shapes and encodings" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x3a7e);
    const rand = prng.random();
    for ([_]u16{ 1, 2, 5, 257 }) |sigma| {
        const seq = try gpa.alloc(u16, 3000);
        defer gpa.free(seq);
        var freq = try gpa.alloc(u64, sigma);
        defer gpa.free(freq);
        @memset(freq, 0);
        for (seq) |*c| {
            c.* = rand.intRangeLessThan(u16, 0, sigma);
            freq[c.*] += 1;
        }
        const encoding: wavelet.Encoding = if (sigma % 2 == 0) .plain_only else .adopt_min;
        var tree = try wavelet.Tree.build(gpa, seq, freq, encoding);
        defer tree.deinit(gpa);
        // access at every position; occ for every present symbol at sampled cuts
        var counts = try gpa.alloc(usize, sigma);
        defer gpa.free(counts);
        @memset(counts, 0);
        for (seq, 0..) |c, pos| {
            const a = tree.access(pos);
            try testing.expectEqual(c, a.sym);
            try testing.expectEqual(counts[c], a.occ);
            counts[c] += 1;
        }
        for (0..sigma) |sym| {
            if (freq[sym] == 0) continue;
            var running: usize = 0;
            for (seq, 0..) |c, pos| {
                if (pos % 251 == 0) try testing.expectEqual(running, tree.occ(@intCast(sym), pos));
                if (c == sym) running += 1;
            }
            try testing.expectEqual(running, tree.occ(@intCast(sym), seq.len));
        }
    }
}

// ── codex end-to-end ──

fn expectCodexFaithful(text: []const u8, opts: codex.Options, patterns: []const []const u8) !void {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, text, opts);
    defer idx.deinit(gpa);

    const rebuilt = try idx.restore(gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqualSlices(u8, text, rebuilt);

    for (patterns) |p| {
        try testing.expectEqual(oracleCount(text, p), idx.count(p));
        if (opts.sample_rate > 0) {
            const got = (try idx.find(gpa, p)).got;
            defer gpa.free(got);
            const want = try oracleFind(gpa, text, p);
            defer gpa.free(want);
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

test "codex: exact count/find/restore on adversarial corpora" {
    const overlapping = "aaaaaaaaaaaaaaaaaaaa";
    try expectCodexFaithful(overlapping, .{}, &.{ "a", "aa", "aaa", overlapping, "b", "" });
    try expectCodexFaithful("mississippi", .{ .sample_rate = 1 }, &.{ "i", "issi", "ssi", "mississippi", "mississippix", "p", "x" });
    try expectCodexFaithful("", .{}, &.{ "", "a" });
    try expectCodexFaithful("x", .{}, &.{ "x", "y", "xx" });
    // binary corpus: NULs and high bytes are ordinary content
    try expectCodexFaithful("\x00\x01\xff\x00\x01\xff\x00", .{ .sample_rate = 2 }, &.{ "\x00", "\x00\x01\xff", "\xff\x00", "\x02" });
    // both bitvector postures answer identically
    try expectCodexFaithful("the quick brown fox jumps over the lazy dog", .{ .encoding = .plain_only }, &.{ "the", "o", "quick brown", "cat" });
}

test "codex: pattern longer than text and whole-text pattern" {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, "short", .{});
    defer idx.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), idx.count("much longer than the text"));
    try testing.expectEqual(@as(usize, 1), idx.count("short"));
}

test "codex: sample_rate 0 disables locate but keeps count/restore" {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, "count only", .{ .sample_rate = 0 });
    defer idx.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), idx.count("o"));
    // Locate DECLINES rather than faulting: a mark-less codex is a smaller
    // index, not a broken one, and it still counts exactly (declinature, not a fault).
    try testing.expectEqual(fault.Decline.capability_missing, (try idx.find(gpa, "o")).declined);
    try testing.expectEqual(fault.Decline.capability_missing, idx.posOf(0).declined);
    const rebuilt = try idx.restore(gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqualSlices(u8, "count only", rebuilt);
}

test "codex: the sharded build agrees with ground truth at multi-megabyte scale" {
    // Every corpus above is far below `parallel.build_min_bytes`, so all of
    // them build on one thread and never enter the sharded BWT derivation or
    // the sharded locate scatter. This is the smallest corpus that crosses both
    // floors — that, and not a taste for big numbers, is why it is this size.
    //
    // The three ways sharding breaks are all invisible under the floor: a
    // histogram reduction that drops a shard's tally yields a wrong C table; a
    // `Mark` prefix sum off by one yields sample writes that overlap; a shard
    // boundary that is not a multiple of 64 yields a lost read-modify-write on
    // a mark word two shards share. So every oracle below is ground truth —
    // the text itself — rather than a second implementation of the sharding,
    // which would agree with the bug.
    const gpa = testing.allocator;
    const len = (2 << 20) + 7331; // deliberately neither 64- nor shard-aligned
    const text = try gpa.alloc(u8, len);
    defer gpa.free(text);

    var prng = std.Random.DefaultPrng.init(0x5ade_1a26);
    const rand = prng.random();
    // Skewed the way real text is — a few hot bytes over a long tail — so the
    // Huffman tree is deep and lopsided rather than a balanced 8 levels.
    for (text) |*c| c.* = if (rand.uintLessThan(u8, 4) == 0) rand.int(u8) else "abcdefghij \n"[rand.uintLessThan(usize, 12)];
    // Plant every one of the 256 values, so the reduction has a live tally in
    // every bucket instead of leaving the tail to chance.
    for (text[0..256], 0..) |*c, i| c.* = @intCast(i);
    // A needle repeated across the whole corpus, so `find` walks marks in every
    // shard rather than clustering its rows inside one of them.
    const needle = "\x00sentinel-straddle\xff";
    var at: usize = 997;
    while (at + needle.len < len) : (at += 65_536) @memcpy(text[at..][0..needle.len], needle);

    var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = 32 });
    defer idx.deinit(gpa);

    // The C table IS the sharded histogram, reduced and accumulated. Compare it
    // with a direct count over the text: one dropped tally shifts every bucket
    // after it, and nothing else in the index would notice on its own.
    var freq: [257]usize = @splat(0);
    freq[0] = 1; // the sentinel holds exactly one row
    for (text) |c| freq[@as(usize, c) + 1] += 1;
    var acc: usize = 0;
    for (&idx.c_table, &freq) |got, f| {
        try testing.expectEqual(acc, got);
        acc += f;
    }

    // restore() re-derives the whole text from the wavelet tree and that C
    // table alone, so a wrong bucket surfaces here as a byte divergence.
    const rebuilt = try idx.restore(gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqualSlices(u8, text, rebuilt);

    // find() is the only path that reads the sharded marks AND the
    // prefix-summed sample array, so it is where a bad `base` shows up.
    for ([_][]const u8{ needle, "abc", "\xff", "zzzz-absent" }) |p| {
        try testing.expectEqual(oracleCount(text, p), idx.count(p));
        const got = (try idx.find(gpa, p)).got;
        defer gpa.free(got);
        const want = try oracleFind(gpa, text, p);
        defer gpa.free(want);
        try testing.expectEqualSlices(u32, want, got);
    }
}

test "codex: property fuzz — random corpora, sampled + mutated patterns" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc0dec5);
    const rand = prng.random();
    for (0..25) |round| {
        const sigma: u8 = ([_]u8{ 2, 4, 26, 255 })[round % 4];
        const len = rand.intRangeAtMost(usize, 1, 2048);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 0, sigma);
        const rate: u32 = ([_]u32{ 1, 7, 32 })[round % 3];
        var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = rate });
        defer idx.deinit(gpa);

        const rebuilt = try idx.restore(gpa);
        defer gpa.free(rebuilt);
        try testing.expectEqualSlices(u8, text, rebuilt);

        var pat_buf: [64]u8 = undefined;
        for (0..20) |_| {
            const m = rand.intRangeAtMost(usize, 1, @min(text.len, pat_buf.len));
            const start = rand.intRangeAtMost(usize, 0, text.len - m);
            @memcpy(pat_buf[0..m], text[start .. start + m]);
            // half the probes are mutated — usually absent, sometimes still present
            if (rand.boolean()) pat_buf[rand.intRangeLessThan(usize, 0, m)] +%= 1;
            const p = pat_buf[0..m];
            try testing.expectEqual(oracleCount(text, p), idx.count(p));
            const got = (try idx.find(gpa, p)).got;
            defer gpa.free(got);
            const want = try oracleFind(gpa, text, p);
            defer gpa.free(want);
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

// ── persistence ──

test "codex: save/load round-trip is behaviorally identical, both postures" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5afe);
    const rand = prng.random();
    const corpora = [_][]const u8{
        "mississippi",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "\x00\x01\xff\x00\x01\xff\x00",
        "the quick brown fox jumps over the lazy dog",
    };
    for (corpora) |text| {
        for ([_]wavelet.Encoding{ .adopt_min, .plain_only }) |enc| {
            for ([_]u32{ 0, 4 }) |rate| {
                var built = try codex.Codex.build(gpa, text, .{ .sample_rate = rate, .encoding = enc });
                defer built.deinit(gpa);
                const blob = try built.save(gpa);
                defer gpa.free(blob);
                var loaded = try codex.Codex.load(gpa, blob);
                defer loaded.deinit(gpa);

                try testing.expectEqual(built.len(), loaded.len());
                try testing.expectEqual(built.stats.index_bytes, loaded.stats.index_bytes);
                const rebuilt = try loaded.restore(gpa);
                defer gpa.free(rebuilt);
                try testing.expectEqualSlices(u8, text, rebuilt);

                // probe with present substrings and mutated (usually absent) ones
                var pat_buf: [16]u8 = undefined;
                for (0..24) |_| {
                    const m = rand.intRangeAtMost(usize, 1, @min(text.len, pat_buf.len));
                    const start = rand.intRangeAtMost(usize, 0, text.len - m);
                    @memcpy(pat_buf[0..m], text[start .. start + m]);
                    if (rand.boolean()) pat_buf[rand.intRangeLessThan(usize, 0, m)] +%= 1;
                    const p = pat_buf[0..m];
                    try testing.expectEqual(oracleCount(text, p), loaded.count(p));
                    if (rate > 0) {
                        const got = (try loaded.find(gpa, p)).got;
                        defer gpa.free(got);
                        const want = try oracleFind(gpa, text, p);
                        defer gpa.free(want);
                        try testing.expectEqualSlices(u32, want, got);
                    }
                }
            }
        }
    }
}

test "codex: load fails closed on truncation, bit rot, and wrong magic" {
    const gpa = testing.allocator;
    var built = try codex.Codex.build(gpa, "integrity is not optional", .{});
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);

    // sanity: the pristine blob loads
    var ok = try codex.Codex.load(gpa, blob);
    ok.deinit(gpa);

    // every truncation must be rejected, never crash or half-load
    var trunc = try gpa.dupe(u8, blob);
    defer gpa.free(trunc);
    var cut: usize = 0;
    while (cut < blob.len) : (cut += @max(blob.len / 37, 1)) {
        try testing.expectError(error.Corrupt, codex.Codex.load(gpa, trunc[0..cut]));
    }

    // single flipped bit anywhere: the checksum fails closed
    var prng = std.Random.DefaultPrng.init(0xb17f11f);
    const rand = prng.random();
    for (0..50) |_| {
        const at = rand.intRangeLessThan(usize, 0, blob.len);
        trunc[at] ^= @as(u8, 1) << rand.int(u3);
        try testing.expectError(error.Corrupt, codex.Codex.load(gpa, trunc));
        trunc[at] = blob[at]; // restore for the next probe
    }

    var bad_magic = try gpa.dupe(u8, blob);
    defer gpa.free(bad_magic);
    bad_magic[0] = 'X';
    try testing.expectError(error.Corrupt, codex.Codex.load(gpa, bad_magic));
}

test "codex: index measures smaller than raw text on compressible input" {
    const gpa = testing.allocator;
    // realistic compressible text: repeated vocabulary, code-like shape
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    const words = [_][]const u8{ "const ", "return ", "self.", "alloc", "defer ", "try ", "pub fn ", "usize", "( ", ") {\n", "}\n" };
    while (text.items.len < 200_000) {
        try text.appendSlice(gpa, words[rand.intRangeLessThan(usize, 0, words.len)]);
    }
    var idx = try codex.Codex.build(gpa, text.items, .{ .sample_rate = 0 });
    defer idx.deinit(gpa);
    // count-only index must land well under the raw bytes (entropy-bound space)
    try testing.expect(idx.stats.index_bytes < text.items.len / 2);
    try testing.expectEqual(oracleCount(text.items, "pub fn "), idx.count("pub fn "));
}
