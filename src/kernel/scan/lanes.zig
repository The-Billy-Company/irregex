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

/// The WIDEST composition this build can drive as a real vector kernel, or
/// `null` where it can drive none. Callers gate on this at COMPILE time and
/// leave their field null when it is `null`; `runPortable` below is then the
/// specification and the test oracle rather than a shipping path, because a
/// scalar gather per byte is exactly the latency-bound shape the composition
/// was built to escape.
///
/// **Per width, because the two widths need different instructions and one bool
/// could only answer for the narrower of them by lying about the wider.** The
/// 16-lane form is one 16-byte table lookup, which is `TBL` on NEON and
/// `pshufb` on SSSE3 — `shuffle` below already has both arms, and gating it on
/// NEON meant every SSE machine ran a kernel it had the instruction for through
/// the scalar oracle instead. The 32-lane form needs a lookup across a REGISTER
/// PAIR, which SSSE3 has no equivalent for at all (it would take AVX-512
/// `vpermi2b`), so it stays NEON. Everything below still COMPILES everywhere.
///
/// This is a CAPABILITY, and deliberately not a claim that anyone measured the
/// kernel here. The 16-lane `pshufb` composition has never been timed, and an
/// unmeasured fast path is not a fast path — but that is a fact about the
/// price plane, not about the instruction set, and conflating the two is what
/// left the SSSE3 arm unreachable rather than merely unpriced. The ladder
/// conjoins the two facts itself (`ladder/rungs.zig`: kernel exists AND
/// `price.calibrated`), so an unpriced target declines through the gate that
/// knows why instead of through this one.
///
/// The FEATURE, not the architecture. This read `switch (builtin.cpu.arch) {
/// .aarch64, .aarch64_be => true, … }`, and NEON is an optional AArch64
/// feature — so `zig build -Dtarget=aarch64-linux-gnu -Dcpu=baseline-neon`
/// armed the composition, reached `shufflePair`, and died on that function's
/// own `@compileError`. Not a slow build or a wrong answer: no build at all,
/// for anyone targeting an AArch64 profile without SIMD. `shufflePair` states
/// its requirement in the feature's own terms, so the gate in front of it has
/// to be asked in those terms too.
pub const widest: ?Width = if (builtin.cpu.has(.aarch64, .neon))
    .lanes32
else if (builtin.cpu.has(.x86, .ssse3))
    .lanes16
else
    null;

/// WHICH byte-permute this build compiled, as one name. `widest` answers how
/// many lanes a kernel may drive; this answers what instruction drives them,
/// which is the axis the numbers vary on and the one `widest` cannot express:
/// `.ssse3` and `.avx` are both 16-lane and are not the same machine.
///
/// One member per arm in `shuffle` below, in the same order, because that is
/// what the name is FOR — a build that took the `vpshufb` arm must not be
/// described by a row measured over `pshufb`. The test at the bottom of this
/// file holds the two in step, so adding an arm without a class fails here
/// rather than silently pricing the new arm as the old one.
///
/// There is deliberately no AVX-512 member. The 32-lane form on x86 would need
/// `vpermi2b` and `shuffle` has no such arm, so a class for it would name a
/// kernel this engine cannot build - a row keyed on it could never be selected
/// and would read like a port that had happened.
pub const Isa = enum { portable, ssse3, avx, neon };

/// The class this build belongs to. Comptime, like every arm it stands for: the
/// permute is chosen when the binary is made, so a machine cannot be talked
/// into a class whose instructions were pruned out of it.
///
/// This is also the *dispatch* fact a caller elsewhere must read rather than
/// re-derive. `sheng.resident` asks whether the shuffle underneath the quotient
/// sieve is a real single instruction, and answering that by naming the
/// architecture instead of the feature is how a generic x86-64 build came to arm
/// a pre-pass whose kernel was a sixteen-element scalar gather per byte —
/// strictly slower than the DFA the pre-pass exists to skip.
pub const isa: Isa = if (builtin.cpu.has(.aarch64, .neon))
    .neon
else if (builtin.cpu.has(.x86, .avx))
    .avx
else if (builtin.cpu.has(.x86, .ssse3))
    .ssse3
else
    .portable;

/// Can THIS width run as a real vector kernel here? The question every caller
/// actually has, since a lowering picks its width from the machine's state
/// count and only then needs to know whether the build can drive it.
///
/// `Width` is `enum(u8)` valued at its own lane count, so the widths order by
/// their tag and "no wider than `widest`" is the whole test.
pub fn armed(comptime w: Width) bool {
    return if (widest) |cap| @intFromEnum(w) <= @intFromEnum(cap) else false;
}

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
/// `quality/ratchets/isa-floor` is the gate that keeps it that way.
///
/// The in-range precondition is ASSERTED, not merely documented. The three arms
/// answer differently above 15 — `tbl` zeroes every index ≥ 16, `pshufb` zeroes
/// only on the high bit and masks the rest to the low nibble, and
/// `shufflePortable` masks unconditionally — so a caller that drifts out of
/// range does not get a wrong answer, it gets a DIFFERENT wrong answer per
/// architecture, which no single-host test can see. The assert is a safe-build
/// check and free in ReleaseFast (where it instead hands the optimizer the
/// range fact), so the whole differential corpus above this leaf doubles as a
/// probe for the one thing the kernel cannot otherwise catch.
pub inline fn shuffle(t: Vec, idx: Vec) Vec {
    std.debug.assert(@reduce(.Max, idx) < 16);
    if (comptime builtin.cpu.has(.aarch64, .neon)) return asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
        : [o] "=w" (-> Vec),
        : [t] "w" (t),
          [i] "w" (idx),
    );
    // VEX first, and not as a micro-optimization: an `asm` template names an
    // ENCODING, and a legacy-SSE `pshufb` reached from code LLVM compiled with
    // VEX around it costs an AVX/SSE transition every time control crosses
    // between them, because the core has to preserve the upper halves of every
    // YMM register across the boundary. It is invisible in a disassembly that
    // looks correct and invisible in an instruction count — the kernel retires
    // the same ops, it just stalls on each one. Measured on the i5-13500 with
    // the 16-lane end-of-line fold, which is the shape that made LLVM emit VEX
    // for the surrounding `\n` test: 203.6 cyc/B legacy against 0.85 for the
    // same fold without the lookahead, at an IPC of 0.079. Same instruction,
    // same table, 236× — spent entirely on the encoding boundary.
    if (comptime builtin.cpu.has(.x86, .avx)) return asm ("vpshufb %[i], %[t], %[o]"
        : [o] "=x" (-> Vec),
        : [t] "x" (t),
          [i] "x" (idx),
    );
    // No AVX on this target, so nothing can be VEX-encoded and the legacy form
    // is the only one — and cannot transition against anything.
    if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb %[i], %[o]"
        : [o] "=x" (-> Vec),
        : [t] "0" (t),
          [i] "x" (idx),
    );
    return shufflePortable(t, idx);
}

/// What `shuffle` computes, written once in Zig and compiled on EVERY target —
/// including the two where an `asm` arm displaces it.
///
/// Its job is to be the arm the differential can always reach. A build compiles
/// exactly one of `shuffle`'s three arms and comptime-prunes the others, so a
/// test that only exercises `shuffle` proves whichever arm the host happened to
/// have and says nothing about the two it discarded; the portable one, needed
/// by every target that is neither NEON nor SSSE3, was reachable from no test
/// on no machine. Holding the host's instruction to this on each CI
/// architecture pins all three to one statement, because each asm arm is proved
/// against the same shared reference.
///
/// The masking is what `tbl`/`pshufb` do to an in-range index and is therefore
/// unobservable under the assert above; `shuffleModel` below is where the
/// out-of-range disagreement is written down deliberately.
pub fn shufflePortable(t: Vec, idx: Vec) Vec {
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
/// future caller to have checked. `pub` for the differential's sake — it is the
/// one arm with no portable twin to be held to, so a test has to reach it by
/// name and supply the definition itself.
pub inline fn shufflePair(lo: Vec, hi: Vec, idx: Vec) Vec {
    if (comptime !builtin.cpu.has(.aarch64, .neon))
        @compileError("lanes.shufflePair is NEON-only — callers gate on `native`");
    std.debug.assert(@reduce(.Max, idx) < 32);
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
/// than fault — fill unreachable lanes with the identity. A row that breaks
/// this now trips the shuffle's own assert in a safe build instead of quietly
/// answering one thing here and another on the next architecture.
pub fn run(
    comptime w: Width,
    comptime ix: Index,
    bytes: []const u8,
    tbl: []const u8,
    start_lane: u8,
    match_lane: u8,
) bool {
    // A comptime-known condition means only the taken branch is analyzed, which
    // is what keeps `shufflePair`'s AArch64 asm out of an x86 build's sight —
    // and it has to be asked per WIDTH, or the 32-lane arm's requirement
    // silently sets the 16-lane arm's floor.
    return if (comptime armed(w))
        runNative(w, ix, bytes, tbl, start_lane, match_lane)
    else
        runPortable(w, ix, bytes, tbl, start_lane, match_lane);
}

/// The vector fold, reachable by name.
///
/// `run` above dispatches on `armed`, so on a target that can drive neither
/// width `run` IS `runPortable`, and a test written against `run` and
/// `reference` compares a function to itself. That is not a hypothetical: it is
/// what the rung's headline "kernel ≡ definition" differential did on every
/// Linux CI run, reporting two thousand agreeing cases and proving none of
/// them. A test that means to exercise the vector fold has to say so.
///
/// The 16-lane form runs on every target — `shuffle` always resolves to
/// something, portable arm included — so it is a real differential even where
/// the rung declines to arm. The 32-lane form needs the two-register `TBL` and
/// instantiating it off NEON is a compile error, so a caller gates that width
/// on `armed(.lanes32)`.
pub fn runNative(
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
