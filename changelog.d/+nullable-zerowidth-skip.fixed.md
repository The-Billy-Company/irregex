**`.skip` search no longer drops a zero-width match at a bare boundary / EOL**
(`src/regex/analysis.zig`, `src/regex/core.zig`). The first-byte `.skip` search
seeds a start only at line position 0 and immediately *before* a byte in the
first-set — never at a bare word-boundary gap or at end-of-line. That is sound
for a match that must consume a first byte, but a **conditionally-nullable**
branch can match with no consumed byte at a position the skip never visits. So a
pattern like `zzz|\b{4,6}$` or `q|\B{2}` — where one branch supplies a first-set
(forcing `.skip`) while another matches zero-width via a word boundary — silently
missed the zero-width branch. `reachesMatchEol` couldn't rescue it: it
deliberately won't cross a `\b`/`\B`, so its `eol_empty` shortcut stays false for
these *content-dependent* EOL matches.

Surfaced by the regex engine's own adversarial differential fuzzer against the
`rg` oracle: `MATCH-DIVERGENCE pat=/^\S\w{2}|\b{4,6}$/` and
`DOC-DIVERGENCE pat=/…|\B+\B{4,6}$/` (gist returned `false` where `rg` matched).

Fix: a new conservative analysis predicate `reachesMatchZeroWidth` — does the
start ε-reach `match` through a zero-width path that may cross *any* assertion
(`^ $ \b \B`)? — sets a `Regex.nullable` flag, and `lineMatchPike` routes nullable
patterns to the `.plain` search (which re-seeds every position, EOL included)
instead of `.skip`. Sound by construction: a false "nullable" only forgoes the
skip optimisation, never a match, and genuinely consuming patterns
(`func\s+\w+`, `pgxpool`, …) stay non-nullable on the fast `.skip` path. The full
differential fuzz suite is green again; permanent regression coverage lands in
`src/regex/core_test.zig` (the `z|\b{4,6}$` / `z|\B{2}` / `z|\b{2,}$` skip-mode
cases, expectations cross-checked against `rg`).
