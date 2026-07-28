---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/bench/rungs/shuffle/bench.zig
    - pkg/kernels/irregex/src/kernel/regex/linear/shuffle/shuffle.zig
  sentinels:
    - description: "the harness fails closed on disagreement and on the gate arming where it must not"
      file: pkg/kernels/irregex/bench/rungs/shuffle/bench.zig
      contains:
        - "error.ComposeProofFailed"
        - "the dispatch gate ARMED on an accelerated pattern"
        - "throughput above is over a prefix"
---

# bench/shuffle — the composition rung's production proof harness

`zig build compose-rung` (from `pkg/kernels/irregex/`) links the **real**
engine and the **real** rung, so the baseline is the shipped `Dfa.docMatch`
rather than a reimplementation of it. Both arms run over the same buffer, in the
same process, **interleaved round by round** and reported min-of-N — on a box
carrying ten coworker agents, an un-interleaved A/B measures the load, not the
kernel.

Four things it establishes, each fail-closed:

1. **Agreement at buffer scale.** Every row prints whether the two arms returned
   the same verdict; one disagreement exits non-zero. (The exhaustive proof is
   the 350k-case differential against the Pike VM in `compose_test.zig`; this is
   the same claim at 206 MiB.)
2. **Throughput, both arms, one run.** Each row carries the core clock measured
   _beside it_ by a dependent-`ADD` chain, and its `B/cyc` columns are derived
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
4. **The honest boundary.** The `dot-star-chain` row lowers the rung _past_ its
   own dispatch gate (`Compose.lower`, not `Compose.build`) purely to publish
   how badly it loses to an armed literal skip — then prints, on the row below,
   that `build` refuses that exact pattern. A rung with no ≈1× row is hiding
   something; this one publishes a 0.15× row.

Haystack: `$COMPOSE_HAY` when set (the research lane's generated file, for
reproducing its exact numbers), else the real Billy corpus concatenated into one
contiguous buffer. `$COMPOSE_ROUNDS` sets the min-of-N depth (default 7).

## Reference run — Apple M4 Max, 206.8 MiB of the Billy corpus

| pattern          | \|Q\| | lanes | base B/cyc | comp B/cyc | speedup                          |
| ---------------- | ----- | ----- | ---------- | ---------- | -------------------------------- |
| `class-alt`      | 9     | 16    | 0.335      | 2.259      | 6.75×                            |
| `class-alt6`     | 12    | 16    | 0.339      | 2.269      | 6.69×                            |
| `date-suffix`    | 14    | 16    | 0.328      | 2.208      | 6.73×                            |
| `alnum-run`      | 15    | 16    | 0.339      | 2.270      | 6.70×                            |
| `hex-pair`       | 17    | 32    | 0.343      | 1.142      | 3.33×                            |
| `digits-long`    | 17    | 32    | 0.340      | 1.137      | 3.34×                            |
| `hex-triple`     | 22    | 32    | 0.330      | 1.108      | 3.36×                            |
| `uni-prop`       | 94    | —     | —          | declined   | past 31 states                   |
| `dot-star-chain` | 31    | 32    | 23.42      | 3.551      | **0.15× ← boundary, gate holds** |

`B/cyc` above is at each row's own measured clock (3.6–4.0 GHz under coworker
load). The best full-buffer row renormalised to 4.512 GHz is **1.993 B/cycle**.
