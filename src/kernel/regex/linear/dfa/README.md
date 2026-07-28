---
doc_radar:
  sentinels:
    - description: "the eager driver's two bounds — the hard size ceiling and the calibrated cost policy"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/powerset.zig
      contains: ["pub const max_states: u32 = 4096;", "pub const max_visits: u64 = 750_000;"]
    - description: "the shared determinizer core both drivers run, and the on-demand driver's own skip"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/subset.zig
      contains: ["pub fn startAccel", "pub fn forceStartRow", "visits: u64 = 0,"]
    - description: "the immutable automaton keeps its interior / last-byte tables and the word-context walk"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/dfa.zig
      contains: ["trans_fin", "pub fn matchWord", "pub fn docMatch"]
---

# linear/dfa — the determinized primary engine

**One table lookup per byte, regardless of match density.** The Pike VM in
`../pike/` costs O(active threads)/byte, which loses on a selective-but-common
first byte (`;$`, `[0-9]{4}`) because it re-seeds a closure almost everywhere. A
DFA spends the same `state = trans[state * ncls + class[byte]]` per byte either
way, and scans a whole document in one fused pass. Lineage: Thompson/Cox
([_Regular Expression Matching Can Be Simple And Fast_](https://swtch.com/~rsc/regexp/regexp1.html), 2007) → RE2 / rust-`regex` byte classes and hybrid DFA.

**Two drivers, one construction.** The subset construction itself lives in
`subset.zig`; `powerset.zig` and `lazy.zig` are policies over it, so they cannot
disagree about what a pattern means. The eager driver runs first and freezes an
immutable, scratch-free `Dfa` that every thread shares. When it declines, the
on-demand driver determinizes the same automaton one visited state at a time,
into a per-thread cache. The Pike VM stands behind both as the fuzz oracle.

Declining is a cost judgment with two bounds of different kinds. `max_states` is
a hard safety ceiling on memory and termination that nothing may lift.
`max_visits` is the calibrated cost policy, metered in NFA-state visits — the
unit that actually costs time, since one closure's price is the size of the
subset it walks. Size alone is the wrong meter: `\w+X` determinizes to just 332
states, yet every closure runs over the ~10³-state UTF-8 trie Unicode `\w` lowers
to, costing ~15 ms to find a small automaton. `force_dfa` waives the policy (so
the differential oracles reach the DFA on every pattern they generate); nothing
waives the ceiling.

| File                | Role                                                                                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dfa.zig`           | The immutable automaton: byte-class table, interior vs last-byte transitions (`trans_fin` resolves `$`), start acceleration, whole-document `docMatch`, word-context walk.                                                                       |
| `subset.zig`        | The construction both drivers share: byte-class refinement (by word-ness for `\b`), the assertion-resolving epsilon-closure, the transition step, subset interning, the visit meter, and the start-row skip derivation.                          |
| `powerset.zig`      | The **eager** policy: walk to fixpoint under the bounds, then apply what only a finished automaton admits — start acceleration, premultiplied rows, the `$`-resolving final table.                                                               |
| `lazy.zig`          | The **on-demand** policy: an immutable `Lazy` (classes, anchoring, its own start acceleration) plus a per-thread mutable `Cache` that determinizes a state the first time a haystack walks into it, and quits to the Pike VM rather than thrash. |
| `dfa_test.zig`      | DFA unit cases + differential fuzz against the Pike VM.                                                                                                                                                                                          |
| `powerset_test.zig` | Determinizer structural invariants + exhaustive language equivalence vs a from-scratch NFA spec.                                                                                                                                                 |

`dfa.zig` is the one submodule besides the `Regex` handle that `src/root.zig`
re-exports (`regex_dfa`), for C-ABI and library consumers.

## Word boundaries at the DFA floor

`\b` / `\B` / `\<` / `\>` are not deferred to the VM: `powerset.build` refines
byte classes by ASCII word-ness and doubles the interior table so a transition
is selected by the _next_ byte's word-ness, which lets `matchWord` decide them
at O(1)/byte. Under Unicode a gap abutting a non-ASCII scalar is undecidable by
an ASCII-classed DFA, so `matchWord` **quits** (returns null) and the Pike VM
resolves that line — a bounded literal still rides the trigram prefilter.
