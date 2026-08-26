# bench/rungs/lowering

**The compile side, priced per stage.** Every other rung in this folder measures
bytes per second. This one measures the microseconds that go by before the first
haystack byte is read, and it exists because that half of the engine had no
instrument at all.

That absence had a shape. The engine could say true, precise, unactionable
things — "`\w+X` costs 8.4 million NFA-state visits" — while the question anyone
compiling a pattern actually has is *which stage do I fix*. Four stages sat
inside one `compileOpts` call, so the honest answer was a guess, and a guess is
how `(\w)(\w)(\w)(\w)` at 963 µs was attributed to a per-occurrence UTF-8 trie
weave. The guess happened to be right. This rung is what makes the next one
unnecessary.

## The Four Sections

- **`agree`** runs first, always, and is the reason the rest is trustworthy.
  Compile time is the one number you can always improve by building something
  else, so before a single stage is timed every slate pattern is compiled down
  both determinizations and held against the Pike VM over haystacks laced with
  malformed UTF-8 — lone continuation bytes, truncated sequences, surrogate
  encodings — because the decoder's resync path is where a product construction
  goes wrong. A divergence exits non-zero instead of publishing a µs.
- **`stage`** splits one compile into `parse`, `thomp` (Thompson NFA), `mint`
  (minterm lowering), `cpdet` (codepoint subset construction), `cross` (the
  decoder product), and `resid`. Each stage is re-run over the artifact the
  shipped compile produced, min-of-25, so it is the shipped construction and not
  a transcription of it. Read `resid` as a **bound on what is still
  unattributed** — analyses, the byte powerset when the symbolic road declined,
  the handle's owned copies — never as a stage.
- **`occurrence`** repeats one codepoint class *k* times. If the trie is woven
  per occurrence then `thomp` is linear in *k*, and the printed slope is the
  µs/occurrence a shared trie has to remove. The paired thing to watch is `nfa`:
  sharing the *weave* must not change the states, so a fix flattens `thomp` and
  leaves `nfa` alone. A fix that moved both built a different automaton.
- **`range`** is the same law on a controlled axis. `\d` vs `\w` vs `\p{L}`
  differ in range count *and* in shape, so a slope read off them conflates two
  variables; these classes are synthesized to hold an exact number of disjoint
  non-ASCII ranges and differ in nothing else.
- **`gate`** prints the pair space the symbolic road is admitted on: `bound`, the
  free `nodes × states` upper bound; `pairs`, the horizon's exact count; `prod`,
  what the walk actually interned; and `slack`, how much the bound overstates. A
  row where `bound` clears the ceiling and `pairs` does not is a pattern being
  declined to the on-demand tier **by arithmetic** — it would hold an eager
  table if the gate read the exact figure. The count of such rows is the last
  line of the section, and driving it to zero is the point.

## Why It Is A Rung And Not A Test

The contract in [`../README.md`](../README.md) is agreement plus a measured
price, and both halves apply here unchanged. The agreement half is `agree`. The
price half is the reason the sections are separate: a compile-time win is only
real if the automaton is unchanged, and the two facts are established by
different evidence — one by differential, one by clock. Mixing them into a
single "faster" number is how a compile-side optimization ships a smaller
automaton that answers differently on malformed input.

## Running It

```sh
zig build lowering-rung                      # all sections
zig build lowering-rung -- gate              # just the pair-space table
zig build lowering-rung -- occurrence        # just the scaling law
```

Built `ReleaseFast` like every production-posture rung, because Debug IR is not
the IR the shipped compile runs and a stage share taken over the wrong one is a
claim about the build mode.
