---
doc_radar:
  sentinels:
    - description: "the eager-DFA state cap past which the build declines and the Pike VM serves"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/dfa/powerset.zig
      contains: "pub const max_states: u32 = 4096;"
    - description: "the immutable automaton keeps its interior / last-byte tables and the word-context walk"
      file: pkg/kernels/irregex/src/kernel/match/regex/linear/dfa/dfa.zig
      contains: ["trans_fin", "pub fn matchWord", "pub fn docMatch"]
---

# linear/dfa — the determinized primary engine

**One table lookup per byte, regardless of match density.** The Pike VM in
`../pike/` costs O(active threads)/byte, which loses on a selective-but-common
first byte (`;$`, `[0-9]{4}`) because it re-seeds a closure almost everywhere. A
DFA spends the same `state = trans[state * ncls + class[byte]]` per byte either
way, and scans a whole document in one fused pass. Lineage: Thompson/Cox
([_Regular Expression Matching Can Be Simple And Fast_](https://swtch.com/~rsc/regexp/regexp1.html), 2007) → RE2 / rust-`regex` byte classes and hybrid DFA.

Determinization happens **eagerly at compile time** — these patterns are tiny —
and the result is immutable and scratch-free, so one `Dfa` is shared freely
across threads. Where the powerset would blow up it declines instead of
degrading: past `max_states` the build returns null and `../program/lower.zig` leaves the
Pike VM as the engine, which is also the fuzz oracle both are checked against.

| File                | Role                                                                                                                                                                        |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `dfa.zig`           | The immutable automaton: byte-class table, interior vs last-byte transitions (`trans_fin` resolves `$`), start acceleration, whole-document `docMatch`, word-context walk.  |
| `powerset.zig`      | Subset construction: collapses the byte alphabet into equivalence classes, resolves `^`/`$` into the start / final tables, refines classes by word-ness for `\b`, or bails. |
| `dfa_test.zig`      | DFA unit cases + differential fuzz against the Pike VM.                                                                                                                     |
| `powerset_test.zig` | Determinizer structural invariants + exhaustive language equivalence vs a from-scratch NFA spec.                                                                            |

`dfa.zig` is the one submodule besides the `Regex` handle that `src/root.zig`
re-exports (`regex_dfa`), for C-ABI and library consumers.

## Word boundaries at the DFA floor

`\b` / `\B` / `\<` / `\>` are not deferred to the VM: `powerset.build` refines
byte classes by ASCII word-ness and doubles the interior table so a transition
is selected by the _next_ byte's word-ness, which lets `matchWord` decide them
at O(1)/byte. Under Unicode a gap abutting a non-ASCII scalar is undecidable by
an ASCII-classed DFA, so `matchWord` **quits** (returns null) and the Pike VM
resolves that line — a bounded literal still rides the trigram prefilter.
