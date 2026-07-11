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

/// One `(trigram, doc)` posting — the flat unit `builder.zig` sorts before
/// folding into the CSR body, and the pair `debugAllPostings` decodes back to.
pub const Posting = struct { tri: Trigram, doc: u32 };

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
    /// into `docs`) — the parallel extraction + counting-sort + CSR fold lives
    /// in `builder.zig`; aliased here so `Index.build` stays the entry point.
    pub const build = @import("builder.zig").build;

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

    /// The candidate-set query path (rarest-first AND, alternation union, and
    /// the debug decode) lives in `query.zig`; aliased here so `queryLiteral`
    /// / `queryAny` / `debugAllPostings` stay methods on `Index`.
    pub const queryLiteral = @import("query.zig").queryLiteral;
    pub const queryAny = @import("query.zig").queryAny;
    pub const debugAllPostings = @import("query.zig").debugAllPostings;
};
