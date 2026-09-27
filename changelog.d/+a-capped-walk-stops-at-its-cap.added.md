- **`irgx_find_upto_in`: the first `cap` matches, and no more walked.**
  `irgx_find_all_in` owes the caller the count the whole window holds, so a cap
  on it bounds what gets written and never what gets walked - `sub(count=2)`,
  `split(maxsplit=1)` and `FindAll(b, 3)` all paid for every match in the text
  to learn a total they then threw away. The new verb is `irgx_find_first_in`
  generalized from one span to `cap`: same walk, modes and refusals, stopped at
  the cap, with `*written` reporting what was written. Additive, so the ABI
  version stays 2.

  Every binding uses it where a limit is a prefix: Python's capped `sub`,
  `subn` and `split` on both transports, Go's `FindAll…(n)` for `n > 0` (and the
  windowed `…In` spellings), and Rust's `replacen` and `splitn`. A binding's
  thinning of empty matches is causal, so a capped prefix thins to the full
  sequence's prefix whenever it still reaches the cap; only when thinning left
  it short of a window the walk filled does the binding pay for the whole walk,
  which a pattern with no empty matches never triggers. Go and Rust's vendored
  archives are rebuilt to carry the symbol.
