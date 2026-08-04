# linear/symbolic — determinizing over predicates, not bytes

**The byte determinizer pays for Unicode twice.** A class like `\w` lowers to
roughly 900 NFA states of UTF-8 byte trie, and subset construction re-walks
that trie on _every_ closure. `\w+X` costs on the order of 8.4 million
NFA-state visits to discover a 332-state automaton this way — a cost
`symbolic_test.zig` pins at a 10,000x collapse against the codepoint path on
that same pattern. That tax is why `../dfa/powerset.zig`'s cost budget declines
essentially every Unicode class pattern to the on-demand tier.

The tax is not inherent. It comes from choosing bytes as the alphabet before
determinizing. Choose *predicates* instead — the classes the pattern actually
names — and the automaton is discovered at ASCII price. Lineage: symbolic
automata (Veanes et al., _Symbolic Automata Constraint Solving_, 2010) and the
Brzozowski-derivative alphabet of RE# (2024); the product-with-a-decoder step is
this engine's own, and is what keeps the scan loop byte-shaped.

## The Four Steps

1. **`alphabet.zig` — the predicate alphabet.** Each distinct class in the
   pattern is interned once as a set of scalar ranges. One boundary sweep over
   every predicate's ranges yields the **minterms** — the coarsest partition of
   the codepoint space no predicate splits, in `O(B log B)` interval endpoints
   rather than pairwise intersection's exponential blowup. `\w+X` has three
   (`X`, `\w` minus `X`, everything else).
2. **`program.zig` — Thompson construction over codepoints.** The same lowering
   `../../compile/` performs, except a class is one predicate id rather than a
   byte sub-automaton. Word boundaries, buffer anchors, and a raw byte class
   ≥ `0x80` are refused here, so the two axes the byte determinizer resolves and
   this one doesn't can never arrive downstream.
3. **`determinize.zig` — subset construction over minterms.** Structurally
   `../dfa/subset.zig` with the alphabet swapped: seed, epsilon-close, step,
   intern, fixpoint. It bills the _same_ visit meter, so the two prices are
   directly comparable, and `\w` is now one bitmask test instead of a trie walk.
4. **`decoder.zig` + `transcribe.zig` — back to bytes.** A UTF-8 → minterm
   decoder is built once over the whole alphabet, then crossed with the pattern
   automaton; the reachable pairs _are_ the byte DFA. Same `Dfa`, same
   premultiplied tables, same `match` — the scan loop never learns this happened.

`../automata/reduce.zig` then quotients out the decoder phase the pattern
cannot observe (Moore refinement) and merges the byte classes the quotient no
longer separates, in both dimensions. `transcribe.zig` calls it directly rather
than through a local minimizer, so the symbolic and byte roads share one
reduction pass instead of transcribing the layout twice. Without it the product
ships a table twice the byte path's size; with it, the product lands on no more
states or classes than the byte construction's own reduced table.

Each file earns its place in the pipeline:

- **`alphabet.zig`** interns scalar-range predicates and computes the minterm
  partition they induce; membership is a bitmask per predicate.
- **`program.zig`** builds the Thompson NFA over codepoints — consume-with-
  predicate, split, `^`/`$`, match — and refuses everything this alphabet
  can't say.
- **`determinize.zig`** runs subset construction over minterms to fixpoint:
  interior and last-byte tables, the unanchored re-seed, the dead sink, the
  visit meter.
- **`decoder.zig`** is the UTF-8 → minterm decoder: a hash-consed byte trie
  over the alphabet, the rejected-minterm prune, and the byte-class partition
  its edges induce.
- **`transcribe.zig`** computes the product of decoder × pattern automaton,
  resyncs on malformed input, calls the shared reduction pass, and freezes the
  result into a `Dfa`.
- **`symbolic.zig`** is the facade `../program/lower.zig` calls: eligibility,
  orchestration, and every failure turned into a decline the byte path answers.
- **`symbolic_test.zig`** runs line and document differentials against both the
  Pike VM and the byte powerset over malformed UTF-8, plus the measured visit
  collapse.

## Declining Is the Normal Case, Not the Failure Case

This path is **offered** a pattern; it never owns one. `symbolic.eligible`
requires a real codepoint class (an ASCII-only program is already optimal on
the byte path), and the builder declines on a word boundary, a buffer anchor, a
raw high-byte class, too many predicates, or any ceiling. Every decline falls
through to [`../dfa/powerset.zig`](../dfa/powerset.zig) exactly as before, and
`Options.symbolic = .off` pins that path explicitly — which is how the
differential holds this construction against the one it replaces, forever.

## What Is Deliberately Not Here

Full RE# (Boolean-closed derivatives with `&` and `~`), leftmost-longest
semantics, and lookaround. The alphabet is the part of that research program
that pays for itself inside this engine's existing shape; the rest would change
what a pattern _means_, which is a different decision than what it costs.
