---
doc_radar:
  sentinels:
    - description: "the syntax plane owns the class/AST/instruction vocabulary the whole engine shares"
      file: pkg/kernels/irregex/src/gist/kernel/regex/syntax/syntax.zig
      contains: ["pub const ByteSet", "pub const Node", "pub const State", "pub const ScalarSet"]
    - description: "case folding is Unicode-aware and lives with the AST it rewrites"
      file: pkg/kernels/irregex/src/gist/kernel/regex/syntax/syntax.zig
      contains: ["pub fn foldCaseAst"]
---

# gist/kernel/regex/syntax — grammar, classes, and the AST

The **front of the regex pipeline**: the shared vocabulary every downstream
stage is written against. It turns pattern bytes into an AST, defines the
byte-class and Unicode-scalar-class types the matcher and DFA consume, and
carries the compiled NFA instruction those classes lower into. Nothing here
executes a match — it only names what a match is over.

| File | Role |
| --- | --- |
| `syntax.zig` | The syntax plane: `ByteSet` / `ScalarSet` classes, the `Node` AST, the recursive-descent parser (codepoint-decoding in Unicode mode), Unicode-aware `foldCaseAst`, and the compiled NFA `State` instruction. Kept whole because the class, AST, and instruction invariants are co-maintained by parser and compiler (`MONOLITHIC`). |
| `word.zig` | The one `\w` word-character test every engine arm reduces `\b` / `\B` / `\<` / `\>` / `-w` to — a single boolean over the codepoint straddling a gap, shared so the ASCII and Unicode arms cannot disagree. |
| `syntax_test.zig` | Parser / AST / class construction cases. |

`analysis/`, `compile/`, and `linear/` all import these types folder-relative
(`@import("../syntax/syntax.zig")`); the split from execution is deliberate so a
grammar change touches one file, not the match loop.
