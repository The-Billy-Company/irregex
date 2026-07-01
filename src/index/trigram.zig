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
//! emit) lives in `ngram.zig`, so the SoTA sparse-n-gram variant (ADR-pending)
//! drops in there without touching build/query.

const std = @import("std");
const ngram = @import("ngram.zig");

/// A trigram packed big-endian into the low 24 bits of a u32 (re-exported from
/// `ngram` so the index's public surface stays self-contained).
pub const Trigram = ngram.Trigram;

/// Longest doc (≥ 1) — the scratch-buffer size both extractors need.
inline fn maxDocLen(docs: []const []const u8) usize {
    var m: usize = 1;
    for (docs) |d| m = @max(m, d.len);
    return m;
}

pub const Posting = struct { tri: Trigram, doc: u32 };

fn postingLess(_: void, a: Posting, b: Posting) bool {
    return if (a.tri != b.tri) a.tri < b.tri else a.doc < b.doc;
}

/// Emit each doc's distinct trigrams into `out` as postings tagged `base_doc + i`,
/// reusing `scratch` (≥ longest doc). Returns the posting count written.
fn emitPostings(docs: []const []const u8, base_doc: u32, scratch: []Trigram, out: []Posting) usize {
    var w: usize = 0;
    for (docs, 0..) |d, i| {
        const k = ngram.extractSortedUnique(d, scratch);
        const doc: u32 = base_doc + @as(u32, @intCast(i));
        for (scratch[0..k]) |t| {
            out[w] = .{ .tri = t, .doc = doc };
            w += 1;
        }
    }
    return w;
}

pub const QueryError = error{ NeedleTooShort, OutOfMemory };
pub const LoadError = error{ BadFormat, OutOfMemory };

/// On-disk format version (independent of the C-ABI version). The serialized
/// blob is a **local-machine cache** (native-endian) — rebuild, don't ship it.
pub const format_version: u32 = 1;
const magic = "GISTIDX\x01";
/// On-disk header size (magic + version + doc_count + postings_len). Public so a
/// zero-copy consumer can locate the `Posting` table inside a mapped blob.
pub const header_len = magic.len + 4 + 4 + 8;

/// Below this many corpus bytes the single-threaded comparison-sort build wins
/// — thread spawn + a 64 MiB counting histogram aren't worth it.
const parallel_build_threshold: usize = 4 << 20; // 4 MiB

/// An immutable trigram index over a fixed set of documents.
pub const Index = struct {
    postings: []const Posting,
    doc_count: u32,
    allocator: std.mem.Allocator,
    /// True when `postings` ALIASES a caller-owned buffer (e.g. an mmap'd index
    /// file) rather than this allocator's heap. `deinit` then frees nothing —
    /// the caller unmaps/frees the backing bytes. The zero-copy cold-load win.
    borrowed: bool = false,

    /// Build an index over `docs` (entry = one doc's bytes; doc ids are indices
    /// into `docs`). Large corpora fan extraction across cores (private regions,
    /// no contention) then order via an O(n) counting sort on the 24-bit key (vs
    /// O(n log n) compare): stable, and doc-major concat lands each bucket
    /// doc-ascending — byte-identical to the comparison-sorted result. Small
    /// corpora keep the single-threaded sort (the 64 MiB histogram isn't worth it).
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
        const postings = try allocator.alloc(Posting, upper);
        errdefer allocator.free(postings);
        const scratch = try allocator.alloc(Trigram, maxDocLen(docs));
        defer allocator.free(scratch);

        const final = postings[0..emitPostings(docs, 0, scratch, postings)];
        std.mem.sort(Posting, final, {}, postingLess);
        const exact = allocator.realloc(postings, final.len) catch final;
        return .{ .postings = exact, .doc_count = @intCast(docs.len), .allocator = allocator };
    }

    const radix_bits = 24; // a trigram is 24 bits → one histogram bucket each
    const radix = 1 << radix_bits;

    fn buildParallel(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error!Index {
        const ncpu = std.Thread.getCpuCount() catch 1;
        const nthr = @min(@max(ncpu, 1), docs.len);

        // Byte-balanced contiguous doc shards (so concat stays doc-major); each
        // shard's half-open [lo, hi) doc range is one `bounds` entry.
        const target = upper / nthr;
        const bounds = try allocator.alloc([2]usize, nthr);
        defer allocator.free(bounds);
        {
            var t: usize = 0;
            var acc: usize = 0;
            var start: usize = 0;
            for (docs, 0..) |d, di| {
                acc += d.len;
                if (t + 1 < nthr and acc >= target * (t + 1)) {
                    bounds[t] = .{ start, di + 1 };
                    start = di + 1;
                    t += 1;
                }
            }
            bounds[t] = .{ start, docs.len };
            t += 1;
            while (t < nthr) : (t += 1) bounds[t] = .{ docs.len, docs.len };
        }

        const shards = try allocator.alloc(ExtractShard, nthr);
        defer allocator.free(shards);
        const threads = try allocator.alloc(std.Thread, nthr);
        defer allocator.free(threads);
        // Per-shard private posting buffer, sized to its byte budget (an upper
        // bound on its distinct-trigram count), allocated on the main thread.
        var allocated: usize = 0;
        errdefer for (shards[0..allocated]) |*sh| allocator.free(sh.buf);
        for (0..nthr) |t| {
            const slice = docs[bounds[t][0]..bounds[t][1]];
            var bytes: usize = 0;
            for (slice) |d| bytes += d.len;
            shards[t] = .{ .docs = slice, .base_doc = @intCast(bounds[t][0]), .buf = try allocator.alloc(Posting, @max(bytes, 1)) };
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
        // Thread-local scratch via the always-thread-safe page allocator (the
        // caller's may be an arena / non-Sync allocator).
        const scratch = std.heap.page_allocator.alloc(Trigram, maxDocLen(sh.docs)) catch {
            sh.err = true;
            return;
        };
        defer std.heap.page_allocator.free(scratch);
        sh.n = emitPostings(sh.docs, sh.base_doc, scratch, sh.buf);
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
        if (!self.borrowed) self.allocator.free(self.postings);
        self.* = undefined;
    }

    /// Bytes needed to serialize this index (header + raw postings).
    pub fn serializedSize(self: *const Index) usize {
        return header_len + self.postings.len * @sizeOf(Posting);
    }

    /// Serialize into `buf` (`>= serializedSize()`). IO-free — caller writes the
    /// bytes wherever it likes (kernel stays fs-agnostic). Returns bytes written.
    pub fn writeInto(self: *const Index, buf: []u8) usize {
        @memcpy(buf[0..magic.len], magic);
        std.mem.writeInt(u32, buf[magic.len..][0..4], format_version, .little);
        std.mem.writeInt(u32, buf[magic.len + 4 ..][0..4], self.doc_count, .little);
        std.mem.writeInt(u64, buf[magic.len + 8 ..][0..8], self.postings.len, .little);
        const pb = std.mem.sliceAsBytes(self.postings);
        @memcpy(buf[header_len .. header_len + pb.len], pb);
        return header_len + pb.len;
    }

    const Header = struct { doc_count: u32, plen: usize, body: usize };

    /// Validate a `writeInto` blob's header (magic + version + length) and return
    /// its metadata. Shared by the copying `fromBytes` and the zero-copy
    /// `fromMappedBytes` — the one place the on-disk layout is parsed.
    fn parseHeader(bytes: []const u8) LoadError!Header {
        if (bytes.len < header_len) return LoadError.BadFormat;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return LoadError.BadFormat;
        if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format_version) return LoadError.BadFormat;
        const doc_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
        const plen: usize = @intCast(std.mem.readInt(u64, bytes[magic.len + 8 ..][0..8], .little));
        const body = plen * @sizeOf(Posting);
        if (bytes.len < header_len + body) return LoadError.BadFormat;
        return .{ .doc_count = doc_count, .plen = plen, .body = body };
    }

    /// Rebuild an index from a `writeInto` blob, COPYING the postings (the index
    /// owns them, `deinit` frees them) so `bytes` may be freed/unmapped after.
    pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Index {
        const h = try parseHeader(bytes);
        const postings = try allocator.alloc(Posting, h.plen);
        @memcpy(std.mem.sliceAsBytes(postings), bytes[header_len .. header_len + h.body]);
        return .{ .postings = postings, .doc_count = h.doc_count, .allocator = allocator };
    }

    /// BORROW a `writeInto` blob as an index WITHOUT copying: `postings` aliases
    /// straight into `bytes` (e.g. an mmap'd file), so the load is O(header) — no
    /// read-into-heap, no second alloc, no memcpy of the (often 100+ MiB) posting
    /// table. The OS faults in only the handful of pages the binary search probes,
    /// so a cold first query pays ~nothing where the copying path paid two full
    /// passes over the blob. The returned index is `borrowed`: `deinit` frees
    /// nothing; the caller owns `bytes` and must keep it mapped for the index's
    /// lifetime. `bytes` must be `@alignOf(Posting)`-aligned at `header_len` — an
    /// mmap base is page-aligned and `header_len` (24) is a multiple of 4, so it
    /// holds for the intended caller; any 4-aligned buffer works in general.
    pub fn fromMappedBytes(bytes: []const u8) LoadError!Index {
        const h = try parseHeader(bytes);
        const raw: []align(@alignOf(Posting)) const u8 = @alignCast(bytes[header_len .. header_len + h.body]);
        return .{
            .postings = std.mem.bytesAsSlice(Posting, raw),
            .doc_count = h.doc_count,
            .allocator = undefined, // unused: `borrowed` ⇒ `deinit` frees nothing
            .borrowed = true,
        };
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

    /// Candidate docs that *may* contain `needle` (AND of its trigrams' posting
    /// lists). Returned slice is caller-owned (same allocator), sorted ascending.
    /// `needle.len < 3` ⇒ NeedleTooShort (caller full-scans; can't filter < 3 B).
    ///
    /// T1 — rarest-first: resolve each trigram's range, order by width, seed from
    /// the rarest gram, intersect outward. AND is commutative so order is
    /// irrelevant, but the rarest seed (not lexicographically-first) stays small
    /// and shrinks fastest — e.g. "context.Context" no longer seeds on "con".
    pub fn queryLiteral(self: *const Index, allocator: std.mem.Allocator, needle: []const u8) QueryError![]u32 {
        if (needle.len < 3) return QueryError.NeedleTooShort;
        const qbuf = try allocator.alloc(Trigram, needle.len);
        defer allocator.free(qbuf);
        const m = ngram.extractSortedUnique(needle, qbuf);
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
        for (self.postings[seed[0]..seed[1]], 0..) |p, i| cand[i] = p.doc;
        var n: usize = cand.len;
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

    /// Union of the candidate sets of `needles` (each ≥3 B) — the sound superset
    /// for an alternation where every match contains one of them. Sorted ascending
    /// and deduplicated, caller-owned. A sub-query error (e.g. a needle < 3 B)
    /// propagates so the caller full-scans rather than drop a branch's matches.
    pub fn queryAny(self: *const Index, allocator: std.mem.Allocator, needles: []const []const u8) QueryError![]u32 {
        if (needles.len == 1) return self.queryLiteral(allocator, needles[0]);
        var buf = try allocator.alloc(u32, 0);
        errdefer allocator.free(buf);
        var n: usize = 0;
        for (needles) |needle| {
            const c = try self.queryLiteral(allocator, needle);
            defer allocator.free(c);
            if (n + c.len > buf.len) buf = try allocator.realloc(buf, n + c.len);
            @memcpy(buf[n..][0..c.len], c);
            n += c.len;
        }
        std.mem.sort(u32, buf[0..n], {}, comptime std.sort.asc(u32));
        const w = ngram.dedupSorted(u32, buf, n); // dedup the now-sorted union
        return allocator.realloc(buf, w) catch buf[0..w];
    }
};
