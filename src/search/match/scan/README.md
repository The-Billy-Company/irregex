# gist/kernel/scan

The **byte-level verify primitives** — the hot per-file kernels that decide
whether a candidate matches. This is the half of the head-to-head that has to
out-throughput ripgrep's multi-core scan; the fused work-stealing walk that
feeds these kernels on the no-prefilter path lives in the ripgrep engine
(`faces/cli/search/engine/parallel.zig`), and the resident session drives `verify`
directly.

| File         | Role                                                                                                                             |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `simd.zig`   | SIMD substring presence test (`contains ≡ std.mem.indexOf`) — the hot primitive in the verify path.                              |
| `verify.zig` | The pure data-parallel candidate-verify kernel + SIMD scan; the corpus-aware matcher wrappers that drive it live in the callers. |

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary are gated
by `bench/gates/scan_regress.sh`.
