**Finished the search-engine unification the previous entry started.** The
`search` verb's removal (see `unify-search-engine`) left the old
`src/commands/search/` package dead (deleted, minus its one still-needed
`looksLikeRegex` helper, moved into `ripgrep/args.zig`), `root.zig` still
exporting/testing it, and stale doc comments across `index/persist.zig`,
`corpus/corpus.zig`, and `corpus/haystack.zig` pointing at it.

**The bench gates and README were still asserting the pre-unification
contract.** `bench/gates/streams.sh` and `bench/gates/scan_regress.sh` (plus
`bench/races/_compete.sh`'s shared invocation helpers) still shelled the
removed `gist search <pattern> --show files` syntax and asserted the old
`search` verb's wider-than-`rg` corpus (`--no-ignore --hidden`) and a
"routes to the live scan" stderr announcement that no longer exists — so both
gates were silently non-functional (argument-parse failures, not green
checks) rather than actually verifying anything. Rewrote both against the
unified engine's real contract: `gist <pattern> -l`, `.gitignore`/hidden
parity with `rg`'s default, and stderr silent except `--rank`'s timing line.
`scan_regress.sh` now surfaces real FN/FP counts against `rg` for
no-prefilter patterns instead of skipping the comparison — worth a follow-up
look, since a first run found genuine mismatches (binary-file handling
divergence) it was never actually catching before.

`README.md`, `bench/gates/README.md`, `src/commands/cli/README.md`, and the
`project-overview.mdc` navigation line were all rewritten to match: the
canonical usage is the bare `gist <pattern>`/`gist rg`, `.gitignore` and
hidden-file semantics now match `rg` exactly (no more documented
superset-of-`rg` corpus), and `--rank`/`-l` replace the removed `search
--rank`/`--show files` spelling throughout.
