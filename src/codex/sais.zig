//! sais — linear-time suffix array by induced sorting (SA-IS).
//!
//! Nong, Zhang & Chan, *Two Efficient Algorithms for Linear Time Suffix Array
//! Construction* (IEEE ToC 2011; DCC 2009). This is the O(n) construction the
//! codex self-index builds on — the only super-linear stage of the naive
//! FM-index pipeline, replaced here by the real thing:
//!
//!   1. classify each suffix L (larger than its right neighbor) or S (smaller),
//!   2. induced-sort the LMS substrings (leftmost-S positions) in one L-pass +
//!      one S-pass over the bucket array,
//!   3. name the sorted LMS substrings; if names repeat, recurse on the reduced
//!      string (≤ n/2 long — the linear recurrence T(n) = T(n/2) + O(n)),
//!   4. seed the final buckets with the now fully-ordered LMS suffixes and
//!      induce every L then every S suffix into place.
//!
//! The top-level entry (`build`) lifts bytes into u16 symbols shifted +1 and
//! appends the unique smallest sentinel 0, so ALL byte values — including NUL —
//! are first-class corpus content; the recursion instantiates the same code at
//! u32 over the reduced name alphabet. Proof of correctness here is
//! differential: `codex_test.zig` checks byte-exact equality against a naive
//! comparison-sort oracle across random, adversarial, and degenerate texts.

const std = @import("std");
const bits = @import("../primitives/bits.zig");

const B8 = bits.Field(u8);
const EMPTY = std.math.maxInt(u32);

/// Suffix array of `text` + sentinel: returns `sa` of length `text.len + 1`
/// over the shifted alphabet (byte c ↦ c+1, sentinel 0). `sa[0]` is always the
/// sentinel suffix `text.len`. Caller frees.
pub fn build(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    const n = text.len + 1;
    const sa = try gpa.alloc(u32, n);
    errdefer gpa.free(sa);
    if (n == 1) {
        sa[0] = 0;
        return sa;
    }
    const s = try gpa.alloc(u16, n);
    defer gpa.free(s);
    for (text, 0..) |c, i| s[i] = @as(u16, c) + 1;
    s[n - 1] = 0;
    try sais(u16, gpa, s, sa, 257);
    return sa;
}

/// Suffix-type bitmap: bit i set ⇔ suffix i is S-type. One bit per position —
/// at recursion depth d this is n/2^d bits, so the whole stack stays ≤ 2 bits
/// per input symbol.
const Types = struct {
    bits: []u8,

    fn init(gpa: std.mem.Allocator, n: usize) !Types {
        const b = try gpa.alloc(u8, B8.words(n));
        @memset(b, 0);
        return .{ .bits = b };
    }

    fn deinit(self: Types, gpa: std.mem.Allocator) void {
        gpa.free(self.bits);
    }

    fn set(self: Types, i: usize, v: bool) void {
        if (v) B8.set(self.bits, i) else B8.clear(self.bits, i);
    }

    fn isS(self: Types, i: usize) bool {
        return B8.get(self.bits, i);
    }

    /// LMS position: an S-type suffix whose left neighbor is L-type.
    fn isLMS(self: Types, i: usize) bool {
        return i > 0 and self.isS(i) and !self.isS(i - 1);
    }
};

/// Fill `bkt` with per-symbol bucket boundaries: tails when `end`, else heads.
fn fillBuckets(comptime T: type, s: []const T, bkt: []u32, end: bool) void {
    @memset(bkt, 0);
    for (s) |c| bkt[c] += 1;
    var sum: u32 = 0;
    for (bkt) |*b| {
        sum += b.*;
        b.* = if (end) sum else sum - b.*;
    }
}

/// Left-to-right pass: every placed suffix j with an L-type left neighbor
/// induces j−1 at the head of its bucket.
fn induceL(comptime T: type, s: []const T, sa: []u32, bkt: []u32, t: Types) void {
    fillBuckets(T, s, bkt, false);
    for (0..s.len) |i| {
        const v = sa[i];
        if (v == EMPTY or v == 0) continue;
        const j = v - 1;
        if (!t.isS(j)) {
            sa[bkt[s[j]]] = j;
            bkt[s[j]] += 1;
        }
    }
}

/// Right-to-left pass: every placed suffix j with an S-type left neighbor
/// induces j−1 at the tail of its bucket.
fn induceS(comptime T: type, s: []const T, sa: []u32, bkt: []u32, t: Types) void {
    fillBuckets(T, s, bkt, true);
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const v = sa[i];
        if (v == EMPTY or v == 0) continue;
        const j = v - 1;
        if (t.isS(j)) {
            bkt[s[j]] -= 1;
            sa[bkt[s[j]]] = j;
        }
    }
}

/// Core recursion. `s` must end with a unique smallest sentinel (value 0 at
/// the top level; the reduced string's last name plays the role below).
/// `sigma` = alphabet size (max symbol + 1). Writes the suffix array into `sa`.
fn sais(comptime T: type, gpa: std.mem.Allocator, s: []const T, sa: []u32, sigma: usize) std.mem.Allocator.Error!void {
    const n = s.len;
    std.debug.assert(n >= 2 and sa.len == n);

    const t = try Types.init(gpa, n);
    defer t.deinit(gpa);
    t.set(n - 1, true); // the sentinel is S by definition
    t.set(n - 2, false); // and its left neighbor is L (sentinel is strictly smallest)
    var i = n - 2;
    while (i > 0) {
        i -= 1;
        t.set(i, s[i] < s[i + 1] or (s[i] == s[i + 1] and t.isS(i + 1)));
    }

    const bkt = try gpa.alloc(u32, sigma);
    defer gpa.free(bkt);

    // ── stage 1: sort the LMS substrings by one seeded induce ──
    @memset(sa, EMPTY);
    fillBuckets(T, s, bkt, true);
    for (1..n) |j| {
        if (t.isLMS(j)) {
            bkt[s[j]] -= 1;
            sa[bkt[s[j]]] = @intCast(j);
        }
    }
    induceL(T, s, sa, bkt, t);
    induceS(T, s, sa, bkt, t);

    // compact the sorted LMS suffixes into sa[0..n1]
    var n1: usize = 0;
    for (0..n) |k| {
        const v = sa[k];
        if (v != EMPTY and t.isLMS(v)) {
            sa[n1] = v;
            n1 += 1;
        }
    }

    // ── name each LMS substring by rank; equal substrings share a name ──
    @memset(sa[n1..], EMPTY);
    var names: u32 = 0;
    var prev: u32 = EMPTY;
    for (0..n1) |k| {
        const pos = sa[k];
        var differs = false;
        var d: usize = 0;
        while (d < n) : (d += 1) {
            // the sentinel is unique, so any comparison reaching it differs first
            if (prev == EMPTY or s[pos + d] != s[prev + d] or t.isS(pos + d) != t.isS(prev + d)) {
                differs = true;
                break;
            }
            if (d > 0 and (t.isLMS(pos + d) or t.isLMS(prev + d))) break; // both closed equal
        }
        if (differs) {
            names += 1;
            prev = pos;
        }
        sa[n1 + pos / 2] = names - 1; // pos/2 is injective over LMS positions
    }
    // squeeze the names (currently at scattered pos/2 slots) into text order at the tail
    {
        var w = n;
        var r = n;
        while (r > n1) {
            r -= 1;
            if (sa[r] != EMPTY) {
                w -= 1;
                sa[w] = sa[r];
            }
        }
    }
    const s1 = sa[n - n1 .. n]; // the reduced string, in LMS text order
    const sa1 = sa[0..n1]; // disjoint from s1 since n1 ≤ n/2

    // ── order the LMS suffixes: direct if names are unique, else recurse ──
    if (names < n1) {
        try sais(u32, gpa, s1, sa1, names);
    } else {
        for (s1, 0..) |name, k| sa1[name] = @intCast(k);
    }

    // rewrite s1 to hold the LMS positions themselves (text order), then map
    // the reduced ranks back to text positions
    {
        var w: usize = 0;
        for (1..n) |j| {
            if (t.isLMS(j)) {
                s1[w] = @intCast(j);
                w += 1;
            }
        }
    }
    for (sa1) |*v| v.* = s1[v.*];

    // ── stage 2: seed buckets with the fully-sorted LMS order, induce all ──
    @memset(sa[n1..], EMPTY);
    fillBuckets(T, s, bkt, true);
    var k = n1;
    while (k > 0) {
        k -= 1;
        const j = sa[k];
        sa[k] = EMPTY;
        bkt[s[j]] -= 1;
        sa[bkt[s[j]]] = j;
    }
    induceL(T, s, sa, bkt, t);
    induceS(T, s, sa, bkt, t);
}
