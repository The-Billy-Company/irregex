- **`sub` with a group-reading template and `split` with groups are one crossing each.**
  `findall` already walked, captured and built its answer in a single call into
  the engine; these two still built a `Match` per match and crossed once more
  for each one's groups. Two new whole-answer verbs, `rendered` and
  `group_pieces`, do the walk, the capture pass and the assembly on the far side,
  with the same thinning, cap, refusal and disagreement rules as the verbs beside
  them - and a template that reads only `\g<0>` skips the capture pass entirely.

  On a 10 KB text with the accelerator, `sub(r"(\w+)=(\w+)", r"\2=\1", …)` goes
  from about 7x slower than `re` to 0.8x (0.5x with an optional group), and a
  grouped `split` from 12-51x slower to about 2x. The ctypes transport gets the
  same verbs and roughly halves.

  Parsed templates are also kept per pattern, as `re` keeps them: parsing one
  cost several times what the substitution it fed did, so a short `sub` spent
  most of its time re-reading a template it had read the call before.
