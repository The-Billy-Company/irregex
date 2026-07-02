**The two search engines merged into one.** `gist`'s certified ripgrep-parity
walk-and-emit pipeline (`src/commands/ripgrep/`) is now the *sole* engine, and it
gained a second, much faster candidate source: the persisted trigram index. When
a fresh index covers the searched subtree it is used automatically as an
*acceleration structure* — reads of files the index can prove cannot match
(trigram non-candidates unchanged since the index was built) are elided, while
the live walk stays authoritative for path discovery and `.gitignore` semantics,
so output is byte-identical to a pure walk. `--no-index` forces the live walk;
`--index` forces the accelerated path (default: auto-detect). A new
`bench/gates/index_elision_parity.sh` differential gate proves the core safety
claim continuously — every query's index-accelerated output equals its
`--no-index` full read across literal / regex / caseless / word / count /
files-with(out) / context / invert / only-matching / type- / path-scoped cases,
plus the freshness overlay (16/16 byte-identical).

`--rank[=N]` folds in gist's one output shape ripgrep can't express — the
definition-first ranked view (RRF fusion over per-file signals, a symbol's
definition outranking its call sites, codegen demoted) — now a flag on the
unified engine (`src/commands/ripgrep/rank.zig`) instead of a separate verb.

**The `search` verb is gone.** Bare `gist <pattern> [PATH...]` is canonical
(`index` and `status` remain the only lifecycle verbs); `gist rg` is the same
engine addressed explicitly. rgsuite parity held at the 278/282 baseline
throughout and the full `zig build test` slate stays green.
