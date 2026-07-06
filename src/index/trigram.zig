//! gist — positional-trigram candidate index (the proven baseline tier).
//!
//! A document that *contains a literal* must contain every trigram of that
//! literal, so the AND of the per-trigram posting lists is a sound *candidate
//! set*: a superset of the true matches, cheaply computed without scanning. It
//! is a FILTER, not a matcher — the caller still verifies each candidate with
//! the real regex engine (false positives are expected and harmless; false
//! negatives are not, and the trigram filter has none for literals ≥ 3 bytes).
//!
//! **On-disk/in-memory shape — a CSR directory over delta-varint posting
//! lists** (csearch's own index format: google/codesearch `index/write.go`).
//! A flat `(trigram, doc)` pair table costs 8 bytes/posting (4 tag + 4 doc) and
//! most of that tag is redundant — a distinct trigram has, on average, dozens
//! of postings sharing it. So the index instead stores three parallel arrays
//! over the `n` DISTINCT trigrams present (`dir_tri`/`dir_off`/`dir_count`,
//! csearch's exact per-trigram index-entry triple) plus one `body` byte blob:
//! each group's ascending doc ids are delta-encoded (first id raw, each
//! successor `doc[i]-doc[i-1]`, always ≥ 1 since a doc's own trigram set is
//! deduped) and varint-packed (`varint.zig`), so a locally-clustered doc-id run
//! — the common case for any trigram that appears in a meaningful fraction of
//! files — costs ~1 byte/posting instead of 4. Measured on this repo (18,910
//! files, 343,857 distinct trigrams, 25.56M postings): **195.0 MiB flat → 30.1
//! MiB CSR+varint (6.5x)**, closing most of the README's "COLD one-shot
//! literal vs csearch/zoekt" gap (28 MiB) without giving up the
//! zero-copy mmap load (`persist.zig`) — `dir_*`/`body` still alias the mapped
//! pages directly (`fromMappedBytes`), so a cold query still touches only the
//! handful of pages its binary search + a few small per-trigram decodes probe.
//!
//! Design is deliberately allocation-light and free of std.AutoHashMap so it
//! stays stable across Zig's container-API churn. The n-gram *strategy* (which
//! grams to emit) lives in `ngram.zig`, so the SoTA sparse-n-gram variant
//! (ADR-pending) drops in there without touching build/query.

const std = @import("std");
const ngram = @import("ngram.zig");
const varint = @import("varint.zig");

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
/// v2: CSR trigram directory + delta-varint posting bodies (was a flat
/// (trigram,doc) pair table) — bumped so a v1 cache is rejected, not misread.
pub const format_version: u32 = 2;
const magic = "GISTIDX\x01";
/// On-disk header size (magic + version + doc_count + n_tri + posting_count).
/// Public so a zero-copy consumer can locate the directory in a mapped blob.
pub const header_len = magic.len + 4 + 4 + 8 + 8;

/// Below this many corpus bytes the single-threaded comparison-sort build wins
/// — thread spawn + a 64 MiB counting histogram aren't worth it.
const parallel_build_threshold: usize = 4 << 20; // 4 MiB

/// An immutable trigram index over a fixed set of documents, stored as a CSR
/// directory (`dir_tri`/`dir_off`/`dir_count`, one entry per DISTINCT trigram —
/// csearch's own `(trigram, count, offset)` index-entry shape) over a
/// delta-varint-packed `body` of ascending doc ids (see file header for why).
pub const Index = struct {
    dir_tri: []const u32,
    dir_off: []const u32,
    dir_count: []const u32,
    body: []const u8,
    doc_count: u32,
    posting_count: u32,
    allocator: std.mem.Allocator,
    /// True when the four slices above ALIAS a caller-owned buffer (e.g. an
    /// mmap'd index file) rather than this allocator's heap. `deinit` then
    /// frees nothing — the caller unmaps/frees the backing bytes. The
    /// zero-copy cold-load win.
    borrowed: bool = false,

    /// Build an index over `docs` (entry = one doc's bytes; doc ids are indices
    /// into `docs`). Large corpora fan extraction across cores (private regions,
    /// no contention) then order via an O(n) counting sort on the 24-bit key (vs
    /// O(n log n) compare): stable, and doc-major concat lands each bucket
    /// doc-ascending — byte-identical to the comparison-sorted result. Small
    /// corpora keep the single-threaded sort (the 64 MiB histogram isn't worth it).
    /// The flat sorted postings are then `compact`ed into the CSR+varint shape.
    pub fn build(allocator: std.mem.Allocator, docs: []const []const u8) QueryError!Index {
        var upper: usize = 0;
        for (docs) |d| upper += d.len; // ≥ distinct trigrams across all docs

        const flat = if (upper < parallel_build_threshold or docs.len < 2)
            try buildFlatSerial(allocator, docs, upper)
        else
            buildFlatParallel(allocator, docs, upper) catch |e| switch (e) {
                // Any threading/alloc hiccup degrades gracefully to the proven path.
                error.OutOfMemory => try buildFlatSerial(allocator, docs, upper),
            };
        defer allocator.free(flat);
        return compact(allocator, @intCast(docs.len), flat);
    }

    fn buildFlatSerial(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error![]Posting {
        const postings = try allocator.alloc(Posting, upper);
        errdefer allocator.free(postings);
        const scratch = try allocator.alloc(Trigram, maxDocLen(docs));
        defer allocator.free(scratch);

        const final = postings[0..emitPostings(docs, 0, scratch, postings)];
        std.mem.sort(Posting, final, {}, postingLess);
        return allocator.realloc(postings, final.len) catch final;
    }

    const radix_bits = 24; // a trigram is 24 bits → one histogram bucket each
    const radix = 1 << radix_bits;

    fn buildFlatParallel(allocator: std.mem.Allocator, docs: []const []const u8, upper: usize) std.mem.Allocator.Error![]Posting {
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
            return countingAssemble(allocator, shards, t);
        };
        for (0..nthr) |t| threads[t].join();
        for (shards) |*sh| if (sh.err) return error.OutOfMemory;
        return countingAssemble(allocator, shards, nthr);
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
    fn countingAssemble(allocator: std.mem.Allocator, shards: []ExtractShard, used: usize) std.mem.Allocator.Error![]Posting {
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
        return out;
    }

    /// Fold a sorted flat `(trigram, doc)` list into the CSR directory + body:
    /// one `(dir_tri, dir_off, dir_count)` triple per distinct trigram (upper
    /// bound `sorted.len`, realloc'd down — every group has count ≥ 1) and a
    /// `body` of delta-varint-packed doc ids sized to the worst case
    /// (`varint.max_len` bytes/posting) then realloc'd down to what was
    /// actually written. Both reallocs typically shrink 3-8x (file header).
    fn compact(allocator: std.mem.Allocator, doc_count: u32, sorted: []const Posting) std.mem.Allocator.Error!Index {
        const dir_tri = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_tri);
        const dir_off = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_off);
        const dir_count = try allocator.alloc(u32, @max(sorted.len, 1));
        errdefer allocator.free(dir_count);
        var body = try allocator.alloc(u8, @max(sorted.len * varint.max_len, 1));
        errdefer allocator.free(body);

        var gi: usize = 0; // dir index (distinct-trigram count so far)
        var bp: usize = 0; // body write cursor
        var i: usize = 0;
        while (i < sorted.len) {
            const t = sorted[i].tri;
            const group_off = bp;
            var prev: u32 = 0;
            var cnt: u32 = 0;
            while (i < sorted.len and sorted[i].tri == t) : (i += 1) {
                const doc = sorted[i].doc;
                const delta: u64 = if (cnt == 0) doc else doc - prev;
                bp += varint.encode(body[bp..], delta);
                prev = doc;
                cnt += 1;
            }
            dir_tri[gi] = t;
            dir_off[gi] = @intCast(group_off);
            dir_count[gi] = cnt;
            gi += 1;
        }

        return .{
            .dir_tri = allocator.realloc(dir_tri, gi) catch dir_tri[0..gi],
            .dir_off = allocator.realloc(dir_off, gi) catch dir_off[0..gi],
            .dir_count = allocator.realloc(dir_count, gi) catch dir_count[0..gi],
            // realloc to EXACTLY bp (0 frees the placeholder) so `deinit` frees what
            // was allocated — an empty index otherwise leaks the `@max(…,1)` byte.
            .body = allocator.realloc(body, bp) catch body[0..bp],
            .doc_count = doc_count,
            .posting_count = @intCast(sorted.len),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Index) void {
        if (!self.borrowed) {
            self.allocator.free(self.dir_tri);
            self.allocator.free(self.dir_off);
            self.allocator.free(self.dir_count);
            self.allocator.free(self.body);
        }
        self.* = undefined;
    }

    /// Bytes needed to serialize this index (header + directory + body).
    pub fn serializedSize(self: *const Index) usize {
        return header_len + self.dir_tri.len * 4 + self.dir_off.len * 4 + self.dir_count.len * 4 + self.body.len;
    }

    /// Serialize into `buf` (`>= serializedSize()`). IO-free — caller writes the
    /// bytes wherever it likes (kernel stays fs-agnostic). Returns bytes written.
    pub fn writeInto(self: *const Index, buf: []u8) usize {
        @memcpy(buf[0..magic.len], magic);
        std.mem.writeInt(u32, buf[magic.len..][0..4], format_version, .little);
        std.mem.writeInt(u32, buf[magic.len + 4 ..][0..4], self.doc_count, .little);
        std.mem.writeInt(u64, buf[magic.len + 8 ..][0..8], self.dir_tri.len, .little);
        std.mem.writeInt(u64, buf[magic.len + 16 ..][0..8], self.posting_count, .little);
        var off = header_len;
        for ([_][]const u32{ self.dir_tri, self.dir_off, self.dir_count }) |arr| {
            const bytes = std.mem.sliceAsBytes(arr);
            @memcpy(buf[off..][0..bytes.len], bytes);
            off += bytes.len;
        }
        @memcpy(buf[off..][0..self.body.len], self.body);
        return off + self.body.len;
    }

    const Header = struct { doc_count: u32, n_tri: usize, posting_count: usize };

    /// Validate a `writeInto` blob's header (magic + version + length) and return
    /// its metadata. Shared by the copying `fromBytes` and the zero-copy
    /// `fromMappedBytes` — the one place the on-disk layout is parsed.
    fn parseHeader(bytes: []const u8) LoadError!Header {
        if (bytes.len < header_len) return LoadError.BadFormat;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return LoadError.BadFormat;
        if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != format_version) return LoadError.BadFormat;
        const doc_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
        const n_tri: usize = @intCast(std.mem.readInt(u64, bytes[magic.len + 8 ..][0..8], .little));
        const pc64 = std.mem.readInt(u64, bytes[magic.len + 16 ..][0..8], .little);
        if (pc64 > std.math.maxInt(u32)) return LoadError.BadFormat; // posting_count must fit u32
        const dir_bytes = std.math.mul(usize, n_tri, 4 * 3) catch return LoadError.BadFormat;
        const need = std.math.add(usize, header_len, dir_bytes) catch return LoadError.BadFormat;
        if (bytes.len < need) return LoadError.BadFormat;
        return .{ .doc_count = doc_count, .n_tri = n_tri, .posting_count = @intCast(pc64) };
    }

    /// Reject a corrupt/hostile blob whose header parsed but whose body is unsafe
    /// to query. Proves every invariant the fast query path (`decodeGroup`)
    /// assumes: distinct ascending trigrams; each group non-empty, in-bounds, and
    /// EXACTLY consumed; every posting-body varint canonical, bounded, u32-sized;
    /// doc ids strictly ascending and < `doc_count` with no wrap; and
    /// `sum(dir_count) == posting_count`. Both loaders run this before returning,
    /// so a returned `Index` is always safe to walk — the on-disk format is a
    /// native-endian local rebuildable cache, but even a mangled one fails closed
    /// (`BadFormat`) instead of a panic, a silent accept, or a later OOB read.
    fn validateStructure(
        dir_tri: []const u32,
        dir_off: []const u32,
        dir_count: []const u32,
        body: []const u8,
        doc_count: u32,
        posting_count: u32,
    ) LoadError!void {
        const n = dir_tri.len;
        if (n == 0) {
            // Canonical empty index (also the all-files-shorter-than-3-bytes case,
            // where doc_count > 0 but no trigram exists): no groups, no body.
            if (body.len != 0 or posting_count != 0) return LoadError.BadFormat;
            return;
        }
        if (dir_off[0] != 0) return LoadError.BadFormat;
        var sum: u64 = 0;
        for (0..n) |i| {
            if (i > 0 and dir_tri[i] <= dir_tri[i - 1]) return LoadError.BadFormat; // distinct, ascending
            if (dir_count[i] == 0) return LoadError.BadFormat; // ≥ 1 posting per group
            if (dir_off[i] > body.len) return LoadError.BadFormat;
            const group_end = if (i + 1 < n) dir_off[i + 1] else body.len;
            if (group_end < dir_off[i] or group_end > body.len) return LoadError.BadFormat; // nondecreasing, in-bounds
            var pos: usize = dir_off[i];
            var prev: u32 = 0;
            for (0..dir_count[i]) |k| {
                const d = varint.decodeBoundedCanonical(body[pos..group_end], varint.max_len) catch return LoadError.BadFormat;
                pos += d.len;
                const doc: u32 = if (k == 0) d.value else blk: {
                    if (d.value == 0) return LoadError.BadFormat; // delta ≥ 1 ⇒ strictly ascending
                    break :blk std.math.add(u32, prev, d.value) catch return LoadError.BadFormat; // no wrap
                };
                if (doc >= doc_count) return LoadError.BadFormat; // doc id in range
                prev = doc;
            }
            if (pos != group_end) return LoadError.BadFormat; // group exactly consumed — no gap, no trailing bytes
            sum += dir_count[i];
        }
        if (sum != posting_count) return LoadError.BadFormat;
    }

    /// Rebuild an index from a `writeInto` blob, COPYING the directory + body
    /// (the index owns them, `deinit` frees them) so `bytes` may be freed after.
    /// Each region is allocated at its own element type (`u32`/`u8`), so the
    /// natural allocator alignment holds without an `@alignCast` — unlike the
    /// zero-copy `fromMappedBytes` below, this path never reinterprets a raw
    /// byte slice as `u32`s.
    pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Index {
        const h = try parseHeader(bytes);
        var off: usize = header_len;
        const dir_tri = try allocator.alloc(u32, h.n_tri);
        errdefer allocator.free(dir_tri);
        @memcpy(std.mem.sliceAsBytes(dir_tri), bytes[off..][0 .. h.n_tri * 4]);
        off += h.n_tri * 4;
        const dir_off = try allocator.alloc(u32, h.n_tri);
        errdefer allocator.free(dir_off);
        @memcpy(std.mem.sliceAsBytes(dir_off), bytes[off..][0 .. h.n_tri * 4]);
        off += h.n_tri * 4;
        const dir_count = try allocator.alloc(u32, h.n_tri);
        errdefer allocator.free(dir_count);
        @memcpy(std.mem.sliceAsBytes(dir_count), bytes[off..][0 .. h.n_tri * 4]);
        off += h.n_tri * 4;
        const body_len = bytes.len - off;
        // Alloc EXACTLY body_len (0 allowed) so `deinit`'s `free(self.body)` matches
        // the allocation — an empty-body index (canonical empty / all-docs-<3-bytes)
        // previously alloc'd a 1-byte placeholder but stored/freed a 0-len slice,
        // leaking the byte.
        const body = try allocator.alloc(u8, body_len);
        errdefer allocator.free(body);
        @memcpy(body, bytes[off..]);
        // Fail closed on a corrupt body before handing the index to the query path
        // (the errdefers above free the copies on rejection).
        try validateStructure(dir_tri, dir_off, dir_count, body, h.doc_count, @intCast(h.posting_count));
        return .{
            .dir_tri = dir_tri,
            .dir_off = dir_off,
            .dir_count = dir_count,
            .body = body,
            .doc_count = h.doc_count,
            .posting_count = @intCast(h.posting_count),
            .allocator = allocator,
        };
    }

    /// BORROW a `writeInto` blob as an index WITHOUT copying: the directory +
    /// body ALIAS straight into `bytes` (e.g. an mmap'd file), so the load is
    /// O(header) — no read-into-heap, no second alloc, no memcpy of the (often
    /// 100+ MiB) posting table. The OS faults in only the handful of pages the
    /// binary search + per-trigram decode touch, so a cold first query pays
    /// ~nothing where the copying path paid two full passes over the blob. The
    /// returned index is `borrowed`: `deinit` frees nothing; the caller owns
    /// `bytes` and must keep it mapped for the index's lifetime. `bytes` must be
    /// 4-byte-aligned at `header_len` — an mmap base is page-aligned and
    /// `header_len` (32) is a multiple of 4, so every dir region start (each a
    /// multiple of 4 bytes further in) stays 4-aligned too.
    pub fn fromMappedBytes(bytes: []const u8) LoadError!Index {
        const h = try parseHeader(bytes);
        // Every dir region starts a multiple of 4 bytes past `bytes.ptr` (header_len
        // 32 + k·4), so a 4-aligned base makes all three u32-aligned. An mmap base
        // is page-aligned; a hand-built misaligned slice must fail closed here
        // rather than trap in the `@alignCast` below.
        if (@intFromPtr(bytes.ptr) % 4 != 0) return LoadError.BadFormat;
        var off: usize = header_len;
        const tri_bytes = h.n_tri * 4;
        const dir_tri_raw: []align(4) const u8 = @alignCast(bytes[off..][0..tri_bytes]);
        off += tri_bytes;
        const dir_off_raw: []align(4) const u8 = @alignCast(bytes[off..][0..tri_bytes]);
        off += tri_bytes;
        const dir_count_raw: []align(4) const u8 = @alignCast(bytes[off..][0..tri_bytes]);
        off += tri_bytes;
        const dir_tri = std.mem.bytesAsSlice(u32, dir_tri_raw);
        const dir_off = std.mem.bytesAsSlice(u32, dir_off_raw);
        const dir_count = std.mem.bytesAsSlice(u32, dir_count_raw);
        const body = bytes[off..];
        try validateStructure(dir_tri, dir_off, dir_count, body, h.doc_count, @intCast(h.posting_count));
        return .{
            .dir_tri = dir_tri,
            .dir_off = dir_off,
            .dir_count = dir_count,
            .body = body,
            .doc_count = h.doc_count,
            .posting_count = @intCast(h.posting_count),
            .allocator = undefined, // unused: `borrowed` ⇒ `deinit` frees nothing
            .borrowed = true,
        };
    }

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
        for (qbuf[0..m], 0..) |t, i| groups[i] = self.dirIndexOf(t) orelse return allocator.alloc(u32, 0);
        std.mem.sort(usize, groups, self, dirCountLess);

        const seed = groups[0];
        var cand = try allocator.alloc(u32, self.dir_count[seed]);
        errdefer allocator.free(cand);
        var n: usize = self.decodeGroup(seed, cand);

        if (groups.len > 1) {
            const scratch = try allocator.alloc(u32, self.doc_count);
            defer allocator.free(scratch);
            for (groups[1..]) |gi| {
                const cnt = self.decodeGroup(gi, scratch);
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
            const cnt = self.decodeGroup(gi, scratch);
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
