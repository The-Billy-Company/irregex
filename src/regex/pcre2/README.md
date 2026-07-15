# gist — PCRE2 backend internals

The opt-in `-P`/`--pcre2` engine (lookaround, backreferences, named captures)
that the linear default engine cannot express. `../pcre2.zig` is the stable
module entry the frozen `../matcher.zig` seam imports; it re-exports the exact
`Pcre`/`Options`/`CompileError`/`Span` surface and the implementation lives
here.

| File          | Role                                                                                                                                                                                                                                                                   |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ffi.zig`     | The minimal explicit-`extern` C-ABI surface of the vendored PCRE2 10.47 8-bit library (`_8` symbols). No `@cImport`; the archive is compiled + linked hermetically by `build.zig` (`pcre2Library`).                                                                    |
| `engine.zig`  | The `Pcre` handle: `compile` (JIT with interpreter fallback + compile diagnostics), the immutable shared program, per-thread `Sim`/`SpanSim` scratch (match data + resource ceilings + a private 10 MiB JIT stack), and `lineMatch`/`docMatch`/`bufMatch`/`matchSpan`. |
| `literal.zig` | Sound required-literal extraction for the trigram prefilter — the longest ASCII run PCRE2 provably requires in **every** match, or `""`. Never over-claims, so the index can never wrongly elide a `-P` query's read.                                                  |

## Design notes

- **Concurrency.** One `Pcre` (the compiled program) is shared read-only across
  worker threads; all mutable match state is the per-thread `Sim`/`SpanSim`
  scratch. PCRE2 match data must never be shared, so the split is load-bearing.
- **Determinism over pathological input.** A match limit (10M) and depth limit
  (10k) ride every match context, so catastrophic backtracking trips a clean
  no-match in milliseconds instead of hanging. Any resource-limit / error return
  is fail-closed to "no match".
- **Unicode / invalid UTF-8.** `Options.unicode` compiles with UTF+UCP plus
  `PCRE2_MATCH_INVALID_UTF`, so a search over binary/partial text matches the
  valid spans and never errors — ripgrep `-P` parity.

The vendored sources + provenance (release URL, sha256, license) live in
`../../../vendor/pcre2/`.
