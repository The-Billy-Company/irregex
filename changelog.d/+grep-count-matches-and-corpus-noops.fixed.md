**`grep` closes four more reflexive-invocation gaps found by dogfooding gist *as
the agent* against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`). Racing the
two on real repo questions surfaced one silent-wrong landmine and three
fail-loud-on-a-legal-call breaks — each of which an agent's muscle memory hits:

- **`--count-matches` was a silent-wrong landmine — now a true match count.** It
  aliased to `-c`/`--count`, so it counted matching *lines* where rg counts
  individual match *spans* — on `e` in one file gist said `165` (lines) while rg
  said `988` (matches), a wrong-but-confident number (the worst agent failure).
  It now counts non-overlapping leftmost-first spans via the same span engine
  `-o` rides (a per-shard `SpanSim`, allocated only when the flag is set), while
  `-c`/`--count` stays line-count. `-m N` caps the total; `--count-matches -v`
  falls back to counting non-matching lines (rg's behavior — invert has no span
  to count). **Proven byte-identical to `rg --count-matches`** across 11
  literal + regex patterns over the shared `-g '*.go' services/backend` scope
  (up to 2 591 files each, 0 mismatches).
- **Corpus-policy no-ops gist already satisfies are accepted, not fail-loud.**
  `--hidden`, `--no-ignore[-vcs/-parent/-dot/-global]`, `-u`/`-uu`/
  `--unrestricted`, `--one-file-system` all ask rg to widen its corpus toward
  what gist's index **already** searches (it ignores `.gitignore` and includes
  hidden dotfiles — README "Scope vs ripgrep"), so they're no-ops here, not
  errors. Proven to leave output byte-identical to the bare query.
- **`--sort`/`--sortr` swallow their value (gist emits path-ascending already).**
  gist's `grep` output is sorted by path (a stable, deterministic order), which
  *is* `--sort path` — the overwhelmingly common agent request — so the flag is
  a no-op that consumes its value instead of erroring.
- **Recognized-but-unsupportable flags fail LOUD with the reason + `rg`
  fallback, not the generic "unknown flag" dump.** `-P`/`--pcre2` (PCRE
  backreferences/lookaround — gist runs a linear-time RE2-style engine),
  `-U`/`--multiline[-dotall]` (gist matches per line), and
  `--json`/`--vimgrep`/`--column` (gist emits fixed `path:line:text`) now print
  a one-line "why + use `rg …`" instead of leaving the agent to guess whether it
  typo'd or hit a real limit. Crucially still fail loud — never silently ignored
  (which would give a wrong result on a genuinely PCRE/multiline pattern).

Correctness unchanged: the `gist ≡ rg` set oracle still proves **0 FN / 0 FP**
(140 literals + 70 regexes over the byte-identical snapshot), and the parser
carries 4 new adversarial tests (count-matches ≠ count, the corpus no-op family,
`--sort` value-swallow, the fail-loud contract for `-P`/`-U`/`--json`/…).
