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

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

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
/// pays N× on a miss (the common case for a file-level gate). Needles
/// shorter than 2 bytes (or a set past the cap) fall back to the per-needle
/// loop; correctness is identical either way.
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

fn memchrPos(hay: []const u8, from: usize, c: u8) ?usize {
    const cv: Vec = @splat(c);
    var i: usize = from;
    while (i + vlen <= hay.len) : (i += vlen) {
        const blk: Vec = hay[i..][0..vlen].*;
        const bits: Mask = @bitCast(blk == cv);
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
    if (n == 1) return memchr2Pos(hay, from, needle[0], std.ascii.toUpper(needle[0]));

    const fl: Vec = @splat(needle[0]);
    const fu: Vec = @splat(std.ascii.toUpper(needle[0]));
    const ll: Vec = @splat(needle[n - 1]);
    const lu: Vec = @splat(std.ascii.toUpper(needle[n - 1]));
    const last_off = n - 1;

    var i: usize = from;
    // Both windows [i, i+vlen) and [i+last_off, i+last_off+vlen) stay in bounds.
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        const bits: Mask = (@as(Mask, @bitCast(bf == fl)) | @as(Mask, @bitCast(bf == fu))) &
            (@as(Mask, @bitCast(bl == ll)) | @as(Mask, @bitCast(bl == lu)));
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

/// Bytewise caseless equality against a pre-lowered needle (one fold per hay
/// byte — the survivor-verify cost the caseless kernel pays).
fn eqlCaseless(hay: []const u8, needle_lower: []const u8) bool {
    for (hay, needle_lower) |h, l| if (std.ascii.toLower(h) != l) return false;
    return true;
}

/// Two-byte-class find (the 1-byte caseless needle: lower|upper spelling).
fn memchr2Pos(hay: []const u8, from: usize, a: u8, b: u8) ?usize {
    const av: Vec = @splat(a);
    const bv: Vec = @splat(b);
    var i: usize = from;
    while (i + vlen <= hay.len) : (i += vlen) {
        const blk: Vec = hay[i..][0..vlen].*;
        const bits: Mask = @as(Mask, @bitCast(blk == av)) | @as(Mask, @bitCast(blk == bv));
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == a or hay[i] == b) return i;
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
