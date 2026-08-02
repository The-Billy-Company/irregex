//! gist — lane algebra: transformations as vectors, composition as one shuffle.
//!
//! A transformation of a |Q|-state machine is a |Q|-byte vector: lane `i` holds
//! where state `i` goes. Composing two of them is then a *byte shuffle* —
//! `(f∘g)[i] = f[g[i]]` is literally `TBL f, g` on AArch64, a constant-time
//! instruction whose cost is independent of the table contents (Arm A-profile
//! A64, `TBX`: "the execution time of this instruction is independent of the
//! index or table data values"). That single identity is what this file is.
//!
//! Why it buys anything: function composition is ASSOCIATIVE, so the per-byte
//! transformations of a chunk may be combined in any order. Matching wants only
//! the FINAL state, which makes it a reduction rather than a scan — and a binary
//! tree over `n` leaves has exactly `n−1` internal nodes, the same count as the
//! serial fold. Re-association is therefore free in instructions and pays a
//! quarter of the dependency depth: the loop-carried chain drops from one
//! dependent load per byte to one `TBL` per chunk. The leaves' table addresses
//! depend only on input bytes, never on a previous result, so they pipeline.
//!
//! The kernel is semantics-free on purpose. It composes whatever the caller
//! lowered, so a sibling (the quotient sieve) can reuse it with its own tables
//! without depending on the regex rung above it — this file imports nothing but
//! `std` and `builtin`.
//!
//! Measured on an Apple M4 Max (`bench/compose/bench.zig`): `TBL` 1-register and
//! 2-register both retire at 4.02/cycle with 2-cycle latency, the load port at
//! 3.03 128-bit loads/cycle. Sixteen lanes is therefore LOAD-port bound — one
//! table row per byte at 1.125 loads/byte after the source-byte amortization
//! below — and thirty-two lanes is SHUFFLE-port bound. Sixty-four lanes needs
//! `TBL` with a 4-register list, which retires at only 1.33/cycle, and the
//! technique stops paying; this file deliberately stops at 32.

const std = @import("std");
const builtin = @import("builtin");

/// A 16-lane transformation, and the shape every shuffle here speaks.
pub const Vec = @Vector(16, u8);

/// Is COMPOSITION worth arming on this target? Callers gate on this at COMPILE
/// time and leave their field null when it is false; `runPortable` below is
/// then the specification and the test oracle rather than a shipping path,
/// because a scalar gather per byte is exactly the latency-bound shape the
/// composition was built to escape.
///
/// AArch64 only, and deliberately narrower than `shuffle`'s own portability:
/// the 32-lane form needs `TBL` with a two-register list, which SSSE3 has no
/// equivalent for (it would take AVX-512 `vpermi2b`), and the 16-lane form on
/// `pshufb` has never been measured — an unmeasured fast path is not a fast
/// path. Everything below still COMPILES everywhere; it just never runs.
pub const native = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => true,
    else => false,
};

/// How many lanes a transformation carries — that is, how many states the
/// lowered machine has, absorbing sink included. The value is the row stride in
/// bytes, so `@intFromEnum` is the table geometry.
pub const Width = enum(u8) {
    /// One `TBL` per composition. The whole win lives here.
    lanes16 = 16,
    /// Two `TBL`s against a register pair. Still ahead of a table walk, but the
    /// bottleneck has moved from the load port to the shuffle port.
    lanes32 = 32,

    pub fn stride(self: Width) usize {
        return @intFromEnum(self);
    }
};

/// How a buffer position picks its table row.
pub const Index = enum {
    /// `row = byte`. A 256-row table.
    byte,
    /// `row = byte | (at_line_end << 8)`, where a position is at a line end when
    /// the NEXT byte is `\n` or the buffer ended. A 512-row table. The index
    /// still depends only on input bytes, so the loads stay independent and the
    /// re-association survives — which is the whole reason end-of-line is folded
    /// into the table rather than consulted after the fact.
    byte_eol,

    fn rows(self: Index) usize {
        return switch (self) {
            .byte => 256,
            .byte_eol => 512,
        };
    }
};

/// Bytes a table of this geometry occupies. Callers size their allocation with
/// it, so the two halves of the contract cannot drift.
pub fn tableBytes(w: Width, ix: Index) usize {
    return ix.rows() * w.stride();
}

// ── the two shuffles ────────────────────────────────────────────────────────

/// `out[i] = t[idx[i]]` for `idx[i] < 16` — one instruction everywhere it is
/// one instruction, and a scalar gather where it is not.
///
/// **This is the shared primitive.** It is the whole of the 16-wide table
/// lookup that `scan/teddy.zig`, `scan/classrun.zig` and the sieve's
/// `sheng.zig` each carry their own copy of; a sibling can import it from here
/// without importing the rung, because this file depends on nothing but `std`
/// and `builtin`. Out-of-range indices differ by architecture (NEON zeroes,
/// SSSE3 zeroes on the high bit only), so callers keep indices in range — the
/// lowering above fills unreachable lanes with the identity for exactly this
/// reason.
///
/// Each arm is predicated on the FEATURE that instruction needs, not on the
/// architecture that usually has it. An `asm` block is opaque to LLVM's
/// subtarget check, so an arch-only arm emits `pshufb` — SSSE3, and not in the
/// x86_64 baseline — into an artifact whose declared floor never promised it:
/// it assembles, it ships, and it faults on the first machine that took the
/// declaration at its word. Asking `cpu.has` costs nothing at run time (the
/// answer is comptime) and makes the floor the target's rather than a guess.
pub inline fn shuffle(t: Vec, idx: Vec) Vec {
    if (comptime builtin.cpu.has(.aarch64, .neon)) return asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
        : [o] "=w" (-> Vec),
        : [t] "w" (t),
          [i] "w" (idx),
    );
    if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb %[i], %[o]"
        : [o] "=x" (-> Vec),
        : [t] "0" (t),
          [i] "x" (idx),
    );
    var out: [16]u8 = undefined;
    const tt: [16]u8 = t;
    const ii: [16]u8 = idx;
    for (&out, ii) |*o, k| o.* = tt[k & 0x0F];
    return out;
}

/// The 32-lane shuffle: `out[i] = {lo,hi}[idx[i]]` for `idx[i] < 32`.
///
/// `TBL` with a two-register list requires CONSECUTIVE vector registers, which
/// no inline-asm constraint can request — clang reaches it only through the
/// `vqtbl2q_u8` intrinsic and an `uint8x16x2_t` register tuple. Pinning the two
/// halves to `v30`/`v31` as fixed-register *inputs* (never clobbered — `TBL`
/// does not write its table operands) recovers the instruction and lets the
/// register allocator hoist and share the two `mov`s across both halves of a
/// composition. Measured against the alternatives on the same buffer in one
/// process: this form 0.98 B/cycle, a single asm block moving the pair itself
/// 0.92, four moves 0.77, `TBX`-merged single-register lookups 0.59, and
/// zero-extend-and-OR 0.44.
///
/// Guarded here rather than at the call site: `native` above already keeps the
/// 32-lane algebra off non-NEON targets, but a leaf that assembles an optional
/// instruction should refuse to compile off-feature rather than trust every
/// future caller to have checked.
inline fn shufflePair(lo: Vec, hi: Vec, idx: Vec) Vec {
    if (comptime !builtin.cpu.has(.aarch64, .neon))
        @compileError("lanes.shufflePair is NEON-only — callers gate on `native`");
    return asm ("tbl %[o].16b, {v30.16b, v31.16b}, %[i].16b"
        : [o] "=w" (-> Vec),
        : [i] "w" (idx),
          [l] "{v30}" (lo),
          [h] "{v31}" (hi),
    );
}

/// The width-specialized algebra: what a transformation IS, how two compose,
/// how one is read out of a table, and how one is applied to a running state.
/// `run` below is written once against this interface.
fn Algebra(comptime w: Width) type {
    return struct {
        /// A transformation. Sixteen lanes fit one register; thirty-two need a
        /// pair, which is why composition costs twice as much there.
        const Xform = if (w == .lanes16) Vec else struct { lo: Vec, hi: Vec };

        /// Bytes whose transformations one 64-bit source load feeds. Eight, so
        /// the per-byte source fetch amortizes to ⅛ of a load and the leaves
        /// come out of `ubfx` field extracts instead of eight scalar loads —
        /// worth ~1.6× on a load-port-bound kernel.
        const group = 8;
        /// Groups per chunk. Sixteen lanes hold eight transformations plus the
        /// tree in registers comfortably; thirty-two need two registers each, so
        /// the chunk halves rather than spill.
        const groups = if (w == .lanes16) 4 else 2;
        const chunk = group * groups;
        const stride = @intFromEnum(w);

        inline fn row(tbl: []const u8, idx: usize) Xform {
            const r = tbl[idx * stride ..][0..stride];
            return if (w == .lanes16) r.* else .{ .lo = r[0..16].*, .hi = r[16..32].* };
        }

        /// The `group` row indices starting at `at`, from ONE 64-bit source load
        /// (two when the end-of-line axis is armed) rather than eight byte
        /// loads, the source bytes coming back out as `ubfx` field extracts.
        ///
        /// This is not a micro-optimization, it is the difference between the
        /// two bounds. The kernel is LOAD-port bound, and a table row is already
        /// one load per byte; fetching each source byte separately makes it two,
        /// which is what a naive `bytes[i]` per leaf compiles to. Measured on
        /// the 9-state pattern over 206 MiB: 1.41 B/cycle fetching each source
        /// byte, 2.26 amortized — 4.2× over the shipped DFA becoming 6.8×.
        ///
        /// Callers must guarantee `at + group + @intFromBool(ix == .byte_eol)`
        /// bytes are readable — `runNative`'s loop bound is what does.
        inline fn groupRows(comptime ix: Index, bytes: []const u8, at: usize) [group]usize {
            const src = std.mem.readInt(u64, bytes[at..][0..group], .little);
            const nxt = if (ix == .byte_eol) std.mem.readInt(u64, bytes[at + 1 ..][0..group], .little) else 0;
            var out: [group]usize = undefined;
            inline for (&out, 0..) |*o, j| {
                const b: u8 = @truncate(src >> (8 * j));
                o.* = switch (ix) {
                    .byte => b,
                    // End-of-BUFFER is unreachable here: the loop reserves the
                    // lookahead byte, so the scalar tail owns the final
                    // position and only the `\n` test is left.
                    .byte_eol => @as(usize, b) |
                        @as(usize, if (@as(u8, @truncate(nxt >> (8 * j))) == '\n') 256 else 0),
                };
            }
            return out;
        }

        /// `later ∘ earlier` — apply `earlier` first. Reading it as a shuffle:
        /// each lane of `earlier` names the lane of `later` to fetch.
        inline fn compose(later: Xform, earlier: Xform) Xform {
            return if (w == .lanes16)
                shuffle(later, earlier)
            else
                .{
                    .lo = shufflePair(later.lo, later.hi, earlier.lo),
                    .hi = shufflePair(later.lo, later.hi, earlier.hi),
                };
        }

        /// Drive a state through a transformation. `cur` is a broadcast of the
        /// live lane, so only lane 0 of the result is meaningful; keeping it in
        /// a vector is what makes this one instruction rather than an extract.
        inline fn apply(f: Xform, cur: Vec) Vec {
            return if (w == .lanes16) shuffle(f, cur) else shufflePair(f.lo, f.hi, cur);
        }

        /// Reduce eight transformations in program order (`v[0]` earliest) into
        /// `v[0]`. Seven combines for eight leaves — the same count the serial
        /// fold would pay — but three levels deep instead of eight.
        inline fn reduce8(v: *[8]Xform) void {
            comptime var span = 1;
            inline while (span < 8) : (span <<= 1) {
                comptime var a = 0;
                inline while (a + span < 8) : (a += 2 * span) v[a] = compose(v[a + span], v[a]);
            }
        }
    };
}

/// Where the position `i` of `bytes` reads its transformation.
inline fn rowOf(comptime ix: Index, bytes: []const u8, i: usize) usize {
    return switch (ix) {
        .byte => bytes[i],
        .byte_eol => @as(usize, bytes[i]) |
            @as(usize, if (i + 1 == bytes.len or bytes[i + 1] == '\n') 256 else 0),
    };
}

/// Fold `bytes` through `tbl` and report whether the machine ever reached
/// `match_lane`, starting from `start_lane`.
///
/// **Precondition — `match_lane` must be a fixed point of every row.** The scan
/// probes the running lane once per chunk, not once per byte, so "we passed
/// through MATCH" is only observable if MATCH absorbs. A caller whose sink is
/// not absorbing gets a different (wrong) question answered; this is the one
/// thing the kernel cannot check for you, because it never looks at the table.
///
/// Every lane value in every row must also be `< w.stride()`. Out-of-range
/// lanes read as zero under `TBL`, which would silently alias lane 0 rather
/// than fault — fill unreachable lanes with the identity.
pub fn run(
    comptime w: Width,
    comptime ix: Index,
    bytes: []const u8,
    tbl: []const u8,
    start_lane: u8,
    match_lane: u8,
) bool {
    // A comptime-known condition means only the taken branch is analyzed, which
    // is what keeps the AArch64 asm below out of an x86 build's sight.
    return if (comptime native)
        runNative(w, ix, bytes, tbl, start_lane, match_lane)
    else
        runPortable(w, ix, bytes, tbl, start_lane, match_lane);
}

fn runNative(
    comptime w: Width,
    comptime ix: Index,
    bytes: []const u8,
    tbl: []const u8,
    start_lane: u8,
    match_lane: u8,
) bool {
    const A = Algebra(w);
    // The lookahead index reads `bytes[i+1]`, so the vector body stops one byte
    // short of the buffer and the scalar tail resolves the final position (and
    // with it the end-of-buffer flag).
    const reserve = @intFromBool(ix == .byte_eol);
    var cur: Vec = @splat(start_lane);
    var i: usize = 0;
    while (i + A.chunk + reserve <= bytes.len) : (i += A.chunk) {
        var g: [A.groups]A.Xform = undefined;
        inline for (0..A.groups) |q| {
            const idx = A.groupRows(ix, bytes, i + A.group * q);
            var v: [8]A.Xform = undefined;
            inline for (0..8) |j| v[j] = A.row(tbl, idx[j]);
            A.reduce8(&v);
            g[q] = v[0];
        }
        // Fold the groups, then the chunk into the running state. That last
        // compose is the ONLY loop-carried shuffle: one per chunk, not per byte.
        comptime var span = 1;
        inline while (span < A.groups) : (span <<= 1) {
            comptime var a = 0;
            inline while (a + span < A.groups) : (a += 2 * span) g[a] = A.compose(g[a + span], g[a]);
        }
        cur = A.apply(g[0], cur);
        if (cur[0] == match_lane) return true;
    }
    while (i < bytes.len) : (i += 1) cur = A.apply(A.row(tbl, rowOf(ix, bytes, i)), cur);
    return cur[0] == match_lane;
}

/// The same fold, one byte at a time and one lane at a time — the portable
/// definition of what `run` computes. It is the oracle the differential holds
/// the vector kernel to, and the body non-AArch64 builds compile to (they never
/// arm the rung, so it is never on a hot path).
fn runPortable(
    comptime w: Width,
    comptime ix: Index,
    bytes: []const u8,
    tbl: []const u8,
    start_lane: u8,
    match_lane: u8,
) bool {
    const stride = comptime w.stride();
    var cur = start_lane;
    for (0..bytes.len) |i| {
        cur = tbl[rowOf(ix, bytes, i) * stride + cur];
        if (cur == match_lane) return true;
    }
    return cur == match_lane;
}

/// `runPortable` under its own name, so a test can hold the vector kernel to the
/// scalar definition on the SAME target rather than trusting two architectures
/// to agree.
pub const reference = runPortable;
