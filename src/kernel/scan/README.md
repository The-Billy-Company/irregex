# `src/kernel/scan/` — byte-level verify primitives

The hot per-file kernels that decide whether a candidate matches. This is the
half of the head-to-head that has to out-throughput ripgrep's multi-core
scan. The fused work-stealing walk that *feeds* these kernels lives in
`exec/cold/engine/swarm/`; the resident session drives `verify` directly.

## Files

`scan.zig` is the door: it groups the ten files below under one name
(`scan.literals`, `scan.classrun`, `scan.anchor`, …), because four of them
used to be reachable from the package root and six were not, which is a
strange way to ship an Aho–Corasick and a Teddy.

- **`lanes.zig`** is the literal-lane vocabulary and byte-shuffle algebra
  (`Vec`, 16/32 widths, `shuffle` / reduction). It is std-only, and the
  regex shuffle rung and Teddy share it; it moved here from
  `regex/linear/shuffle/` so Teddy never imports the regex package.
- **`simd.zig`** is SIMD substring presence (`contains` ≡
  `std.mem.indexOf`), a memchr-style rare-pair anchor gate for fixed
  strings over 64-byte blocks gated on a cheap any-lane OR-reduce (movemask
  only in hit blocks). It also owns the anchor decision as a value: `Plan`
  (the chosen pair plus single-probe eligibility), `planFor` (static, from
  the shipped table), `planOn` (the same decision re-priced on one
  document's bytes), and the `*With` entry points a caller drives a minted
  plan through. `Gate` carries a plan so the whole-file drop and the
  hit-jump loop share one decision; `Gate.on(hay)` re-decides it for one
  body and is idempotent on purpose.
- **`anchor.zig`** decides which two needle offsets the block filter
  compares — the filter's only variable cost, and therefore the one place
  that decision is allowed to be made. It minimizes summed byte rarity,
  then breaks ties toward the widest separation. It also carries the
  recorded defects: ranking marginals prices a conjunction as `P(a)·P(b)`
  and so assumes the probes are independent (text badly violates it), and a
  saturating density table turned that drift into a collapse onto the
  adjacent pair. See `research/pincer/`.
- **`rarity.zig`** is the corpus-derived byte-density table feeding
  `anchor`'s selection and the single-probe dispatch threshold (the memchr
  crate's "rare byte" heuristic, measured over a large polyglot monorepo).
  Its *ordering* is the load-bearing property: a saturating cell is a tie,
  and a tie hands the decision to a fallback.
- **`calibrate.zig`** re-prices `anchor`'s decision on the buffer actually
  in hand, at 64 KB sampled in 256-byte stratified windows, cheapest pair
  wins, landing at 1.03–1.04× of the best-possible pair where the static
  table sits at 1.39–2.21×. It is reached only through `simd.planOn`, and
  as an improvement test (`refine`) rather than an override, because
  adopting the sample's favorite unconditionally was a measured CPU tax and
  a purely relative accept margin is a winner's curse. Its size gate is a
  claim about the scan the sampling amortizes against, so it is priced per
  document and never per line.
- **`verify.zig`** is the pure data-parallel candidate-verify kernel and the
  SIMD scan wrappers callers drive.
- **`teddy.zig`** is Teddy, the nibble-shuffle multi-literal prefilter
  (Hyperscan's slim-Teddy, 8 buckets per group), which resolves up to
  `max_buckets` = 64 needles in a constant two loads per block via
  nibble-to-bucket `tbl`/`pshufb` tables, where the fused first+last gate
  would pay `1 + N`. It is byte-exact leftmost versus `std.mem.indexOf`,
  proven by the differential fuzz in `simd_test.zig`.
- **`literal_set.zig`** is the literal-set dispatcher, one engine over the
  whole size range: one needle takes the rare-byte `memmem` kernel, sets
  through 64 take grouped Teddy, larger sets take sparse Aho–Corasick.
  Every result carries an `Authority`: an `.exact` pure-literal set (the
  pattern *is* this alternation) decides presence/position outright, while
  a `.candidate` cover only nominates a regex-engine candidate. This is the
  machine the ladder fronts every boolean entry point with
  (`../regex/linear/ladder/verdict.zig`).
- **`aho.zig`** is sparse Aho–Corasick (Aho & Corasick 1975) for literal
  sets past Teddy's 64: trie edges plus failure links, with edges
  sibling-linked rather than a `states × 256` matrix so compile memory is
  bounded by the literal bytes. Compiled slices are immutable and scanning
  allocates nothing. Each state carries its longest-suffix output, so
  `find` keeps leftmost-start semantics, not merely earliest-ending. Caps:
  `max_literals` = 8192, `max_literal_bytes` = 1 MiB.
- **`classrun.zig`** is the dense-class kernel: a class-repetition pattern
  (`\w+`, `[a-z]{3,}`) decided as "≥ min consecutive members of a byte
  set" — range-compare / truffle SIMD membership plus word-trick run
  detection, a streaming whole-buffer `-c` line count (membership and
  newline masks in one pass), a `-o` span walker (`nextSpan` chunks member
  runs by the leftmost-first window rule `analysis.classSpanShape` proves,
  no Pike VM), and a scalar-UTF-8 codepoint resolver so Unicode classes
  (`\w`) settle high bytes in-kernel. It bypasses the DFA's serial table
  walk and its powerset compile; `analysis.classRunShape` decides
  eligibility.

## Where It Sits on the Ladder

A caseful `-F` pattern never builds an automaton; `simd` answers presence.
A regex whose language reduces to a literal alternation is settled by
`literal_set` (memmem → Teddy → Aho–Corasick by set size) with no automaton
at all, and one whose *required* literals form a necessary cover uses the
same engine as a `.candidate` prefilter ahead of the regex machines. Regex
paths compile elsewhere (`../regex/`) and may still call into `verify` for
candidate confirmation after trigram / crest elision.

## Gates

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary live
in the face package's `bench/conformance/gates/parity/scan_regress.sh`.

## When to Edit

SIMD strategy, verify fusion, or hot-loop invariants. Changing *which* files
are candidates is `index/` and cold-engine work, not this package.
