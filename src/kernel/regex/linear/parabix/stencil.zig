//! irregex — character classes as boolean circuits over the bit planes.
//!
//! A byte-at-a-time engine asks "is THIS byte in the set?" and answers with a
//! table load. Parabix asks the question of 512 positions at once and answers
//! with pure boolean algebra: a byte set is a function of eight bits, and any
//! function of eight bits is a circuit over the eight basis planes. Membership
//! becomes `and`/`or`/`not` on whole streams — no gather, no per-byte lookup,
//! and nothing in the loop that can miss in L1.
//!
//! The compiler is Shannon expansion over the byte's bits, top bit first,
//! folded as it goes: a subtree whose two cofactors agree collapses to one of
//! them, and a cofactor that is the constant 0 or 1 degenerates the mux into a
//! single `and`/`or`/`not`. That is what makes real classes cheap without any
//! special-casing — `[a-z]` and `[0-9]` fall out as a handful of gates because
//! their cofactor trees are mostly constant, and a scattered set pays for its
//! scatter, which is correct.
//!
//! Prior art: Cameron et al., PACT 2014 (see `plane.zig`). Character-class
//! compilation to bit-plane logic is theirs; this is a in-tree rebuild of
//! the idea with a folding Shannon expansion in place of icGrep's multiplexed
//! `CC_Compiler`. No novelty claimed.
//!
//! The interpreter dispatches per GATE over a whole stripe, so the decode cost
//! of a gate is spread across `plane.stripe_width` positions and what remains
//! is the four NEON ops the gate actually is.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const plane = @import("plane.zig");

/// Distinct byte sets one admitted pattern may carry. Six covers the shapes
/// the gate admits — `\w+@\w+\.\w+`, `[A-Z][a-z]+ [A-Z][a-z]+`, an IP-address
/// digit/dot alternation — and past it the marker program is dense enough that
/// the DFA is the better rung anyway.
pub const max_classes: usize = 6;

/// Gates per class circuit. A fully scattered 256-bit set needs a complete
/// binary mux tree; this cap declines those to the DFA rather than emitting a
/// circuit that would cost more than a table load. Every contiguous-range
/// class in the admitted family lands far under it.
pub const max_gates: usize = 40;

/// A fallback is admitted only while its decoded gate stream remains cheaper
/// than the marker work it feeds. Larger scattered sets belong to the DFA.
pub const max_fallback_gates: usize = 16;

/// The recurring class shapes get one decoded superinstruction, not one
/// interpreter dispatch per Shannon gate. Four ranges cover the classes seen
/// in the production patterns (`word`, `alnum`, folded letters, digit/punct
/// pairs); genuinely scattered sets retain the costed fallback below.
pub const Shape = enum(u8) { empty, full, one, ranges1, ranges2, ranges3, ranges4, fallback };

/// An operand name. Refs 0–7 are basis planes, 8–15 their complements, 16 the
/// all-zero stream, 17 the all-ones stream, 18+i gate i's output.
///
/// The basis and the constants are NAMED, never stored: a stripe's eight planes
/// arrive in registers from the transposition and the interpreter reads them
/// where they are. Materializing them into a slot array — the obvious first
/// design — wrote 1152 bytes of scratch per 512 bytes of haystack and made the
/// class phase cost 2.4× the transposition it depends on. Only gate outputs,
/// which genuinely outlive their producer, are written down.
pub const Ref = u8;

const ref_zero: Ref = 16;
const ref_ones: Ref = 17;
const ref_gate0: Ref = 18;

/// Where gate outputs land. Generic in the stream type so one compiled circuit
/// drives both grains: `plane.Wide` for the striped bulk of a document,
/// `plane.Lane` for a short line or the final partial block, where transposing
/// four blocks to use one would be most of the work.
pub fn Scratch(comptime T: type) type {
    return [max_gates]T;
}

inline fn zeroOf(comptime T: type) T {
    return if (@typeInfo(T) == .vector) @splat(0) else 0;
}

/// One two-input gate in SSA form. `conj` picks `and` over `or`; De Morgan
/// plus the pre-complemented basis planes mean no gate ever needs to negate,
/// which is why a `not` is not in the instruction set.
pub const Gate = struct { a: Ref, b: Ref, conj: bool };

/// Resolve one operand. A complement is recomputed rather than stored — one
/// `mvn` off a register beats a load off a plane array that had to be written
/// first, and De Morgan already keeps complements rare.
inline fn read(comptime T: type, r: Ref, basis: *const [8]T, out: *const Scratch(T)) T {
    if (r < 8) return basis[r];
    if (r < 16) return ~basis[r - 8];
    if (r == ref_zero) return zeroOf(T);
    if (r == ref_ones) return ~zeroOf(T);
    return out[r - ref_gate0];
}

/// A byte set as straight-line boolean code over the basis planes.
pub const Circuit = struct {
    gates: [max_gates]Gate = undefined,
    n: u8 = 0,
    /// Where the answer lands. May be a basis plane, a complement, or a
    /// constant when the set is a single bit test, everything, or nothing.
    root: Ref = ref_zero,
    shape: Shape = .fallback,
    ranges: [4][2]u8 = undefined,

    /// The class's membership stream over `basis`.
    pub fn eval(self: *const Circuit, comptime T: type, basis: *const [8]T, out: *Scratch(T)) T {
        switch (self.shape) {
            .empty => return zeroOf(T),
            .full => return ~zeroOf(T),
            .one => return equal(T, basis, self.ranges[0][0]),
            .ranges1 => return between(T, basis, self.ranges[0]),
            .ranges2 => return between(T, basis, self.ranges[0]) | between(T, basis, self.ranges[1]),
            .ranges3 => return between(T, basis, self.ranges[0]) | between(T, basis, self.ranges[1]) | between(T, basis, self.ranges[2]),
            .ranges4 => return between(T, basis, self.ranges[0]) | between(T, basis, self.ranges[1]) | between(T, basis, self.ranges[2]) | between(T, basis, self.ranges[3]),
            .fallback => {},
        }
        for (self.gates[0..self.n], 0..) |g, i| {
            const a = read(T, g.a, basis, out);
            const b = read(T, g.b, basis, out);
            out[i] = if (g.conj) a & b else a | b;
        }
        return read(T, self.root, basis, out);
    }

    /// NEON ops this circuit costs per stripe — the honest half of the rung's
    /// self-assessment, and what `parabix.zig` weighs against the marker
    /// program when deciding whether it can beat the DFA.
    pub fn ops(self: *const Circuit) usize {
        const per_block: usize = switch (self.shape) {
            .empty, .full => 0,
            .one => 8,
            .ranges1 => 34,
            .ranges2 => 69,
            .ranges3 => 104,
            .ranges4 => 139,
            .fallback => self.n,
        };
        return per_block * plane.stripe;
    }

    pub fn usesFallback(self: *const Circuit) bool {
        return self.shape == .fallback;
    }
};

inline fn equal(comptime T: type, basis: *const [8]T, byte: u8) T {
    var out = ~zeroOf(T);
    inline for (0..8) |k| out &= if (byte & (@as(u8, 1) << k) != 0) basis[k] else ~basis[k];
    return out;
}

/// Bit-sliced unsigned `x < constant`, MSB first. `equal-so-far` makes the
/// recurrence a fixed 16-op catalogue entry independent of the set's bytes.
inline fn lessThan(comptime T: type, basis: *const [8]T, constant: u9) T {
    if (constant >= 256) return ~zeroOf(T);
    var equal_so_far = ~zeroOf(T);
    var less = zeroOf(T);
    inline for (0..8) |j| {
        const k = 7 - j;
        if (constant & (@as(u9, 1) << k) != 0) {
            less |= equal_so_far & ~basis[k];
            equal_so_far &= basis[k];
        } else equal_so_far &= ~basis[k];
    }
    return less;
}

inline fn between(comptime T: type, basis: *const [8]T, range: [2]u8) T {
    const below_lo = lessThan(T, basis, range[0]);
    const at_most_hi = lessThan(T, basis, @as(u9, range[1]) + 1);
    return ~below_lo & at_most_hi;
}

/// Compile a byte set into a circuit, or decline when it needs more gates than
/// the cap allows.
pub fn compile(set: *const syn.ByteSet) ?Circuit {
    var ranges: [4][2]u8 = undefined;
    var nranges: usize = 0;
    var overflow = false;
    var byte: u16 = 0;
    while (byte <= 255) {
        if (!set.has(@intCast(byte))) {
            byte += 1;
            continue;
        }
        const lo = byte;
        while (byte <= 255 and set.has(@intCast(byte))) byte += 1;
        if (nranges == ranges.len) {
            overflow = true;
            break;
        }
        ranges[nranges] = .{ @intCast(lo), @intCast(byte - 1) };
        nranges += 1;
    }

    if (!overflow and byte > 255) {
        var c = Circuit{};
        if (nranges > 0) @memcpy(c.ranges[0..nranges], ranges[0..nranges]);
        c.shape = switch (nranges) {
            0 => .empty,
            1 => if (ranges[0][0] == 0 and ranges[0][1] == 255)
                .full
            else if (ranges[0][0] == ranges[0][1])
                .one
            else
                .ranges1,
            2 => .ranges2,
            3 => .ranges3,
            4 => .ranges4,
            else => unreachable,
        };
        return c;
    }

    var c = Circuit{};
    c.root = expand(&c, set, 7, 0) orelse return null;
    if (c.n > max_fallback_gates) return null;
    return c;
}

/// Shannon expansion of `set` restricted to the bytes agreeing with `prefix`
/// on bits above `level`, folding constants and equal cofactors as it goes.
/// Returns the slot holding the restricted membership function, or null when
/// the gate budget is exhausted.
fn expand(c: *Circuit, set: *const syn.ByteSet, level: i32, prefix: u32) ?Ref {
    if (level < 0) return if (set.has(@intCast(prefix))) ref_ones else ref_zero;

    const k: u3 = @intCast(level);
    const off = expand(c, set, level - 1, prefix) orelse return null;
    const on = expand(c, set, level - 1, prefix | (@as(u32, 1) << k)) orelse return null;
    if (off == on) return off; // this bit does not matter here

    const bit: Ref = k; // basis plane k — "bit k is 1"
    const nbit: Ref = 8 + @as(Ref, k); // its complement

    // The mux `bit ? on : off` under every degeneracy worth a shorter form.
    if (on == ref_ones and off == ref_zero) return bit;
    if (on == ref_zero and off == ref_ones) return nbit;
    if (on == ref_ones) return emit(c, bit, off, false);
    if (off == ref_ones) return emit(c, nbit, on, false);
    if (on == ref_zero) return emit(c, nbit, off, true);
    if (off == ref_zero) return emit(c, bit, on, true);
    const hi = emit(c, bit, on, true) orelse return null;
    const lo = emit(c, nbit, off, true) orelse return null;
    return emit(c, hi, lo, false);
}

fn emit(c: *Circuit, a: Ref, b: Ref, conj: bool) ?Ref {
    if (c.n == max_gates) return null;
    c.gates[c.n] = .{ .a = a, .b = b, .conj = conj };
    c.n += 1;
    return ref_gate0 + c.n - 1;
}

/// The class stream's definition, straight from `ByteSet.has` — the oracle the
/// circuit compiler is held to over random sets and random text. `src` is one
/// block's worth or less.
pub fn scalarStream(set: *const syn.ByteSet, src: []const u8) plane.Block {
    var out: plane.Block = 0;
    for (src, 0..) |b, j| {
        if (set.has(b)) out |= @as(plane.Block, 1) << @intCast(j);
    }
    return out;
}
