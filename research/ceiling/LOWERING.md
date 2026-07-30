# Lowering — the compiler between the algorithm and the machine

Everything in [`PRIOR_ART.md`](PRIOR_ART.md) is stated in bytes/cycle, which
quietly assumes the machine runs the algorithm you wrote. Twice during the scan
campaign it did not, and both times the gap was **2× or more** — larger than any
algorithmic choice made in the same week.

These are not style notes. Each one is a spelling of _identical semantics_ that
LLVM lowers differently, each was found by reading disassembly after a
prototype-to-in-tree regression, and each cost a day. They are recorded here
rather than in a styleguide because the styleguide cannot say _why_, and the why
is what makes them predictable instead of superstition.

## 1. `@Vector(n, u128)` is not a vector on AArch64

The Parabix rung holds a stripe of bit-planes. Spelling that stripe as
`@Vector(8, u128)` and applying `&`/`|`/`^` produces **16 scalar GPR
operations** with 18 loads and 10 stores. The bit-identical data respelled as
`@Vector(128, u8)` produces 8 paired `q`-register loads and one `and.16b`.

This is not a Zig defect — the campaign verified that by reproducing it in
clang 21 through `__attribute__((vector_size))`, and then found the deliberate
commit: LLVM 646478f (David Green, 2024-08-23), _"[AArch64] Scalarize i128
add/sub/mul/and/or/xor vectors"_, which enumerates exactly these opcodes and
ships its own test. Zig is lowering `<8 x i128>` faithfully; the target says
scalarize.

Respelling the stripe was the single largest win in that rung's build. A patch
narrowing the LLVM rule to leave bitwise ops vectorized measures 53 → 23
instructions and 1.57× on an M4.

**Rule:** on AArch64, a SIMD lane type wider than 64 bits is a scalar
instruction wearing vector syntax. Choose the lane width the hardware has (`u8`,
`u16`, `u32`, `u64`) and index into it, however unnatural that makes the code
read.

## 2. The stripe wants to be wider than the register file argues

Intuition says a stripe should fit the architectural registers, and spilling is
the thing to avoid. Measured across stripe widths 1/2/4/8, throughput went
**3.44 → 7.62 GB/s** — monotonically better as the stripe outgrew the registers.

The reason is that the cost being traded is not "vector load vs. register": it
is "one spilled vector load" against "the scalar dispatch, bounds arithmetic,
and loop bookkeeping for one more gate iteration." The second is more expensive
than the first on a wide out-of-order core, and it is per-gate rather than
per-block.

**Rule:** pick stripe width by measurement, and expect the answer to be past
the point where register pressure says stop.

## 3. Trusting the compiler to amortize adjacent loads does not work

The composition rung reads a small table of transformation leaves. Written the
obvious way — `bytes[i]` for each field, on a table whose fields are adjacent
and constant-offset — the first in-tree build sat at 1.41 bytes/cycle, i.e. 0.71
cycles/byte, on a core that retires 3.03 loads/cycle. That is almost exactly
**two loads per byte**: the compiler emitted a separate load per field and never
fused them.

Folding each group into one `readInt(u64)` and recovering the fields with bit
extraction took the same kernel to **2.26 bytes/cycle** — a 1.6× win with no
change to the algorithm, the table, or the answer.

**Rule:** in a loop whose limit is load ports rather than ALU, count the loads
in the disassembly before believing a throughput number. Adjacent constant-offset
byte reads are the specific shape that looks free and is not.

## Why this file exists

The campaign's entire premise was that a scan loop's cost is dominated by one
structural property — the loop-carried dependent load — and that beating it
requires escaping the model rather than tuning inside it. That premise held.
But **the measured cost of a bad lowering was the same order as the cost of the
wrong algorithm**, and a rung that escapes the dependency chain and then pays
two loads per byte has spent its whole advantage before it starts.

So the honest summary of the throughput table one directory up: those numbers
are properties of an algorithm _and_ a spelling, and the spelling is not free.
