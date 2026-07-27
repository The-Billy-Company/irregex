---
doc_radar:
  counts:
    - description: "seven regex pipeline stages — syntax, analysis, compile, linear, pcre2, unicode, oracle"
      glob: pkg/kernels/irregex/src/kernel/match/regex/*/
      equals: 7
      unit: dirs
  sentinels:
    - description: "the package root re-exports the engine's stages through its entry file, never around it"
      file: pkg/kernels/irregex/src/root.zig
      contains:
        - 'const regex_engine = @import("kernel/match/regex/regex.zig");'
        - 'pub const regex = regex_engine.program;'
        - 'pub const regex_dfa = regex_engine.dfa;'
    - description: "the engine is a sealed deep module — an outside import that skips the entry file fails lint-zig-arch"
      file: pkg/kernels/irregex/contract/irregex.ward
      contains:
        - 'seal kernel/match/regex through regex.zig'
---

# gist — T2 regex

The regex execution tier: a linear-time **Thompson NFA** over bytes (RE2 /
ripgrep philosophy — no backtracking, no catastrophic blowup) with a byte-class
DFA as the primary O(1)/byte engine and a Pike VM fallback. Organized by real
pipeline stage — the AST flows front-to-back, `syntax → analysis → compile →
linear`, with `unicode` data feeding the class lowering, `pcre2` the opt-in
escape hatch, and `oracle` the independent correctness backstop.

**One door in.** These seven stages are internals: every caller outside this
folder enters through [`regex.zig`](regex.zig), which re-exports the compiled
handle, the engine-neutral `Matcher` seam, captures, and the leaf data
namespaces the surface shares. The seal in
[`contract/irregex.ward`](../../../../contract/irregex.ward) makes
that a build-time law — `make lint-zig-arch` fails any import that reaches past
it. The reason is soundness, not tidiness: the crest sieve once carried a
second, smaller parser, the two grammars disagreed on the zero-width `\<` /
`\>` boundaries, and it silently pruned two thirds of the matching corpus. A
single entry point is how "there is exactly one grammar" becomes a property
instead of a promise — a fork cannot reach the internals it would need.
Competition for this engine is other _engines_ (Rust `regex`, RE2, PCRE2,
Hyperscan), measured in `bench/`; never a second parser inside this tree.

| Stage    | Folder                  | Role                                                                                                                                                                                                                                                                     |
| -------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| syntax   | [`syntax/`](syntax)     | Byte/scalar classes, the AST, the recursive-descent parser, Unicode-aware case folding, and the compiled NFA instruction — the vocabulary every stage shares.                                                                                                            |
| analysis | [`analysis/`](analysis) | Sound, conservative accelerator analyses: required-literal / cover extraction for the trigram prefilter, first-byte sets, and the scan-skip `Prefilter`.                                                                                                                 |
| compile  | [`compile/`](compile)   | Thompson AST→NFA lowering, and capture extraction: a one-pass engine for the patterns whose group assignment is never ambiguous, the Pike VM for the rest.                                                                                                               |
| linear   | [`linear/`](linear)     | The engine: the compiled handle (`program/`), engine selection (`ladder/`), the two machines that answer (`pike/`, `dfa/`), a second route to the same DFA table (`symbolic/`), and the optional rungs that beat it where they apply (`compose/`, `parabix/`, `sieve/`). |
| pcre2    | [`pcre2/`](pcre2)       | The opt-in vendored PCRE2 JIT backend for lookaround / backreferences the linear tier can't express; `--engine auto` escalates to it only on demand.                                                                                                                     |
| unicode  | [`unicode/`](unicode)   | The pinned-UCD data + UTF-8 leaf: scalar-range → byte-range decomposition, codepoint decode for `\b`, and the `\w \d \s` / `\p{…}` / fold tables.                                                                                                                        |
| oracle   | [`oracle/`](oracle)     | Adversarial differential tests against an _independent_ oracle (and `rg` at default semantics) — catches bugs the in-family Pike-vs-DFA fuzz would share.                                                                                                                |

**Unicode is default-on (rg-parity).** In Unicode mode the parser decodes
codepoints, non-ASCII literals / `[...]` / `\p{…}` / `\w \d \s` / `.` become a
`uclass` (scalar ranges), and case folding expands each to its full simple-fold
orbit. `compile/` lowers a `uclass` through `unicode/utf8seq.zig` into a
hash-consed minimal UTF-8 byte trie woven into the same byte NFA — so the DFA
still determinizes it at the O(1)/byte floor. Unicode `\b`/`-w` decode the
straddling codepoint via `unicode/tables.zig` and stay on the Pike VM,
prefiltered. `(?-u)` / `--no-unicode` revert every surface to ASCII bytes.
