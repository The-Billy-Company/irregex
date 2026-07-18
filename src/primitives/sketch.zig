//! irregex — the RELATE half: compression-kinship sketches.
//!
//! Where a regular expression asks "do these bytes MATCH this shape?", the
//! irregular half asks "how much do these bytes RESEMBLE those bytes?" — with
//! zero parsing, over any language. The signal is the relative-entropy
//! distance of Benedetto, Caglioti & Loreto ("Language Trees and Zipping",
//! Phys. Rev. Lett. 88, 048702 / cond-mat/0108530): two texts are close when
//! one compresses well in the other's dictionary. The mechanism is the fast
//! successor to running a real compressor per pair — the Lempel–Ziv Jaccard
//! Distance of Raff & Nicholas (KDD 2017): parse each text into its LZ78
//! phrase DICTIONARY, then compare dictionaries as sets. Same signal as NCD,
//! comparable-or-better accuracy, and the sets min-hash down to a fixed-size
//! sketch, so a repo-scale distance query is O(k) per pair instead of a
//! compressor run.
//!
//! Three primitives, kernel-profile (explicit allocator for scratch only, no
//! I/O, thread-safe by construction — a built `Sketch` is immutable):
//!
//!   build(bytes)          → Sketch     one LZ78 parse, bottom-k of the phrase hashes
//!   distance(a, b)        → f64        1 − Jaccard, estimated from the two sketches
//!   Sketch (value type)   fixed k=128 u64 slots — mmap-friendly, mergeable, tiny
//!
//! The sketch is a KMV ("k minimum values") summary: the k smallest 64-bit
//! phrase hashes, ascending. Jaccard between two KMV sketches is estimated on
//! the k smallest of their UNION (Beyer et al., SIGMOD 2007) — an unbiased
//! estimator that needs no per-permutation signatures, stays mergeable, and
//! keeps the record a flat `[k]u64` a future persisted-blob section can alias
//! zero-copy (the same discipline as the trigram posting table).
//!
//! Phrase identity is a 64-bit hash, never the phrase bytes (LZJD does the
//! same): an FNV-1a accumulator extends per byte — O(1)/byte, no substring
//! materialization — and a splitmix64 finalizer spreads it to the uniformity
//! bottom-k selection assumes. Hash collisions merely coalesce two phrases;
//! at 2^64 the effect on a k=128 estimate is beneath measurement.

const std = @import("std");

/// Sketch width. 128 slots × 8 bytes = 1 KiB/file; the standard MinHash
/// operating range (100–200 hashes) puts the Jaccard estimator's standard
/// error at ~1/√k ≈ 0.09 — ample for nearest-neighbor ranking.
pub const k = 128;

/// Phrases shorter than this stay in the LZ dictionary (they must — the
/// parse's phrase boundaries depend on them) but are NOT offered to the
/// sketch. Every text over one character set shares the 1–2 byte phrase
/// base, so admitting it spends sketch slots on a constant noise floor that
/// washes out kinship (measured on this repo with min=1: `hydra similar` on a
/// Zig kernel surfaced Rust, Markdown, and TSX within ±0.02 of each other).
/// Three bytes is where style begins — the same floor the trigram index is
/// built on. Length, not content — the parse itself stays classic LZ78.
pub const min_phrase = 3;

/// A file's compression-kinship summary: the `len` smallest distinct phrase
/// hashes of its LZ78 dictionary, ascending in `h[0..len]`. `len < k` only
/// for tiny inputs whose whole dictionary fits. A value type — copy, persist,
/// or share across threads freely; nothing points back at the parsed bytes.
pub const Sketch = struct {
    h: [k]u64,
    len: u16,

    pub const empty: Sketch = .{ .h = @splat(0), .len = 0 };

    /// The sketch's phrase-hash slots, ascending.
    pub fn slots(self: *const Sketch) []const u64 {
        return self.h[0..self.len];
    }
};

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// splitmix64 finalizer — spreads the FNV accumulator so bottom-k selection
/// sees uniform keys (FNV alone clusters short phrases in the low bits).
inline fn finalize(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Open-addressed u64 set for the seen-phrase dictionary — the only scratch
/// the parse needs. Power-of-two capacity, linear probing, grow at 7/8 load.
/// Key 0 is the empty slot sentinel; a real hash of 0 remaps to 1 (one
/// phrase pair coalesced per 2^64 — beneath the estimator's noise floor).
const PhraseSet = struct {
    slots: []u64,
    count: usize,

    fn init(gpa: std.mem.Allocator, cap_hint: usize) !PhraseSet {
        var cap: usize = 64;
        while (cap < cap_hint) cap *= 2; // hint is bounded by per-file caps far below overflow
        const slots = try gpa.alloc(u64, cap);
        @memset(slots, 0);
        return .{ .slots = slots, .count = 0 };
    }

    fn deinit(self: *PhraseSet, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }

    /// Insert `key`; returns true when it was NEW. Grows before the probe
    /// chain can degrade, so the parse stays O(1) amortized per phrase.
    fn insert(self: *PhraseSet, gpa: std.mem.Allocator, key_in: u64) !bool {
        const key = if (key_in == 0) 1 else key_in;
        if (self.count * 8 >= self.slots.len * 7) try self.grow(gpa);
        const mask = self.slots.len - 1;
        var i = key & mask;
        while (true) : (i = (i + 1) & mask) {
            const s = self.slots[i];
            if (s == key) return false;
            if (s == 0) {
                self.slots[i] = key;
                self.count += 1;
                return true;
            }
        }
    }

    fn grow(self: *PhraseSet, gpa: std.mem.Allocator) !void {
        const old = self.slots;
        self.slots = try gpa.alloc(u64, old.len * 2);
        @memset(self.slots, 0);
        const mask = self.slots.len - 1;
        for (old) |key| {
            if (key == 0) continue;
            var i = key & mask;
            while (self.slots[i] != 0) i = (i + 1) & mask;
            self.slots[i] = key;
        }
        gpa.free(old);
    }
};

/// Bottom-k tracker: a size-`k` max-heap so the common case (candidate ≥
/// current worst) is one compare, no write. O(n log k) worst case.
const BottomK = struct {
    heap: [k]u64, // max-heap once saturated
    len: u16,

    const init: BottomK = .{ .heap = @splat(0), .len = 0 };

    fn offer(self: *BottomK, v: u64) void {
        if (self.len < k) {
            // Filling phase: append then sift up.
            self.heap[self.len] = v;
            self.len += 1;
            var i: usize = self.len - 1;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.heap[parent] >= self.heap[i]) break;
                std.mem.swap(u64, &self.heap[parent], &self.heap[i]);
                i = parent;
            }
            return;
        }
        if (v >= self.heap[0]) return; // not smaller than the worst kept
        // Replace the max, sift down.
        self.heap[0] = v;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            const r = 2 * i + 2;
            var m = i;
            if (l < k and self.heap[l] > self.heap[m]) m = l;
            if (r < k and self.heap[r] > self.heap[m]) m = r;
            if (m == i) break;
            std.mem.swap(u64, &self.heap[i], &self.heap[m]);
            i = m;
        }
    }
};

/// Parse `bytes` into its LZ78 phrase dictionary and return the bottom-k
/// sketch of the phrase hashes. One pass, O(1)/byte; `gpa` covers only the
/// seen-phrase scratch set, freed before return. Deterministic: the same
/// bytes always produce the same sketch, on every platform (no pointers, no
/// iteration-order dependence).
pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Sketch {
    // LZ78 phrase count grows ~n/log n; /8 is a comfortable overshoot that
    // avoids most grows without over-reserving for incompressible input.
    var seen = try PhraseSet.init(gpa, bytes.len / 8);
    defer seen.deinit(gpa);
    var low: BottomK = .init;

    var h: u64 = fnv_offset;
    var plen: usize = 0;
    for (bytes) |b| {
        h = (h ^ b) *% fnv_prime;
        plen += 1;
        if (try seen.insert(gpa, h)) {
            if (plen >= min_phrase) low.offer(finalize(h));
            h = fnv_offset; // phrase complete — start the next one
            plen = 0;
        }
        // else: the phrase is already in the dictionary; keep extending it.
    }
    // A trailing partial phrase (already in the dictionary) is dropped —
    // classic LZ78 tail behavior; its prefix phrases are all present.

    var out = Sketch.empty;
    out.len = low.len;
    @memcpy(out.h[0..low.len], low.heap[0..low.len]);
    std.mem.sort(u64, out.h[0..out.len], {}, comptime std.sort.asc(u64));
    return out;
}

/// LZJD distance between two sketches: `1 − Ĵ(A,B)` with the Jaccard
/// estimated on the k smallest of the union (the KMV estimator, Beyer et al.
/// 2007). 0 = same dictionary, → 1 = nothing shared. Symmetric; O(k).
/// Two EMPTY sketches (both inputs shorter than one phrase) are distance 0.
pub fn distance(a: *const Sketch, b: *const Sketch) f64 {
    const as = a.slots();
    const bs = b.slots();
    if (as.len == 0 and bs.len == 0) return 0.0;
    if (as.len == 0 or bs.len == 0) return 1.0;

    // Merge ascending, counting intersections among the first `budget`
    // distinct union values, where budget = min(k, |A|, |B|) — the KMV rule:
    // never judge past the sketch resolution either side actually has.
    const budget = @min(as.len, bs.len);
    var i: usize = 0;
    var j: usize = 0;
    var taken: usize = 0;
    var shared: usize = 0;
    while (taken < budget and i < as.len and j < bs.len) {
        if (as[i] == bs[j]) {
            shared += 1;
            i += 1;
            j += 1;
        } else if (as[i] < bs[j]) {
            i += 1;
        } else {
            j += 1;
        }
        taken += 1;
    }
    // Union values remaining on one side still count toward the budget but
    // can no longer intersect; they only dilute (correctly).
    const jaccard = @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(budget));
    return 1.0 - jaccard;
}
