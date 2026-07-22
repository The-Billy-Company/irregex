Accelerate the SIMD scan floor on two load-port-bound fronts. First, widen the
single-load byte scanners in `scan.simd` from the 16-byte NEON register to a
64-byte stride (`scan_vlen`): `memchr` (line-end find), `countByte` (line-number
counter), `countByteWithFlag` (`--json` base pass), the reverse `lastIndexOfScalar`
(line-start walk), and the caseless single-byte find. These issue one load per
block, so the out-of-order core runs the four independent 16-byte loads across its
NEON pipes — measured ~35% faster (17→23 GiB/s, Apple M4). A `vlen`-wide second
tier runs before the scalar tail so a haystack under 64 bytes still vectorizes (no
short-line/small-gap regression). The two-load substring kernel (`indexOfPos` &
co.) deliberately stays at `vlen` — its strided second load already saturates the
ports, so widening measured flat.

Second, add `scan.teddy` — the Hyperscan/ripgrep Teddy multi-literal prefilter —
and hand the fused any-of gate (`scan.simd.containsAny`/`indexOfAnyPos`, the
whole-buffer prefilter for needle-less alternations like `func|const|return|struct`)
off to it at 4+ needles. The fused first+last gate pays `1 + N` loads per block, so
its cost grows linearly in the alternation size; Teddy pre-bakes every needle's
first two bytes into nibble→bucket tables and resolves all N with one `tbl` (NEON) /
`pshufb` (SSSE3) shuffle per position, collapsing the block cost to a CONSTANT 2
loads regardless of N. Slim Teddy, one bucket per needle (≤ 8), fixed 16-wide, with
a scalar-gather fallback on other arches. The N ≥ 4 handoff is where the load-count
win dominates on every architecture regardless of vector width, so N = 2,3 keep the
fused gate (better on wide-vector AVX2/512); both paths are byte-exact — a
throughput dispatch, not a fallback.

Byte-exact throughout: the `simd_test.zig` differential oracles stay green (the new
Teddy fuzz vs the `std.mem.indexOfPos` leftmost minimum over random needle
sets/resume offsets, plus the widened `memchr`/`lastIndexOfScalar`/`countByte`
scanners vs `std`), and `gist` counts match `rg` exactly on 4- and 8-literal
alternations across ~290k lines. Measured Teddy speedup over the fused path on the
mostly-miss file-gate corpus (Apple M4): N=4 1.6×, N=8 2.2×.
