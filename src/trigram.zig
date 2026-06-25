//! gist — positional-trigram candidate index (the proven baseline tier).
//!
//! A document that *contains a literal* must contain every trigram of that
//! literal, so the AND of the per-trigram posting lists is a sound *candidate
//! set*: a superset of the true matches, cheaply computed without scanning. It
//! is a FILTER, not a matcher — the caller still verifies each candidate with
//! the real regex engine (false positives are expected and harmless; false
//! negatives are not, and the trigram filter has none for literals ≥ 3 bytes).
//!
//! Design is deliberately allocation-light and free of std.ArrayList /
//! std.AutoHashMap so it stays stable across Zig's container-API churn: the
//! index is one flat slice of (trigram, doc) postings sorted by (trigram, doc),
//! queried by hand-rolled binary search. The n-gram *strategy* (which grams to
//! emit) is isolated to `extractSortedUnique`, so the SoTA sparse-n-gram
//! variant (ADR-pending) drops in there without touching build/query.

const std = @import("std");

/// A trigram packed big-endian into the low 24 bits of a u32.
pub const Trigram = u32;

inline fn key(a: u8, b: u8, c: u8) Trigram {
    return (@as(Trigram, a) << 16) | (@as(Trigram, b) << 8) | @as(Trigram, c);
}

/// Extract every overlapping trigram of `text`, sorted ascending and
/// deduplicated, into `buf` (which must be at least `text.len` long). Returns
/// the number of distinct trigrams written. `text.len < 3` ⇒ 0 (no trigram).
pub fn extractSortedUnique(text: []const u8, buf: []Trigram) usize {
    if (text.len < 3) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 <= text.len) : (i += 1) {
        buf[n] = key(text[i], text[i + 1], text[i + 2]);
        n += 1;
    }
    std.mem.sort(Trigram, buf[0..n], {}, comptime std.sort.asc(Trigram));
    var w: usize = 0;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        if (w == 0 or buf[w - 1] != buf[j]) {
            buf[w] = buf[j];
            w += 1;
        }
    }
    return w;
}

const Posting = struct { tri: Trigram, doc: u32 };

fn postingLess(_: void, a: Posting, b: Posting) bool {
    if (a.tri != b.tri) return a.tri < b.tri;
    return a.doc < b.doc;
}

pub const QueryError = error{ NeedleTooShort, OutOfMemory };
pub const LoadError = error{ BadFormat, OutOfMemory };

/// On-disk format version (independent of the C-ABI version). The serialized
/// blob is a **local-machine cache** (native-endian posting bytes) — rebuild,
/// don't ship it across architectures.
pub const format_version: u32 = 1;
const magic = "GISTIDX\x01";
const header_len = magic.len + 4 + 4 + 8; // magic + version + doc_count + postings_len

/// Below this many total corpus bytes, the single-threaded comparison-sort
/// build wins — thread spawn + a 64 MiB counting histogram aren't worth it.
const parallel_build_threshold: usize = 4 << 20; // 4 MiB

/// An immutable trigram index over a fixed set of documents.
pub const Index = struct {
    postings: []Posting,
    doc_count: u32,
    allocator: std.mem.Allocator,

    /// Build an index over `docs` (each entry is one document's bytes). Document
    /// ids are the indices into `docs`.
    ///
    /// Large corpora take the fast path: extraction is **fanned out across
    /// cores** (each thread fills a private region, no contention), and the
    /// global ordering is an O(n) **counting sort** on the 24-bit trigram key
    /// rather than an O(n log n) comparison sort — the count is stable, and
    /// because the concatenated postings are doc-major, each bucket comes out
    /// doc-ascending, byte-identical to the comparison-sorted result. Small
    /// corpora (tests, tiny repos) keep the single-threaded comparison sort:
    /// the 64 MiB counting histogram isn't worth it below the threshold.
    pub fn build(allocator: std.mem.Allocator, docs: []const []const u8) QueryError!Index {
        var upper: usize = 0;
        for (docs) |d| upper += d.len; // ≥ distinct trigrams across all docs

        if (upper < parallel_build_threshold or docs.len < 2) {
            return buildSerial(allocator, docs, upper);
        }
        return buildParallel(allocator, docs, upper) catch |e| switch (e) {
            // Any threading/alloc hiccup degrades gracefully to the proven path.
            error.OutOfMemory => buildSerial(allocator, docs, upper),
        };
    }

    fn buildSerial(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) QueryError!Index {
        var max_len: usize = 0;
        for (docs) |d| if (d.len > max_len) {
            max_len = d.len;
        };
        const postings = try allocator.alloc(Posting, upper);
        errdefer allocator.free(postings);
        const scratch = try allocator.alloc(Trigram, @max(max_len, 1));
        defer allocator.free(scratch);

        var w: usize = 0;
        for (docs, 0..) |d, di| {
            const k = extractSortedUnique(d, scratch);
            for (scratch[0..k]) |t| {
                postings[w] = .{ .tri = t, .doc = @intCast(di) };
                w += 1;
            }
        }
        const final = postings[0..w];
        std.mem.sort(Posting, final, {}, postingLess);
        const exact = allocator.realloc(postings, w) catch final;
        return .{ .postings = exact, .doc_count = @intCast(docs.len), .allocator = allocator };
    }

    const radix_bits = 24; // a trigram is 24 bits → one histogram bucket each
    const radix = 1 << radix_bits;

    fn buildParallel(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error!Index {
        const ncpu = std.Thread.getCpuCount() catch 1;
        const nthr = @min(@max(ncpu, 1), docs.len);

        // Byte-balanced contiguous doc shards (so concat stays doc-major).
        const target = upper / nthr;
        const lo = try allocator.alloc(usize, nthr);
        defer allocator.free(lo);
        const hi = try allocator.alloc(usize, nthr);
        defer allocator.free(hi);
        {
            var t: usize = 0;
            var acc: usize = 0;
            var start: usize = 0;
            for (docs, 0..) |d, di| {
                acc += d.len;
                if (t + 1 < nthr and acc >= target * (t + 1)) {
                    lo[t] = start;
                    hi[t] = di + 1;
                    start = di + 1;
                    t += 1;
                }
            }
            lo[t] = start;
            hi[t] = docs.len;
            t += 1;
            while (t < nthr) : (t += 1) {
                lo[t] = docs.len;
                hi[t] = docs.len;
            }
        }

        const shards = try allocator.alloc(ExtractShard, nthr);
        defer allocator.free(shards);
        const threads = try allocator.alloc(std.Thread, nthr);
        defer allocator.free(threads);
        // Per-shard private posting buffer, sized to its byte budget (an upper
        // bound on its distinct-trigram count). Allocated by the main thread.
        var allocated: usize = 0;
        errdefer for (shards[0..allocated]) |*sh| allocator.free(sh.buf);
        for (0..nthr) |t| {
            var bytes: usize = 0;
            for (docs[lo[t]..hi[t]]) |d| bytes += d.len;
            shards[t] = .{ .docs = docs[lo[t]..hi[t]], .base_doc = @intCast(lo[t]), .buf = try allocator.alloc(Posting, @max(bytes, 1)) };
            allocated += 1;
        }
        defer for (shards) |*sh| allocator.free(sh.buf);

        for (0..nthr) |t| threads[t] = std.Thread.spawn(.{}, extractShard, .{&shards[t]}) catch {
            // Couldn't spawn — run remaining shards inline, join what we have.
            for (t..nthr) |u| extractShard(&shards[u]);
            for (0..t) |u| threads[u].join();
            return countingAssemble(allocator, docs.len, shards, t);
        };
        for (0..nthr) |t| threads[t].join();
        for (shards) |*sh| if (sh.err) return error.OutOfMemory;
        return countingAssemble(allocator, docs.len, shards, nthr);
    }

    const ExtractShard = struct {
        docs: []const []const u8,
        base_doc: u32,
        buf: []Posting,
        n: usize = 0,
        err: bool = false,
    };

    fn extractShard(sh: *ExtractShard) void {
        var max_len: usize = 1;
        for (sh.docs) |d| if (d.len > max_len) {
            max_len = d.len;
        };
        // Thread-local scratch via the always-thread-safe page allocator (the
        // caller's allocator may be an arena / non-Sync allocator).
        const scratch = std.heap.page_allocator.alloc(Trigram, max_len) catch {
            sh.err = true;
            return;
        };
        defer std.heap.page_allocator.free(scratch);
        var w: usize = 0;
        for (sh.docs, 0..) |d, i| {
            const k = extractSortedUnique(d, scratch);
            const doc: u32 = sh.base_doc + @as(u32, @intCast(i));
            for (scratch[0..k]) |t| {
                sh.buf[w] = .{ .tri = t, .doc = doc };
                w += 1;
            }
        }
        sh.n = w;
    }

    /// Counting-sort the per-shard postings (doc-major across shards) into one
    /// (trigram, doc)-ascending slice. O(total + radix).
    fn countingAssemble(allocator: std.mem.Allocator, doc_count: usize, shards: []ExtractShard, used: usize) std.mem.Allocator.Error!Index {
        var total: usize = 0;
        for (shards[0..used]) |sh| total += sh.n;

        const hist = try allocator.alloc(u32, radix);
        defer allocator.free(hist);
        @memset(hist, 0);
        for (shards[0..used]) |sh| for (sh.buf[0..sh.n]) |p| {
            hist[p.tri] += 1;
        };
        // Prefix-sum counts → bucket start offsets.
        var sum: u32 = 0;
        for (hist) |*h| {
            const c = h.*;
            h.* = sum;
            sum += c;
        }
        const out = try allocator.alloc(Posting, total);
        errdefer allocator.free(out);
        // Scatter in doc-major order ⇒ each bucket lands doc-ascending (stable).
        for (shards[0..used]) |sh| for (sh.buf[0..sh.n]) |p| {
            out[hist[p.tri]] = p;
            hist[p.tri] += 1;
        };
        return .{ .postings = out, .doc_count = @intCast(doc_count), .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.postings);
        self.* = undefined;
    }

    /// Bytes needed to serialize this index (header + raw postings).
    pub fn serializedSize(self: *const Index) usize {
        return header_len + self.postings.len * @sizeOf(Posting);
    }

    /// Serialize into `buf` (caller sizes it `>= serializedSize()`). IO-free —
    /// the caller writes the bytes wherever it likes (the kernel stays
    /// filesystem-agnostic). Returns the number of bytes written.
    pub fn writeInto(self: *const Index, buf: []u8) usize {
        @memcpy(buf[0..magic.len], magic);
        std.mem.writeInt(u32, buf[magic.len..][0..4], format_version, .little);
        std.mem.writeInt(u32, buf[magic.len + 4 ..][0..4], self.doc_count, .little);
        std.mem.writeInt(u64, buf[magic.len + 8 ..][0..8], self.postings.len, .little);
        const pb = std.mem.sliceAsBytes(self.postings);
        @memcpy(buf[header_len .. header_len + pb.len], pb);
        return header_len + pb.len;
    }

    /// Rebuild an index from a blob produced by `writeInto`. Copies the postings
    /// (so the returned index owns them and `deinit` frees them); `bytes` may be
    /// freed/unmapped afterward. Validates magic + version + length.
    pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Index {
        if (bytes.len < header_len) return LoadError.BadFormat;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return LoadError.BadFormat;
        if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format_version) return LoadError.BadFormat;
        const doc_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
        const plen = std.mem.readInt(u64, bytes[magic.len + 8 ..][0..8], .little);
        const body = plen * @sizeOf(Posting);
        if (bytes.len < header_len + body) return LoadError.BadFormat;
        const postings = try allocator.alloc(Posting, plen);
        @memcpy(std.mem.sliceAsBytes(postings), bytes[header_len .. header_len + body]);
        return .{ .postings = postings, .doc_count = doc_count, .allocator = allocator };
    }

    /// Half-open [start, end) index range of `tri`'s postings (docs ascending).
    fn rangeOf(self: *const Index, tri: Trigram) [2]usize {
        const p = self.postings;
        var lo: usize = 0;
        var hi: usize = p.len;
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (p[m].tri < tri) lo = m + 1 else hi = m;
        }
        const start = lo;
        hi = p.len;
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (p[m].tri <= tri) lo = m + 1 else hi = m;
        }
        return .{ start, lo };
    }

    fn rangeHasDoc(self: *const Index, r: [2]usize, doc: u32) bool {
        const p = self.postings;
        var lo = r[0];
        var hi = r[1];
        while (lo < hi) {
            const m = lo + (hi - lo) / 2;
            if (p[m].doc < doc) lo = m + 1 else if (p[m].doc > doc) hi = m else return true;
        }
        return false;
    }

    fn rangeWidthLess(_: void, a: [2]usize, b: [2]usize) bool {
        return (a[1] - a[0]) < (b[1] - b[0]);
    }

    /// Candidate documents that *may* contain `needle` (AND of its trigrams'
    /// posting lists). Returned slice is owned by the caller (free with the same
    /// allocator), sorted ascending. `needle.len < 3` ⇒ NeedleTooShort (the
    /// caller must fall back to a full scan — a trigram index cannot filter on
    /// fewer than 3 bytes).
    ///
    /// T1 — **rarest-first**: resolve every trigram's posting range up front,
    /// order them by width, seed the candidate set from the *rarest* trigram,
    /// and intersect outward. The seed array is then as small as the corpus
    /// allows and each step shrinks fastest — the AND is commutative so the
    /// result is identical to any order, but the work is bounded by the rarest
    /// gram instead of the lexicographically-first one (which is what made a
    /// query like "context.Context" — seeded on the common "con" — slow).
    pub fn queryLiteral(self: *const Index, allocator: std.mem.Allocator, needle: []const u8) QueryError![]u32 {
        if (needle.len < 3) return QueryError.NeedleTooShort;
        const qbuf = try allocator.alloc(Trigram, needle.len);
        defer allocator.free(qbuf);
        const m = extractSortedUnique(needle, qbuf);
        if (m == 0) return QueryError.NeedleTooShort;

        const ranges = try allocator.alloc([2]usize, m);
        defer allocator.free(ranges);
        for (qbuf[0..m], 0..) |t, i| ranges[i] = self.rangeOf(t);
        std.mem.sort([2]usize, ranges, {}, rangeWidthLess);

        // Seed from the rarest trigram (postings are doc-ascending within a
        // range, so `cand` is ascending and `rangeHasDoc`'s binary search holds).
        const seed = ranges[0];
        var cand = try allocator.alloc(u32, seed[1] - seed[0]);
        errdefer allocator.free(cand);
        var n: usize = 0;
        for (self.postings[seed[0]..seed[1]]) |p| {
            cand[n] = p.doc;
            n += 1;
        }
        // Intersect against the remaining ranges, rarest-first, compacting.
        for (ranges[1..]) |r| {
            var w: usize = 0;
            for (cand[0..n]) |doc| {
                if (self.rangeHasDoc(r, doc)) {
                    cand[w] = doc;
                    w += 1;
                }
            }
            n = w;
            if (n == 0) break;
        }
        return allocator.realloc(cand, n) catch cand[0..n];
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

test "extract: distinct overlapping trigrams of 'banana'" {
    var buf: [8]Trigram = undefined;
    const n = extractSortedUnique("banana", &buf);
    // ban, ana, nan, ana → {ban, ana, nan} = 3 distinct
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "extract: under 3 bytes yields nothing" {
    var buf: [4]Trigram = undefined;
    try std.testing.expectEqual(@as(usize, 0), extractSortedUnique("ab", &buf));
}

test "query: literal hits exactly the containing docs" {
    const docs = [_][]const u8{ "the cat sat", "the dog ran", "concatenate" };
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();

    const got = try idx.queryLiteral(std.testing.allocator, "cat");
    defer std.testing.allocator.free(got);
    // doc0 "the cat sat" and doc2 "concatenate" both contain "cat"; doc1 does not.
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2 }, got);
}

test "query: true negative returns empty candidate set" {
    const docs = [_][]const u8{ "the cat sat", "the dog ran" };
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    const got = try idx.queryLiteral(std.testing.allocator, "car");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "query: filter semantics — present-but-not-contiguous is a candidate" {
    // "bcaabc" contains trigrams "bca" and "abc" but NOT the literal "abca".
    // The trigram filter must keep it as a candidate (sound superset); the
    // caller's exact verify is what ultimately rejects it.
    const docs = [_][]const u8{"bcaabc"};
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    const got = try idx.queryLiteral(std.testing.allocator, "abca");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
}

test "query: needle under 3 bytes is reported, not silently wrong" {
    const docs = [_][]const u8{"hello"};
    var idx = try Index.build(std.testing.allocator, &docs);
    defer idx.deinit();
    try std.testing.expectError(QueryError.NeedleTooShort, idx.queryLiteral(std.testing.allocator, "he"));
}

test "serialize: round-trip preserves postings and query results" {
    const a = std.testing.allocator;
    const docs = [_][]const u8{ "the cat sat", "the dog ran", "concatenate" };
    var idx = try Index.build(a, &docs);
    defer idx.deinit();

    const buf = try a.alloc(u8, idx.serializedSize());
    defer a.free(buf);
    const n = idx.writeInto(buf);
    try std.testing.expectEqual(idx.serializedSize(), n);

    var loaded = try Index.fromBytes(a, buf);
    defer loaded.deinit();
    try std.testing.expectEqual(idx.doc_count, loaded.doc_count);
    try std.testing.expectEqualSlices(Posting, idx.postings, loaded.postings);

    const got = try loaded.queryLiteral(a, "cat");
    defer a.free(got);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 2 }, got);
}

test "serialize: garbage / truncated blob is rejected, not misread" {
    const a = std.testing.allocator;
    try std.testing.expectError(LoadError.BadFormat, Index.fromBytes(a, "not a gist index"));
    try std.testing.expectError(LoadError.BadFormat, Index.fromBytes(a, magic)); // header truncated
}
