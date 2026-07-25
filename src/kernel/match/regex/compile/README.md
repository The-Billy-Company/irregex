---
doc_radar:
  sentinels:
    - description: "capture extraction is a separate Pike VM — the primary engine stays capture-free"
      file: pkg/kernels/irregex/src/kernel/match/regex/compile/captures.zig
      contains: ["pub const Caps"]
---

# kernel/match/regex/compile — AST → NFA lowering + captures

The **middle of the pipeline**: lower the parsed AST into the flat instruction
program the executors run, and — separately — extract capture-group boundaries
when a caller asks for them.

| File           | Role                                                                                                                                                                                                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compile.zig`  | Thompson construction: lowers the `syntax.zig` AST into the flat `State` program that both the Pike VM (`../linear/pike/`) and the eager DFA (`../linear/dfa/powerset.zig`) execute. The structural counterpart to powerset determinization, kept out of the engine so the match loop stays purely execution. |
| `captures.zig` | A dedicated Pike VM that reports group boundaries (`Caps`). The primary engine is deliberately capture-free — a byte-class DFA can't track groups — so submatch extraction is its own opt-in pass, unifying the linear and PCRE2 (`../pcre2/captures.zig`) capture shapes.                                    |

Depends on `../syntax/syntax.zig` (AST + `State`) and `../unicode/utf8seq.zig`
(scalar-range lowering); `captures.zig` also bridges `../pcre2/captures.zig`.

## When to edit

Thompson lowering bugs, capture-group shape changes, or Unicode scalar→byte
expansion that must stay shared with the DFA. Match-loop hot paths stay in
`../linear/`; grammar changes stay in `../syntax/`.
