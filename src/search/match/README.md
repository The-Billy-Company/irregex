# `engine/` — the transport-neutral compiled query

The shared search core (ADR-352). One deep module owns _"a search intent,
compiled"_, so the cold CLI (`faces/cli/search/`) and the warm resident session
(`session/`) cannot drift on **what matches** or **which literals are safe to
prune by** — they compile and match through the same code here.

| File             | Role                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `query.zig`      | `CompiledQuery` — lower a `(pattern, fixed, ignore_case, mode)` spec into an immutable matcher (literal SIMD fast path, else the linear-time regex engine), and expose the two things every face needs: the sound trigram `prefilter` for index candidate pruning, and the per-doc `docMatches` / `countLines` decision. Plus `regexPrefilter`, the required-literal-vs-alternation-cover selector the cold `trigramFilter` shares. |
| `query_test.zig` | Compile shapes (literal / regex / escaped `-F -i`), prefilter selection, the fail-closed `error.Unsupported` boundary, and the match/count kernels against hand-computed answers.                                                                                                                                                                                                                                                   |

## Two invariants make it the shared boundary

- **Fail-closed, never fatal.** Every entry point returns a typed error — a
  pattern outside the linear-time syntax is `error.Unsupported`, allocation
  failure is `error.OutOfMemory`. A bad query can never `die()`/exit an embedding
  host (the resident daemon, and later the C FFI). The CLI keeps its own `die()`
  shell around this core; the core itself does not.
- **Thread-safe for the parallel walk.** A `CompiledQuery` is immutable after
  `compile`; the only per-query mutable state (the regex Pike-VM simulation) is a
  caller-owned `Scratch`, one per worker, threaded into the match primitives — so
  N walk workers share one compiled query with N scratches.

Richer cold-only presentations (content, context, `--json`) stay in
`faces/cli/search/` — they consume the same match decision but shape their own
output.
