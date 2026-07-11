//! Hermetic proof of the incremental graft's core invariant: **an index folded
//! from reused (inverted) postings plus freshly-extracted ones is byte-identical
//! to a from-scratch build over the same doc set.** No filesystem, no walk —
//! this exercises the exact algebra `graft.tryFold` runs (invert the old index →
//! reuse unchanged docs' grams, re-extract changed ones → `fromDocMajorPostings`)
//! against `Index.build` as the oracle. The end-to-end FS classification (mtime
//! split, deletes, skip rules) is covered by the shell integration gate; this
//! locks the byte-exactness that makes an unattended `index --auto` safe.

const std = @import("std");
const trigram = @import("../../index/trigram.zig");
const builder = @import("../../index/builder.zig");
const ngram = @import("../../index/ngram.zig");
const graft = @import("graft.zig");
const Index = trigram.Index;
const Posting = trigram.Posting;
const Trigram = ngram.Trigram;

/// Assert two indexes serialize to identical bytes (the graft's contract).
fn expectSameBytes(gpa: std.mem.Allocator, a: *const Index, b: *const Index) !void {
    try std.testing.expectEqual(a.serializedSize(), b.serializedSize());
    const ba = try gpa.alloc(u8, a.serializedSize());
    defer gpa.free(ba);
    const bb = try gpa.alloc(u8, b.serializedSize());
    defer gpa.free(bb);
    _ = a.writeInto(ba);
    _ = b.writeInto(bb);
    try std.testing.expectEqualSlices(u8, ba, bb);
}

/// Fold a doc-major posting list built from per-doc trigram slices (the exact
/// shape `graft.tryFold` assembles) — trigrams already sorted-unique per doc.
fn foldDocs(gpa: std.mem.Allocator, doc_tris: []const []const Trigram) !Index {
    var postings: std.ArrayList(Posting) = .empty;
    defer postings.deinit(gpa);
    for (doc_tris, 0..) |tris, i| {
        for (tris) |t| try postings.append(gpa, .{ .tri = t, .doc = @intCast(i) });
    }
    return builder.fromDocMajorPostings(gpa, @intCast(doc_tris.len), postings.items);
}

fn gramsOf(gpa: std.mem.Allocator, text: []const u8) ![]Trigram {
    const scratch = try gpa.alloc(Trigram, @max(text.len, 1));
    defer gpa.free(scratch);
    const k = ngram.extractSortedUnique(text, scratch);
    return gpa.dupe(Trigram, scratch[0..k]);
}

test "invert ∘ refold is byte-identical to the source index" {
    const gpa = std.testing.allocator;
    // Includes a <3-byte doc ("ab") and an empty doc ("") — 0-posting docs that
    // must still round-trip as doc slots (doc_count unchanged).
    const docs = [_][]const u8{
        "package main\nfunc WalletService() { pgxpool.Acquire() }",
        "export const comp = () => defaultReadOnly(1234)",
        "def read_only(): return default_transaction_read_only",
        "ab",
        "",
        "fn handler() { let uniquetoken_zzz = 1; }",
    };
    var full = try Index.build(gpa, &docs);
    defer full.deinit();

    var inv = try graft.invertByDoc(gpa, &full);
    defer inv.deinit(gpa);

    // Re-emit every doc's grams straight from the inverted index (the "all
    // reused" path) and refold.
    var doc_tris = try gpa.alloc([]const Trigram, full.doc_count);
    defer gpa.free(doc_tris);
    for (0..full.doc_count) |d| doc_tris[d] = inv.tris[inv.off[d]..inv.off[d + 1]];
    var rebuilt = try foldDocs(gpa, doc_tris);
    defer rebuilt.deinit();

    try expectSameBytes(gpa, &full, &rebuilt);
    try std.testing.expectEqual(full.doc_count, rebuilt.doc_count);
    try std.testing.expectEqual(full.posting_count, rebuilt.posting_count);
}

test "graft math: reuse unchanged + re-extract changed + append == full rebuild" {
    const gpa = std.testing.allocator;
    const v1 = [_][]const u8{
        "package main\nfunc Handler1() {}",
        "package main\nfunc Handler2() { pgxpool.Acquire() }",
        "export const x = 1",
        "def ro(): return read_only",
    };
    var old = try Index.build(gpa, &v1);
    defer old.deinit();
    var inv = try graft.invertByDoc(gpa, &old);
    defer inv.deinit(gpa);

    // v2: doc 1 changed, doc 3 unchanged, a brand-new doc appended, doc order
    // otherwise preserved (exactly the walk-order re-emit the graft does).
    const changed1 = "package main\nfunc Handler2() { newBody_qqq() }";
    const appended = "fn brand_new() { let z = zzz_unique_tok; }";
    const v2 = [_][]const u8{ v1[0], changed1, v1[2], v1[3], appended };

    var reference = try Index.build(gpa, &v2);
    defer reference.deinit();

    // Simulate the graft: reuse inverted grams for unchanged docs {0,2,3},
    // re-extract the changed doc {1} and the appended doc {4}.
    const g_changed = try gramsOf(gpa, changed1);
    defer gpa.free(g_changed);
    const g_appended = try gramsOf(gpa, appended);
    defer gpa.free(g_appended);
    var doc_tris = [_][]const Trigram{
        inv.tris[inv.off[0]..inv.off[1]],
        g_changed,
        inv.tris[inv.off[2]..inv.off[3]],
        inv.tris[inv.off[3]..inv.off[4]],
        g_appended,
    };
    var grafted = try foldDocs(gpa, &doc_tris);
    defer grafted.deinit();

    try expectSameBytes(gpa, &reference, &grafted);
}
