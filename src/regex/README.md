# gist — T2 regex

The regex execution tier: a linear-time **Thompson NFA** over bytes (RE2 /
ripgrep philosophy — no backtracking, no catastrophic blowup) with a byte-class
DFA as the primary O(1)/byte engine and a Pike VM fallback. Re-exported through
`src/root.zig` (`regex` / `regex_syntax` / `regex_dfa`).

| File | Role |
|---|---|
| `core.zig` | Public `Regex` handle: Thompson compile, Pike simulation, scan accelerators (anchored fast path, first-byte skip), required-literal carry for the T0 prefilter. |
| `syntax.zig` | Regex *syntax*: byte classes, the AST, the recursive-descent parser, the compiled NFA `State`, and sound required-literal / alternation-cover extraction. |
| `dfa.zig` | Byte-class DFA — the primary match engine. The immutable, scratch-free automaton (`match` / `docMatch`) that scans a whole document in one fused pass; consumes the finished tables. |
| `powerset.zig` | Powerset (subset) construction — determinizes the Thompson program (byte classes + `^`/`$` anchors, capped at `max_states`) into the immutable `dfa.zig` `Dfa`, or null on blow-up (Pike fallback). |
| `core_test.zig` | Engine tests: parser/AST, Pike VM, prefilters, scan accelerators. |
| `dfa_test.zig` | DFA unit cases + differential fuzz against the Pike VM (line- and doc-level). |

Split across files purely to stay under the shape cap; the imports between them
are folder-relative (`@import("syntax.zig")` etc.).
