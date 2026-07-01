**The engine now lives entirely under `src/`, split into concern-scoped tiers;
`bench/` is the benchmark/verify harness only** — a clean separation of the
product from the tooling that measures it. Engine logic had accreted inside
`bench/` next to the latency harness; it moved out into six tiers, each a
subfolder with its own `README.md`:

- `src/index/` (**T0** trigram candidate index — `ngram`/`trigram`/`persist`),
  `src/regex/` (Thompson NFA + byte-class DFA + Pike VM), `src/rank/` (**T4** RRF
  fusion + language-agnostic signals), `src/scan/` (no-prefilter parallel verify
  — `simd`/`sweep`/`verify`), `src/corpus/` (loading + mtime freshness overlay),
  `src/commands/` (the CLI driver surfaces that compose the tiers).
- The `rg` drop-in was **renamed off ripgrep's source layout onto its features**:
  the one `rgcompat` monolith became `src/commands/ripgrep/{args,ignore,output,
  json,run}.zig`, `rgemit` became `output.zig`, and `pathfilter` split into
  `src/commands/scope/{glob,types}.zig`. Each module is now named for what it *is*.
- `build.zig` builds two artifacts on the shared kernel — the production `gist`
  CLI (`src/commands/cli/main.zig`) and a separate `gist-bench` harness
  (`bench/bench.zig`); they no longer share a binary.

Pure structural move — every `*_test.zig` rides `src/root.zig` and the full suite
(177 tests, incl. the differential Pike-VM fuzz oracle) stays green. Rule-of-Five
registry entries record the `src/` tier fan-out and the harness-only `bench/`.
