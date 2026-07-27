---
doc_radar:
  sentinels:
    - description: "capture extraction is a separate Pike VM — the primary engine stays capture-free"
      file: pkg/kernels/irregex/src/kernel/match/regex/compile/captures.zig
      contains: ["pub const Caps", "onepass: OnePass", "linear: Captures"]
    - description: "the one-pass arm fails closed into a declinature, never a fault (ADR-373 law 1)"
      file: pkg/kernels/irregex/src/kernel/match/regex/compile/onepass.zig
      contains: ["fault.Answer(OnePass)", "declined = .not_worthwhile", "pub fn attach"]
---

# kernel/match/regex/compile — AST → NFA lowering + captures

The **middle of the pipeline**: lower the parsed AST into the flat instruction
program the executors run, and — separately — extract capture-group boundaries
when a caller asks for them.

| File           | Role                                                                                                                                                                                                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compile.zig`  | Thompson construction: lowers the `syntax.zig` AST into the flat `State` program that both the Pike VM (`../linear/pike/`) and the eager DFA (`../linear/dfa/powerset.zig`) execute. The structural counterpart to powerset determinization, kept out of the engine so the match loop stays purely execution. |
| `captures.zig` | A dedicated Pike VM that reports group boundaries (`Caps`). The primary engine is deliberately capture-free — a byte-class DFA can't track groups — so submatch extraction is its own opt-in pass, unifying the linear, one-pass and PCRE2 (`../pcre2/captures.zig`) capture shapes.                          |
| `onepass.zig`  | The determinized capture arm. Most patterns never have two live alternatives, so their ε-closures determinize and the caller's own slot vector is the working set — no thread list, no per-`save` copy, no scratch. Built from a `Captures` and falling back to it, so the two arms cannot disagree.          |

Depends on `../syntax/syntax.zig` (AST + `State`) and `../unicode/utf8seq.zig`
(scalar-range lowering); `captures.zig` also bridges `../pcre2/captures.zig`,
and `onepass.zig` borrows `../analysis/prefilter.zig` for candidate starts.

## The one-pass arm is a speed decision, never a semantic one

`onepass.zig` may only be chosen for patterns it can prove unambiguous, and its
slot vector must equal the Pike VM's byte for byte — `onepass_test.zig` is that
proof, comparing the two arms over a randomized pattern/input corpus. Every
uncertainty in the checker (a converging ε-path, a conflicting transition, an
assertion-guarded accept with live successors, a table past its cap) resolves to
a **declinature** — `attach` answers `fault.Answer(OnePass){ .declined }`, not an
error, because a pattern needing a search is routine and the Pike VM is the
correct answer one tier down (ADR-373 law 1). Unanchored search is a
budgeted restart loop: a pattern whose candidate starts are not selective hands
the query back rather than going quadratic where the Pike VM is linear.

One family is refused for a lowering reason rather than a semantic one. Classes
that are disjoint as CODEPOINT sets (`\w` and `\s`) share UTF-8 lead bytes once
`compile.zig` weaves them into byte tries, so at that byte the automaton really
does have two live alternatives — `(\w+)\s*=\s*(\w+)` is one-pass under
`--no-unicode` and refused in the default Unicode mode. A predicate/minterm
alphabet at the lowering is what would hand that family back; a looser checker
here would just be wrong.

## When to edit

Thompson lowering bugs, capture-group shape changes, or Unicode scalar→byte
expansion that must stay shared with the DFA. Match-loop hot paths stay in
`../linear/`; grammar changes stay in `../syntax/`.
