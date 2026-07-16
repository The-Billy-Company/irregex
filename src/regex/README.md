# gist — T2 regex

The regex execution tier: a linear-time **Thompson NFA** over bytes (RE2 /
ripgrep philosophy — no backtracking, no catastrophic blowup) with a byte-class
DFA as the primary O(1)/byte engine and a Pike VM fallback. Re-exported through
`src/root.zig` (`regex` / `regex_syntax` / `regex_analysis` / `regex_compile` /
`regex_prefilter` / `regex_dfa`).

| File                | Role                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core.zig`          | Public `Regex` handle: `compile` orchestration, the Pike VM (`Sim` scratch, epsilon-closure, the comptime-specialized `search`), and `lineMatch`/`docMatch` dispatch (DFA primary, Pike fallback).                                                                                                                                                                                                                                    |
| `syntax.zig`        | Regex _syntax_: byte classes (`ByteSet`), the Unicode scalar-range class (`uclass` / `ScalarSet`), the AST (`Node`), the recursive-descent parser (codepoint-decoding in Unicode mode), Unicode-aware `foldCaseAst`, and the compiled NFA instruction (`State`).                                                                                                                                                                      |
| `unicode/`          | The Unicode data + UTF-8 leaf (own README): `utf8seq.zig` lowers a scalar range to non-overlapping UTF-8 byte-range steps, `decode.zig` decodes codepoints fwd/last for `\b`, `tables.zig` is the data API (`\w \d \s`, `\p{…}`, fold orbits, `isWord`/`isUpper`) over the generated `tables.gen.zig` (pinned UCD, drift-gated).                                                                                                      |
| `analysis.zig`      | Sound, read-only analyses feeding the accelerators — AST visitors (required-literal / alternation-cover extraction, anchored-start) and compiled-NFA visitors (`analyzeFirst` first-byte set, `reachesMatchEol`).                                                                                                                                                                                                                     |
| `compile.zig`       | Thompson construction: lowers the AST into the flat NFA `State` program both the Pike VM and the DFA execute (the structural counterpart to `powerset.zig`).                                                                                                                                                                                                                                                                          |
| `prefilter.zig`     | First-byte scan acceleration: the `Prefilter` (first-byte set + precomputed singleton-memchr / SIMD-range / scalar-probe skip strategy) the Pike `.skip` path uses to jump over dead spans.                                                                                                                                                                                                                                           |
| `dfa.zig`           | Byte-class DFA — the primary match engine. The immutable, scratch-free automaton (`match` / `docMatch`) that scans a whole document in one fused pass; consumes the finished tables.                                                                                                                                                                                                                                                  |
| `powerset.zig`      | Powerset (subset) construction — determinizes the Thompson program (byte classes + `^`/`$` anchors, capped at `max_states`) into the immutable `dfa.zig` `Dfa`, or null on blow-up (Pike fallback).                                                                                                                                                                                                                                   |
| `core_test.zig`     | Engine tests: parser/AST, Pike VM, prefilters, scan accelerators.                                                                                                                                                                                                                                                                                                                                                                     |
| `dfa_test.zig`      | DFA unit cases + differential fuzz against the Pike VM (line- and doc-level).                                                                                                                                                                                                                                                                                                                                                         |
| `powerset_test.zig` | Determinizer correctness (non-Pike): **(A)** structural invariants — byte-class soundness + minimality, transition totality over the reachable machine, no-orphan/dead-state absorption, build determinism, exact class counts, cap-bail; **(B)** EXHAUSTIVE language equivalence vs a from-scratch NFA spec (every string ≤7, spec validated ≡ Pike) that catches a wrong transition function — plus a randomized fuzz running both. |

The opt-in PCRE2 backend for the constructs this linear tier deliberately can't
express (lookaround, backreferences) lives in [`pcre2/`](pcre2/), behind the
`pcre2.zig` module entry and the frozen `matcher.zig` seam; `--engine auto`
escalates to it only when the linear engine declines a pattern.

**Unicode is default-on (rg-parity).** In Unicode mode the parser decodes
codepoints, non-ASCII literals / `[...]` / `\p{…}` / `\w \d \s` / `.` become a
`uclass` (scalar ranges), and `foldCaseAst` expands each to its full simple-fold
orbit. `compile.zig` lowers a `uclass` through `unicode/utf8seq.zig` into a
hash-consed minimal UTF-8 byte trie woven into the same byte NFA — so the DFA
still determinizes it at the O(1)/byte floor (`powerset_test.zig` extends its
exhaustive equivalence to UTF-8 alphabets). Unicode `\b`/`-w` decode the
straddling codepoint via `unicode/tables.zig::isWord` and stay on the Pike VM,
prefiltered. `(?-u)` / `--no-unicode` revert every surface to ASCII bytes. The
independent differential oracles (`adversarial_test.zig`) cross-check gist's
Unicode engine against `rg` at its default semantics.

Split across files purely to stay under the shape cap; the imports between them
are folder-relative (`@import("syntax.zig")` etc.).
