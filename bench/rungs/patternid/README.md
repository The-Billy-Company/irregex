---
doc_radar:
  sentinels:
    - description: "the sections this README describes are the sections the rung runs"
      file: pkg/kernels/irregex/bench/rungs/patternid/bench.zig
      contains: ["fn overlapSection", "fn speedSection", "fn buildSection", "fn settleSection"]
    - description: "settling authority is derived with the cover, not apart from it"
      file: pkg/kernels/irregex/src/kernel/slate/muster.zig
      contains: ["fn coverOf", "const Cover = struct"]
---

# `patternid-rung` — does attribution-in-the-key cost states?

One number, and it gates a design.

## The question

`slate/patterns.zig` answers "which of my N patterns hit this document?" with a
fused any-of gate followed by up to N per-pattern confirmations. The proposal in
`spikes/patternid-automaton/SPIKE.md` is to let the single fused pass
carry the answer, by widening the trailing word of the determinizer's state key
from a match flag to a 64-pattern bitmask.

That widening is free in bytes. `subset.zig` already interns each DFA state on a
`[]u64` of length `words + 1` whose last word holds `@intFromBool(matched)` — a
full 64-bit slot storing a value in `{0, 1}`. Same key length, same allocation,
same hash, same compare.

What it might not be free in is **states**. Two subsets that agree on their NFA
consume-set but disagree on which pattern terminals they passed through are one
state today and two states afterward. If that refinement multiplies out,
`powerset.zig`'s `max_states` budget declines the build and the feature degrades
to today's behavior: still correct, no longer faster.

## What it measures

The same union NFA, determinized twice, with exactly one line different:

```zig
d.key[d.nw] = if (d.attribute) mask else @intFromBool(mask != 0);
```

Everything else — closure, worklist, seeding, byte loop — is shared, because two
transcriptions would be measuring their own difference rather than the one under
test. Output is TSV: `slate, N, nfa, bool, mask, ratio`. **`ratio` is the claim.**

## Reading it honestly

This is a measurement rig, not the engine. It steps all 256 bytes rather than
byte classes, and resolves zero-width assertions at a fixed interior gap. Both
arms do so identically, so the ratio is sound even where the absolute counts
differ from what `powerset.zig` would build. Do not quote the `bool` column as
the shipped automaton's size; quote the ratio.

## The union is built at the program layer

Which is also what the real change does. `npat` match terminals are pushed first,
so a terminal's NFA index **is** its pattern ordinal, and the determinizer reads
the ordinal straight off the state id it already holds — no payload on
`syn.State`, no side table.

`slate/patterns.zig` today fuses by concatenating pattern *text* into
`(?:p0)|(?:p1)|…` and re-parsing, which collapses every arm onto one shared
`.match` terminal. That is exactly why it cannot attribute, and why the N
confirms exist.

## Section 2 — overlapping semantics, demonstrated

The same mask, walked over a haystack instead of counted, reports at every
position the set of patterns whose match **ends** there:

```text
case      hay        end  patterns
foo-nest  foofoofoo    3  foo
foo-nest  foofoofoo    6  foo,foofoo
foo-nest  foofoofoo    9  foo,foofoo,foofoofoo
```

Ends 3, 6, 9 — what rust-regex reports only in `MatchKind::All` via
`try_search_overlapping_fwd`, and what both `gist -o` and `rg -o` cannot express
(they report three non-overlapping `foo`s, and reordering the alternation to
`foofoofoo|foofoo|foo` reports one).

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

## Section 5 — what the muster is allowed to settle

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

## Run

```bash
cd pkg/kernels/irregex && zig build patternid-rung
```
