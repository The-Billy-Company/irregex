# `seams/` — the bytes a type does not own

A dossier about one defect class rather than one component: a type has bytes no
field owns, some code turns a value of that type into a byte sequence, and
something downstream treats the sequence as if it meant the value.

It opens because the sibling parser
[outliner](https://github.com/The-Billy-Company/outliner) traced a
nondeterministic build artifact to exactly that, and **one of the two record
types was ours** — `Dfa.PatRun`, `struct { hi: u32, mask: u64 }`, twelve bytes
of fields in a type `@sizeOf` rounds to sixteen. Two types were found by
chasing one symptom, which is not the same as knowing there are only two.

- [`PREDICTION-1-seams.md`](PREDICTION-1-seams.md) — written before the sweep:
  where a live site would be found, what it would reach, why the damage would
  be `hash` and `eql` disagreeing rather than a wrong hash, and why the gate has
  to be a compile error rather than a byte comparison.
- [`RESULT-1-seams.md`](RESULT-1-seams.md) — every byte-view site in `src/`
  classified by consequence, the one live defect (`Op.uclass`'s `[2]u21` in the
  AST interner), the vacuous first draft of its own regression test, the three
  near-misses rejected, and the instrument this lane trusts least.

The gate the dossier lands is `frame.seamless(T)` plus the comptime refusal in
`mix.SliceCtx`; its anti-vacuity lives in `frame_test.zig`, which asserts the
predicate can still say **no**.
