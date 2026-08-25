- `fullmatch` reads `pos` as a window now, not as the start of the text.
  `re.fullmatch(r"^\w+", " lead", 1)` is `None`, because `^` cannot hold at
  offset 1; this was returning a match, because the munch plane scans from a
  cursor and reads that cursor as the beginning of the subject. `^`, `\b` and
  their kin therefore asserted differently under `fullmatch` than under every
  other verb here, which is the sort of divergence you only find by asking.

  Fixed by asking the arm whose assertions are already right: one leftmost
  search from the same bounds, and if nothing begins at `pos` then nothing
  full-matches from `pos` either. Reading the pattern for an anchor instead
  would need a parse this module does not have, and a substring test would get
  `\^` wrong. The extra search only happens from a non-zero `pos`, so the
  common call pays nothing for it.
