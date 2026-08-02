# linear/symbolic — determinizing over predicates, not bytes

**The byte determinizer pays for Unicode twice.** `\w` lowers to a ~10³-state
UTF-8 byte trie, and subset construction re-walks that trie on _every_ closure —
so `\w+X`, an automaton of 318 states, costs **8,386,778 NFA-state visits** to
discover, against **90** for its `(?-u)` ASCII twin. That tax is why
`../dfa/powerset.zig`'s cost budget declines essentially every Unicode class
pattern to the on-demand tier.

The tax is not inherent. It comes from choosing bytes as the alphabet before
determinizing. Choose **predicates** instead — the classes the pattern actually
names — and the automaton is discovered at ASCII price. Lineage: symbolic
automata (Veanes et al., _Symbolic Automata Constraint Solving_, 2010) and the
Brzozowski-derivative alphabet of RE# (2024); the product-with-a-decoder step is
this engine's own, and is what keeps the scan loop byte-shaped.

## The four steps

1. **`alphabet.zig` — the predicate alphabet.** Each distinct class in the
   pattern is interned once as a set of scalar ranges. A sweep line over all of
   them yields the **minterms**: the coarsest partition of the codepoint space
   no predicate splits. `\w+X` has three (`X`, `\w` minus `X`, everything else).
2. **`program.zig` — Thompson construction over codepoints.** The same lowering
   `../../compile/` performs, except a class is one predicate id rather than a
   byte sub-automaton. Word boundaries and buffer anchors are refused here, so
   the two axes the byte determinizer resolves and this one doesn't can never
   arrive downstream.
3. **`determinize.zig` — subset construction over minterms.** Structurally
   `../dfa/subset.zig` with the alphabet swapped: seed, epsilon-close, step,
   intern, fixpoint. It bills the _same_ visit meter, so the two prices are
   directly comparable — and `\w` is now one bitmask test instead of a trie walk.
4. **`decoder.zig` + `transcribe.zig` — back to bytes.** A UTF-8 → minterm
   decoder is built once over the whole alphabet, then crossed with the pattern
   automaton; the reachable pairs _are_ the byte DFA. Same `Dfa`, same
   premultiplied tables, same `match` — the scan loop never learns this happened.

`minimize.zig` then quotients out the decoder phase the pattern cannot observe
(Moore refinement), and a column merge drops the byte classes the quotient no
longer separates. Without those two the product ships a table twice the byte
path's; with them it lands on the byte construction's _minimal_ automaton.

| File                | Role                                                                                                                                               |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `alphabet.zig`      | Interned scalar-range predicates and the minterm partition they induce; membership is a bitmask per predicate.                                     |
| `program.zig`       | Thompson NFA over codepoints — consume-with-predicate, split, `^`/`$`, match — and the eligibility refusal for everything this alphabet can't say. |
| `determinize.zig`   | Subset construction over minterms to fixpoint: interior and last-byte tables, the unanchored re-seed, the dead sink, the visit meter.              |
| `decoder.zig`       | The UTF-8 → minterm decoder: hash-consed byte trie over the alphabet, the rejected-minterm prune, and the byte-class partition its edges induce.   |
| `transcribe.zig`    | The product of decoder × pattern automaton, resync on malformed input, class merge, and the frozen `Dfa`.                                          |
| `minimize.zig`      | Moore partition refinement over both transition tables — the pass that makes the product's size claim true.                                        |
| `symbolic.zig`      | The facade `../program/lower.zig` calls: eligibility, orchestration, and every failure turned into a decline the byte path answers.                |
| `symbolic_test.zig` | Line and document differentials against BOTH the Pike VM and the byte powerset over malformed UTF-8, plus the measured visit collapse.             |

## Declining is the normal case, not the failure case

This path is **offered** a pattern; it never owns one. `symbolic.eligible`
requires a real codepoint class (an ASCII-only program is already optimal on the
byte path), and the builder declines on a word boundary, a buffer anchor, a raw
high-byte class, too many predicates, or any ceiling. Every decline falls
through to `../dfa/powerset.zig` exactly as before, and `Options.symbolic = .off`
pins that path explicitly — which is how the differential holds this
construction against the one it replaces, forever.

## What is deliberately not here

Full RE# (Boolean-closed derivatives with `&` and `~`), leftmost-longest
semantics, and lookaround. The alphabet is the part of that research program
that pays for itself inside this engine's existing shape; the rest would change
what a pattern _means_, which is a different decision than what it costs.
