//! A sliver is a needle too thin to be a trigram — one or two bytes, where
//! `extractSortedUnique` yields nothing and the index has classically stood
//! down to a full corpus scan (the certificate records that honestly:
//! `literal-punct2` = `})` at cand% = 100).
//!
//! The tier that closes it adds **no bytes to the index**. A trigram directory
//! already witnesses every sliver that a document long enough to own a trigram
//! can contain, because the sliver must sit inside one of that document's
//! trigrams:
//!
//! - a 2-byte `ab` occurring at offset p in a document of length ≥ 3 lies
//!   inside `ab?` (when p+2 < len) or inside `?ab` (when p+2 = len, which
//!   forces p ≥ 1). So the union of those two trigram families over-approximates
//!   the documents containing `ab`, and nothing else can contain it.
//! - a 1-byte `a` lies inside some trigram of the document by the same argument,
//!   so the union runs over every group whose trigram mentions `a`.
//!
//! **Soundness** rests on the length premise, and the one place it fails is a
//! document shorter than 3 bytes: it owns no trigram, appears in no posting
//! list, and would be pruned by a union that never had a chance to see it.
//! `short_docs` carries those documents and is unioned in unconditionally, so
//! the answer stays a superset of the truth. The caller proves shortness with
//! the crest sidecar it already maps — `max ρ(d) ≥ 3` witnesses a run of three
//! same-class bytes, hence a length of at least 3 — and admits every document
//! it cannot prove long. Over-admission costs a read; under-admission would
//! cost a match, so the asymmetry runs the safe way by construction.
//!
//! **Cost** is bounded before any posting is decoded. `dir_count` is the exact
//! cardinality of every group, so one directory walk prices the whole union and
//! `budget_ratio` declines the ones that cannot pay. On the certificate corpus
//! that ceiling refuses 75 of 16,918 witnessed bigrams, and the most selective
//! refusal still occurs in 65.6% of documents — the budget only ever discards
//! filters that were not going to filter.

const std = @import("std");
const blob = @import("../postings/persisted_blob.zig");
const trigram = @import("trigram.zig");

const Index = trigram.Index;

pub const Error = trigram.QueryError;

/// The longest needle this tier answers. At 3 bytes the ordinary trigram path
/// takes over with an exact single-group answer, which is strictly better.
pub const max_len: usize = 2;

/// Decode ceiling for one sliver union, as a multiple of `doc_count`. A union
/// costs Σ `dir_count` over its witness groups, known from the directory before
/// a single varint is read; past this the tier declines and the caller keeps
/// its full scan. See the module header for the measurement that sets it.
pub const budget_ratio: u64 = 8;

/// Documents that may contain `needle` (1–2 bytes), ascending and caller-owned,
/// over the same allocator. `short_docs` must be an ASCENDING SUPERSET of the
/// documents owning no trigram (length < 3); passing less is unsound.
///
/// `NeedleTooShort` means *the tier declined* — an empty answer would claim no
/// document matches, so the sentinel keeps the caller on its full-scan path.
pub fn candidates(idx: *const Index, gpa: std.mem.Allocator, needle: []const u8, short_docs: []const u32) Error![]u32 {
    if (needle.len == 0 or needle.len > max_len) return Error.NeedleTooShort;
    if (idx.doc_count == 0) return gpa.alloc(u32, 0);

    var price: Price = .{ .count = idx.dir_count };
    eachWitness(idx, needle, &price, Price.take);
    if (price.cost > budget_ratio * idx.doc_count) return Error.NeedleTooShort;

    // No witness group ⇒ no document of length ≥ 3 holds the needle, and the
    // short ones are exactly `short_docs`. The strongest answer this tier gives.
    if (price.widest == 0) return gpa.dupe(u32, short_docs);

    const words = try gpa.alloc(u64, (idx.doc_count + 63) / 64);
    defer gpa.free(words);
    @memset(words, 0);
    const scratch = try gpa.alloc(u32, price.widest);
    defer gpa.free(scratch);

    var fold: Fold = .{ .idx = idx, .words = words, .scratch = scratch };
    eachWitness(idx, needle, &fold, Fold.absorb);
    if (fold.failed) |e| return e;

    return emit(gpa, words, idx.doc_count, short_docs);
}

/// Prices the union without decoding: Σ cardinality, and the widest group,
/// which sizes the single decode scratch the fold then reuses.
const Price = struct {
    count: []const u32,
    cost: u64 = 0,
    widest: usize = 0,

    fn take(self: *Price, gi: usize) void {
        const n = self.count[gi];
        self.cost += n;
        self.widest = @max(self.widest, n);
    }
};

/// Decodes each witness group straight into the membership bitset.
const Fold = struct {
    idx: *const Index,
    words: []u64,
    scratch: []u32,
    failed: ?Error = null,

    fn absorb(self: *Fold, gi: usize) void {
        if (self.failed != null) return;
        const view: blob.Structure = .{
            .dir_tri = self.idx.dir_tri,
            .dir_off = self.idx.dir_off,
            .dir_count = self.idx.dir_count,
            .body = self.idx.body,
            .doc_count = self.idx.doc_count,
            .posting_count = self.idx.posting_count,
        };
        const n = blob.decodeGroup(view, gi, self.scratch) catch {
            self.failed = Error.Corrupt;
            return;
        };
        for (self.scratch[0..n]) |d| {
            if (d >= self.idx.doc_count) {
                self.failed = Error.Corrupt;
                return;
            }
            self.words[d >> 6] |= @as(u64, 1) << @truncate(d);
        }
    }
};

/// Visit every directory group whose trigram witnesses `needle`.
///
/// The two lengths want opposite access patterns and get them. A 2-byte needle
/// has at most 512 witness groups — one contiguous `ab?` run plus one strided
/// `?ab` probe per lead byte — so it binary-searches and stays flat as the
/// directory grows. A 1-byte needle is witnessed by up to 196,608 trigrams, far
/// past the point where probing loses to one sequential pass over `dir_tri`.
fn eachWitness(idx: *const Index, needle: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), usize) void) void {
    if (needle.len == 1) {
        const b = needle[0];
        for (idx.dir_tri, 0..) |t, gi| {
            const hit = @as(u8, @truncate(t >> 16)) == b or @as(u8, @truncate(t >> 8)) == b or @as(u8, @truncate(t)) == b;
            if (hit) visit(ctx, gi);
        }
        return;
    }
    const key: u32 = (@as(u32, needle[0]) << 8) | needle[1];

    // `ab?` — the trigrams sharing the needle as their high 16 bits form one
    // contiguous directory run, since `dir_tri` is sorted by packed value.
    var gi = lowerBound(idx.dir_tri, key << 8);
    while (gi < idx.dir_tri.len and (idx.dir_tri[gi] >> 8) == key) : (gi += 1) visit(ctx, gi);

    // `?ab` — one candidate per lead byte, strided by 2^16. The `a == b` needle
    // is the one case where a group (`aaa`) belongs to both families; skipping
    // it here keeps every group visited exactly once.
    for (0..256) |c| {
        const t: u32 = (@as(u32, @intCast(c)) << 16) | key;
        if (t >> 8 == key) continue;
        if (indexOf(idx.dir_tri, t)) |g| visit(ctx, g);
    }
}

/// First index holding a value ≥ `t` (`dir_tri.len` when none does).
fn lowerBound(dir: []const u32, t: u32) usize {
    var lo: usize = 0;
    var hi: usize = dir.len;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        if (dir[m] < t) lo = m + 1 else hi = m;
    }
    return lo;
}

fn indexOf(dir: []const u32, t: u32) ?usize {
    const i = lowerBound(dir, t);
    return if (i < dir.len and dir[i] == t) i else null;
}

/// Set bits ascending, merged with the already-ascending `short_docs`.
fn emit(gpa: std.mem.Allocator, words: []const u64, doc_count: u32, short_docs: []const u32) Error![]u32 {
    var total: usize = short_docs.len;
    for (words) |w| total += @popCount(w);
    const out = try gpa.alloc(u32, total);
    errdefer gpa.free(out);

    var w: usize = 0;
    var s: usize = 0;
    for (words, 0..) |word, wi| {
        var bits = word;
        while (bits != 0) {
            const d: u32 = @intCast(wi * 64 + @ctz(bits));
            bits &= bits - 1;
            if (d >= doc_count) break; // tail padding of the final word
            while (s < short_docs.len and short_docs[s] < d) : (s += 1) {
                out[w] = short_docs[s];
                w += 1;
            }
            if (s < short_docs.len and short_docs[s] == d) s += 1; // dedup
            out[w] = d;
            w += 1;
        }
    }
    while (s < short_docs.len) : (s += 1) {
        out[w] = short_docs[s];
        w += 1;
    }
    return gpa.realloc(out, w) catch out[0..w];
}
