# gist — T2 regex

The regex execution tier: a linear-time **Thompson NFA** over bytes (RE2 /
ripgrep philosophy — no backtracking, no catastrophic blowup) with a byte-class
DFA as the primary O(1)/byte engine and a Pike VM fallback. Re-exported through
`src/root.zig` (`regex` / `regex_syntax` / `regex_dfa`).

| File | Role |
|---|---|
| `core.zig` | Public `Regex` handle: Thompson compile, Pike simulation, scan accelerators (anchored fast path, first-byte skip), required-literal carry for the T0 prefilter. |
| `syntax.zig` | Regex *syntax*: byte classes, the AST, the recursive-descent parser, the compiled NFA `State`, and sound required-literal / alternation-cover extraction. |
| `dfa.zig` | Byte-class DFA — the primary match engine. Determinizes the Thompson program (powerset, capped) into an immutable, scratch-free automaton that scans a whole document in one fused pass. |
| `core_test.zig` | Engine tests: parser/AST, Pike VM, prefilters, scan accelerators. |
| `dfa_test.zig` | DFA unit cases + differential fuzz against the Pike VM (line- and doc-level). |

Split across files purely to stay under the shape cap; the imports between them
are folder-relative (`@import("syntax.zig")` etc.).
