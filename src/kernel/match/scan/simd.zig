//! gist — SIMD substring presence test (the hot primitive in the verify path).
//!
//! Why this exists (proven, not assumed — read `std/mem.zig::findPos`): Zig's
//! `std.mem.indexOf` is SIMD only for a 1-byte needle; lengths **2–4** fall to
//! `findPosLinear` (a naive byte loop) and 5+ to Boyer-Moore-Horspool (a scalar
//! skip table, no vector scan). Code search is dominated by 2–4 byte needles
//! (`})`, `ctx`, `func`, `=>`, `::`, `fn`), so that naive path is the hot loss.
//!
//! `contains` runs the memchr-style "generic SIMD" (as in Rust's memchr crate):
//! splat the needle's first and last byte, vector-compare both lanes across a
//! V-wide window, AND the masks, and only `eql`-verify the few surviving
//! positions. Returns presence (the verify path only needs a bool). Byte-exact
//! with `std.mem.indexOf` — proven end-to-end by the rg equality oracle.

const std = @import("std");
const bitsmod = @import("../../primitives/bits.zig");
const teddy = @import("teddy.zig");

/// Needle count at which the fused any-of gate hands off to Teddy. Below this
/// the fused first+last gate's `1 + N` loads/block are cheap and its wider
/// (`vlen`) block wins on AVX2/512; at 4+ Teddy's constant 2 loads/block win on
/// every architecture regardless of vector width (measured: N=4 1.6×, N=8 2.2×
/// on Apple M4). Both paths are byte-exact — this is a throughput dispatch, not
/// a fallback. `teddy.max_buckets` (8) caps both, so the handoff never fails.
const teddy_min: usize = 4;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Wide stride for the SINGLE-load byte scanners (`memchr`, `countByte`,
/// reverse memchr, the caseless single-byte find). Measured on Apple M4
/// (2026-07-22, `bench/harness/flagbench` + a width sweep): a 64-byte stride
/// runs a pure one-load-per-block scan ~35% faster than the 16-byte NEON
/// register (17→23 GiB/s) — the scan is load-port bound, so the out-of-order
/// core issues the four independent 16-byte loads across its NEON pipes. The
/// TWO-load substring kernel (`indexOfPos` & co.) gets NO such win (its second
/// strided last-byte load already saturates the ports — measured flat 16→64),
/// so it deliberately stays at `vlen`. A `vlen`-wide second tier runs before
/// the scalar tail so a haystack shorter than `scan_vlen` still vectorizes.
const scan_vlen: usize = @max(vlen, 64);
const ScanVec = @Vector(scan_vlen, u8);
const ScanMask = std.meta.Int(.unsigned, scan_vlen);

/// Cap on the fused any-of kernel's needle fan-out — mirrors
/// `analysis.pureLiterals`' cap, and bounds the fixed splat/mask arrays below.
const max_any: usize = 8;

/// Any-of presence — the multi-literal whole-file gate for alternations like
/// `panic|0x` whose union covers every match. ONE fused pass over `hay`: each
/// needle keeps its own first+last-byte SIMD fingerprint (the same selective
/// pair the single-needle kernel uses — `panic` filters on `p…c`, not the
/// `pa` prefix that English/code prose is full of), the per-needle masks OR
/// into one survivor mask, and only survivors pay an `eql` verify. The
/// per-needle last-byte loads all land within one `max_len`-wide window of
/// the shared first-byte block — L1 hits, so memory traffic stays 1× the
/// haystack regardless of needle count, where the per-needle `contains` loop
/// pays N× on a miss (the common case for a file-level gate). At `teddy_min`+
/// needles this pass hands off to `teddy` (constant 2 loads/block, no
/// linear-in-N term). Needles shorter than 2 bytes (or a set past the cap) fall
/// back to the per-needle loop; correctness is identical either way.
pub fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    if (needles.len == 0) return false;
    if (needles.len == 1) return contains(hay, needles[0]);
    var fused = needles.len <= max_any;
    var max_off: usize = 0;
    for (needles) |n| {
        if (n.len == 0) return true;
        if (n.len == 1) fused = false;
        max_off = @max(max_off, n.len - 1);
    }
    if (!fused) {
        for (needles) |n| if (contains(hay, n)) return true;
        return false;
    }
    if (needles.len >= teddy_min) if (teddy.Teddy.init(needles)) |td| return td.contains(hay);

    var f: [max_any]Vec = undefined;
    var l: [max_any]Vec = undefined;
    for (needles, 0..) |n, k| {
        f[k] = @splat(n[0]);
        l[k] = @splat(n[n.len - 1]);
    }
    var i: usize = 0;
    // Every window [i+off, i+off+vlen), off <= max_off, stays in bounds.
    while (i + max_off + vlen <= hay.len) : (i += vlen) {
        const b0: Vec = hay[i..][0..vlen].*;
        var per: [max_any]Mask = undefined;
        var any: Mask = 0;
        for (needles, 0..) |n, k| {
            const bl: Vec = hay[i + n.len - 1 ..][0..vlen].*;
            per[k] = @bitCast((b0 == f[k]) & (bl == l[k]));
            any |= per[k];
        }
        var survivors = bitsmod.ones(any);
        while (survivors.next()) |j| {
            const pos = i + j;
            const bit = @as(Mask, 1) << j;
            for (needles, 0..) |n, k| {
                if (per[k] & bit != 0 and std.mem.eql(u8, hay[pos..][0..n.len], n)) return true;
            }
        }
    }
    // Scalar tail: candidate starts in [i, hay.len) the vector loop never saw.
    for (needles) |n| if (std.mem.indexOfPos(u8, hay, i, n) != null) return true;
    return false;
}

/// Leftmost occurrence at or after `from` of ANY needle — the position-returning
/// twin of `containsAny`, and the whole-buffer multi-literal prefilter (rg's
/// Teddy) that jumps a line scan hit-to-hit over a needle-less alternation
/// (`function|const|…`). ONE fused pass: each needle's first+last-byte SIMD
/// fingerprints OR into a survivor mask, and within a block the lowest surviving
/// bit that `eql`-verifies is the leftmost hit — `bitsmod.ones` walks survivors
/// ascending, so the first verified position wins. At `teddy_min`+ needles it
/// hands off to `teddy` (constant 2 loads/block). Needles shorter than 2 bytes
/// (or a set past `max_any`) fall back to the per-needle `indexOfPos` minimum;
/// byte-exact with that reference either way. `null` when no needle occurs.
pub fn indexOfAnyPos(hay: []const u8, from: usize, needles: []const []const u8) ?usize {
    if (needles.len == 0) return null;
    if (needles.len == 1) return indexOfPos(hay, from, needles[0]);
    var fused = needles.len <= max_any;
    var max_off: usize = 0;
    for (needles) |n| {
        if (n.len == 0) return if (from <= hay.len) from else null;
        if (n.len == 1) fused = false;
        max_off = @max(max_off, n.len - 1);
    }
    if (!fused) return leftmostOf(hay, from, needles);
    if (needles.len >= teddy_min) if (teddy.Teddy.init(needles)) |td| return td.find(hay, from);

    var f: [max_any]Vec = undefined;
    var l: [max_any]Vec = undefined;
    for (needles, 0..) |n, k| {
        f[k] = @splat(n[0]);
        l[k] = @splat(n[n.len - 1]);
    }
    var i: usize = from;
    // Every window [i+off, i+off+vlen), off <= max_off, stays in bounds.
    while (i + max_off + vlen <= hay.len) : (i += vlen) {
        const b0: Vec = hay[i..][0..vlen].*;
        var per: [max_any]Mask = undefined;
        var any: Mask = 0;
        for (needles, 0..) |n, k| {
            const bl: Vec = hay[i + n.len - 1 ..][0..vlen].*;
            per[k] = @bitCast((b0 == f[k]) & (bl == l[k]));
            any |= per[k];
        }
        var survivors = bitsmod.ones(any);
        while (survivors.next()) |j| {
            const pos = i + j;
            const bit = @as(Mask, 1) << j;
            for (needles, 0..) |n, k| {
                if (per[k] & bit != 0 and std.mem.eql(u8, hay[pos..][0..n.len], n)) return pos;
            }
        }
    }
    // Scalar tail: leftmost candidate start in [i, hay.len) the vector loop missed.
    return leftmostOf(hay, i, needles);
}

/// Leftmost `indexOfPos` across `needles` at or after `from` — the reference the
/// fused kernel matches, and its 1-byte / over-cap fallback and scalar tail.
fn leftmostOf(hay: []const u8, from: usize, needles: []const []const u8) ?usize {
    var best: ?usize = null;
    for (needles) |n| if (indexOfPos(hay, from, n)) |p| {
        if (best == null or p < best.?) best = p;
    };
    return best;
}

/// Substring presence, byte-exact with `std.mem.indexOf != null` (see the
/// module doc for the first+last-byte SIMD scheme and why it beats std here).
pub fn contains(hay: []const u8, needle: []const u8) bool {
    return indexOfPos(hay, 0, needle) != null;
}

/// Leftmost occurrence of `needle` at or after `from` — the position-returning
/// core `contains` rides, and the scan the needle-driven doc loops drive (jump
/// hit to hit at SIMD speed, engine only on the containing line).
pub fn indexOfPos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    const n = needle.len;
    if (n == 0) return if (from <= hay.len) from else null;
    if (from >= hay.len or n > hay.len - from) return null;
    if (n == 1) return memchrPos(hay, from, needle[0]);

    const first: Vec = @splat(needle[0]);
    const last: Vec = @splat(needle[n - 1]);
    const last_off = n - 1;

    var i: usize = from;
    // Both windows [i, i+vlen) and [i+last_off, i+last_off+vlen) stay in bounds.
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        const bits: Mask = @bitCast((bf == first) & (bl == last));
        var survivors = bitsmod.ones(bits);
        while (survivors.next()) |j| {
            const pos = i + j;
            if (std.mem.eql(u8, hay[pos .. pos + n], needle)) return pos;
        }
    }
    // Scalar tail for the < vlen remainder.
    return std.mem.indexOfPos(u8, hay, i, needle);
}

/// Leftmost occurrence of byte `c` at or after `from` — the public forward
/// memchr the line-free scanner drives to find a matched line's end (`\n`).
pub fn memchr(hay: []const u8, from: usize, c: u8) ?usize {
    return memchrPos(hay, from, c);
}

/// Last occurrence of byte `c` in `hay[0..upto]`, or null — the reverse memchr
/// that walks backward from a match offset to its line START. SIMD blocks from
/// the high end; within a hit block the highest set bit is the last occurrence.
pub fn lastIndexOfScalar(hay: []const u8, upto: usize, c: u8) ?usize {
    var i: usize = @min(upto, hay.len);
    const wide: ScanVec = @splat(c);
    while (i >= scan_vlen) {
        i -= scan_vlen;
        const bits: ScanMask = @bitCast(@as(ScanVec, hay[i..][0..scan_vlen].*) == wide);
        if (bits != 0) return i + (scan_vlen - 1 - @clz(bits));
    }
    const narrow: Vec = @splat(c);
    while (i >= vlen) {
        i -= vlen;
        const bits: Mask = @bitCast(@as(Vec, hay[i..][0..vlen].*) == narrow);
        if (bits != 0) return i + (vlen - 1 - @clz(bits));
    }
    while (i > 0) {
        i -= 1;
        if (hay[i] == c) return i;
    }
    return null;
}

/// Count occurrences of byte `c` in `hay` — SIMD (per-block match mask popcount).
/// The incremental line-number counter for the line-free scanner (rg's
/// `lines::count`), paid only over the gap between consecutive emitted lines.
pub fn countByte(hay: []const u8, c: u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    const wide: ScanVec = @splat(c);
    while (i + scan_vlen <= hay.len) : (i += scan_vlen)
        n += @popCount(@as(ScanMask, @bitCast(@as(ScanVec, hay[i..][0..scan_vlen].*) == wide)));
    const narrow: Vec = @splat(c);
    while (i + vlen <= hay.len) : (i += vlen)
        n += @popCount(@as(Mask, @bitCast(@as(Vec, hay[i..][0..vlen].*) == narrow)));
    while (i < hay.len) : (i += 1) n += @intFromBool(hay[i] == c);
    return n;
}

/// Count `c` in `hay` AND report whether any `other` byte occurs — one fused
/// SIMD pass (two splats, two compares, one `popCount` + one OR per block). The
/// `--json` single-file base pass needs both the per-chunk newline count (line
/// base) and a binary sniff (any NUL); folding them keeps memory traffic at 1×
/// the chunk where two `countByte`/`memchr` calls would pay 2×. Byte-exact with
/// `countByte(hay, c)` and `indexOfScalar(hay, other) != null`.
pub fn countByteWithFlag(hay: []const u8, c: u8, other: u8) struct { count: usize, seen: bool } {
    var i: usize = 0;
    var n: usize = 0;
    var seen = false;
    const cw: ScanVec = @splat(c);
    const ow: ScanVec = @splat(other);
    while (i + scan_vlen <= hay.len) : (i += scan_vlen) {
        const blk: ScanVec = hay[i..][0..scan_vlen].*;
        n += @popCount(@as(ScanMask, @bitCast(blk == cw)));
        seen = seen or @as(ScanMask, @bitCast(blk == ow)) != 0;
    }
    const cv: Vec = @splat(c);
    const ov: Vec = @splat(other);
    while (i + vlen <= hay.len) : (i += vlen) {
        const blk: Vec = hay[i..][0..vlen].*;
        n += @popCount(@as(Mask, @bitCast(blk == cv)));
        seen = seen or @as(Mask, @bitCast(blk == ov)) != 0;
    }
    while (i < hay.len) : (i += 1) {
        n += @intFromBool(hay[i] == c);
        seen = seen or hay[i] == other;
    }
    return .{ .count = n, .seen = seen };
}

fn memchrPos(hay: []const u8, from: usize, c: u8) ?usize {
    var i: usize = from;
    const wide: ScanVec = @splat(c);
    while (i + scan_vlen <= hay.len) : (i += scan_vlen) {
        const bits: ScanMask = @bitCast(@as(ScanVec, hay[i..][0..scan_vlen].*) == wide);
        if (bits != 0) return i + @ctz(bits);
    }
    const narrow: Vec = @splat(c);
    while (i + vlen <= hay.len) : (i += vlen) {
        const bits: Mask = @bitCast(@as(Vec, hay[i..][0..vlen].*) == narrow);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == c) return i;
    return null;
}

/// ASCII-caseless substring presence — the `-i` twin of `contains`. `needle`
/// MUST be pre-folded to ASCII lowercase by the caller, and the gate producers
/// own the soundness bounds (ASCII-only literal, Kelvin/long-s orbits excluded
/// under Unicode fold — `query.zig::foldClosedWindow`). Same first+last-byte SIMD
/// scheme, each anchor compared against both case spellings; survivors pay one
/// bytewise caseless verify. Presence-exact with a scalar
/// `ascii.eqlIgnoreCase` sliding scan.
pub fn containsCaseless(hay: []const u8, needle: []const u8) bool {
    return indexOfCaselessPos(hay, 0, needle) != null;
}

/// Leftmost ASCII-caseless occurrence of `needle` (pre-lowered) at or after
/// `from` — the position-returning core `containsCaseless` rides, and the
/// scan the gated line-verify loops drive (find a window hit, run the engine
/// on just that line).
pub fn indexOfCaselessPos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    const n = needle.len;
    if (n == 0) return if (from <= hay.len) from else null;
    if (from >= hay.len or n > hay.len - from) return null;
    if (n == 1) {
        const m0 = foldMask(needle[0]);
        return memchrFoldPos(hay, from, m0, needle[0] | m0);
    }

    // ASCII fold via bit 5: 'A'|0x20=='a'. Per-anchor fold mask = 0x20 for a
    // letter, else 0 — OR the window with it and ONE exact compare matches both
    // case spellings of a letter yet stays byte-exact for a non-letter anchor
    // (a 0 mask ⇒ no spurious survivors, the win over a blanket `|0x20`). The
    // needle is pre-lowered, so folding it too (`needle[·]|mask`) is a no-op
    // that also hardens against an un-lowered byte.
    const mask0 = foldMask(needle[0]);
    const maskL = foldMask(needle[n - 1]);
    const fm0: Vec = @splat(mask0);
    const fmL: Vec = @splat(maskL);
    const first: Vec = @splat(needle[0] | mask0);
    const last: Vec = @splat(needle[n - 1] | maskL);
    const last_off = n - 1;

    var i: usize = from;
    // Both windows [i, i+vlen) and [i+last_off, i+last_off+vlen) stay in bounds.
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        const bits: Mask = @bitCast(((bf | fm0) == first) & ((bl | fmL) == last));
        var survivors = bitsmod.ones(bits);
        while (survivors.next()) |j| {
            const pos = i + j;
            if (eqlCaseless(hay[pos .. pos + n], needle)) return pos;
        }
    }
    // Scalar tail for the < vlen remainder.
    while (i + n <= hay.len) : (i += 1) if (eqlCaseless(hay[i .. i + n], needle)) return i;
    return null;
}

/// The ASCII case-fold mask for one byte: `0x20` iff it is a letter (so
/// `b | 0x20` folds its case), else `0` (so `b | 0` is an exact match). Bit 5
/// is the sole upper/lower difference across ASCII letters.
inline fn foldMask(b: u8) u8 {
    return if (std.ascii.isAlphabetic(b)) 0x20 else 0;
}

/// Bytewise caseless equality against a pre-lowered needle (one fold per hay
/// byte — the survivor-verify cost the caseless kernel pays).
fn eqlCaseless(hay: []const u8, needle_lower: []const u8) bool {
    for (hay, needle_lower) |h, l| if (std.ascii.toLower(h) != l) return false;
    return true;
}

/// Single-byte caseless find: OR each window with `mask` (0x20 for a letter,
/// else 0) and compare once against the folded byte `lo` — one OR + one
/// compare, vs the two compares a lower|upper pair costs, and exact for a
/// non-letter (mask 0).
fn memchrFoldPos(hay: []const u8, from: usize, mask: u8, lo: u8) ?usize {
    var i: usize = from;
    const mw: ScanVec = @splat(mask);
    const lw: ScanVec = @splat(lo);
    while (i + scan_vlen <= hay.len) : (i += scan_vlen) {
        const bits: ScanMask = @bitCast((@as(ScanVec, hay[i..][0..scan_vlen].*) | mw) == lw);
        if (bits != 0) return i + @ctz(bits);
    }
    const mv: Vec = @splat(mask);
    const lv: Vec = @splat(lo);
    while (i + vlen <= hay.len) : (i += vlen) {
        const bits: Mask = @bitCast((@as(Vec, hay[i..][0..vlen].*) | mv) == lv);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) if (hay[i] | mask == lo) return i;
    return null;
}

/// A literal presence gate, threaded from the pattern analyzers to every
/// needle consumer (the whole-file drop and the per-line engine bypass).
/// `ci` selects the caseless kernel — `bytes` are then pre-folded ASCII
/// lowercase and the producer has proven the fold ASCII-closed. `equiv`
/// records a producer-proven match EQUIVALENCE (the pattern IS this one pure
/// literal), which lets the `-l` fast path emit on a gate hit alone.
pub const Gate = struct {
    bytes: []const u8,
    ci: bool = false,
    equiv: bool = false,

    pub inline fn in(self: Gate, hay: []const u8) bool {
        return if (self.ci) containsCaseless(hay, self.bytes) else contains(hay, self.bytes);
    }

    /// Leftmost gate occurrence at or after `from` — lets a doc loop jump
    /// hit-to-hit at SIMD speed and run the engine only on the hit's line.
    pub inline fn find(self: Gate, hay: []const u8, from: usize) ?usize {
        return if (self.ci) indexOfCaselessPos(hay, from, self.bytes) else indexOfPos(hay, from, self.bytes);
    }
};
