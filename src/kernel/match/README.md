---
doc_radar:
  counts:
    - description: "match keeps regex + scan execution packages"
      glob: pkg/kernels/irregex/src/kernel/match/*/
      unit: dirs
      equals: 2
  sentinels:
    - description: "CompiledQuery remains the shared fail-closed core"
      file: pkg/kernels/irregex/src/kernel/match/query.zig
      contains: ["error.Unsupported", "immutable after", "pub const CompiledQuery"]
---

# `src/kernel/match/` — exact-match engine

The transport-neutral match core ([ADR-352](../../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)).
One deep module owns _"a search intent, compiled"_, so the cold CLI, warm
session, FFI face, and language bindings cannot drift on **what matches** or
**which literals are safe to prune**.

## Layout

| Piece             | Job                                                                                                                                                                         |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `query.zig`       | `CompiledQuery` — lower `(pattern, fixed, ignore_case, mode)` into an immutable matcher; expose the sound trigram `prefilter` + per-doc `docMatches` / `countLines`         |
| `prefilter.zig`   | `query.zig`'s private sub-module: the sound literal derivations warm + cold share verbatim — required/alt cover, caseless fold-window + case-variant OR-set, `-F -i` escape |
| `word.zig`        | `query.zig`'s private sub-module: the ripgrep `-w` word-boundary post-match rule (`wordOk` + the literal / regex word-span scans) over the shared `\b` oracle               |
| [`regex/`](regex) | Linear-time NFA + byte-class DFA + Pike + opt-in PCRE2 (`syntax → analysis → compile → linear`)                                                                             |
| [`scan/`](scan)   | SIMD substring presence + fused parallel verify (fixed-string hot path) + the dense class-run boolean/count kernel                                                          |

## Two invariants make it the shared boundary

1. **Fail-closed, never fatal.** Typed `error.Unsupported` /
   `error.OutOfMemory` — a bad pattern can never `die()` / exit an embedding
   host. The CLI wraps this core with its own `die()` shell; the core does not.
2. **Immutable after compile.** N walk workers share one `CompiledQuery` with
   N caller-owned `Scratch` buffers (Pike simulation state).

## Match ladder (cheapest sound rung first)

Fixed `-F` → `scan/` SIMD → linear regex (DFA primary, Pike fallback) →
PCRE2 only when `-P` / `--engine auto` needs lookaround or backrefs. Unicode
default-on at rg parity; details in [`regex/README.md`](regex/README.md).

Richer cold-only presentations (context, `--json`, color) stay in
`surface/exec/cold/emit/` — they consume the same match decision but shape their
own output.
