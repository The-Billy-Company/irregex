//! irregex — SIMD substring presence test (the hot primitive in the verify
//! path).
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
const builtin = @import("builtin");
const assay = @import("../../assay/assay.zig"); // instrumentation floor: the plan A/B switch
const bitsmod = @import("../math/bits.zig");
const calibrate = @import("calibrate.zig");
const teddy = @import("teddy.zig");
const rarity = @import("rarity.zig");
const anchor = @import("anchor.zig");

/// Needle count at which the fused any-of gate hands off to Teddy — every set
/// with more than one needle, which is every set that has a choice.
///
/// It was 4, and the number was calibrated at N=4 (1.6×) and N=8 (2.2×) on Apple
/// M4 without measuring the band it created. The band was where the loss lived:
/// the fused gate's `1 + N` loads/block are only cheap when the survivor rate is,
/// and its first+last fingerprint is *degenerate* for a short needle over a
/// correlated alphabet — a 2-byte UTF-8 needle fingerprints on its own two bytes,
/// so every occurrence of the lead byte survives to `eql`. The tell was that
/// adding a FOURTH needle made the same scan several times FASTER, because the
/// fourth needle crossed the threshold: a dispatch whose cost falls when the work
/// grows is the threshold being wrong, not the kernels.
///
/// Measured on a 268 MB mixed-script corpus, `-c` over an alternation of N UTF-8
/// literals, minimum of 15 runs, counts identical to rg at every width:
///
///   | needles | wall  | cpu    | rg wall | rg cpu |
///   |---------|-------|--------|---------|--------|
///   | 2       | 17.3  | 65.9   | 87.1    | 87.8   |
///   | 3       | 16.9  | 68.0   | 88.4    | 88.9   |
///   | 4       | 17.8  | 70.9   | 87.0    | 87.9   |
///   | 6       | 22.7  | 66.7   | 126.3   | 102.3  |
///
/// Flat in N, which is the property being bought: the band is gone rather than
/// moved, and no width is now served by the arm that loses on it.
///
/// Both paths are byte-exact — this is a throughput dispatch, not a fallback.
/// `teddy.max_buckets` (8) caps both, so the handoff never fails; `Teddy.init`
/// declines a set it cannot bucket and the fused gate still catches it.
const teddy_min: usize = 2;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Wide stride for the streaming scanners (`memchr`, `countByte`, reverse
/// memchr, the caseless single-byte find, AND `indexOfPos`'s block loop).
/// Measured on Apple M4 (2026-07-22, the face package's
/// `bench/apparatus/harness/flagbench` + a width sweep): a 64-byte stride runs a
/// one-load-per-block scan ~35% faster than the 16-byte NEON register — the
/// out-of-order core issues the four independent 16-byte loads across its NEON
/// pipes. A `vlen`-wide second tier runs before the scalar tail so a haystack
/// shorter than `scan_vlen` still vectorizes.
const scan_vlen: usize = @max(vlen, 64);
const ScanVec = @Vector(scan_vlen, u8);
const ScanMask = std.meta.Int(.unsigned, scan_vlen);

/// The streaming block stride, published so a matched control cannot invent
/// its own. RECORDED DEFECT (2026-07-29): `bench/bounds/roofline` declared
/// `suggestVectorLength(u8) orelse 16` locally — 16 bytes on NEON against this
/// 64 — so its "matched dual-window control" ran four times the iterations and
/// measured ~10% SLOWER than the production path it was built to upper-bound.
/// Anything claiming to be matched reads this, `anchorsOf`, and `anyLane`.
pub const block_bytes: usize = scan_vlen;

/// A wide compare mask, in the geometry `anyLane` accepts.
pub const BlockHits = @Vector(scan_vlen, bool);

/// Ask the memory system for a block the streaming loops will reach in eight
/// iterations — where asking is worth anything.
///
/// A software prefetch buys a sequential scan nothing that the hardware stream
/// prefetcher does not already do; the only thing it can sell is a faster RAMP,
/// on a stream the hardware has not recognized yet. Whether that is worth its
/// slot in the loop is a property of the core, not of the kernel, and it is not
/// something any CPUID bit reports — so it is measured per target and named
/// here rather than left inline where it reads as free.
///
/// **x86-64: declined, measured.** On Raptor Lake the hint costs the
/// single-probe block loop **1.29×** (0.0450 → 0.0349 tick/B, `Qzxjvw` over
/// 8 MiB, min-of-24 round-robin after warmup, `taskset` to a P-core). The L2
/// streamer recognizes the stride immediately and the loop is issue-bound, so
/// the hint is a pure µop tax. This is the coefficient that put the exact
/// literal kernel BEHIND a bare `memchr` on the first byte (`settle_literal_one`
/// 0.092 vs `skip_scan` 0.069 cyc/B) and cost the auction a 1.32× regret on
/// `Qzxjvw`, which is how it was found.
///
/// **aarch64: kept.** Its measured cost/benefit is the reason
/// `bench/bounds/roofline` exists; the ladder there is what re-prices it.
///
/// Callers pass the block base and the loop's own bound, so the clamp stays one
/// expression and no call site re-derives it.
pub inline fn streamAhead(buf: []const u8, at: usize) void {
    if (comptime builtin.cpu.arch.isX86()) return;
    @prefetch(&buf[@min(at + 8 * scan_vlen, buf.len - 1)], .{ .rw = .read, .locality = 2 });
}

/// The cheap per-block gate of every streaming loop: "did ANY lane hit?".
/// `@reduce(.Or)` over the compare mask lowers to a short cross-lane OR tree
/// (NEON: 3 `orr` + a halving reduce; AVX2: `vpmovmskb`+test), where
/// `@bitCast`-to-integer — the movemask emulation — costs a multi-µop
/// widen/shift/accumulate sequence PER BLOCK on NEON. Movemask still runs to
/// name positions, but only inside blocks this gate already proved hot
/// (roofline 2026-07-23 on M4: gating the dual-window kernel on this lifted
/// the contiguous streaming scan 44.8 → 53.6 GB/s and the per-file corpus
/// scan 20.8 → 30.2 GB/s with the tail + probe work; see bench/roofline).
pub inline fn anyLane(eq: BlockHits) bool {
    if (comptime @import("builtin").cpu.arch.isX86())
        return bitsmod.laneMask(ScanMask, eq) != 0; // vpmovmskb + test — already cheap
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
            per[k] = bitsmod.laneMask(ScanMask, eqs[k]);
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
/// `indexOfAnyPos` against a caller's pre-minted anchor decision.
///
/// `plan` applies to the ONE-needle set only — the same contract `verify.oneShot`
/// carries, and for the same reason: a genuine alternation's fused pass anchors
/// every needle on its own first+last byte, so there is no single pair to supply
/// and a plan would have nowhere to go. Passing one for a multi-needle set is
/// silently ignored rather than an error, because the natural caller is a loop
/// that mints `if (needles.len == 1) planOn(...) else null` once and then does not
/// want to re-test arity per iteration.
///
/// The reason this entry point exists: a hit-jumping doc loop calls the plain
/// `indexOfAnyPos` once per HIT, and the one-needle delegation below lands in
/// `core`'s lazy `planOf`. On a body with millions of filter survivors that is the
/// static pair being re-derived per hit AND — the expensive half — the static pair
/// being used at all. Hoisting the decision to the document lets it be a
/// *calibrated* pair, which is where the order of magnitude is.
pub fn indexOfAnyPosWith(hay: []const u8, from: usize, needles: []const []const u8, plan: ?Plan) ?usize {
    if (needles.len == 1) if (plan) |p| return indexOfPosWith(hay, from, needles[0], p);
    return indexOfAnyPos(hay, from, needles);
}

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
            per[k] = bitsmod.laneMask(ScanMask, eqs[k]);
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
    var survivors = bitsmod.ones(bitsmod.laneMask(ScanMask, eq));
    while (survivors.next()) |j| {
        const pos = i + j;
        if (std.mem.eql(u8, hay[pos .. pos + needle.len], needle)) return pos;
    }
    return null;
}

/// The two offsets `indexOfPos` filters a block on: the needle's rarest and
/// second-rarest bytes by corpus density (`rarity.zig`), at ANY offsets — the
/// eql verify confirms the rest, so the filter is free to anchor on `Z…9`
/// where first+last would anchor on `Z…_` (49% of blocks contain `_`).
///
/// Public for the same reason as `block_bytes`: a control that re-derives its
/// own anchors is not measuring this kernel. RECORDED DEFECT (2026-07-29): the
/// roofline control filtered on `needle[0]`/`needle[len-1]`, so on the needle
/// `Zq9_…` it probed `Z…_` (density 7 and 255) where production probes `Z…q`
/// (7 and 55) — a different, far less selective filter.
///
/// The policy itself lives in `anchor.zig` — including the RECORDED DEFECT that
/// the marginal-rarity selection this function used to inline was, on a
/// lowercase identifier, worse than the fixed first+last it replaced. Do not
/// re-inline it here: one decision, one module, so a control cannot disagree
/// with the kernel it bounds.
pub fn anchorsOf(needle: []const u8) anchor.Pair {
    return anchor.select(needle);
}

/// Whether `indexOfPos` will *enter* the single-probe loop for this needle —
/// one load and one compare per block instead of two. Published for the same
/// reason as `anchorsOf`. RECORDED DEFECT (2026-07-29): the roofline's control
/// was unconditionally dual-window, so on a rare-anchored needle it measured a
/// path production never takes and came in ~10% BELOW the production line it
/// was supposed to bound. Entry is not the whole story — the demotion guard
/// inside the loop can still fall through to the dual shape mid-buffer.
pub inline fn singleProbeEligible(needle: []const u8) bool {
    return needle.len > 1 and anchor.singleProbeWorthwhile(needle, anchorsOf(needle));
}

/// Substring presence, byte-exact with `std.mem.indexOf != null` (see the
/// module doc for the first+last-byte SIMD scheme and why it beats std here).
pub fn contains(hay: []const u8, needle: []const u8) bool {
    return indexOfPos(hay, 0, needle) != null;
}

/// The anchor decision, hoisted so a caller can pay for it ONCE and reuse it
/// across many calls with the same needle.
///
/// `anchor.select` is not free — it holds the six marginally-rarest offsets and
/// then prices all fifteen pairs among them against the fitted digraph table —
/// and `query.zig` calls `contains` once **per line**. Worse, the wide tier this
/// decision feeds only runs when `hay.len >= needle.len - 1 + block_bytes`, so on
/// a source line shorter than that the pair was computed and then never read.
/// Both of those are per-line waste that no amount of tuning inside the loop can
/// recover, because the work is outside it.
///
/// So the decision is a value. `planOf` is the static one; `contains`/`indexOfPos`
/// still call it lazily and only when the wide tier will actually run, so the
/// unplanned path got strictly cheaper rather than merely no worse.
pub const Plan = struct {
    pair: anchor.Pair,
    /// Whether the single-load block shape is worth entering — see
    /// `singleProbeEligible`. Cached with the pair because it is a pure function
    /// of it and the loop would otherwise re-derive it per call.
    single: bool,
};

/// The static plan: today's shipped policy, no sample of the haystack.
pub fn planOf(needle: []const u8) Plan {
    const pair = anchor.select(needle);
    return .{ .pair = pair, .single = anchor.singleProbeWorthwhile(needle, pair) };
}

/// The ONE mint every hoist site shares — a `Gate`, a one-needle `LiteralSet`, a
/// candidate verify. `null` where there is no decision to make: a 1-byte needle
/// goes straight to `memchr`, which takes no pair.
///
/// `<prefix>NO_PLAN` (internal, undocumented — the `<prefix>MUSTER_TIER` /
/// `<prefix>NO_COVER` idiom) stands the hoist down so BOTH arms are measurable on
/// ONE binary. That instrument is not a nicety here. This tree is edited by ~10
/// agents concurrently, so two binaries built even minutes apart differ by more
/// than the change under test — a two-build A/B of this very hoist reported a
/// 5.8× win on `-l` over a tree, which was coworkers' unrelated work being
/// attributed to an anchor decision. Measure one binary against itself.
///
/// Read once per query at a mint site, never inside a scan loop.
pub fn planFor(needle: []const u8) ?Plan {
    if (needle.len <= 1) return null;
    if (assay.envFlag("GIST_NO_PLAN")) return null;
    return planOf(needle);
}

/// `planFor`, priced on the buffer actually about to be searched instead of on a
/// shipped table — the seam `calibrate.zig`'s module doc has been waiting for
/// ("calibrate once when a document is admitted, then thread the chosen pair
/// through every line of that document"). Call it where a WHOLE document is in
/// hand, never per line: the size gate is a statement about the scan the sampling
/// has to amortize against, so evaluating it on a slice of the work prices the
/// wrong thing.
///
/// `calibrate.refine` declines below its own gate (3.1 MB at a 3-byte needle
/// rising to 16.8 MB at the offset cap) AND whenever the static pair is already
/// as good as anything the sample found, so the static plan is what almost every
/// document gets and the fallback is the common path, not the exception.
///
/// It is `refine` and not `best` on purpose. Adopting the sample's favorite
/// unconditionally was a measured 0.5–1.1% CPU tax with no row it won — the table
/// is already right most of the time, and swapping off it also forfeits the
/// single-probe shape for nothing. `refine` makes the incumbent compete on the
/// same sample; the defect is recorded in full at `calibrate.refine`.
pub fn planOn(hay: []const u8, needle: []const u8) ?Plan {
    return refineOn(hay, needle, planFor(needle) orelse return null);
}

/// `<prefix>NO_CALIBRATE`, answered once per PROCESS rather than once per document.
///
/// `refineOn` is a per-FILE seam, so this used to be a `getenv` — a linear walk
/// of `environ` with a `strcmp` per entry — for every file in the corpus. On this
/// tree (880 files, 16 KB mean) that is ~50 ns against a ~205 ns scan of the mean
/// document: a debug knob priced at a quarter of the work it gates, paid by every
/// run whether or not anybody set it.
///
/// Sound because the answer cannot move under us. Nothing in this kernel calls
/// `setenv`, and the A/B this knob exists for spawns a CHILD per arm
/// (`research/pincer/PROOF.md` §7.2.e — "child CPU time in one binary against
/// itself"), so "one binary" means one BUILD and each arm gets a fresh
/// environment read at its own startup. Relaxed ordering because the value is a
/// pure function of that environment: two threads racing here compute the same
/// answer, and a thread reading `unknown` after another has stored simply
/// computes it again.
var calibrate_knob: std.atomic.Value(u8) = .init(0); // 0 unknown · 1 on · 2 off

fn calibrateOff() bool {
    return switch (calibrate_knob.load(.monotonic)) {
        0 => blk: {
            const off = assay.envFlag("GIST_NO_CALIBRATE");
            calibrate_knob.store(@as(u8, 1) + @intFromBool(off), .monotonic);
            break :blk off;
        },
        1 => false,
        else => true,
    };
}

/// `planOn` against an incumbent the caller ALREADY HOLDS, returning the plan to
/// scan with — `held` itself whenever the sample has no material objection, which
/// is the common answer.
///
/// This is the seam every per-document caller wants, and the reason is arithmetic.
/// `planOn` re-derives its own incumbent through `planFor` -> `planOf` ->
/// `anchor.select`, which since the distance-conditioned joint correction costs
/// ~21 ns on a 4-8 byte needle and ~37 ns at 32 — but every per-document caller in
/// this kernel (`Gate.plan`, `LiteralSet.single.plan`) minted exactly that value
/// once per query and is holding it in a field. So the whole re-derivation is
/// recomputing a constant. Measured over this tree's 880 documents, a `planOn` per
/// file cost 142 ns of which `refine` itself — the part that reads the document —
/// was 2.7; the other 139 were the recomputed static plan plus the two `getenv`s
/// on the way to it.
///
/// **Idempotence lives in the caller now.** `planOn` bought it by refusing to look
/// at what the caller held; a caller that remembers the static plan and always
/// passes THAT (see `Gate.base`) gets the same property, because `held` is then by
/// construction the same value on file N+1 as it was on file N.
pub fn refineOn(hay: []const u8, needle: []const u8, held: Plan) Plan {
    if (calibrateOff()) return held;
    // `anchor.Pair`'s slots carry meaning and are NOT sorted, but a candidate
    // offset SET is unordered, so the incumbent goes in low-first. Declining
    // returns `held` untouched, so the slot assignment survives a decline.
    const pinned = if (held.pair.probe < held.pair.confirm)
        [2]usize{ held.pair.probe, held.pair.confirm }
    else
        [2]usize{ held.pair.confirm, held.pair.probe };
    const off = calibrate.refine(hay, needle, block_bytes, pinned) orelse return held;
    return .{
        .pair = .{ .probe = off[0], .confirm = off[1] },
        // RECORDED DEFECT (calibrate.zig doc, defect 3): `singleProbeWorthwhile`
        // prices the probe byte against the STATIC rarity table, so it cannot
        // judge a calibrated pair at all — and the input that makes it wrong is
        // exactly the one calibration produces, a byte that is statically rare and
        // locally common. That shape was measured at HALVED throughput on a
        // uniform-random buffer; the in-loop demotion counter catches it only
        // after paying for it. A calibrated plan therefore always takes the dual
        // loop, which needs no rarity claim about either byte.
        .single = false,
    };
}

/// `contains` against a pre-computed plan. Byte-identical verdict to `contains`
/// for any plan `anchor` can return — the pair only chooses which two offsets the
/// block filter compares, and `verifyBlock`'s `eql` is what decides a match — so
/// this is a cost seam, never a semantic one. The differential test pins that.
pub fn containsWith(hay: []const u8, needle: []const u8, plan: Plan) bool {
    return indexOfPosWith(hay, 0, needle, plan) != null;
}

/// Leftmost occurrence of `needle` at or after `from` — the position-returning
/// core `contains` rides, and the scan the needle-driven doc loops drive (jump
/// hit to hit at SIMD speed, engine only on the containing line).
pub fn indexOfPos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    return core(hay, from, needle, null);
}

/// `indexOfPos` against a pre-computed plan — see `Plan`. Same verdict, minus the
/// per-call anchor decision.
pub fn indexOfPosWith(hay: []const u8, from: usize, needle: []const u8, plan: Plan) ?usize {
    return core(hay, from, needle, plan);
}

/// `inline` so each entry point specializes: the `plan orelse` below folds to a
/// constant in both, and neither pays a branch for the other's shape.
inline fn core(hay: []const u8, from: usize, needle: []const u8, plan: ?Plan) ?usize {
    const n = needle.len;
    if (n == 0) return if (from <= hay.len) from else null;
    if (from >= hay.len or n > hay.len - from) return null;
    if (n == 1) return memchrPos(hay, from, needle[0]);

    const last_off = n - 1;
    var i: usize = from;

    // Anchor selection at ANY offsets — a candidate start is `i + j` for any
    // start-relative window, and the eql verify confirms the rest, so the
    // filter is free to anchor on `Z…9` where first+last would anchor on
    // `Z…_` (49% of blocks contain `_`). Policy and its recorded defects live
    // in `anchor.zig`; this loop only consumes the decision.
    //
    // Guarded on the wide tier's OWN entry condition, which is the point: both
    // wide loops below already test it per iteration, so hoisting it here is
    // behavior-identical and means a haystack too short for the wide tier —
    // every source line under `needle.len - 1 + block_bytes` — never prices an
    // anchor pair it cannot use. `plan` skips the decision outright.
    if (i + last_off + scan_vlen <= hay.len) {
        const chosen = plan orelse planOf(needle);
        const o1 = chosen.pair.probe;
        const o2 = chosen.pair.confirm;
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
        //
        // The two shapes are 1.42× apart on M4 (measured under layout
        // randomization, Mytkowicz et al. ASPLOS 2009 — see below), which makes
        // eligibility for the single-probe loop the only lever anyone has found on
        // this kernel. THREE attempts to speed up the dual loop itself were
        // measured and all LOST; recorded so they are not re-tried:
        //
        //   · Instruction shaving — hoist the prefetch clamp out of the loop and
        //     drop the `blocks` counter (derive it from `i`): −1%. The loop is not
        //     issue-bound, so removing µops buys nothing.
        //   · Shuffle-derived second window — one load, then `vext`/`palignr` the
        //     confirm window out of it instead of a second load: −8.2%. Trading a
        //     load for a shuffle loses; the load units are not the constraint.
        //   · Single-load bitmask gate — one load compared against both anchors,
        //     folded with `bits.blockMask`'s addp tree, masks aligned by integer
        //     shift: −14.6%. The worst of the three. Even one extra wide fold per
        //     block costs more than the load it replaced.
        //
        // The shape of all three results is the same: on this core the loads are
        // nearly free and the vector compare/fold is the critical resource, so
        // every trade of memory work for ALU work is a regression. Anything that
        // reduces COMPARES per byte is worth measuring; anything that reduces
        // LOADS per byte at the cost of ALU work has been measured, three ways.
        if (chosen.single) {
            var blocks: usize = 0;
            var hot: usize = 0;
            while (i + last_off + scan_vlen <= hay.len) : (i += scan_vlen) {
                // Where the core's stream prefetcher wants the help — see
                // `streamAhead`, which is where the per-target measurement lives.
                streamAhead(hay, i);
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
            streamAhead(hay, i);
            const eq = (@as(ScanVec, hay[i + o1 ..][0..scan_vlen].*) == p1) &
                (@as(ScanVec, hay[i + o2 ..][0..scan_vlen].*) == p2);
            if (!anyLane(eq)) continue;
            if (verifyBlock(hay, needle, i, eq)) |pos| return pos;
        }
    }

    // Narrow tier: the < scan_vlen remainder (and any haystack too short for
    // the wide tier) still vectorizes at `vlen`.
    const first: Vec = @splat(needle[0]);
    const last: Vec = @splat(needle[n - 1]);
    while (i + last_off + vlen <= hay.len) : (i += vlen) {
        const bf: Vec = hay[i..][0..vlen].*;
        const bl: Vec = hay[i + last_off ..][0..vlen].*;
        const bits: Mask = bitsmod.laneMask(Mask, (bf == first) & (bl == last));
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
        const bits: Mask = bitsmod.laneMask(Mask, (bf == first) & (bl == last));
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
        const bits: ScanMask = bitsmod.laneMask(ScanMask, @as(ScanVec, hay[i..][0..scan_vlen].*) == wide);
        if (bits != 0) return i + (scan_vlen - 1 - @clz(bits));
    }
    const narrow: Vec = @splat(c);
    while (i >= vlen) {
        i -= vlen;
        const bits: Mask = bitsmod.laneMask(Mask, @as(Vec, hay[i..][0..vlen].*) == narrow);
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
        n += @popCount(bitsmod.laneMask(ScanMask, @as(ScanVec, hay[i..][0..scan_vlen].*) == wide));
    const narrow: Vec = @splat(c);
    while (i + vlen <= hay.len) : (i += vlen)
        n += @popCount(bitsmod.laneMask(Mask, @as(Vec, hay[i..][0..vlen].*) == narrow));
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
        n += @popCount(bitsmod.laneMask(ScanMask, blk == cw));
        seen = seen or bitsmod.laneMask(ScanMask, blk == ow) != 0;
    }
    const cv: Vec = @splat(c);
    const ov: Vec = @splat(other);
    while (i + vlen <= hay.len) : (i += vlen) {
        const blk: Vec = hay[i..][0..vlen].*;
        n += @popCount(bitsmod.laneMask(Mask, blk == cv));
        seen = seen or bitsmod.laneMask(Mask, blk == ov) != 0;
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
        if (anyLane(eq)) return i + @ctz(bitsmod.laneMask(ScanMask, eq));
    }
    const narrow: Vec = @splat(c);
    while (i + vlen <= hay.len) : (i += vlen) {
        const bits: Mask = bitsmod.laneMask(Mask, @as(Vec, hay[i..][0..vlen].*) == narrow);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == c) return i;
    return null;
}

/// ASCII-caseless substring presence — the `-i` twin of `contains`. `needle`
/// MUST be pre-folded to ASCII lowercase by the caller, and the gate producers
/// own the soundness bounds (ASCII-only literal, Kelvin/long-s orbits excluded
/// under Unicode fold — `foldClosedWindow` below). Same first+last-byte SIMD
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
        var survivors = bitsmod.ones(bitsmod.laneMask(ScanMask, eq));
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
        const bits: Mask = bitsmod.laneMask(Mask, ((bf | fm0) == first) & ((bl | fmL) == last));
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
        const bits: ScanMask = bitsmod.laneMask(ScanMask, (@as(ScanVec, hay[i..][0..scan_vlen].*) | mw) == lw);
        if (bits != 0) return i + @ctz(bits);
    }
    const mv: Vec = @splat(mask);
    const lv: Vec = @splat(lo);
    while (i + vlen <= hay.len) : (i += vlen) {
        const bits: Mask = bitsmod.laneMask(Mask, (@as(Vec, hay[i..][0..vlen].*) | mv) == lv);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) if (hay[i] | mask == lo) return i;
    return null;
}

/// The longest ASCII-fold-CLOSED window of a literal, or null when none
/// reaches 2 bytes — the producer-side soundness rule for every caseless gate
/// below, which is why it lives here rather than beside one of its callers. A
/// byte is fold-closed when its case-fold orbit stays within its two ASCII
/// spellings: non-ASCII bytes decline (multi-byte positional orbits), and under
/// Unicode fold (rg's `-i` default) `k`/`K` (KELVIN SIGN U+212A) and `s`/`S`
/// (LONG S U+017F) decline — the same two escape orbits `query`'s
/// `caselessVariants` excludes; ASCII fold (`(?-u)`) admits them. A caseless
/// match must contain every segment of the raw literal in some case spelling,
/// so gating on one admissible window stays a sound necessary condition even
/// when the whole literal declines (`eventsource` carries an `s` whose Unicode
/// orbit escapes ASCII — but its `event` prefix gates cleanly). Only a window
/// covering the ENTIRE literal can ever prove match equivalence; a partial
/// window is containment-only, so `Gate.caseless` takes `equiv` separately.
pub fn foldClosedWindow(lit: []const u8, unicode: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= lit.len) : (i += 1) {
        const closed = i < lit.len and lit[i] < 0x80 and
            !(unicode and (lit[i] == 'k' or lit[i] == 'K' or lit[i] == 's' or lit[i] == 'S'));
        if (!closed) {
            if (i - start >= 2 and (best == null or i - start > best.?.len)) best = lit[start..i];
            start = i + 1;
        }
    }
    return best;
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
    /// The anchor decision for `bytes`, minted ONCE when the gate is built.
    ///
    /// This is the whole reason `Plan` exists as a value. A gate is derived once
    /// per invocation from the compiled pattern and then consumed per file (the
    /// whole-file drop) and per match (`find`, driving the hit-to-hit jump loop) —
    /// so a lazily-planning `contains` re-priced the same fifteen candidate pairs
    /// against the digraph table for every file in the corpus and every hit in
    /// every file. The needle never changes across any of those calls.
    ///
    /// `null` only where there is no decision to make: a caseless gate rides
    /// `containsCaseless`, a different kernel that takes no pair, and a 1-byte
    /// gate goes straight to `memchr`. Build through `of`/`caseless` rather than a
    /// struct literal — there is deliberately no default, because a literal that
    /// omitted the field would compile and silently give the per-call cost back.
    ///
    /// This is the EFFECTIVE plan — what `in` and `find` scan with, read straight
    /// with no further choice to make. `on` overwrites it with the document's pair
    /// and keeps the static one in `base`.
    plan: ?Plan,

    /// The static incumbent `on` refines against, once `on` has overwritten `plan`
    /// with a document's pair. `null` means `plan` IS still the static one, so a
    /// gate straight out of `of` needs no second field written.
    ///
    /// It exists so `on` can be cheap AND idempotent at once. Idempotence needs the
    /// incumbent to be the same value on file N+1 as on file N (see `on`); the old
    /// shape bought that by re-deriving it from `bytes` through `planFor`, an
    /// `anchor.select` per FILE (~21 ns at 4-8 bytes, ~37 at 32) to reconstruct a
    /// value the gate was already holding. Keeping it makes that recomputation
    /// unnecessary rather than merely faster.
    ///
    /// Deliberately NOT consulted by `in`/`find`. Those two are the hit-to-hit jump
    /// loop, called once per MATCH, and folding the choice into them cost a
    /// measured 1.2x on `-o` and `-l` over this tree — a per-hit branch traded for a
    /// per-file `select` is the wrong direction by three orders of magnitude in
    /// call count. The scan reads one field; only `on` reads two.
    base: ?Plan = null,

    /// The case-sensitive gate, plan included.
    pub fn of(bytes: []const u8) Gate {
        return .{ .bytes = bytes, .plan = planFor(bytes) };
    }

    /// The caseless gate. `bytes` must already be ASCII-lowered by the producer,
    /// which also proves the fold ASCII-closed; `equiv` records match equivalence.
    pub fn caseless(bytes: []const u8, equiv: bool) Gate {
        return .{ .bytes = bytes, .ci = true, .equiv = equiv, .plan = null };
    }

    /// This gate re-planned against the ONE document it is about to be run over —
    /// the per-file grain `planOn` exists for. A gate is minted once per query from
    /// the pattern alone, so without this every file in a run shares an anchor pair
    /// chosen from a shipped corpus table; on a body whose local byte distribution
    /// the table does not describe, that pair can be two locally-dense bytes and
    /// the block filter degenerates to "verify almost every position". Measured on
    /// a 200 MB buffer whose alphabet is the statically-RARE bytes: a full sweep
    /// costs 70 ms on the static pair and 3.9–4.0 ms re-planned, 17.6–17.9× — and
    /// the static pair takes the *single*-probe shape there, so the fast loop aimed
    /// at the wrong byte loses to the two-probe loop aimed well by that much.
    ///
    /// Call it where a whole document is in hand, ONCE per document. Never per
    /// line: `planOn`'s size gate is a claim about the scan the sampling amortizes
    /// against, so pricing it on a slice of the work prices the wrong thing.
    ///
    /// **Idempotent, and that is load-bearing.** The incumbent is `base orelse
    /// plan` — the static pair on the first call and, once `base` is written, that
    /// same static pair forever after. So re-planning an already-re-planned gate
    /// re-decides from the static pair rather than compounding. Without that
    /// property a long-lived gate (an `Emitter` walks many files, assigning the
    /// result back over itself) would carry the previous document's pair into the
    /// next one as the incumbent to beat — and `refine` only swaps on a MATERIAL
    /// improvement, so a pair that was ideal for file N would be defended into file
    /// N+1 where it is the pathological one. That is the whole failure this method
    /// exists to remove.
    ///
    /// It used to buy that property by re-deriving the incumbent through
    /// `planFor(bytes)` and deliberately ignoring `self.plan` — correct, but an
    /// `anchor.select` per FILE to reconstruct a constant the gate was already
    /// carrying. Remembering it gets the same guarantee out of the type.
    ///
    /// A caseless gate returns unchanged: `containsCaseless` is a different kernel
    /// that takes no pair, so there is nothing to re-plan.
    pub fn on(self: Gate, hay: []const u8) Gate {
        if (self.ci) return self;
        const held = self.base orelse self.plan orelse return self;
        return .{
            .bytes = self.bytes,
            .equiv = self.equiv,
            .plan = refineOn(hay, self.bytes, held),
            .base = held,
        };
    }

    pub inline fn in(self: Gate, hay: []const u8) bool {
        if (self.ci) return containsCaseless(hay, self.bytes);
        return if (self.plan) |p| containsWith(hay, self.bytes, p) else contains(hay, self.bytes);
    }

    /// Leftmost gate occurrence at or after `from` — lets a doc loop jump
    /// hit-to-hit at SIMD speed and run the engine only on the hit's line.
    pub inline fn find(self: Gate, hay: []const u8, from: usize) ?usize {
        if (self.ci) return indexOfCaselessPos(hay, from, self.bytes);
        return if (self.plan) |p| indexOfPosWith(hay, from, self.bytes, p) else indexOfPos(hay, from, self.bytes);
    }
};
