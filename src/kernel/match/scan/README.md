---
doc_radar:
  sentinels:
    - description: "simd presence + verify remain the hot scan primitives"
      file: pkg/kernels/irregex/src/kernel/match/scan/simd.zig
      contains: "contains"
    - description: "corpus byte-density table drives anchor selection + the single-probe dispatch"
      file: pkg/kernels/irregex/src/kernel/match/scan/rarity.zig
      contains: "single_probe_max"
    - description: "verify is the fused parallel confirm kernel"
      file: pkg/kernels/irregex/src/kernel/match/scan/verify.zig
      contains: "pub fn"
    - description: "classrun ships the boolean scan, the fused -c line count, and the -o span walker"
      file: pkg/kernels/irregex/src/kernel/match/scan/classrun.zig
      contains:
        - "pub fn scan"
        - "pub fn countLines"
        - "pub fn nextSpan"
    - description: "teddy carries 64 buckets — the widened multi-literal prefilter, not the old 8"
      file: pkg/kernels/irregex/src/kernel/match/scan/teddy.zig
      contains: "pub const max_buckets: usize = 64;"
    - description: "the literal-set dispatcher carries the two-authority contract and tiers on teddy's bucket ceiling"
      file: pkg/kernels/irregex/src/kernel/match/scan/literal_set.zig
      contains:
        - "pub const Authority = enum { exact, candidate };"
        - "teddy_mod.max_buckets"
    - description: "aho is the sparse large-set automaton bounded by literal bytes, not a states x 256 matrix"
      file: pkg/kernels/irregex/src/kernel/match/scan/aho.zig
      contains: "Sparse Aho"
---

# `src/kernel/match/scan/` — byte-level verify primitives

The hot per-file kernels that decide whether a candidate matches. This is
the half of the head-to-head that has to out-throughput ripgrep's multi-core
scan. The fused work-stealing walk that _feeds_ these kernels lives in
`surface/exec/cold/engine/swarm/`; the resident session drives `verify`
directly.

## Files

| File           | Job                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simd.zig`     | SIMD substring presence (`contains ≡ std.mem.indexOf`) — memchr-style rare-pair anchor gate for fixed strings, 64-byte blocks gated on a cheap any-lane OR-reduce (movemask only in hit blocks)                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `rarity.zig`   | Corpus-derived byte-density table feeding `simd`'s anchor selection + single-probe dispatch (the memchr crate's "rare byte" heuristic, measured over the Billy tree)                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `verify.zig`   | Pure data-parallel candidate-verify kernel + SIMD scan wrappers callers drive                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `teddy.zig`    | Teddy nibble-shuffle multi-literal prefilter (Hyperscan's slim-Teddy, 8 buckets per group): resolves up to `max_buckets` = **64** needles in a constant 2 loads per block via nibble→bucket `tbl`/`pshufb` tables, where the fused first+last gate would pay `1 + N`. Byte-exact leftmost vs `std.mem.indexOf`, proven by the differential fuzz in `simd_test.zig`                                                                                                                                                                                                                                                                    |
| `literal_set.zig` | The **literal-set dispatcher** — one engine over the whole size range. One needle takes the rare-byte `memmem` kernel, sets through 64 take grouped Teddy, larger sets take sparse Aho–Corasick. Every result carries an `Authority`: an `.exact` pure-literal set (the pattern _is_ this alternation) decides presence/position outright, while a `.candidate` cover only nominates a regex-engine candidate. This is the machine the ladder fronts every boolean entry point with (`../regex/linear/ladder/verdict.zig`)                                                                                                          |
| `aho.zig`      | Sparse Aho–Corasick (Aho & Corasick 1975) for large literal sets past Teddy's 64: trie edges + failure links, edges sibling-linked rather than a `states × 256` matrix so compile memory is bounded by the literal bytes. Compiled slices are immutable; scanning allocates nothing. Each state carries its longest-suffix output, so `find` keeps **leftmost-start** semantics, not merely earliest-ending. Caps: `max_literals` = 8192, `max_literal_bytes` = 1 MiB                                                                                                                                                                |
| `classrun.zig` | Dense-class kernel: a class-repetition pattern (`\w+`, `[a-z]{3,}`) decided as "≥ min consecutive members of a byte set" — range-compare / truffle SIMD membership + word-trick run detection, a streaming whole-buffer `-c` line count (membership + newline masks in one pass), a `-o` span walker (`nextSpan` chunks member runs by the leftmost-first window rule `analysis.classSpanShape` proves — no Pike VM), and a scalar-UTF-8 codepoint resolver so Unicode classes (`\w`) settle high bytes in-kernel. Bypasses the DFA's serial table walk _and_ its powerset compile; `analysis.classRunShape` decides eligibility |

## Where it sits on the ladder

A caseful `-F` pattern never builds an automaton — `simd` answers presence.
A regex whose language reduces to a literal alternation is settled by
`literal_set` (memmem → Teddy → Aho–Corasick by set size) with no automaton at
all, and one whose _required_ literals form a necessary cover uses the same
engine as a `.candidate` prefilter ahead of the regex machines. Regex paths
compile elsewhere (`../regex/`) and may still call into `verify` for candidate
confirmation after trigram / crest elision.

## Gates

Soundness (0 FN / 0 FP vs `rg (?-u)`) and the straggler-balance canary:
`bench/gates/scan_regress.sh`.

## When to edit

SIMD strategy, verify fusion, or hot-loop invariants. Changing _which_ files
are candidates is `index/` + cold engine work, not this package.
