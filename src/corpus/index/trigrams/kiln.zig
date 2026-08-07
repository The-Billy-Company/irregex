//! kiln — the trigram index fired in BLOCKS instead of cast in one piece.
//!
//! The counting-scatter builder this replaces was correct and fast and had one
//! structural flaw: every intermediate it needed was proportional to the CORPUS.
//! Extraction materialized the whole `(trigram, doc)` pair table (8 bytes a
//! posting), the scatter allocated the whole doc-id array beside it (4 more),
//! and a 16.7M-bucket histogram sat across both. On llvm-project's 1.9 GiB /
//! 175k files that is 141.9M postings ⇒ 1082 MiB of pairs + 541 MiB of doc ids
//! + 64 MiB of histogram, all resident at once, to produce a 154 MiB index. The
//! shape says the whole corpus must fit in memory several times over before an
//! index exists, which is why `csearch` — which spills — held a 5x smaller peak.
//!
//! **The fix is to sort a WINDOW and keep only what compresses.** Each worker
//! fills a fixed-size block of pairs from its doc range, stable-radix-sorts it
//! on the 24-bit trigram, and immediately encodes it into a *run*: the same
//! delta-varint shape the finished index uses. The block is then reused, so
//! nothing corpus-sized is ever materialized — the intermediate is the runs plus
//! one bounded block per worker. Measured on that corpus: 370 runs holding
//! 167 MiB, or 1.23 bytes a posting where the pair table spent 8, against a
//! 96 MiB block window that does not grow with the input at all.
//!
//! **And the merge needs no comparisons.** A worker owns a contiguous ascending
//! doc range and fills its blocks in doc order, so ordering the runs
//! worker-major then block-major orders them by doc range. For any trigram,
//! concatenating its group from run 0, run 1, … therefore yields globally
//! ascending doc ids — a k-way merge's answer without a heap, because the
//! partition already carries the order a heap would have to rediscover. The
//! sweep walks the runs in lockstep, takes the smallest trigram any cursor is
//! parked on, and concatenates that group straight into the CSR body. (A doc
//! whose trigrams straddle a block boundary is still sound: each of its
//! trigrams lands in exactly one block, so no trigram sees that doc twice and
//! the concatenation stays strictly ascending.)
//!
//! Nothing about the FORMAT changes — this produces the identical bytes
//! `trigram.zig`'s directory + body did, and the round-trip and differential
//! tests are the proof.

const std = @import("std");
const ngram = @import("ngram.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const portal = @import("../../../portal.zig");
const varint = @import("../postings/varint.zig");

const Trigram = ngram.Trigram;

/// One posting while it is still scratch. The tag is dead the moment grouping is
/// known — which is exactly what a run encodes away.
const Pair = struct { tri: Trigram, doc: u32 };

/// The four CSR regions a fired index is made of, owned by the caller's
/// allocator. Deliberately not an `Index`: this module knows how to *build* the
/// shape and nothing about querying, loading, or persisting it.
pub const Fired = struct {
    dir_tri: []u32,
    dir_off: []u32,
    dir_count: []u32,
    body: []u8,
    posting_count: u32,
};

/// Resident memory every worker's block window and its sort scratch may hold at
/// once, across the whole fan-out. This is a BUDGET, not a bound derived from
/// the corpus — it is the entire reason the builder's footprint is flat — so it
/// is chosen against the machine rather than the input: big enough that a block
/// amortizes its sort and its run header over hundreds of thousands of postings,
/// small enough to disappear beside the index being built.
const block_budget: usize = 96 << 20;

/// A block small enough to be pure overhead (its run headers stop amortizing)
/// and large enough that no plausible thread count makes the window a line item.
const min_block_postings: usize = 1 << 15;
const max_block_postings: usize = 1 << 21;

/// One sorted, compressed block. `base` is the doc id every first-in-group doc
/// is written relative to, so a run's doc deltas are bounded by its own doc span
/// rather than by the corpus — the difference between a 2-byte varint and a
/// 4-byte one on every group.
const Run = struct {
    bytes: []u8,
    base: u32,
    postings: u32,
};

/// Where the builder gets a document's bytes — and the one place the two build
/// shapes differ.
///
/// **`held` is a snapshot; `streamed` is a promise.** A held build read the
/// whole corpus up front, so every byte it will ever index is already resident;
/// that residency IS the peak it pays. A streamed build carries only the census
/// — a path and a stated size per doc — and re-opens each file when its worker
/// reaches it, so what stays resident is one read buffer per worker rather than
/// the corpus.
///
/// **The trade is real, deliberate, and already covered.** Between the census
/// and the read, a file can be edited, truncated, or deleted; a streamed build
/// therefore indexes whatever is on disk at READ time, and indexes a vanished
/// file as empty. That is not a new hazard, it is the SAME window the freshness
/// anchor exists to close: the anchor is stamped before the walk, so every file
/// whose mtime/ctime moved after it is folded in live at query time no matter
/// which bytes this build happened to see. A held build narrows the window; it
/// has never closed it, because the corpus keeps changing while the index is
/// being written either way.
pub const Source = union(enum) {
    held: []const []const u8,
    streamed: Stream,

    fn count(s: Source) usize {
        return switch (s) {
            .held => |d| d.len,
            .streamed => |st| st.sizes.len,
        };
    }

    fn size(s: Source, doc: usize) usize {
        return switch (s) {
            .held => |d| d[doc].len,
            .streamed => |st| st.sizes[doc],
        };
    }

    /// Doc `doc`'s bytes, valid only until the next call with the same `buf`.
    /// A read that fails yields the empty document — see the TOCTOU note above.
    fn body(s: Source, doc: usize, buf: []u8) []const u8 {
        return switch (s) {
            .held => |d| d[doc],
            .streamed => |st| st.read(st.ctx, @intCast(doc), buf),
        };
    }
};

/// A census plus the means to read from it. `read` is called from worker
/// threads, so it must be thread-safe and must not touch a shared allocator.
pub const Stream = struct {
    sizes: []const u32,
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, doc: u32, buf: []u8) []const u8,
    witness: ?Witness = null,
};

/// A second reader of the bytes this build is already holding, for the length
/// of one doc.
///
/// **This exists because a streamed build's scarcest resource is a doc's bytes
/// while they are in hand.** A held build could afford several independent
/// passes over the corpus — the corpus was in memory, so they were free. A
/// streamed build pays a file read for each one, so anything else that wants
/// per-doc bytes should ride along here rather than open the file again. The
/// crest sieve is exactly that, and so is recording the length the build
/// ACTUALLY saw, which is the only honest input to a content shard's offset
/// catalog when the stated sizes came from an earlier walk.
///
/// `saw` runs on a worker thread, once per doc, with the bytes valid only for
/// the call. Workers own disjoint doc ranges, so writing to `out[doc]` needs no
/// synchronization — anything else does.
pub const Witness = struct {
    ctx: *anyopaque,
    saw: *const fn (ctx: *anyopaque, doc: u32, bytes: []const u8) void,
};

fn statedSize(_: void, n: u32) usize {
    return n;
}

/// A worker's doc range and the runs it fired from it. Runs are allocated from
/// `page_allocator` rather than the caller's allocator for the reason the
/// extractor already used it: a caller may hand us an arena, and an arena is
/// not thread-safe.
const Worker = struct {
    src: Source,
    lo: u32,
    hi: u32,
    cap: usize,
    runs: std.ArrayList(Run) = .empty,
    postings: usize = 0,
    err: bool = false,
};

/// Build the CSR directory + delta-varint body over `docs` (doc ids are
/// indices), whose bodies are already resident.
pub fn fire(gpa: std.mem.Allocator, docs: []const []const u8) std.mem.Allocator.Error!Fired {
    return fireFrom(gpa, .{ .held = docs });
}

/// Build it from any source. `OutOfMemory` is the only failure, and the caller
/// degrades to the serial builder on it — a threading hiccup is never allowed
/// to cost postings, because a candidate filter that drops postings answers
/// false NEGATIVES.
pub fn fireFrom(gpa: std.mem.Allocator, src: Source) std.mem.Allocator.Error!Fired {
    const ndocs = src.count();
    var bytes: usize = 0;
    for (0..ndocs) |i| bytes += src.size(i);
    const ncpu = portal.cpuCount() catch 1;
    const nthr = @min(@max(ncpu, 1), ndocs);
    const cap = blockCap(nthr);

    const bounds = try gpa.alloc(usize, nthr + 1);
    defer gpa.free(bounds);
    switch (src) {
        .held => |d| parallel.greedyBounds([]const u8, d, {}, parallel.sliceLen, bytes, bounds),
        .streamed => |st| parallel.greedyBounds(u32, st.sizes, {}, statedSize, bytes, bounds),
    }

    const workers = try gpa.alloc(Worker, nthr);
    defer gpa.free(workers);
    for (workers, 0..) |*w, t| w.* = .{ .src = src, .lo = @intCast(bounds[t]), .hi = @intCast(bounds[t + 1]), .cap = cap };
    defer for (workers) |*w| {
        for (w.runs.items) |r| std.heap.page_allocator.free(r.bytes);
        w.runs.deinit(std.heap.page_allocator);
    };

    const threads = try gpa.alloc(std.Thread, nthr);
    defer gpa.free(threads);
    var spawned: usize = 0;
    while (spawned < nthr) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, extract, .{&workers[spawned]}) catch break;
    }
    // Every worker must run. A shard the OS declined to spawn is extracted on
    // this thread instead of skipped: omitting one omits its postings, and this
    // tier is allowed false positives but never a false negative.
    for (spawned..nthr) |u| extract(&workers[u]);
    for (threads[0..spawned]) |th| th.join();
    for (workers) |*w| if (w.err) return error.OutOfMemory;
    return sweep(gpa, workers);
}

fn blockCap(nthr: usize) usize {
    // Two buffers per worker — the block and the sort's ping-pong destination.
    const per = block_budget / @max(nthr, 1) / (2 * @sizeOf(Pair));
    return std.math.clamp(per, min_block_postings, max_block_postings);
}

// ─────────────────────────── extraction ───────────────────────────

/// Fill, sort, and fire blocks until this worker's doc range is exhausted. The
/// two `cap`-sized pair buffers and the per-doc trigram scratch are the worker's
/// whole footprint; the runs it leaves behind are the only thing that grows.
fn extract(w: *Worker) void {
    const pa = std.heap.page_allocator;
    var longest: usize = 1;
    for (w.lo..w.hi) |i| longest = @max(longest, w.src.size(i));

    // A streamed worker reads each doc into one buffer sized to the largest doc
    // it will see, and reuses it for every doc after — the whole reason a
    // streamed build's footprint is per-WORKER instead of per-corpus. A held
    // worker's bodies are already resident and it allocates nothing here.
    const hold: []u8 = switch (w.src) {
        .held => &.{},
        .streamed => pa.alloc(u8, longest) catch {
            w.err = true;
            return;
        },
    };
    defer pa.free(hold);

    const block = pa.alloc(Pair, w.cap) catch {
        w.err = true;
        return;
    };
    defer pa.free(block);
    const spare = pa.alloc(Pair, w.cap) catch {
        w.err = true;
        return;
    };
    defer pa.free(spare);
    const scratch = pa.alloc(Trigram, longest) catch {
        w.err = true;
        return;
    };
    defer pa.free(scratch);
    // One private presence bitmap, zeroed once: each doc clears only its own
    // bits on the way out, so there is no per-doc memset.
    const bitmap = pa.alloc(u64, ngram.bitmap_words) catch {
        w.err = true;
        return;
    };
    defer pa.free(bitmap);
    @memset(bitmap, 0);

    const wit: ?Witness = switch (w.src) {
        .held => null,
        .streamed => |st| st.witness,
    };

    var n: usize = 0; // postings held in `block`
    var base: u32 = w.lo; // first doc this block carries
    for (w.lo..w.hi) |i| {
        const doc: u32 = @intCast(i);
        const body = w.src.body(i, hold);
        if (wit) |x| x.saw(x.ctx, doc, body);
        const k = ngram.extractUniqueUnordered(body, bitmap, scratch);
        var done: usize = 0;
        while (done < k) {
            if (n == block.len) {
                if (!fireBlock(w, block[0..n], spare, base)) return;
                n = 0;
                base = doc; // this doc's remaining trigrams open the next block
            }
            const take = @min(k - done, block.len - n);
            for (scratch[done..][0..take]) |t| {
                block[n] = .{ .tri = t, .doc = doc };
                n += 1;
            }
            done += take;
        }
    }
    if (n != 0) _ = fireBlock(w, block[0..n], spare, base);
}

/// Sort one filled block and record it as a run. False ⇒ out of memory, and the
/// worker is already flagged.
fn fireBlock(w: *Worker, block: []Pair, spare: []Pair, base: u32) bool {
    const pa = std.heap.page_allocator;
    const sorted = sortByTrigram(block, spare[0..block.len]);
    // Sized before it is written, so a run is exactly its own length — a
    // geometrically-grown buffer would hold up to half again as much slack, and
    // the runs ARE the intermediate this builder exists to keep small.
    const bytes = pa.alloc(u8, runSize(sorted, base)) catch {
        w.err = true;
        return false;
    };
    const written = encodeRun(bytes, sorted, base);
    std.debug.assert(written == bytes.len);
    w.runs.append(pa, .{ .bytes = bytes, .base = base, .postings = @intCast(sorted.len) }) catch {
        pa.free(bytes);
        w.err = true;
        return false;
    };
    w.postings += sorted.len;
    return true;
}

/// Stable LSD radix sort of one block on its 24-bit trigram: three 8-bit passes
/// ping-ponging between the two buffers, returning whichever holds the result.
///
/// **Stability is the load-bearing property**, not a nicety. Postings were
/// appended in ascending doc order, so a stable sort on the trigram ALONE leaves
/// every group's doc ids ascending — the builder never compares a doc id, and
/// never needs the composite `(tri, doc)` key a comparison sort would.
fn sortByTrigram(block: []Pair, spare: []Pair) []Pair {
    var src = block;
    var dst = spare;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        var hist: [256]u32 = @splat(0);
        for (src) |p| hist[@as(u8, @truncate(p.tri >> shift))] += 1;
        // A pass whose every key shares this byte would only copy — skip it.
        // Trigram bytes are ASCII-skewed, so on a source corpus this fires
        // often enough to be worth one branch.
        if (src.len != 0 and hist[@as(u8, @truncate(src[0].tri >> shift))] == src.len) continue;
        var sum: u32 = 0;
        for (&hist) |*h| {
            const c = h.*;
            h.* = sum;
            sum += c;
        }
        for (src) |p| {
            const k = @as(u8, @truncate(p.tri >> shift));
            dst[hist[k]] = p;
            hist[k] += 1;
        }
        std.mem.swap([]Pair, &src, &dst);
    }
    return src;
}

// ─────────────────────────── run coding ───────────────────────────
//
// A run is a sequence of groups in ascending trigram order:
//
//   varint(tri - prev_tri)      first group's `prev_tri` is 0, so it is absolute
//   varint(count)               postings in this group, ≥ 1
//   varint(doc[0] - base)       relative to the block's base doc, so it is small
//   varint(doc[k] - doc[k-1])   for k ≥ 1, always ≥ 1 (a doc's trigrams dedupe)
//
// The decoder always knows a group's count before its docs, so nothing needs a
// terminator — the same property that lets the finished index's body be a bare
// concatenation of groups.

fn runSize(sorted: []const Pair, base: u32) usize {
    var total: usize = 0;
    var prev_tri: u32 = 0;
    var i: usize = 0;
    while (i < sorted.len) {
        const tri = sorted[i].tri;
        var j = i;
        var prev_doc: u32 = 0;
        var group: usize = 0;
        while (j < sorted.len and sorted[j].tri == tri) : (j += 1) {
            const doc = sorted[j].doc;
            group += varint.size(if (j == i) doc - base else doc - prev_doc);
            prev_doc = doc;
        }
        total += varint.size(tri - prev_tri) + varint.size(j - i) + group;
        prev_tri = tri;
        i = j;
    }
    return total;
}

fn encodeRun(out: []u8, sorted: []const Pair, base: u32) usize {
    var bp: usize = 0;
    var prev_tri: u32 = 0;
    var i: usize = 0;
    while (i < sorted.len) {
        const tri = sorted[i].tri;
        var j = i;
        while (j < sorted.len and sorted[j].tri == tri) : (j += 1) {}
        bp += varint.encode(out[bp..], tri - prev_tri);
        bp += varint.encode(out[bp..], j - i);
        var prev_doc: u32 = 0;
        for (sorted[i..j], 0..) |p, k| {
            bp += varint.encode(out[bp..], if (k == 0) p.doc - base else p.doc - prev_doc);
            prev_doc = p.doc;
        }
        prev_tri = tri;
        i = j;
    }
    return bp;
}

/// One run's read head, parked on a decoded group header. `tri` is the absolute
/// trigram of the group at `pos`; `live` goes false when the run is spent.
const Cursor = struct {
    bytes: []const u8,
    base: u32,
    pos: usize = 0,
    tri: u32 = 0,
    count: u32 = 0,
    live: bool = false,

    fn open(r: Run) Cursor {
        var c: Cursor = .{ .bytes = r.bytes, .base = r.base };
        c.step(0);
        return c;
    }

    /// Advance onto the next group, or retire. `prev` is the trigram just
    /// consumed, since a run stores trigram DELTAS.
    fn step(c: *Cursor, prev: u32) void {
        if (c.pos >= c.bytes.len) {
            c.live = false;
            return;
        }
        const d = varint.decode(c.bytes[c.pos..]);
        c.pos += d.len;
        const n = varint.decode(c.bytes[c.pos..]);
        c.pos += n.len;
        c.tri = prev + @as(u32, @intCast(d.value));
        c.count = @intCast(n.value);
        c.live = true;
    }
};

// ─────────────────────────── the sweep ───────────────────────────

/// A trigram no run can hold (a trigram is 24 bits), so a spent cursor loses
/// every comparison without the scan needing a liveness branch.
const spent: u32 = std.math.maxInt(u32);

/// Walk every run in lockstep, emitting the CSR directory + body. The runs are
/// already ordered by doc range, so each trigram's answer is the concatenation
/// of its group from each run that holds it — no comparisons between doc ids,
/// no priority queue over docs, one pass.
fn sweep(gpa: std.mem.Allocator, workers: []Worker) std.mem.Allocator.Error!Fired {
    var nruns: usize = 0;
    var postings: usize = 0;
    for (workers) |*w| {
        nruns += w.runs.items.len;
        postings += w.postings;
    }

    const cursors = try gpa.alloc(Cursor, nruns);
    defer gpa.free(cursors);
    // Worker-major then block-major IS doc-ascending order — the invariant the
    // comparison-free concatenation rests on.
    var ci: usize = 0;
    for (workers) |*w| for (w.runs.items) |r| {
        cursors[ci] = .open(r);
        ci += 1;
    };
    // The scan's key is lifted OUT of the cursors into its own `u32` array.
    //
    // Which run is parked on the smallest trigram is asked once per distinct
    // trigram, and the obvious structures for it both lose here. A tournament
    // tree turns 370 predictable reads into nine DEPENDENT ones and measured
    // 673 ms against this scan's 571 ms; scanning the cursors in place reads a
    // liveness flag and a trigram out of a 40-byte struct, so the stride defeats
    // vectorization. A flat key array is 1.5 KiB — L1-resident, contiguous, and
    // reducible with `@min` — so "the minimum of 370 keys" compiles to a handful
    // of SIMD ops, and a spent run simply carries `spent` and always loses.
    const keys = try gpa.alloc(u32, nruns);
    defer gpa.free(keys);
    for (keys, cursors) |*k, c| k.* = if (c.live) c.tri else spent;

    var tris: std.ArrayList(u32) = .empty;
    errdefer tris.deinit(gpa);
    var offs: std.ArrayList(u32) = .empty;
    errdefer offs.deinit(gpa);
    var counts: std.ArrayList(u32) = .empty;
    errdefer counts.deinit(gpa);
    // The body is bounded by its posting count (every varint is ≤ `max_len`) and
    // shrinks to fit at the end — the same trick the previous builder used, and
    // the reason the bound costs address space rather than pages. `mul` rather
    // than `*`: on a 32-bit target the bound can exceed the address space the
    // count itself fits in, and an `OutOfMemory` there sends the caller to the
    // serial builder instead of wrapping into a short buffer.
    const bound = std.math.mul(usize, postings, varint.max_len) catch return error.OutOfMemory;
    var body = try gpa.alloc(u8, bound);
    errdefer gpa.free(body);

    var bp: usize = 0;
    while (true) {
        var tri: u32 = spent;
        for (keys) |k| tri = @min(tri, k);
        if (tri == spent) break;

        try tris.append(gpa, tri);
        try offs.append(gpa, @intCast(bp));
        var total: u32 = 0;
        var prev: u32 = 0; // last doc emitted for this trigram, across all runs
        // Ascending cursor order is ascending doc order, so this concatenation
        // needs no comparison between doc ids — only the trigram equality test.
        for (keys, cursors) |*k, *c| {
            if (k.* != tri) continue;
            var p = c.pos;
            for (0..c.count) |j| {
                const d = varint.decode(c.bytes[p..]);
                p += d.len;
                const doc: u32 = (if (j == 0) c.base else prev) + @as(u32, @intCast(d.value));
                bp += varint.encode(body[bp..], if (total == 0) doc else doc - prev);
                prev = doc;
                total += 1;
            }
            c.pos = p;
            c.step(tri);
            k.* = if (c.live) c.tri else spent;
        }
        try counts.append(gpa, total);
    }

    if (gpa.realloc(body, bp)) |snug| body = snug else |_| body = body[0..bp];
    return .{
        .dir_tri = try tris.toOwnedSlice(gpa),
        .dir_off = try offs.toOwnedSlice(gpa),
        .dir_count = try counts.toOwnedSlice(gpa),
        .body = body,
        // The format counts postings in 32 bits. A corpus past that can't be
        // described, so it is refused rather than silently truncated into an
        // index whose header disagrees with its own body.
        .posting_count = std.math.cast(u32, postings) orelse return error.OutOfMemory,
    };
}
