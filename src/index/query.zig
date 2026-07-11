//! gist — trigram index *query*: turn a literal (or a set of literals) into a
//! sound candidate doc set by AND/OR-ing the per-trigram posting lists. Split
//! from `trigram.zig` (the type + on-disk format); `Index.queryLiteral`,
//! `queryAny`, and `debugAllPostings` alias straight to the functions here. It
//! is a FILTER, not a matcher — the caller verifies each candidate with the
//! real regex engine (false positives harmless, false negatives impossible for
//! literals ≥ 3 bytes).

const std = @import("std");
const ngram = @import("ngram.zig");
const varint = @import("varint.zig");
const trigram = @import("trigram.zig");
const Trigram = trigram.Trigram;
const Posting = trigram.Posting;
const Index = trigram.Index;
const QueryError = trigram.QueryError;

/// Binary search `dir_tri` for `tri`'s directory index, or `null` if no doc
/// carries it (AND of the caller's trigram set is then soundly empty — a
/// literal containing a never-seen trigram cannot occur in any doc).
fn dirIndexOf(self: *const Index, tri: Trigram) ?usize {
    var lo: usize = 0;
    var hi: usize = self.dir_tri.len;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        if (self.dir_tri[m] < tri) lo = m + 1 else if (self.dir_tri[m] > tri) hi = m else return m;
    }
    return null;
}

/// Decode directory group `gi`'s ascending doc-id list into `out` (>= its
/// `dir_count[gi]`, bounded by `doc_count`). Returns the count decoded.
fn decodeGroup(self: *const Index, gi: usize, out: []u32) usize {
    const cnt = self.dir_count[gi];
    var pos: usize = self.dir_off[gi];
    var prev: u32 = 0;
    for (0..cnt) |i| {
        const d = varint.decode(self.body[pos..]);
        pos += d.len;
        const doc: u32 = if (i == 0) @intCast(d.value) else prev + @as(u32, @intCast(d.value));
        out[i] = doc;
        prev = doc;
    }
    return cnt;
}

fn dirCountLess(self: *const Index, a: usize, b: usize) bool {
    return self.dir_count[a] < self.dir_count[b];
}

/// In-place ascending-sorted-list intersection: `a[0..w]` (`w` returned) are
/// the values common to `a` and `b`. Safe to write back into `a` itself —
/// the write cursor never outruns the read cursor it derives from.
fn intersectAscending(a: []u32, b: []const u32) usize {
    var i: usize = 0;
    var j: usize = 0;
    var w: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] < b[j]) {
            i += 1;
        } else if (a[i] > b[j]) {
            j += 1;
        } else {
            a[w] = a[i];
            w += 1;
            i += 1;
            j += 1;
        }
    }
    return w;
}

/// Candidate docs that *may* contain `needle` (AND of its trigrams' posting
/// lists). Returned slice is caller-owned (same allocator), sorted ascending.
/// `needle.len < 3` ⇒ NeedleTooShort (caller full-scans; can't filter < 3 B).
///
/// T1 — rarest-first: resolve each trigram's directory group, order by
/// posting COUNT (exact, from `dir_count` — no decode needed to compare),
/// decode the rarest fully as the seed, then decode+merge-intersect each
/// remaining group outward. AND is commutative so order is irrelevant, but
/// the rarest seed (not lexicographically-first) stays small and shrinks
/// fastest — e.g. "context.Context" no longer seeds on "con".
pub fn queryLiteral(self: *const Index, allocator: std.mem.Allocator, needle: []const u8) QueryError![]u32 {
    if (needle.len < 3) return QueryError.NeedleTooShort;
    const qbuf = try allocator.alloc(Trigram, needle.len);
    defer allocator.free(qbuf);
    const m = ngram.extractSortedUnique(needle, qbuf);
    if (m == 0) return QueryError.NeedleTooShort;

    const groups = try allocator.alloc(usize, m);
    defer allocator.free(groups);
    for (qbuf[0..m], 0..) |t, i| groups[i] = dirIndexOf(self, t) orelse return allocator.alloc(u32, 0);
    std.mem.sort(usize, groups, self, dirCountLess);

    const seed = groups[0];
    var cand = try allocator.alloc(u32, self.dir_count[seed]);
    errdefer allocator.free(cand);
    var n: usize = decodeGroup(self, seed, cand);

    if (groups.len > 1) {
        const scratch = try allocator.alloc(u32, self.doc_count);
        defer allocator.free(scratch);
        for (groups[1..]) |gi| {
            const cnt = decodeGroup(self, gi, scratch);
            n = intersectAscending(cand[0..n], scratch[0..cnt]);
            if (n == 0) break;
        }
    }
    return allocator.realloc(cand, n) catch cand[0..n];
}

/// TEST/DEBUG ONLY: fully decode the index back into a sorted `(tri, doc)`
/// list — O(postings), never on the query hot path. Lets round-trip/parity
/// tests assert byte-for-byte equivalence without exposing the compact
/// on-disk representation to the public query API.
pub fn debugAllPostings(self: *const Index, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Posting {
    const out = try allocator.alloc(Posting, self.posting_count);
    errdefer allocator.free(out);
    const scratch = try allocator.alloc(u32, self.doc_count);
    defer allocator.free(scratch);
    var w: usize = 0;
    for (self.dir_tri, 0..) |t, gi| {
        const cnt = decodeGroup(self, gi, scratch);
        for (scratch[0..cnt]) |d| {
            out[w] = .{ .tri = t, .doc = d };
            w += 1;
        }
    }
    return out;
}

/// Union of the candidate sets of `needles` (each ≥3 B) — the sound superset
/// for an alternation where every match contains one of them. Sorted ascending
/// and deduplicated, caller-owned. A sub-query error (e.g. a needle < 3 B)
/// propagates so the caller full-scans rather than drop a branch's matches.
pub fn queryAny(self: *const Index, allocator: std.mem.Allocator, needles: []const []const u8) QueryError![]u32 {
    if (needles.len == 1) return queryLiteral(self, allocator, needles[0]);
    var buf = try allocator.alloc(u32, 0);
    errdefer allocator.free(buf);
    var n: usize = 0;
    for (needles) |needle| {
        const c = try queryLiteral(self, allocator, needle);
        defer allocator.free(c);
        if (n + c.len > buf.len) buf = try allocator.realloc(buf, n + c.len);
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    std.mem.sort(u32, buf[0..n], {}, comptime std.sort.asc(u32));
    const w = ngram.dedupSorted(u32, buf, n); // dedup the now-sorted union
    return allocator.realloc(buf, w) catch buf[0..w];
}
