Layer C published two fields that read as measurements and were not.
`roofline.json` carried `dram_cyc_per_byte_ceiling` and `l2_cyc_per_byte_ceiling`
unconditionally, each one the GB/s ceiling divided by a hardcoded 4.4 GHz
whenever no counter tier opened, sitting next to a `ghz_source` sibling that said
`assumed (no PMU)` and that no consumer had to read. `report.py` did not read it;
it printed the figure as "derived" without saying the divisor was a guess. One of
the published bundles is x86_64, where 4.4 GHz is not even the right guess - it
is an Apple P-core number.

Four options were on the table: drop the fields, rename them so the derivation
is in the name, keep them and attach the provenance, or move measured and
assumed inputs into visibly different places. The last one is the only one a
future reader cannot undo, so the clock is now a `Clock` with a `measured` bool,
and the single exit from GB/s is `Clock.cycPerByte`, which returns null on an
assumed clock. The two ceilings moved inside an optional `derived_cyc_per_byte`
object that carries the clock it divided by and is absent when there was none.
The flat keys are gone rather than renamed, so a stale reader gets a `KeyError`
instead of a stale number, and the artifact publishes `"ghz": null` rather than a
divisor someone can reach past `measured` and multiply. A renamed field would
have been honest for exactly as long as nobody shortened the name again.

Then the same audit found the bigger version of it one level down. This rung's
build posture is `.asked`, so it compiles at whatever `-Doptimize` you pass,
which Zig defaults to Debug - and every documented invocation of it was a bare
`zig build roofline`. Debug does not vectorize the kernel's unrolled reduction,
so all three tiers report the same scalar issue rate. The artifact on disk read
L1 8.0, L2 8.4, DRAM 8.3 GB/s: a flat hierarchy with L1 slower than L2, roughly
an order of magnitude under the roof this same host records in the README, and
well-formed JSON with a genuinely measured clock, so the derived cycles/byte
inherited the defect honestly and looked like a result. Nothing in the numbers
says which build produced them.

`bench/README.md` has always said to build ReleaseFast. A standing instruction
only the docs enforce is the shape this whole pass is closing, so the rung now
refuses instead of publishing: unoptimized builds error out before spending a
trial, and a tier ladder where L1 is not faster than DRAM errors out too, since a
16 KiB working set that streams no faster than a 512 MiB one has not resolved a
cache hierarchy whatever else it measured. A bandwidth roof is a claim about the
machine, which is what separates it from Layer B's cycles/byte; that one is a
claim about the build, so honoring the caller's mode is right there and wrong
here.

Layer B also stopped asserting a cause it could not know. It reported "kperf
needs root" whenever no counters opened, which misread an unprivileged refusal as
a password problem after `pmu.zig` grew an unprivileged per-thread tier; it now
prints the meter's own note, which says which tiers were tried and why each
declined. The dead `bench/portcert/portcert.sh` citations follow the directory to
`bench/bounds/port/mca.sh`.

No measured value moved, and nothing was replaced with a plausible-looking
number. Two figures stopped existing on hosts that never earned them.
