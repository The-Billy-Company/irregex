# `patternid-rung` — Does Attribution-In-The-Key Cost States?

One number, and it gates a design.

## The Question

`slate/patterns.zig` answers "which of my N patterns hit this document?" with a
fused any-of gate followed by up to N per-pattern confirmations. The proposal is
to let the single fused pass carry the answer, by widening the trailing word of
the determinizer's state key from a match flag to a 64-pattern bitmask. The
design scan behind it read rust-regex's determinizer, dense DFA, NFA, search, and
overlapping/half-match paths end to end, settled the shape, and left exactly one
thing unmeasured: whether that widening multiplies states. This rung is that
measurement, and it came back **1.017-1.121** over six slates, worst on `kin-8`,
the slate built deliberately adversarial: eight patterns sharing both prefixes
and suffixes, which is where subsets genuinely collide.

That widening is free in bytes. `subset.zig` already interns each DFA state on a
`[]u64` of length `words + 1` whose last word holds `@intFromBool(matched)` — a
full 64-bit slot storing a value in `{0, 1}`. Same key length, same allocation,
same hash, same compare.

What it might not be free in is **states**. Two subsets that agree on their NFA
consume-set but disagree on which pattern terminals they passed through are one
state today and two states afterward. If that refinement multiplies out,
`powerset.zig`'s `max_states` budget declines the build and the feature degrades
to today's behavior: still correct, no longer faster.

## What It Measures

The same union NFA, determinized twice, with exactly one line different:

```zig
d.key[d.nw] = if (d.attribute) mask else @intFromBool(mask != 0);
```

Everything else — closure, worklist, seeding, byte loop — is shared, because two
transcriptions would be measuring their own difference rather than the one under
test. Output is TSV: `slate, N, nfa, bool, mask, ratio`. **`ratio` is the claim.**

## Reading It Honestly

This is a measurement rig, not the engine. It steps all 256 bytes rather than
byte classes, and resolves zero-width assertions at a fixed interior gap. Both
arms do so identically, so the ratio is sound even where the absolute counts
differ from what `powerset.zig` would build. Do not quote the `bool` column as
the shipped automaton's size; quote the ratio.

## The Union Is Built At The Program Layer

Which is also what the real change does. `npat` match terminals are pushed first,
so a terminal's NFA index **is** its pattern ordinal, and the determinizer reads
the ordinal straight off the state id it already holds — no payload on
`syn.State`, no side table.

`slate/patterns.zig` today fuses by concatenating pattern *text* into
`(?:p0)|(?:p1)|…` and re-parsing, which collapses every arm onto one shared
`.match` terminal. That is exactly why it cannot attribute, and why the N
confirms exist.

## Section 2 — Overlapping Semantics, Demonstrated

The same mask, walked over a haystack instead of counted, reports at every
position the set of patterns whose match **ends** there:

```text
case      hay        end  patterns
foo-nest  foofoofoo    3  foo
foo-nest  foofoofoo    6  foo,foofoo
foo-nest  foofoofoo    9  foo,foofoo,foofoofoo
```

Ends 3, 6, 9 — what rust-regex reports only in `MatchKind::All` via
`try_search_overlapping_fwd`, and what neither this engine's `-o` nor `rg -o`
can express (they report three non-overlapping `foo`s, and reordering the
alternation to `foofoofoo|foofoo|foo` reports one).

Three things are absent that the reference needs:

- **No `OverlappingState`.** rust-regex carries a resumable cursor and re-enters
  the search once per pattern at a position where several match. Here the whole
  set arrives as one `u64` per position, one visit.
- **No `MatchKind::All` mode.** They need it because one dense DFA serves both
  the recognizer and the span engine, so the default leftmost-first pruning would
  hide the extras. In this kernel those are *separate automata*: pruning
  (`dominate`) exists only in `caliper/automaton.zig`, and `dfa/subset.zig` never
  prunes. The recognizer is already All-mode.
- **No reverse pass.** An `(end, mask)` pair is exactly a rust-regex `HalfMatch`,
  and the backward jaw only has to run for callers who want starts.

## Section 3 — Attribution Priced Against The N Confirms It Replaces

The state-count table above is the cost of putting the mask in the key. This
section is what that cost buys: the same attribution question — which of N
patterns match this document — answered by one `Chorus.docMask` walk against
the N separate `Regex.docMatch` confirms it would replace. Both arms run the
production seams over the same synthetic corpus, so `speedup` is what a real
caller sees rather than a microbenchmark of the inner loop.

The corpus is built to sit in the regime where N confirms hurt most: mostly
lines that match nothing, a few lines each carrying one hit, because every
missing line still costs all N confirms today. Each row's `agree` column
recomputes the same document against the N-confirm arm and fails the row if the
one-pass mask ever disagrees with it — a fast wrong answer is not a result
here.

## Section 4 — Determinization Cost

Nothing above prices what it costs to *discover* the automaton in the first
place, because `powerset.build` re-seeds the NFA start inside every unanchored
`step` — so the start's whole epsilon-closure is re-walked once per
`(state, class)` pair, and for a Unicode class that closure is the roughly
1,000-state UTF-8 trie. This section times single-pattern and slate compiles
end to end and guards `subset.Subset.seeds`, which hoists that re-seed as
loop-invariant: worth **1.3–2.3×** on the union builds this rung compiles.

Five patterns carry the section, chosen for the shape of their start closure —
the quantity the re-seed re-walks. A bare `\w+X` and `\w+\d+` each reach a large
Unicode trie immediately from the start; `pgxpool\.\w+` reaches one through a
literal prefix; `^\w+X` is the anchored control, which never re-seeds and so
must never move. Each row also reports which engine — eager, lazy, or Pike —
the visit budget actually handed the pattern to, because a cheaper closure can
spend its savings getting further before declining, which reads as "no
change" on the clock while being a regression in what compiled.

## Section 5 — What The Muster Is Allowed To Settle

A different question from the four above, measured here because it is the other
way a slate can stop paying per pattern. `slate/muster.zig` marks a pattern
**settled** when its literals are a match *equivalence* — containing one of them
IS a match — and a settled pattern's engine confirm never runs. That used to mean
bare `-F` needles only; it now means anything `analysis.pureLiterals` can prove,
which picks up alternations (`TODO|FIXME|XXX`) and regexes that happen to be
plain literals (`err != nil`).

The section prices three document shapes per slate, because settling can only
move one of them:

```text
slate  N  settled  doc   per_doc_us
alt-6  6  6/6      hit         1.67   ← 3.26 before
alt-6  6  6/6      miss       17.68   ← unmoved, as it must be
alt-6  6  6/6      late       18.82   ← 56.09 before
```

1.95x on a hitting document and 3.01x on `late`, where the matches sit behind a
long non-matching prefix. `late` is the shape that isolates the saving: a skipped
confirm is a skipped **second pass** over the document, so an early hit lets the
confirm exit at once and the win rounds to nothing. `miss` is the control — a
document nothing matches is rejected by the same SIMD roll either way, so a
number that moved there would mean the measurement was wrong.

The mixed `re-6` slate is flat, and that is the honest half. Four of its six
bodies are classes and quantifiers whose confirms settling cannot remove, and
they dominate the row at ~340 us against `alt-6`'s ~2. Widening what *can* settle
does nothing for the patterns that still cannot.

Every row re-derives its answer with N independent single-pattern engines and
prints `agree`, because a settling rule that is wrong is also fast.

## Running It

Build and run the rung from the repository root.

```bash
zig build patternid-rung
```
