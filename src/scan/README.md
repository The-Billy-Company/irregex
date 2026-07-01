# gist/src/scan

The **no-prefilter fallback** — when a regex has no usable literal, every doc is
a candidate, so gist skips the index and scans the live tree directly. This tier
is the half of the head-to-head that has to out-throughput ripgrep's multi-core
scan.

| File         | Role                                                                                                                          |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `simd.zig`   | SIMD substring presence test (`contains ≡ std.mem.indexOf`) — the hot primitive in the verify path.                            |
| `sweep.zig`  | The fused **work-stealing** parallel verify: walkers stream paths into a shared queue while a core-sized pool steals files and reads+scans as the walk still runs (worker-span Δ 169 ms → 2.5 ms vs the old phased scan). |
| `verify.zig` | The pure data-parallel candidate-verify kernel + SIMD scan; the corpus-aware matcher wrappers that drive it live in the callers. |

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary are gated
by `bench/scan_regress.sh`.
