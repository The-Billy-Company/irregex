# `src/kernel/` — pure search kernels

Algorithms and math — no argv, no walk, no emit, no filesystem. Every
transport (cold CLI, warm session, FFI, bindings) compiles through here so
they cannot drift on what a hit is. This package's own contract
(`charter.zone`) declares eight tiers, low→high, and an import may
only point back down the page. Two more tiers of the same law — compression
kinship and set-algebra composition — are zoned separately in the sibling
kinship package, which stands above this library in the ecosystem DAG and
carries its own `charter.zone`.

- [`math/`](math) is the math floor: bits, mix, the pure glob matcher, the
  crest sieve, misread, forest, lease, parallel, the succinct structures.
  Arithmetic with no product opinion.
- [`codex/`](codex) is the FM-index composition over the succinct floors,
  sealing its persisted payload with the wire floor.
- [`scan/`](scan) holds the SIMD scanners and the literal-lane vocabulary
  they share with the regex composer.
- [`regex/`](regex) is THE regex package: parser, linear engines
  (dfa/pike/ladder/sieve/symbolic/parabix/caliper/shuffle), the PCRE2
  bridge, `matcher.zig`'s meta dispatcher, and the consumer-facing
  `regex/glean/` (`Pattern`, `find`/`replace`/`split`, `Cursor`) — all
  sealed through `regex.zig`. Ambition: beat rust-regex.
- [`query/`](query) is the shared compiled query every transport compiles
  through.
- [`rank/`](rank) fuses results and derives cross-language definition signals
  (the ranked view, and the signals the other faces read too).
- [`slate/`](slate) runs many patterns in one walk — `patterns` · `muster`
  · `trawl` · `loom`.
- [`anatomy/`](anatomy) is source anatomy: the parser-free comment/code/string
  span lexer and the line index — what stayed after the unit anatomy
  (functions, regions) and its tokens, spans and leans moved to the kinship
  package.
- The kinship package's `kernel/kinship/` is compression-as-similarity:
  `metric/` · `cluster/` · `recall/`.
- Its `kernel/codex/` is the Ziv–Merhav cento quoter over this package's
  FM-index — that package's product math over the `codex/` tier above.
- Its `kernel/compose/` is set algebra over candidate sets:
  exact-before-statistical composition.

## The Match Ladder

Cheapest sound rung first:

1. **Fixed string** (`-F`, caseful) goes to `scan/` SIMD presence.
2. **Linear regex** compiles to a Thompson NFA plus byte-class DFA, with a
   Pike VM for multiline / oracle work and optional accelerator rungs
   (shuffle, parabix, sieve, …).
3. **PCRE2** (`-P` or `--engine auto`) handles lookaround / backreferences.

Unicode is default-on at rg parity. See [`regex/README.md`](regex/README.md).
The seam deliberately mirrors the rust-regex ecosystem: `regex/` ≈
regex-syntax + regex-automata; sibling `scan/` ≈ memchr + aho-corasick +
teddy; sibling `query/` ≈ the meta engine.

## The Kinship Package's Kernels

- `kinship/recall/lexicon` nominates; `kinship/recall/zipper` decides.
- `kinship/metric/sketch` is the symmetric metric behind `similar` /
  `echoes`.
- `slate/patterns` attributes N intents exactly; its fused gate is
  skip-only.
- `slate/loom` shapes rows engine-side (filter → group → sort → limit).
- `compose/` narrows a typed `CandidateSet` before kinship/coverage run
  inside.

## When to Edit Here

Match semantics, prefilter soundness, DFA/Pike/PCRE caps, ranking signals,
kinship math, multipattern attribution, composition algebra. Do not put
ignore rules, flag parsing, or output coloring here; that is `exec/cold/` /
`corpus/`.
