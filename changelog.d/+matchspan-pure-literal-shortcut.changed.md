Give the span engine a pure-literal fast path, so every "where is the match"
operation (`-o`, `--json`, `--column`, `--vimgrep`, `-w`, `-r`, colored
highlighting) stops paying the Pike VM on literal and literal-alternation
queries — the code-search common case. `Regex.matchSpan`
(`src/kernel/match/regex/linear/core.zig`) now short-circuits through `litSpan`
whenever `re.lits` is non-empty (the `analysis.pureLiterals` match-equivalence
set — an assertion-free alternation of pure literals, per-line only): the span
is found by one SIMD `scan.simd.indexOfPos` per literal (≤ 8) instead of a
per-byte NFA closure. Leftmost-first semantics are preserved exactly — the
strictly-earliest occurrence wins (leftmost start dominates branch priority),
and a positional tie keeps the lowest branch index (pattern order = NFA
priority), because no literal occurring at the winning position can have an
earlier occurrence of its own. `-i` folds a literal byte to a non-singleton
class, so `re.lits` is empty and the shortcut cleanly declines to the Pike VM;
`-U` disables `re.lits` outright, so multiline is untouched.

Byte-identical to ripgrep — `bench/rgsuite` `run.py` 405/405 (parallel and
serial), the differential-fuzz oracle green, and byte-exact `-o`/`--column`/
`--vimgrep`/`-w`/`--json` spot-checks including the `return|ret` tie-break.
Measured on a 57 MB single-file corpus (A/B vs the pre-change binary):
`--json TODO` 560→69 ms (8.2×), `--json function|const|return|struct`
3363→284 ms (11.9×), `--json return|ret` 1452→130 ms (11.2×),
`-o function|const|return|struct` 2914→256 ms (11.4×). The remaining gap to
`rg` on these is no longer span-finding but the searcher loop — gist splits and
verifies per line where rg scans the whole buffer through a Teddy/memmem
prefilter and touches only candidate lines.
