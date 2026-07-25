---
doc_radar:
  counts:
    - description: "seven regex pipeline stages — syntax, analysis, compile, linear, pcre2, unicode, oracle"
      glob: pkg/kernels/irregex/src/kernel/match/regex/*/
      equals: 7
      unit: dirs
  sentinels:
    - description: "only core + DFA are re-exported at the package root; submodules are imported directly"
      file: pkg/kernels/irregex/src/root.zig
      contains:
        - 'pub const regex = @import("kernel/match/regex/linear/program/core.zig");'
        - 'pub const regex_dfa = @import("kernel/match/regex/linear/dfa/dfa.zig");'
---

# gist — T2 regex

The regex execution tier: a linear-time **Thompson NFA** over bytes (RE2 /
ripgrep philosophy — no backtracking, no catastrophic blowup) with a byte-class
DFA as the primary O(1)/byte engine and a Pike VM fallback. Organized by real
pipeline stage — the AST flows front-to-back, `syntax → analysis → compile →
linear`, with `unicode` data feeding the class lowering, `pcre2` the opt-in
escape hatch, and `oracle` the independent correctness backstop. Only the core
handle (`regex`) and DFA (`regex_dfa`) are re-exported through `src/root.zig`;
every other stage is imported directly by its consumer.

| Stage    | Folder                  | Role                                                                                                                                                                |
| -------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| syntax   | [`syntax/`](syntax)     | Byte/scalar classes, the AST, the recursive-descent parser, Unicode-aware case folding, and the compiled NFA instruction — the vocabulary every stage shares.       |
| analysis | [`analysis/`](analysis) | Sound, conservative accelerator analyses: required-literal / cover extraction for the trigram prefilter, first-byte sets, and the scan-skip `Prefilter`.            |
| compile  | [`compile/`](compile)   | Thompson AST→NFA lowering, and the separate capture-extraction Pike VM (the primary engine stays capture-free).                                                     |
| linear   | [`linear/`](linear)     | The engine, in four folders: the compiled handle (`program/`), engine selection (`ladder/`), the Pike VM (`pike/`), and the byte-class DFA + determinizer (`dfa/`). |
| pcre2    | [`pcre2/`](pcre2)       | The opt-in vendored PCRE2 JIT backend for lookaround / backreferences the linear tier can't express; `--engine auto` escalates to it only on demand.                |
| unicode  | [`unicode/`](unicode)   | The pinned-UCD data + UTF-8 leaf: scalar-range → byte-range decomposition, codepoint decode for `\b`, and the `\w \d \s` / `\p{…}` / fold tables.                   |
| oracle   | [`oracle/`](oracle)     | Adversarial differential tests against an _independent_ oracle (and `rg` at default semantics) — catches bugs the in-family Pike-vs-DFA fuzz would share.           |

**Unicode is default-on (rg-parity).** In Unicode mode the parser decodes
codepoints, non-ASCII literals / `[...]` / `\p{…}` / `\w \d \s` / `.` become a
`uclass` (scalar ranges), and case folding expands each to its full simple-fold
orbit. `compile/` lowers a `uclass` through `unicode/utf8seq.zig` into a
hash-consed minimal UTF-8 byte trie woven into the same byte NFA — so the DFA
still determinizes it at the O(1)/byte floor. Unicode `\b`/`-w` decode the
straddling codepoint via `unicode/tables.zig` and stay on the Pike VM,
prefiltered. `(?-u)` / `--no-unicode` revert every surface to ASCII bytes.
