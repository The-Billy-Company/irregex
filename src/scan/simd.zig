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

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

pub fn contains(hay: []const u8, needle: []const u8) bool {
    const n = needle.len;
    if (n == 0) return true;
    if (n > hay.len) return false;
    if (n == 1) return memchr(hay, needle[0]);

    const first: Vec = @splat(needle[0]);
    const last: Vec = @splat(needle[n - 1]);
    const last_off = n - 1;

    var i: usize = 0;
    // Both windows [i, i+vlen) and [i+last_off, i+last_off+vlen) stay in bounds.
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        var bits: Mask = @bitCast((bf == first) & (bl == last));
        while (bits != 0) {
            const j = @ctz(bits);
            const pos = i + j;
            if (std.mem.eql(u8, hay[pos .. pos + n], needle)) return true;
            bits &= bits - 1; // clear lowest set bit
        }
    }
    // Scalar tail for the < vlen remainder.
    return std.mem.indexOfPos(u8, hay, i, needle) != null;
}

fn memchr(hay: []const u8, c: u8) bool {
    const cv: Vec = @splat(c);
    var i: usize = 0;
    while (i + vlen <= hay.len) : (i += vlen) {
        const blk: Vec = hay[i..][0..vlen].*;
        const bits: Mask = @bitCast(blk == cv);
        if (bits != 0) return true;
    }
    while (i < hay.len) : (i += 1) if (hay[i] == c) return true;
    return false;
}
