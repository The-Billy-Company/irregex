Re-planning a literal gate on a document no longer recomputes the static anchor
pair the gate is already carrying.

`simd.Gate.on` is the per-file seam; `Emitter.openOn`, `json.emitOne`,
`json.soloShard` and `verify.gateWide` all reach it once per body. It bought its
idempotence - file N's pair must never become file N+1's incumbent - by deriving
the incumbent through `planFor(bytes)` and deliberately ignoring `self.plan`.
Correct, but `planFor` is `anchor.select`, which since the distance-conditioned
joint correction costs ~21 ns on a 4-8 byte needle and ~37 ns at 32; the gate was
minted from that same needle once per query and had the answer in a field. So
every file in a walk paid a fifteen-pair pricing against the fitted digraph table
to reconstruct a constant, plus two `getenv` calls - a linear walk of `environ`
with a `strcmp` per entry - on the way to it.

Idempotence now comes out of the type instead of out of the recomputation.
`Gate.plan` is the effective plan and `Gate.base` remembers the static one, so the
incumbent handed to `refineOn` is the same value on file N+1 as on file N by
construction rather than by re-deriving it. `simd.refineOn(hay, needle, held)` is
the seam that takes an incumbent a caller already holds; `simd.planOn` is now that
call with `planFor` in front of it, unchanged for its own callers.
`LiteralSet.findOn` refines against the plan `build` already put in
`single.plan` for the same reason. `GIST_NO_CALIBRATE` is read once per process
rather than once per document - nothing here calls `setenv`, and the A/B that knob
exists for spawns a child per arm, so the answer cannot move under a run.

Measured on one binary against itself, arms interleaved round-robin so a
coworker's build lands on both: over this tree's 880 files (13.9 MiB, 16.5 KB
mean), the gate seam plus its scan fell from 368.8 ns per file to 192.8 at a
32-byte needle and 342.7 to 191.7 at 6 bytes, which is 1.79x and 1.67x. It now
sits within 1.6% of the floor measured by running the same scan with no re-plan at
all, and what remains is `calibrate.refine` declining below its own size gate at
2.4 ns. Every arm reports the bytes it scanned and the hits it found, and all
arms agree on both, so the speedup is not an early exit.

Two things this is not. `Gate.base` is deliberately invisible to `in` and `find`:
folding the choice of which field to scan with into those two - the hit-to-hit
jump loop, entered once per MATCH - cost a measured 1.2x on `-o` and `-l` over
this tree before it was taken back out, because trading a per-hit branch for a
per-file `select` is the wrong direction by three orders of magnitude in call
count. And it is not an end-to-end win: over 41 interleaved paired reps the CLI
moves 0.97-1.05x with quartiles straddling 1.0, because the per-file cost of a
real run is ~89 us of walk and intake against 0.19 us of scan dispatch. This
removes work that was provably redundant; it does not move the number a user sees.

Output is byte-identical - the pair only chooses which two offsets the block
filter compares, and the `eql` verify is what decides a match. 411/411
supported-surface ripgrep parity on both the parallel and serial engines, the full
Zig suite green, and every row of the paired CLI A/B asserted identical stdout and
exit code before it was allowed to report a ratio.
