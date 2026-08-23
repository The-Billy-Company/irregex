- `findall` is now one FFI crossing, and the no-bounds calls stopped paying for
  bounds nobody passed.

  `findall` used to come back as spans and get finished in Python: a capture
  call per match for a grouped pattern, a slice and a decode per value, a tuple
  per row. Two verbs on the native transport now hand back the finished list
  itself - `texts` for a groupless pattern, `group_texts` for the rest - walking
  the matches, running the capture pass, thinning the empty matches a `str`
  cannot index, and building the `str`/`bytes`/tuple objects all on the C side
  of the boundary. On a page of prose that is several hundred objects and as
  many crossings folded into one call. Both have ctypes implementations beside
  them, so a build without the accelerator keeps the same answers through the
  same seam.

  Independently, the call shape almost every program uses - `pos=0`, no
  `endpos`, the caller's own `str` or `bytes` in the pattern's own domain - now
  skips the translation object and the region arithmetic entirely in
  `is_match`, `search` and `findall`. An exact type in the right domain *is*
  the validation those layers performed; everything else still takes the slow
  path for its diagnostics. A `search` hit builds its `Match` by assignment
  rather than through two `__init__` frames, and the hot paths read the
  per-thread handle straight off the pool's thread-local, since a method frame
  costs more than the attribute it fetches.

  Measured against `re` on 3.12 (min-of-11, one process, interleaved), the
  bulk and scan shapes this engine exists for now win outright: `findall` on a
  59-byte line 458 ns vs 795 ns, the same line with a character class answered
  2.5x faster, a 17 KiB miss 6.8x faster, 17 KiB `findall` 1.6x faster. The
  rows that remain behind `re` are the ones whose whole budget is call
  dispatch: `re.search` answering a literal hit costs 60 ns, of which the
  match work is single-digit - the rest is the C method call and the C match
  object, a floor a Python-level `Pattern` and `Match` cannot undercut from
  the wrong side of the frame. Those rows are parked at 1.2-4.6x behind with
  the arithmetic written down rather than papered over; the next rung, if it
  is ever worth the surface, is `Pattern`/`Match` as C types in the
  accelerator itself.

  The `METH_FASTCALL` branch the accelerator compiles under a 3.13+ limited
  API also actually compiles now - the method table needed the `PyCFunction`
  cast every fastcall extension carries - so a build against newer headers is
  available the day the wheel matrix wants one.
