---
doc_radar:
  counts:
    - description: "the syntax plane: the facade, five implementation files behind it, the shared \\w test, and one test file"
      glob: pkg/kernels/irregex/src/kernel/regex/syntax/*.zig
      unit: files
      equals: 9
  sentinels:
    - description: "syntax.zig is a front door only — the vocabulary and the parser are defined behind it"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/syntax.zig
      contains: ["pub const Parser", "pub const Node", "pub const foldCaseAst"]
      absent: ["pub const Node = union", "pub const Parser = struct"]
    - description: "the vocabulary every downstream stage is written against lives in one file"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/tree.zig
      contains: ["pub const ByteSet", "pub const Node", "pub const State", "pub const ParseError"]
    - description: "a word assertion is a 4-bit truth table, and the algebra over it is dependency-free"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/assertion.zig
      contains: ["pub const Word", "pub const Sides", "pub const mask"]
    - description: "scalar-range accumulation is parse-time scratch, and case folding rewrites the finished tree"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/scalars.zig
      contains: ["pub const ScalarSet", "pub fn foldCaseAst"]
    - description: "the recursive descent keeps its four mutually-recursive levels together"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/parser.zig
      contains: ["pub const Parser = struct", "pub fn parseAlt", "caseless: bool"]
    - description: "a negated class folds before it complements, and each mode complements in its own universe"
      file: pkg/kernels/irregex/src/kernel/regex/syntax/bracket.zig
      contains: ["fn addComplement", "fn readByteAtom", "const PosixClass"]
---

# kernel/regex/syntax — grammar, classes, and the AST

The **front of the regex pipeline**: the shared vocabulary every downstream
stage is written against. It turns pattern bytes into an AST, defines the
byte-class and Unicode-scalar-class types the matcher and DFA consume, and
carries the compiled NFA instruction those classes lower into. Nothing here
executes a match — it only names what a match is over.

`syntax.zig` is a **facade**: one `pub const` per exported name, so every
consumer keeps writing `@import("../syntax/syntax.zig")` and reading `syn.Node`
while the implementation lives in the five files behind it. The split runs along
the grammar's own layering — vocabulary, then terminal decoders, then class
bodies, then the recursive descent — so each file depends only on the ones
above it and nothing has to know the whole plane.

| File             | Role                                                                                                                                                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `syntax.zig`     | The plane's front door: re-exports only, plus the supported-grammar and rg-parity-rejection contract every other file is written to satisfy.                                                                                      |
| `tree.zig`       | What a parsed pattern *is*: `ByteSet`, the `Node` AST, the compiled NFA `State`, `NamedCap`, and the one `ParseError` set the whole pipeline returns. One file because a `class` node and a `consume` instruction share the class. |
| `assertion.zig`  | The word-assertion family as the truth table it is — `Word` (the six spellings), `mask` (the algebra an engine reaches by intersecting them), `Sides` (what a gap looks like). Zero imports, so every engine arm can share it.     |
| `scalars.zig`    | `ScalarSet` — parse-time scratch for Unicode ranges that no `Node` ever holds — and `foldCaseAst`, the `-i` fold applied to a finished tree with the same range algebra.                                                           |
| `escape.zig`     | What a backslash denotes, and the POSIX class tables it is defined against (`\d` and `[[:digit:]]` are one byte set spelled twice). Terminal decodes only — nothing here re-enters the grammar.                                    |
| `bracket.zig`    | What a `[...]` body denotes, in both modes: `parseClass` (bytes, `(?-u)`) and `parseClassU` (codepoints), plus the shorthand unioners a class body composes.                                                                      |
| `parser.zig`     | The cursor over the pattern and the four mutually-recursive grammar levels (`alt → concat → repeat → atom`) — only the levels that call each other, so the file is the shape of the grammar rather than the shape of the syntax.   |
| `word.zig`       | The one `\w` word-character test every engine arm reduces `\b` / `\B` / `\<` / `\>` / `-w` to — a single boolean over the codepoint straddling a gap, shared so the ASCII and Unicode arms cannot disagree.                        |
| `syntax_test.zig`| Parser / AST / class construction cases.                                                                                                                                                                                         |

## The negation invariant

Every way of writing "not these characters" — `[^…]`, `\D \W \S`, `\P{…}`,
`[[:^name:]]` — is one rule with two easy mistakes, and rg is the oracle for both.

**Fold before you complement.** Under `-i`, the case fold has to apply to the
members as written, not to the finished complement: `[^k]` negated first still
holds `K`, so folding afterwards hands `k` straight back and the class matches the
character it excludes. `Parser.caseless` exists for exactly this, because the
whole-tree `foldCaseAst` pass runs too late to fix it. Folding first leaves a
fold-closed set, which is why that later pass is still safe — it can only be a
no-op on anything negated here.

**Complement in the mode's own universe.** `(?-u)` is a byte engine, so a
complement there is over 256 bytes; in Unicode mode it is over the whole scalar
space, and `[[:^lower:]]` has to admit `日` and not stop at U+00FF. That is why
`tryPosixClass` reports what the bracket said instead of negating it itself, and
why `ScalarSet.complement` and `addComplement` are the only places the rule is
spelled. A negated class also drops `\n` unless `multiline`, so no thread can
consume a line boundary in the fused per-line scan.

`analysis/`, `compile/`, and `linear/` all import these types folder-relative
(`@import("../syntax/syntax.zig")`); the split from execution is deliberate so a
grammar change touches one file, not the match loop.

## When to edit

Parser / AST / class vocabulary, Unicode fold orbits, or the shared `\w` test.
Pick the file by the question you are answering: a new node or instruction is
`tree.zig`, a new escape is `escape.zig`, a new class syntax is `bracket.zig`, a
new quantifier or group flavor is `parser.zig`, a new word-boundary spelling is
`assertion.zig` plus one line in `parser.zig`. Add the export to `syntax.zig`
only when a consumer outside this folder needs the name. If you are changing how
a compiled program _runs_, you want `../linear/` or `../compile/`, not the
grammar.
