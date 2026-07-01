**Regex engine gains AST-level ASCII case-folding, so `-i` / `(?i)` matches
caseless across every backend** (`src/regex/syntax.zig`). Case-insensitivity used
to be handled ad-hoc at the grep layer; it now lives in the engine where the
NFA, lazy DFA, and Pike capture VM all inherit it from one place.

- **`ByteSet.foldCase`** admits the opposite-case twin of every letter present in
  a consuming class (`a`⇄`A`), and **`foldCaseAst`** walks the AST applying it to
  every class (zero-width assertions and structure untouched, `capture` nodes
  recursed transparently). It's idempotent, so re-visiting a shared `{n,m}` atom
  in the DAG is harmless.
- **Trigram soundness preserved**: a folded literal byte becomes a 2-member set,
  which the `only`/`required` literal extraction reports as non-singleton — so a
  caseless pattern yields an empty required-literal and the query soundly falls
  back to a full scan (gist's trigram index is case-sensitive). No false
  negatives from a case-folded search.

Proven against real ripgrep as the oracle: `-i` cases (ASCII caseless literal and
class) diff to **0 bytes** vs `rg`, with the engine's existing differential and
prefilter-soundness tests still green.
