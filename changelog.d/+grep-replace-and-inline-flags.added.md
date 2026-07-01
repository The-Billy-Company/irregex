**`grep` closes three reflexive-invocation gaps found by dogfooding gist *as the
agent* against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`,
`bench/pathfilter.zig`). Racing the two tools on real repo questions surfaced one
silent-wrong landmine, one fail-loud on a legal pattern, and a robustness win rg
lacks — each of which broke a call an agent's muscle memory actually types:

- **`-r` / `--replace` was a silent-wrong landmine — now a real value flag.** rg's
  `-r` *consumes* the replacement, but gist had it mis-listed among the boolean
  no-ops, so `grep -r X pat` parsed `X` as the pattern and `pat` as a path root — a
  wrong-but-confident empty result (the worst agent failure). It now stores
  `opts.replace` and rewrites each match before emit: `$0`/`${0}`/`$&` expand to
  the whole match, `$$` is a literal `$`. A capture-group ref (`$1`, `${2}`) is
  rejected **at parse time** — gist's span engine tracks the whole-match extent,
  not per-group captures, so failing loud beats a silently-dropped substitution.
  Proven byte-identical to `rg -o -r`/`rg -r` over the shared `-t go` corpus.
- **Leading inline flag groups `(?i)` / `(?-u)` / `(?m)` are now honored.** An agent
  pastes rg patterns carrying a global flag group reflexively; gist used to reject
  the whole (legal-to-rg) pattern. Now `i`→ASCII caseless (`(?i)walletservice` is
  byte-identical to `-i`), `m`/`u`/`U`/any `-…` form → no-op (gist is per-line,
  byte-oriented — exactly rg `(?-u)`), while `s` (dotall across newlines) and `x`
  (extended) still fail **loud** rather than silently mis-match. `-F` keeps `(?i)`
  a literal; a non-capturing `(?:…)`/lookahead `(?=…)` is left for the compiler.
- **`-t tsx/jsx/vue/svelte/rego/mdc/cedar` resolve.** Convenience rows for types an
  agent types that even `rg` lacks (`tsx`/`jsx`) or that are repo-native (`rego`,
  Cursor `.mdc`, Cedar policy), so a reflexive `-t tsx useState` scopes instead of
  erroring.

Also documented but *not* a gist change — the decisive reason to prefer gist in an
agent loop: in a harness where stdin is a non-tty pipe (how Cursor/Claude Code/
Codex spawn shells), a bare `rg PATTERN` with no path arg **blocks forever reading
stdin**; gist always searches its indexed roots and never has this failure mode
(`rg PATTERN </dev/null` returns instantly with the same result).

Correctness unchanged: the `gist ≡ rg` set oracle still proves 0 FN / 0 FP (80
literals + 94 regexes), the parser carries 4 new adversarial tests (value
consumption, inline-flag map, `-F` literal, group-ref reject), and all five new
behaviors diff to **0 lines** vs `rg` on the shared scope.
