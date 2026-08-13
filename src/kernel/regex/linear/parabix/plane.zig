//! irregex — the bit-plane floor of the Parabix rung.
//!
//! A byte-at-a-time engine holds one automaton state and consumes one byte per
//! step. A bit-parallel engine holds one POSITION SET and consumes a whole
//! block of positions per step. Everything in this directory follows from that
//! inversion, and this file is where the inversion physically happens: a
//! `Block` is 128 haystack positions, one bit each, and `transpose` turns 128
//! consecutive bytes into the eight *basis planes* — plane k carrying bit k of
//! every one of those bytes, in positional correspondence with the text.
//!
//! Prior art: Cameron, Lin, Herdy, Wu et al., "Bitwise Data Parallelism in
//! Regular Expression Matching" (PACT 2014) and the icGrep line of work at
//! SFU. The transposition here is their inductive-halving s2p in a form we can
//! check against a scalar oracle rather than a transcription of their
//! `hsimd_packh`/`packl` step; the technique is theirs, this implementation is
//! ours, and we claim no novelty for either.
//!
//! Two width decisions are load-bearing and neither is a tuning knob.
//! **128 bits**, because that is the NEON register and because PACT 2014
//! measured the one bad case (nested Kleene) getting *slower* at 256 — a wider
//! block needs more fixpoint iterations, since the loop continues while any
//! marker anywhere in it is still moving. **`u128` as the stream type**, because
//! AArch64 has no `movemask` for Parabix's published long-stream addition but
//! does have carry flags: Zig lowers a `u128` add to `adds`/`adc`, which is the
//! GPR half of the hybrid this lane measured 1.47× faster than keeping the
//! carry chain in vector registers.

const std = @import("std");
const builtin = @import("builtin");

/// One block of positions, one bit each. Bit j is position j of the block, and
/// "later in the text" is "more significant" — which is what makes carry
/// propagation (`MatchStar`, the k-run doubling) move markers FORWARD.
pub const Block = u128;

/// Positions per block. Also bytes per block: the correspondence is one-to-one.
pub const width: usize = 128;

/// One block's worth of a stream, in the shape NEON actually holds it. Boolean
/// algebra over streams is the class compiler's whole instruction set, and a
/// `u128` and/or/not lowers to a GPR *pair* while this lowers to one `and.16b`
/// — so the circuit interpreter speaks `Lane` and only the marker chain, which
/// genuinely needs the carry flags, converts to `Block`.
pub const Lane = @Vector(16, u8);

/// Historical spelling of `Lane` from before the two roles were separated; the
/// transposition's internals still read as byte-vector work.
pub const V16 = Lane;

/// The eight bit planes of one block: `basis[k]` bit j = bit k of byte j.
pub const Basis = [8]Lane;

/// Reinterpret a stream as the integer the marker chain shifts and adds. Free:
/// the bits are already in position, and little-endian `u128` reads lane i bit g
/// as position 8i+g, which is exactly what `transpose` produced.
pub inline fn bits(l: Lane) Block {
    return @bitCast(l);
}

/// Blocks transposed before any class circuit runs. The circuit interpreter
/// dispatches per GATE, not per block, so a stripe amortizes that dispatch —
/// one decoded gate drives `stripe × width` positions.
///
/// 8 is measured, not reasoned. The first version argued for 4 from the size of
/// the register file, on the theory that a wider stripe must spill; the bench's
/// phase ladder said otherwise, because gate dispatch — decode two operand refs,
/// branch on the connective, index the scratch — is scalar work that a spilled
/// vector load is cheaper than. Class-stream throughput on the headline pattern
/// went 3.44 → 5.11 → 6.42 → 7.62 GB/s across stripes of 1, 2, 4, 8, then flat
/// at 16 while the transposition itself got *worse* (14.0 → 12.3 GB/s) as the
/// working set left L1. The knee is here.
///
/// **Do not re-derive this from the register file — that has now been tried
/// twice.** The arithmetic is right and beside the point. A `[8]WideBasis` is 64
/// q-registers against a file of 32, and the spilling is as bad as that implies:
/// statically, 3,224 spill instructions against 6,446 vector ops in the inlined
/// striped path, where `Parabix.block` carries 22 against 1,099, and even a
/// comptime-specialized `[a-z]` with its bounds baked in pays ~6 spills per block
/// at this grain against 0 at block grain. None of that is news to the number
/// above; it is already inside it.
///
/// The second attempt refined the premise and still did not survive review. Its
/// argument was that only `.fallback` pays per-gate dispatch, so a catalogue-only
/// program (`one`, `ranges1..4`, which return from `Circuit.eval` before the gate
/// loop) has nothing to amortize and should prefer block grain. The flaw is that
/// the ladder above was measured *with* the shape catalogue already present, so
/// whatever the stripe buys those shapes is already in the 7.62 — plausibly the
/// per-block `Parabix.block`, `markers` and `transpose` calls and the loop
/// bookkeeping, none of which the stripe pays. Per-block vector work is identical
/// across grains (1.00–1.02×), so the trade is spill traffic against call and
/// dispatch overhead, and the bench has already priced it once.
///
/// That attempt was implemented and reverted *without* being benched, so it is
/// not evidence either way. The rule it leaves behind: this constant moves on a
/// phase-ladder measurement, never on a register count.
pub const stripe: usize = 8;

/// Haystack bytes consumed per stripe.
pub const stripe_width: usize = stripe * width;

/// One stream over a whole stripe: `stripe` `Lane`s end to end, spelled as one flat
/// byte vector so that `&`/`|`/`~` lower to exactly four NEON ops with no lane
/// crossing and no legalization. (`@Vector(stripe, u128)` is the same 512 bits
/// and reads better, but LLVM splits `<4 x i128>` into GPR pairs, which cost the
/// class phase more than the transposition — measured, then fixed.)
pub const Wide = @Vector(stripe * 16, u8);

/// The eight basis planes of a whole stripe.
pub const WideBasis = [8]Wide;

/// Block `b`'s stream out of a stripe's, as the marker chain's integer.
pub inline fn blockOf(w: Wide, comptime b: usize) Block {
    return bits(@as([stripe]Lane, @bitCast(w))[b]);
}

/// Does this build have a real byte-shuffle unit to transpose on?
///
/// **A CAPABILITY, and deliberately not a claim that anyone measured it here.**
/// That distinction is the whole of this predicate's history: it read
/// `builtin.cpu.arch == .aarch64`, and the comment justifying that named a
/// throughput measurement, not an instruction — so an architecture question was
/// standing in for a pricing one, and every x86-64 host in the world got the
/// rung switched off at compile time for a reason that was never about x86.
/// The ladder now conjoins the two facts itself (`ladder/rungs.zig`:
/// `parabix_armable` = this AND `price.calibrated`), so an unpriced target
/// declines through the gate that knows why. Widening this one does not arm a
/// single unmeasured host; it makes the refusal legible and mintable.
///
/// Little-endian, because `bits` reinterprets a `Lane` as the marker chain's
/// `u128` and reads lane i bit g as position 8i+g. That is a correctness
/// requirement, not a performance one, and it is why `aarch64_be` is out.
///
/// NEON or SSSE3, because `transpose` is three rounds of even/odd byte
/// de-interleave and three delta swaps — `@shuffle` and shift/xor, portable Zig
/// that compiles literally anywhere. What differs is what it compiles TO, and
/// the measured budget for one 128-byte block is the reason the floor sits
/// here rather than at SSE2:
///
///   | target             | instructions | per byte |
///   |--------------------|--------------|----------|
///   | NEON (`tbl`)       |          178 |     1.39 |
///   | AVX (`vpshufb`)    |          245 |     1.91 |
///   | SSSE3 (`pshufb`)   |          292 |     2.28 |
///   | SSE2 (`baseline`)  |          398 |     3.11 |
///
/// NEON wins because `uzp1`/`uzp2` IS the even/odd de-interleave, one
/// instruction for what `pshufb` needs a shuffle pair to say and what SSE2 must
/// emulate with `punpck` chains. A 1.6× budget at SSSE3 is a rung that still
/// has something to sell against the DFA; the 2.2× at SSE2 is emulation, and
/// drawing the line at the shuffle — the same instruction `scan/lanes.zig`
/// draws its own 16-lane line at — keeps one answer to "is there a byte
/// permute here" rather than two that can drift.
///
/// The FEATURE, not the architecture. NEON is an optional AArch64 feature, and
/// asking the arch meant an `-mcpu=baseline-neon` profile claimed a shuffle
/// unit it does not have. `cpu.has` costs nothing at run time — the answer is
/// comptime — and makes the floor the target's own rather than a guess about it.
pub const vectorized = builtin.cpu.arch.endian() == .little and
    (builtin.cpu.has(.aarch64, .neon) or builtin.cpu.has(.x86, .ssse3));

/// Bits 0..len-1 — the positions of this block that hold a real byte. Class
/// streams are masked by it so a short final block's padding can never advance
/// a marker, whatever bytes happen to sit past the end.
pub inline fn liveMask(len: usize) Block {
    return if (len >= width) ~@as(Block, 0) else (@as(Block, 1) << @intCast(len)) - 1;
}

/// Bits 0..len — the *positions* of this block, which number one more than its
/// bytes: a match ending on the last byte lands a marker at position `len`.
pub inline fn spanMask(len: usize) Block {
    return if (len + 1 >= width) ~@as(Block, 0) else (@as(Block, 1) << @intCast(len + 1)) - 1;
}

/// Advance a stream by `s` positions across the block seam: the bits shifted
/// out of the previous block arrive as `carry`, and this block's top `s` bits
/// become the next one's. `s` is 1..127 (a whole-block shift never occurs — the
/// k-run compiler caps a fused run below the block width).
pub inline fn shiftIn(x: Block, s: u8, carry: *Block) Block {
    const out = (x << @intCast(s)) | carry.*;
    carry.* = x >> @intCast(width - s);
    return out;
}

/// Add two streams as one long integer, threading the carry across blocks —
/// Parabix's long-stream addition, which on AArch64 is just `adds`/`adc`
/// because a `u128` add already is one.
pub inline fn addIn(x: Block, y: Block, carry: *Block) Block {
    const s1 = @addWithOverflow(x, y);
    const s2 = @addWithOverflow(s1[0], carry.*);
    // At most one of the two can overflow: x + y ≤ 2^129 − 2, so a wrapped sum
    // is never 2^128 − 1 and the +1 cannot wrap again.
    carry.* = s1[1] | s2[1];
    return s2[0];
}

// Even/odd byte de-interleave of the concatenation `a ++ b` — `uzp1`/`uzp2` on
// AArch64. Negative indices select `b` (Zig's `@shuffle` convention: ~i).
const even_bytes: @Vector(16, i32) = .{ 0, 2, 4, 6, 8, 10, 12, 14, ~@as(i32, 0), ~@as(i32, 2), ~@as(i32, 4), ~@as(i32, 6), ~@as(i32, 8), ~@as(i32, 10), ~@as(i32, 12), ~@as(i32, 14) };
const odd_bytes: @Vector(16, i32) = .{ 1, 3, 5, 7, 9, 11, 13, 15, ~@as(i32, 1), ~@as(i32, 3), ~@as(i32, 5), ~@as(i32, 7), ~@as(i32, 9), ~@as(i32, 11), ~@as(i32, 13), ~@as(i32, 15) };

inline fn packEven(a: V16, b: V16) V16 {
    return @shuffle(u8, a, b, even_bytes);
}
inline fn packOdd(a: V16, b: V16) V16 {
    return @shuffle(u8, a, b, odd_bytes);
}

/// Exchange the two off-diagonal blocks of a bit matrix held across two
/// registers — the delta swap of Warren, *Hacker's Delight* §7-3, applied 16
/// lanes at a time so one call transposes a corner of sixteen independent 8×8
/// matrices. `s` is the block size in bits, `m` the columns it moves.
inline fn deltaSwap(a: *V16, b: *V16, comptime s: u3, comptime m: u8) void {
    const sv: @Vector(16, u3) = @splat(s);
    const mv: V16 = @splat(m);
    const t = ((a.* >> sv) ^ b.*) & mv;
    a.* ^= t << sv;
    b.* ^= t;
}

/// 128 bytes ⇒ the eight basis planes. Two halves, both pure register work.
///
/// First, three rounds of byte de-interleave put the block in stride-8 order,
/// so that `u[g]` lane i holds `src[8*i + g]` — the eight bytes that will share
/// an output lane end up one per register. Then three rounds of delta swap
/// transpose all sixteen of those 8×8 bit matrices at once. Reading the result
/// as a little-endian `u128` puts bit j of plane k exactly at position j, with
/// no fix-up: lane i bit g IS position 8i+g.
pub fn transpose(src: *const [width]u8) Basis {
    var v: [8]V16 = undefined;
    inline for (0..8) |g| v[g] = src[g * 16 ..][0..16].*;

    // Round 1 — even/odd byte positions.
    var e: [8]V16 = undefined;
    inline for (0..4) |j| {
        e[j] = packEven(v[2 * j], v[2 * j + 1]);
        e[4 + j] = packOdd(v[2 * j], v[2 * j + 1]);
    }
    // Round 2 — positions mod 4, in the order 0, 2, 1, 3.
    var f: [8]V16 = undefined;
    inline for (0..2) |j| {
        f[j] = packEven(e[2 * j], e[2 * j + 1]);
        f[2 + j] = packOdd(e[2 * j], e[2 * j + 1]);
        f[4 + j] = packEven(e[4 + 2 * j], e[5 + 2 * j]);
        f[6 + j] = packOdd(e[4 + 2 * j], e[5 + 2 * j]);
    }
    // Round 3 — positions mod 8: `u[g]` lane i is `src[8i + g]`.
    var u: [8]V16 = undefined;
    u[0] = packEven(f[0], f[1]);
    u[4] = packOdd(f[0], f[1]);
    u[2] = packEven(f[2], f[3]);
    u[6] = packOdd(f[2], f[3]);
    u[1] = packEven(f[4], f[5]);
    u[5] = packOdd(f[4], f[5]);
    u[3] = packEven(f[6], f[7]);
    u[7] = packOdd(f[6], f[7]);

    // Sixteen 8×8 bit transposes, largest block first (the recursive
    // [[A,B],[C,D]] → [[Aᵀ,Cᵀ],[Bᵀ,Dᵀ]] order).
    inline for (0..4) |r| deltaSwap(&u[r], &u[r + 4], 4, 0x0F);
    inline for ([_]usize{ 0, 1, 4, 5 }) |r| deltaSwap(&u[r], &u[r + 2], 2, 0x33);
    inline for ([_]usize{ 0, 2, 4, 6 }) |r| deltaSwap(&u[r], &u[r + 1], 1, 0x55);

    return u;
}

/// A stripe's worth of transposition, grouped plane-major so the circuit
/// interpreter can hold a whole stream in one value.
pub fn transposeStripe(src: *const [stripe_width]u8) WideBasis {
    var lanes: [8][stripe]Lane = undefined;
    inline for (0..stripe) |b| {
        const basis = transpose(src[b * width ..][0..width]);
        inline for (0..8) |k| lanes[k][b] = basis[k];
    }
    var out: WideBasis = undefined;
    inline for (0..8) |k| out[k] = @bitCast(lanes[k]);
    return out;
}

/// The transposition's definition, written from what a basis plane MEANS
/// rather than from how it is computed — the oracle the differential test
/// holds `transpose` to.
pub fn transposeScalar(src: *const [width]u8) [8]Block {
    var out: [8]Block = @splat(0);
    for (src, 0..) |b, j| {
        inline for (0..8) |k| {
            if ((b >> k) & 1 != 0) out[k] |= @as(Block, 1) << @intCast(j);
        }
    }
    return out;
}
