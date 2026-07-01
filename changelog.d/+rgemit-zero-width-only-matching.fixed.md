**`rg -o` emits zero-width matches for a nullable pattern, matching rg's
`find_iter`** (`bench/rgemit.zig`). gist's only-matching span loop unconditionally
skipped empty spans, so `-o ''` (and other nullable patterns) produced nothing
where ripgrep prints an empty `-o` line per zero-width match.

- **`emitMatches`** now emits a zero-width match when the regex is **nullable**
  (`re.nullable`), following rg's progress rule — an empty match adjacent to the
  previous match's end is skipped, empties advance one byte — and honoring `-w`
  (word-boundary check on the empty span). A **non-nullable** pattern never
  produces an empty span, so its output is byte-identical to before: **zero
  regression risk** for every previously-passing `-o`/`-w` case (verified: no
  passing test regressed).

Proven against real ripgrep as the oracle: `r1891` (`-won ''` over `"\n##\n"` →
one empty match on the blank line, three on `##`) now diffs to **0 bytes** vs
`rg`, taking the drop-in to **100% supported-surface parity (265/265)**.
