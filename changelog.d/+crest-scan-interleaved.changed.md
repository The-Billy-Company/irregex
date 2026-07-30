Crest sieve: scan each document as four interleaved pieces instead of one pass,
for 2.56x the throughput at a byte-identical answer. Widening the class family
to 16 lanes cost no scan time — all of it is one 256-bit vector — but the
per-byte update is a saturating add feeding an AND, a loop-carried chain about
three cycles deep that a single scan cannot fill; it ran at 4.4 cycles/byte with
the machine mostly idle, and preshaping the reset mask into a table to cut the
op count moved it by nothing, which is what a latency bound looks like rather
than a throughput one. Four pieces put four chains in flight and still fit `cur`

- `best` in half the NEON register file. The pieces rejoin exactly, by the run
  algebra the query half already folds over the pattern AST: each piece reports
  its leading run, best interior run, trailing run, and whether it ever broke, and
  the join is `max(F₁, F₂, S₁+P₂)` — `swell.Profile.concat` under another name.
  Leading runs are measured in a separate scan that stops once every lane has
  broken, which ordinary text does within a few dozen bytes, so the main loop
  stays three operations wide. Ablated back to back on the 21 854-file corpus:
  single-thread scan 0.73 → 1.87 GiB/s, from 0.63x to 1.62x the scalar per-byte
  reference, and the sharded whole-corpus index build 45.4 → 19.1 ms. Byte-
  identical on all 21 854 documents, and `crest_test.zig` pins the split against
  the single-piece definition over documents that straddle the interleave floor,
  with breaks walked onto and around every cut, whole-piece runs that must carry
  through, and a run past the u16 cap so saturation crosses a join.
