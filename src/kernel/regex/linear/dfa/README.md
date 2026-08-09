# linear/dfa — the determinized primary engine

**One table lookup per byte, regardless of match density.** The Pike VM in
`../pike/` costs O(active threads)/byte, which loses on a selective-but-common
first byte (`;$`, `[0-9]{4}`) because it re-seeds a closure almost everywhere. A
DFA spends the same lookup per byte either way, and scans a whole document in one
fused pass. Lineage: Thompson/Cox
([_Regular Expression Matching Can Be Simple And Fast_](https://swtch.com/~rsc/regexp/regexp1.html), 2007) → RE2 / rust-`regex` byte classes and hybrid DFA.

**That lookup has two spellings, and the automaton carries both.** The classed
tables are indexed by a byte's equivalence class — `state = trans[state + class[byte]]`,
where the class load sits directly in front of the transition load that consumes
it. `Dfa.Wide` is a byte-indexed **mirror** of the same two tables with that column
folded in, so a raw byte indexes a row (`trans[state + byte]`) and the doc walk
pays two loads per byte where the classed walk pays three. It costs `256/ncls`×
the resident bytes, which is why it is built only when it fits `Wide.budget` and
only for the automata that walk it (unanchored, no start dwell, no word context).
Everything else in the engine keeps reading the classed tables, unchanged.

**Two drivers, one construction.** The subset construction itself lives in
`subset.zig`; `powerset.zig` and `lazy.zig` are policies over it, so they cannot
disagree about what a pattern means. The eager driver runs first and freezes an
immutable, scratch-free `Dfa` that every thread shares. When it declines, the
on-demand driver determinizes the same automaton one visited state at a time,
into a per-thread cache. The Pike VM stands behind both as the fuzz oracle.

**And the freeze is not ours.** It lives in
[`../automata/`](../automata) because `../symbolic/` reaches the same point by a
different road and needs the same layout passes; a copy on each road is how
a layout invariant gets established twice and forgotten once.

Declining is a cost judgment with two bounds of different kinds. `max_states` is
a hard safety ceiling on memory and termination that nothing may lift.
`max_visits` is the calibrated cost policy, metered in NFA-state visits — the
unit that actually costs time, since one closure's price is the size of the
subset it walks. Size alone is the wrong meter: `\w+X` determinizes to just 332
states, yet every closure runs over the ~10³-state UTF-8 trie Unicode `\w` lowers
to, costing ~15 ms to find a small automaton. `force_dfa` waives the policy (so
the differential oracles reach the DFA on every pattern they generate); nothing
waives the ceiling.

- **`dfa.zig`** is the immutable automaton: byte-class table, interior vs last-byte transitions (`trans_fin` resolves `$`), the byte-indexed `Wide` mirror the doc walk steps, the start state's skippable dwell, whole-document `docMatch`, word-context walk.

- **`subset.zig`** is the construction both drivers share: byte-class refinement (by word-ness for `\b`), the assertion-resolving epsilon-closure, the transition step, subset interning, the visit meter, and the start row a dwell is read off.

- **`powerset.zig`** is the *eager* policy. It walks to fixpoint under the bounds, then hands the finished tables to [`../automata/freeze.zig`](../automata), which applies the layout passes only a complete automaton admits. The symbolic road hands over the same thing, so neither transcribes them.

- **`lazy.zig`** is the *on-demand* policy: an immutable `Lazy` (classes, anchoring, its own start dwell) plus a per-thread mutable `Cache` that determinizes a state the first time a haystack walks into it, and quits to the Pike VM rather than thrash. It also carries the **halting** walk — `Cache.onset`, which returns the first position something accepted at instead of a match, because an acceptance is a fact about the automaton and a match is a fact about priority.

- **`onset.zig`** is the policy over that halting walk, and the answer to two questions the leftmost-first ladder cannot ask: *what ends first* (earliest) and *does a match begin exactly here* (anchored). Both need a determinized walk that stops at its first acceptance, and they need **different automata** for it — unanchored, whose re-seed makes the first acceptance the earliest end of any match; anchored, whose single seed makes it proof that a match began where the walk did. `subset.zig` built both from the day it was written; nothing above it could ask for the second. A `Probe` is per-thread scratch that builds each on the first ask that needs it and declines when the compile has no program to determinize.

- **`dfa_test.zig`** carries DFA unit cases and differential fuzz against the Pike VM, plus the two tests that hold the mirror: cell-exactness against the classed tables, and `docMatch` fuzzed with the mirror present and then withheld.

- **`powerset_test.zig`** carries determinizer structural invariants and exhaustive language equivalence against a from-scratch NFA spec.

`dfa.zig` is one of the leaf modules named through `regex.dfa` in
[`../regex.zig`](../../regex.zig), the one door into `kernel/regex/` that
`charter.zone` seals at build time. A cost harness reaches it there —
for a Regex handle's own scan, go through `Regex` instead.

## Word Boundaries at the DFA Floor

`\b` / `\B` / `\<` / `\>` are not deferred to the VM: `powerset.build` refines
byte classes by ASCII word-ness and doubles the interior table so a transition
is selected by the _next_ byte's word-ness, which lets `matchWord` decide them
at O(1)/byte. Under Unicode a gap abutting a non-ASCII scalar is undecidable by
an ASCII-classed DFA, so `matchWord` **quits** (returns null) and the Pike VM
resolves that line — a bounded literal still rides the trigram prefilter.
