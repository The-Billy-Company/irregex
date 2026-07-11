//! gist — trigram index *construction*: extract each doc's distinct trigrams,
//! order the flat `(trigram, doc)` postings, and fold them into the CSR+varint
//! shape `Index` stores. Split from `trigram.zig` (which owns the type, its
//! on-disk format, and `deinit`); the `Index.build` entry point aliases
//! straight to `build` here. Large corpora fan extraction across cores into
//! private regions (no contention), then order via an O(n) counting sort on the
//! 24-bit trigram key — byte-identical to the small-corpus comparison sort.

const std = @import("std");
const ngram = @import("ngram.zig");
const varint = @import("varint.zig");
const trigram = @import("trigram.zig");
const Trigram = trigram.Trigram;
const Posting = trigram.Posting;
const Index = trigram.Index;
const QueryError = trigram.QueryError;

/// Longest doc (≥ 1) — the scratch-buffer size both extractors need.
inline fn maxDocLen(docs: []const []const u8) usize {
    var m: usize = 1;
    for (docs) |d| m = @max(m, d.len);
    return m;
}

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

/// Below this many corpus bytes the single-threaded comparison-sort build wins
/// — thread spawn + a 64 MiB counting histogram aren't worth it.
const parallel_build_threshold: usize = 4 << 20; // 4 MiB

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

/// Order + fold a **doc-major** flat posting list — each doc's trigrams
/// contiguous, docs in ascending-id order (what `emitPostings` and the
/// incremental graft in `commands/ripgrep/graft.zig` both produce) — into the
/// CSR index. The counting sort is stable, so doc-major input lands each
/// trigram bucket doc-ascending: the result is **byte-identical** to the
/// parallel `build` path over the same posting multiset (the graft's whole
/// correctness proof — an incremental fold and a from-scratch rebuild converge
/// on the same bytes). `postings` is caller-owned and untouched (scattered into
/// a private buffer, which is freed here).
pub fn fromDocMajorPostings(allocator: std.mem.Allocator, doc_count: u32, postings: []const Posting) QueryError!Index {
    if (postings.len == 0) return compact(allocator, doc_count, &.{});
    const hist = try allocator.alloc(u32, radix); // 64 MiB — same histogram `countingAssemble` uses
    defer allocator.free(hist);
    @memset(hist, 0);
    for (postings) |p| hist[p.tri] += 1;
    var sum: u32 = 0;
    for (hist) |*h| {
        const c = h.*;
        h.* = sum;
        sum += c;
    }
    const out = try allocator.alloc(Posting, postings.len);
    defer allocator.free(out);
    for (postings) |p| {
        out[hist[p.tri]] = p;
        hist[p.tri] += 1;
    }
    return compact(allocator, doc_count, out);
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
