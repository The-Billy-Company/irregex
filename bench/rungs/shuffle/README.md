# bench/shuffle — The Composition Rung's Production Proof Harness

`zig build compose-rung` (from the repository root) links the **real**
engine and the **real** rung, so the baseline is the shipped `Dfa.docMatch`
rather than a reimplementation of it. Both arms run over the same buffer, in the
same process, **interleaved round by round** and reported min-of-N — on a box
carrying ten coworker agents, an un-interleaved A/B measures the load, not the
kernel.

Four things it establishes, each fail-closed:

1. **Agreement at buffer scale.** Every row prints whether the two arms returned
   the same verdict; one disagreement exits non-zero. The exhaustive proof is
   the 350k-case differential against the Pike VM in `compose_test.zig`; this is
   the same claim over the whole buffer under test.
2. **Throughput, both arms, one run.** Each row carries the core clock measured
   *beside it* by a dependent-`ADD` chain, and its `B/cyc` columns are derived
   with that clock rather than with an advertised boost a shared machine never
   reaches. The summary line renormalises the best row to 4.512 GHz, which is
   the only figure comparable with the pre-registered 0.277 baseline.
3. **Full-buffer scans, proven per row.** The kernel returns the moment a chunk
   lands on MATCH, so one hit turns a throughput number into a measurement of
   the prefix before it. The `hit` column reports the verdict and a row that hit
   says so in the clear. Sentinel tails carry a `~` for exactly this reason: the
   research lane's all-letter tails DO match this haystack (a base64 integrity
   hash in `pnpm-lock.yaml` satisfies `letters digits letters digits letters
   zqx`), and `~` keeps the literal length — hence the state count — identical
   while being absent from the corpus.
4. **The honest boundary.** Every row is lowered through the same
   `Compose.lower`, so `dot-star-chain` is not refused by construction — it
   builds a real composition and loses the ladder's auction anyway, because the
   fallback's first-byte skip prices far cheaper than a 32-lane composition
   over a pattern with two unanchored `.*` gaps. The row prints both bids on the
   line beneath it. A rung with no ≈1× row is hiding something; this one
   publishes a loss below 0.15×.

Set `$COMPOSE_HAY` to the research lane's generated file for reproducing its
exact numbers; unset, the harness concatenates the real host corpus into one
contiguous buffer instead. `$COMPOSE_ROUNDS` sets the min-of-N depth (default
7).

## A Reference Run

One run against the checked-out host corpus, on this Apple M4 Max, while other
agents shared the box — which is why the columns below read lower than a quiet
machine would show and why every claim in this section is about *shape*
(which patterns arm, at which lane width, and which one loses the auction) and
not about a specific cyc/B holding across machines.

- **`class-alt`** (9 states, 16 lanes) measured 0.48 base B/cyc against 2.32
  composed, a 4.8× speedup.
- **`class-alt6`** (12 states, 16 lanes) measured 4.8×, matching `class-alt`'s
  ratio at a wider state count.
- **`date-suffix`** (14 states, 16 lanes) and **`alnum-run`** (15 states, 16
  lanes) both land at 4.8×, the same lane width and the same shape of win.
- **`hex-pair`**, **`digits-long`**, and **`hex-triple`** (17, 17, and 22
  states) all arm at 32 lanes instead of 16 and all measured 2.3× on this run —
  lower than the 16-lane rows above it, which is the axis this slate exists to
  show rather than a fluke of any one pattern.
- **`class-alt8`** (14 states, 16 lanes) arms and measures 4.7×. It is well
  inside the powerset's 31-non-accepting-state ceiling today; treat any claim
  that it declines as stale.
- **`uni-prop`** (73 non-accepting states) declines — past the ceiling
  `Compose.lower` enforces, which is the control this slate needs: a pattern
  that genuinely cannot be composed must say so rather than build a wrong
  answer.
- **`dot-star-chain`** (24 states, 32 lanes) is the boundary row: it builds,
  agrees with the shipped DFA, and still measures roughly a tenth the dense
  walk's throughput, because two unanchored `.*` gaps give the fallback's skip
  a candidate rate the composition cannot match. The ladder's auction reads
  both bids and keeps the DFA, which is the row's whole point.

The best full-buffer row, renormalised to 4.512 GHz the way the pre-registered
0.277 baseline was measured, comes out at roughly 2.0 B/cycle on this run —
read the ratio columns as the durable claim and the renormalised absolute as an
illustration of one moment on one shared machine.
