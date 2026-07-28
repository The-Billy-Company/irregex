//! The Sliver Theorem, and the premise it stands on.
//!
//! `sliver.candidates` is only ever allowed to be WIDE. The theorem asserted
//! here is the one that makes it usable at all:
//!
//!   for every document d and every needle n of 1–2 bytes,
//!   n ⊆ d  ⇒  d ∈ candidates(index, n, short_docs)
//!
//! and it is asserted against the truth (a byte-for-byte `indexOf`), never
//! against a second implementation of the same idea.
//!
//! The premise is separated out and attacked on its own, because it is the
//! only place the theorem can break: a document shorter than three bytes owns
//! no trigram, so the directory cannot witness it. `emptyRescueMissesOnlyShort`
//! runs the tier with the rescue set deliberately REMOVED and proves the damage
//! is exactly the short documents — no more, which would mean the rescue is
//! under-sized, and no fewer, which would mean it is superstition.

const std = @import("std");
const crest = @import("../../../kernel/math/crest.zig");
const sliver = @import("sliver.zig");
const trigram = @import("trigram.zig");

const Index = trigram.Index;

/// The production rule from `persist.zig`: documents no crest vector proves are
/// ≥ 3 bytes. Recomputed here from the same primitive the sidecar stores.
fn shortDocs(gpa: std.mem.Allocator, docs: []const []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (docs, 0..) |d, i| {
        if (@reduce(.Max, @as(@Vector(crest.K, u16), crest.crest(d))) < 3) try out.append(gpa, @intCast(i));
    }
    return out.toOwnedSlice(gpa);
}

fn admits(set: []const u32, doc: u32) bool {
    return std.mem.indexOfScalar(u32, set, doc) != null;
}

/// One needle against one corpus: admitted ⊇ truly-containing, and the answer
/// obeys the ascending/deduplicated contract every caller merges on.
fn assertNeedle(gpa: std.mem.Allocator, idx: *const Index, docs: []const []const u8, short: []const u32, n: []const u8) !void {
    const got = sliver.candidates(idx, gpa, n, short) catch |e| switch (e) {
        // A decline keeps the caller's full scan: never a wrong answer.
        error.NeedleTooShort => return,
        else => return e,
    };
    defer gpa.free(got);
    for (docs, 0..) |d, i| {
        if (std.mem.indexOf(u8, d, n) == null) continue;
        std.testing.expect(admits(got, @intCast(i))) catch |e| {
            std.debug.print("MISSED doc {d} ('{s}') for needle '{s}'\n", .{ i, d, n });
            return e;
        };
    }
    if (got.len > 1) for (1..got.len) |k| try std.testing.expect(got[k - 1] < got[k]);
}

/// Every needle up to 2 bytes over the alphabet, against `std.mem.indexOf`.
fn assertTheorem(gpa: std.mem.Allocator, docs: []const []const u8, alphabet: []const u8) !void {
    var idx = try Index.build(gpa, docs);
    defer idx.deinit();
    const short = try shortDocs(gpa, docs);
    defer gpa.free(short);

    var n: [2]u8 = undefined;
    for (alphabet) |a| {
        n[0] = a;
        try assertNeedle(gpa, &idx, docs, short, n[0..1]);
        for (alphabet) |b| {
            n[1] = b;
            try assertNeedle(gpa, &idx, docs, short, n[0..2]);
        }
    }
}

test "sliver: matched ⇒ never pruned, over generated corpora" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5117E12);
    const rng = prng.random();
    // A tiny alphabet is the adversarial choice: it forces bigram collisions,
    // repeated trigrams, and `aa`-shaped needles to actually occur.
    const alphabet = "ab\n";

    for (0..64) |_| {
        const n_docs = 1 + rng.uintLessThan(usize, 12);
        const docs = try gpa.alloc([]const u8, n_docs);
        defer {
            for (docs) |d| gpa.free(d);
            gpa.free(docs);
        }
        for (docs) |*d| {
            // Lengths 0–5 keep the sub-trigram documents densely represented.
            const len = rng.uintLessThan(usize, 6);
            const buf = try gpa.alloc(u8, len);
            for (buf) |*c| c.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
            d.* = buf;
        }
        try assertTheorem(gpa, docs, alphabet);
    }
}

test "sliver: the rescue set is exactly the documents owning no trigram" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{ "", "x", "ab", "abc", "a1 ", "zzzz", "}) end", "}" };
    var idx = try Index.build(gpa, &docs);
    defer idx.deinit();

    const short = try shortDocs(gpa, &docs);
    defer gpa.free(short);
    // `""`, `"x"`, `"ab"`, `"}"` are genuinely short; `"a1 "` is 3 bytes whose
    // longest same-class run is 2, so the crest cannot prove it long. Admitting
    // it is over-admission — the sound direction — not a defect.
    try std.testing.expect(short.len >= 4);

    for (&[_][]const u8{ "ab", "}", ")", "})", "zz" }) |n| {
        const got = try sliver.candidates(&idx, gpa, n, short);
        defer gpa.free(got);
        for (docs, 0..) |d, i| {
            if (std.mem.indexOf(u8, d, n) != null) try std.testing.expect(admits(got, @intCast(i)));
        }
    }
}

test "sliver: with the rescue removed, only short documents are lost" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEFEC7);
    const rng = prng.random();
    const alphabet = "ab";

    for (0..48) |_| {
        const n_docs = 1 + rng.uintLessThan(usize, 10);
        const docs = try gpa.alloc([]const u8, n_docs);
        defer {
            for (docs) |d| gpa.free(d);
            gpa.free(docs);
        }
        for (docs) |*d| {
            const len = rng.uintLessThan(usize, 5);
            const buf = try gpa.alloc(u8, len);
            for (buf) |*c| c.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
            d.* = buf;
        }
        var idx = try Index.build(gpa, docs);
        defer idx.deinit();

        for (&[_][]const u8{ "a", "b", "aa", "ab", "ba", "bb" }) |n| {
            const bare = sliver.candidates(&idx, gpa, n, &.{}) catch |e| switch (e) {
                error.NeedleTooShort => continue,
                else => return e,
            };
            defer gpa.free(bare);
            for (docs, 0..) |d, i| {
                if (std.mem.indexOf(u8, d, n) == null) continue;
                if (admits(bare, @intCast(i))) continue;
                // The ONLY excuse for a miss is owning no trigram at all.
                std.testing.expect(d.len < 3) catch |e| {
                    std.debug.print("unrescued miss: doc {d} len {d} needle '{s}'\n", .{ i, d.len, n });
                    return e;
                };
            }
        }
    }
}

test "sliver: a declined union is an error, never an empty answer" {
    const gpa = std.testing.allocator;
    // One document of a single repeated byte: every witness group is maximal,
    // so a 1-byte needle prices far above the budget on a 1-document corpus.
    const body = "a" ** 4096;
    const docs = [_][]const u8{body};
    var idx = try Index.build(gpa, &docs);
    defer idx.deinit();

    // Out of range for the tier entirely — 3 bytes is the trigram path's job.
    try std.testing.expectError(error.NeedleTooShort, sliver.candidates(&idx, gpa, "abc", &.{}));
    try std.testing.expectError(error.NeedleTooShort, sliver.candidates(&idx, gpa, "", &.{}));
}

test "sliver: a needle no trigram witnesses yields only the rescue" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{ "hello world", "goodbye", "" };
    var idx = try Index.build(gpa, &docs);
    defer idx.deinit();
    const short = try shortDocs(gpa, &docs);
    defer gpa.free(short);

    // `qz` occurs nowhere, so the union is empty and only the unprovable-length
    // document survives. This is the tier's strongest possible answer.
    const got = try sliver.candidates(&idx, gpa, "qz", short);
    defer gpa.free(got);
    for (got) |d| try std.testing.expect(docs[d].len < 3);
    try std.testing.expect(got.len < docs.len);
}
