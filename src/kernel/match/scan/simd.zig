//! gist — SIMD substring presence test (the hot primitive in the verify path).
//!
//! Why this exists (proven, not assumed — read `std/mem.zig::findPos`): Zig's
//! `std.mem.indexOf` is SIMD only for a 1-byte needle; lengths **2–4** fall to
//! `findPosLinear` (a naive byte loop) and 5+ to Boyer-Moore-Horspool (a scalar
//! skip table, no vector scan). Code search is dominated by 2–4 byte needles
//! (`})`, `ctx`, `func`, `=>`, `::`, `fn`), so that naive path is the hot loss.
//!
//! `contains` runs the memchr-style "generic SIMD" (as in Rust's memchr crate):
//! splat the needle's two RAREST bytes (corpus density — `rarity.zig`),
//! vector-compare both windows across a 64-byte block, AND the masks, and only
//! `eql`-verify the few surviving positions. Every block loop is gated on
//! `anyLane` (a cheap OR-reduce) so miss blocks — the stream — never pay the
//! movemask, and a genuinely-rare probe byte earns a single-load block filter
//! with a runtime demotion guard for buffers the density table doesn't
//! describe. Returns presence (the verify path only needs a bool). Byte-exact
//! with `std.mem.indexOf` — proven end-to-end by the rg equality oracle and
//! the differential fuzz in `bench/`.

const std = @import("std");
const bitsmod = @import("../../primitives/bits.zig");
const teddy = @import("teddy.zig");
const rarity = @import("rarity.zig");

/// Needle count at which the fused any-of gate hands off to Teddy. Below this
/// the fused first+last gate's `1 + N` loads/block are cheap and its wide
/// (`scan_vlen`) block wins on AVX2/512; at 4+ Teddy's constant 2 loads/block win on
/// every architecture regardless of vector width (measured: N=4 1.6×, N=8 2.2×
/// on Apple M4). Both paths are byte-exact — this is a throughput dispatch, not
/// a fallback. `teddy.max_buckets` (8) caps both, so the handoff never fails.
const teddy_min: usize = 4;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Wide stride for the streaming scanners (`memchr`, `countByte`, reverse
/// memchr, the caseless single-byte find, AND `indexOfPos`'s block loop).
/// Measured on Apple M4 (2026-07-22, `bench/harness/flagbench` + a width
/// sweep): a 64-byte stride runs a one-load-per-block scan ~35% faster than
/// the 16-byte NEON register — the out-of-order core issues the four
/// independent 16-byte loads across its NEON pipes. A `vlen`-wide second tier
/// runs before the scalar tail so a haystack shorter than `scan_vlen` still
/// vectorizes.
const scan_vlen: usize = @max(vlen, 64);
const ScanVec = @Vector(scan_vlen, u8);
const ScanMask = std.meta.Int(.unsigned, scan_vlen);

/// The cheap per-block gate of every streaming loop: "did ANY lane hit?".
/// `@reduce(.Or)` over the compare mask lowers to a short cross-lane OR tree
/// (NEON: 3 `orr` + a halving reduce; AVX2: `vpmovmskb`+test), where
/// `@bitCast`-to-integer — the movemask emulation — costs a multi-µop
/// widen/shift/accumulate sequence PER BLOCK on NEON. Movemask still runs to
/// name positions, but only inside blocks this gate already proved hot
/// (roofline 2026-07-23 on M4: gating the dual-window kernel on this lifted
/// the contiguous streaming scan 44.8 → 53.6 GB/s and the per-file corpus
/// scan 20.8 → 30.2 GB/s with the tail + probe work; see bench/roofline).
inline fn anyLane(eq: @Vector(scan_vlen, bool)) bool {
    if (comptime @import("builtin").cpu.arch.isX86())
        return @as(ScanMask, @bitCast(eq)) != 0; // vpmovmskb + test — already cheap
    // NEON path: materialize the compare as its native 0xFF/0x00 byte mask
    // (LLVM folds the select into the compare result), then OR-reduce u64
    // lanes — a short word-wide tree. Both `@reduce(.Or, bool-vector)` and
    // `@bitCast`-to-int lower to a multi-µop per-lane widen/accumulate here
    // (measured: the i1 reduce ran the streaming scan 30% SLOWER on M4;
    // this form ran it 21% faster than the per-block movemask baseline).
    const m: ScanVec = @select(u8, eq, @as(ScanVec, @splat(0xff)), @as(ScanVec, @splat(0)));
    const words: @Vector(scan_vlen / 8, u64) = @bitCast(m);
    return @reduce(.Or, words) != 0;
}

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

    var f: [max_any]ScanVec = undefined;
    var l: [max_any]ScanVec = undefined;
    for (needles, 0..) |n, k| {
        f[k] = @splat(n[0]);
        l[k] = @splat(n[n.len - 1]);
    }
    var i: usize = 0;
    // Wide fused blocks, gated on ONE `anyLane` over the OR of the per-needle
    // masks — a miss block pays loads + compares + one cheap reduce, never
    // the N movemasks the survivor walk needs (paid only in hit blocks).
    // Every window [i+off, i+off+scan_vlen), off <= max_off, stays in bounds.
    while (i + max_off + scan_vlen <= hay.len) : (i += scan_vlen) {
        const b0: ScanVec = hay[i..][0..scan_vlen].*;
        var eqs: [max_any]@Vector(scan_vlen, bool) = undefined;
        var any: @Vector(scan_vlen, bool) = @splat(false);
        for (needles, 0..) |n, k| {
            const bl: ScanVec = hay[i + n.len - 1 ..][0..scan_vlen].*;
            eqs[k] = (b0 == f[k]) & (bl == l[k]);
            any |= eqs[k];
        }
        if (!anyLane(any)) continue;
        var per: [max_any]ScanMask = undefined;
        var mask: ScanMask = 0;
        for (needles, 0..) |_, k| {
            per[k] = @bitCast(eqs[k]);
            mask |= per[k];
        }
        var survivors = bitsmod.ones(mask);
        while (survivors.next()) |j| {
            const pos = i + j;
            const bit = @as(ScanMask, 1) << j;
            for (needles, 0..) |n, k| {
                if (per[k] & bit != 0 and std.mem.eql(u8, hay[pos..][0..n.len], n)) return true;
            }
        }
    }
    // Vector tail: candidate starts in [i, hay.len) the fused loop never saw
    // (our own kernel — no per-call BMH table like `std.mem.indexOfPos`).
    for (needles) |n| if (indexOfPos(hay, i, n) != null) return true;
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

    var f: [max_any]ScanVec = undefined;
    var l: [max_any]ScanVec = undefined;
    for (needles, 0..) |n, k| {
        f[k] = @splat(n[0]);
        l[k] = @splat(n[n.len - 1]);
    }
    var i: usize = from;
    // Wide fused blocks gated on one `anyLane` (see `containsAny`) — the N
    // movemasks run only inside hit blocks, where the survivor walk needs
    // per-needle attribution. Every window [i+off, i+off+scan_vlen),
    // off <= max_off, stays in bounds.
    while (i + max_off + scan_vlen <= hay.len) : (i += scan_vlen) {
        const b0: ScanVec = hay[i..][0..scan_vlen].*;
        var eqs: [max_any]@Vector(scan_vlen, bool) = undefined;
        var any: @Vector(scan_vlen, bool) = @splat(false);
        for (needles, 0..) |n, k| {
            const bl: ScanVec = hay[i + n.len - 1 ..][0..scan_vlen].*;
            eqs[k] = (b0 == f[k]) & (bl == l[k]);
            any |= eqs[k];
        }
        if (!anyLane(any)) continue;
        var per: [max_any]ScanMask = undefined;
        var mask: ScanMask = 0;
        for (needles, 0..) |_, k| {
            per[k] = @bitCast(eqs[k]);
            mask |= per[k];
        }
        var survivors = bitsmod.ones(mask);
        while (survivors.next()) |j| {
            const pos = i + j;
            const bit = @as(ScanMask, 1) << j;
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

/// Ascending survivor walk of one wide block: movemask (paid only in blocks
/// `anyLane` proved hot), then eql-verify each candidate — the first match is
/// the block's leftmost.
inline fn verifyBlock(hay: []const u8, needle: []const u8, i: usize, eq: @Vector(scan_vlen, bool)) ?usize {
    var survivors = bitsmod.ones(@as(ScanMask, @bitCast(eq)));
    while (survivors.next()) |j| {
        const pos = i + j;
        if (std.mem.eql(u8, hay[pos .. pos + needle.len], needle)) return pos;
    }
    return null;
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

    const last_off = n - 1;
    var i: usize = from;

    // Anchor selection: the needle's two RAREST bytes by corpus density
    // (`rarity.zig`), at ANY offsets — a candidate start is `i + j` for any
    // start-relative window, and the eql verify confirms the rest, so the
    // filter is free to anchor on `Z…9` where first+last would anchor on
    // `Z…_` (49% of blocks contain `_`). One L1-cheap pass over the needle.
    var o1: usize = 0; // rarest byte's offset (the probe)
    var o2: usize = last_off; // second-rarest (the confirm)
    {
        var best: u16 = 256;
        var second: u16 = 256;
        for (needle, 0..) |b, k| {
            const d = rarity.density[b];
            if (d < best) {
                second = best;
                o2 = o1;
                best = d;
                o1 = k;
            } else if (d < second) {
                second = d;
                o2 = k;
            }
        }
    }
    const p1: ScanVec = @splat(needle[o1]);
    const p2: ScanVec = @splat(needle[o2]);

    // Wide tier: 64-byte blocks gated on `anyLane` — a miss block never pays
    // the movemask. Two shapes: a GENUINELY rare probe (predictable,
    // rarely-taken branch) earns a single-load block filter that touches the
    // confirm window only on probe hits; a dense probe keeps both loads
    // unconditional — its block-gate branch fires on the CONJUNCTION, where a
    // single-probe branch on a dense byte mispredicts the loop into the
    // ground (measured: halved throughput on a uniform-random buffer). The
    // static density table nominates the shape; a runtime hit counter keeps
    // it honest on buffers the table doesn't describe (base64 blobs, minified
    // bundles, random-looking text): sustained probe-hit rate past ~12.5%
    // demotes THIS call to the dual shape for the rest of the buffer.
    if (rarity.density[needle[o1]] <= rarity.single_probe_max) {
        var blocks: usize = 0;
        var hot: usize = 0;
        while (i + last_off + scan_vlen <= hay.len) : (i += scan_vlen) {
            // Prefetch accelerates the HW prefetcher's ramp on fresh streams —
            // a many-small-files scan restarts the stream at every doc
            // boundary, and the ramp is the dominant per-doc tax.
            @prefetch(&hay[@min(i + 8 * scan_vlen, hay.len - 1)], .{ .rw = .read, .locality = 2 });
            const eq1 = @as(ScanVec, hay[i + o1 ..][0..scan_vlen].*) == p1;
            blocks += 1;
            if (!anyLane(eq1)) continue;
            hot += 1;
            if (hot << 3 > blocks + 8) break; // demote: probe isn't selective HERE (block unscanned — the dual loop below re-enters at this `i`)
            const eq = eq1 & (@as(ScanVec, hay[i + o2 ..][0..scan_vlen].*) == p2);
            if (!anyLane(eq)) continue;
            if (verifyBlock(hay, needle, i, eq)) |pos| return pos;
        }
    }
    while (i + last_off + scan_vlen <= hay.len) : (i += scan_vlen) {
        @prefetch(&hay[@min(i + 8 * scan_vlen, hay.len - 1)], .{ .rw = .read, .locality = 2 });
        const eq = (@as(ScanVec, hay[i + o1 ..][0..scan_vlen].*) == p1) &
            (@as(ScanVec, hay[i + o2 ..][0..scan_vlen].*) == p2);
        if (!anyLane(eq)) continue;
        if (verifyBlock(hay, needle, i, eq)) |pos| return pos;
    }

    // Narrow tier: the < scan_vlen remainder (and any haystack too short for
    // the wide tier) still vectorizes at `vlen`.
    const first: Vec = @splat(needle[0]);
    const last: Vec = @splat(needle[n - 1]);
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
    // Overlapped final block: rewind to the last in-bounds `vlen` window so
    // the remainder scans vectorized. Positions < i were already rejected and
    // re-verify idempotently (and survivors ascend), so leftmost-first holds
    // with no dedup. This replaces a `std.mem.indexOfPos` tail that, for a
    // 5+-byte needle in a >= 52-byte haystack, built a 256-entry BMH skip
    // table PER CALL — a ~2 KiB store burst that dominated per-file cost on
    // a many-small-files corpus (roofline: 20693 files · ~10 KiB average).
    if (hay.len >= last_off + vlen and hay.len - last_off - vlen >= from) {
        const back = hay.len - last_off - vlen;
        const bf: Vec = hay[back..][0..vlen].*;
        const bl: Vec = hay[back + last_off ..][0..vlen].*;
        const bits: Mask = @bitCast((bf == first) & (bl == last));
        var survivors = bitsmod.ones(bits);
        while (survivors.next()) |j| {
            const pos = back + j;
            if (std.mem.eql(u8, hay[pos .. pos + n], needle)) return pos;
        }
        return null;
    }
    // Tiny remainder (< vlen + last_off bytes): bounded linear verify.
    while (i + n <= hay.len) : (i += 1)
        if (std.mem.eql(u8, hay[i .. i + n], needle)) return i;
    return null;
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
        const eq = @as(ScanVec, hay[i..][0..scan_vlen].*) == wide;
        if (anyLane(eq)) return i + @ctz(@as(ScanMask, @bitCast(eq)));
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
    const last_off = n - 1;
    var i: usize = from;

    // Wide tier: 64-byte blocks gated on `anyLane` — a miss block never pays
    // the movemask (same shape as `indexOfPos`'s dense-probe loop).
    const wfm0: ScanVec = @splat(mask0);
    const wfmL: ScanVec = @splat(maskL);
    const wfirst: ScanVec = @splat(needle[0] | mask0);
    const wlast: ScanVec = @splat(needle[n - 1] | maskL);
    while (i + last_off + scan_vlen <= hay.len) : (i += scan_vlen) {
        const bf: ScanVec = hay[i..][0..scan_vlen].*;
        const bl: ScanVec = hay[i + last_off ..][0..scan_vlen].*;
        const eq = ((bf | wfm0) == wfirst) & ((bl | wfmL) == wlast);
        if (!anyLane(eq)) continue;
        var survivors = bitsmod.ones(@as(ScanMask, @bitCast(eq)));
        while (survivors.next()) |j| {
            const pos = i + j;
            if (eqlCaseless(hay[pos .. pos + n], needle)) return pos;
        }
    }

    // Narrow tier + scalar tail for the < scan_vlen remainder.
    const fm0: Vec = @splat(mask0);
    const fmL: Vec = @splat(maskL);
    const first: Vec = @splat(needle[0] | mask0);
    const last: Vec = @splat(needle[n - 1] | maskL);
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
