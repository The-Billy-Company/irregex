# bench/bounds/roofline — Layer C (measured headroom)

Layer C of [irregex's Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-al),
one of the seven layers this package mints itself. Where Layer B bounds the
hot loop against static instruction-level pressure, Layer C tests the
hardware claim: the engine's achieved read bandwidth against this machine's
measured memory-bandwidth ceiling. It reports a near-roof result only at or
above 80%; anything below that is reported as optimization headroom, without
inventing a binding bottleneck.

## What It Is

- **`bandwidth.zig`** is a STREAM-style single-thread read-bandwidth
  microbenchmark at three working-set tiers (L1/L2/DRAM), a matched
  gate/contiguous-production ladder over a corpus-sized buffer of corpus
  bytes, and the engine's real SIMD scan over the corpus.

- **`report.py`** reads `roofline.json` plus, when present, the face package's
  own Layer A `certify.csv` and this package's own Layer B `portcert.json` for
  the compute ceiling; it renders the `## Layer C` markdown section and
  splices it into the mint's working `CERTIFICATE.md` (the artifact home by
  default, or `$<prefix>DIR`). [`mint.sh`](../../certificate/mint/mint.sh)
  copies the finished file into the committed
  [`bench/certificate/artifact/`](../../certificate/artifact/) snapshot only
  when asked (`CERT_PUBLISH_DIR=...`).

- **`test_roofline.py`** carries adverse tests that reject sub-roof
  saturation claims and keep legacy certificate refreshes honest.

Low arithmetic intensity places a theoretical roof; it does not prove an
implementation has reached it. `report.py` therefore reports the measured
operating point, its distance from the roof, and the matched stages that
localize the gap.

## Method

`bandwidth.zig` sizes three buffers to land inside distinct levels of this
machine's cache hierarchy (16 KiB deep in L1, 3 MiB past L1 into L2, 512 MiB
past any cache into DRAM) and streams each with a vectorized, multi-
accumulator sum-reduction (independent accumulators hide load-use latency, so
the loop is bound by load-port/cache bandwidth, not the dependency chain) —
best-of-9 trials, since on this shared coworking box interference only ever
_slows_ a trial, never inflates it, so the max is the cleanest ceiling
estimate. It then times the engine's real `scan/simd.zig` `contains` over the full
corpus with an absent needle (a full scan, no early exit, no verification) —
the clean corpus operating point — plus two present needles for context
(early-exit + verify, not a clean bandwidth number).

### Why the Absent Needle Is Derived, Not Written Down

The absent needle is **not a literal**. `absentNeedle` reads the bytes that are
about to be scanned and returns a 32-byte run of whichever byte value has the
shortest longest-run among them; a run of length N holds no run of length N+1,
so the needle's absence is a fact about the corpus and not about how this file
happens to be spelled. It is then re-checked with `simd.contains` against the
contiguous buffer and against every document, and the run errors out rather
than publish if either finds it.

That guard exists because the arm spent its whole life measuring nothing. The
needle used to be a fixed literal spelled out in the source, and the
corpus root defaults to the package itself — so `bandwidth.zig` was one of the
corpus documents, the literal was tiled into the contiguous buffer, and
`simd.contains` returned on the benchmark's own source a few hundred KiB in.
"production contiguous" published **3,029 GB/s** against the same run's
measured 102 GB/s STREAM roof: an early return timed as a memory sweep. A
freshly-chosen literal would only survive until the next edit of this file.

Between STREAM and the corpus point sits the **matched ladder**, and its whole
value is that consecutive rungs differ by exactly one thing. All three run over
one contiguous buffer sized to the corpus and filled with corpus bytes:

1. **corpus-sized STREAM roof** — the same sum-reduction as the tier sweep, at
   the corpus's own size over the corpus's own content. This, not the 512 MiB
   uniform-random DRAM tier, is the denominator every scan rung is reported
   against; the tier sweep above is a cache-hierarchy datum.
2. **matched gate control** — production's streaming gate with verification and
   document dispatch removed and nothing else changed. Its stride, anchors,
   block gate, and single-probe promotion are read from `simd`'s published
   surface (`block_bytes`, `anchorsOf`, `anyLane`, `singleProbeEligible`)
   rather than restated here.
3. **production contiguous** — real `simd.contains` over that same buffer.

The first gap prices the gate's own instruction and load cost; the second
prices verification and production control flow; the corpus gap that follows
prices document fragmentation and dispatch alone. This ladder makes Layer C
diagnostic even when the scan is nowhere near the hardware roof.

### Why the Control Reads From Production

Through 2026-07 the ladder was **inverted** — the control measured 47.5 GB/s
against production's 53.0 on aarch64, which is impossible for a real upper
bound and meant the published headroom compared two unrelated kernels. Every
cause was this benchmark describing production from memory: a 16-byte stride
against production's 64, first+last anchors instead of the rarity-picked pair,
a per-block movemask where production gates on `anyLane`, and an
unconditionally dual-window loop for a needle production scans single-probe.
The four false assertions are recorded in `bandwidth.zig`'s header; the fix is
that the control no longer gets to have its own opinion about any of them.

### Why a Cycles/Byte Ceiling Can Be Absent From the Artifact

**Every GB/s number here is frequency-free** — bytes ÷ ns needs no clock. A
cycles/byte restatement of the same ceiling does need one: it is GHz ÷ GB/s.
The clock comes from [`../../apparatus/harness/pmu.zig`](../../apparatus/harness/pmu.zig),
streamed under memory load so the frequency describes the regime the ceiling
describes; `pmu.Meter` tries `kperf` (root) and then the unprivileged
per-thread counters, so the rung below often measures a real clock with no
`sudo` at all.

When neither tier opens, the artifact publishes **no cycles/byte at all** — not
a figure derived from a stand-in frequency. Until 2026-08-01 it published
`dram_cyc_per_byte_ceiling` and `l2_cyc_per_byte_ceiling` unconditionally,
computed from a hardcoded 4.4 GHz, next to a `ghz_source` sibling reading
`assumed (no PMU)` that any consumer was free to ignore — and `report.py` did
ignore it, printing the figure as "derived" with no mention that the divisor was
a guess. Divided by an assumption those two fields are just the GB/s ceiling in
other units, times a number nobody measured.

The fix is structural rather than a warning:

- The clock is a `Clock` with a `measured` bool, and the only way out of GB/s is
  `Clock.cycPerByte`, which returns `null` on an unmeasured clock. No caller,
  present or future, can build a cycles/byte figure from the stand-in.
- `roofline.json` nests the clock and publishes `"ghz": null` when it was not
  measured, so there is no flat divisor for a consumer to reach past `measured`
  and multiply.
- The two ceilings moved inside an optional `derived_cyc_per_byte` object that
  carries the clock it was divided by and is **absent** when there was none.
  The old flat keys are gone rather than renamed, so a stale reader gets a
  `KeyError` instead of a stale number, and a stale artifact still on disk reads
  as unmeasured.
- Layer B's llvm-mca cycles/byte likewise no longer gets a `≈N GB/s`
  translation without a measured clock. That conversion was two inferences deep:
  a modeled cycle count times a guessed frequency, printed as a bandwidth.

### Why an Unoptimized Build Refuses to Publish

The same defect one layer down, found in the same audit. This rung's build
posture is `.asked`, so it compiles at whatever `-Doptimize` the caller passes,
which Zig defaults to Debug — and every documented invocation of it, here and in
[`../../README.md`](../../README.md), was a bare `zig build roofline`. The
kernel's whole claim to be a bandwidth probe is its unrolled vector reduction
over eight independent accumulators; unoptimized, that degrades to a scalar loop
and every tier reports the same issue rate.

The artifact on disk when this was found read **L1 8.0 · L2 8.4 · DRAM 8.3
GB/s**: a flat "hierarchy" with L1 *slower* than L2, roughly an order of
magnitude under the 102 GB/s roof this same host records above. It was
well-formed JSON with a genuinely measured clock, so `derived_cyc_per_byte`
inherited the defect honestly and read as a result. Nothing in the numbers says
which build produced them.

Two fail-closed gates now stand where the instruction used to:

- **The build mode.** Debug and ReleaseSmall both suppress the vectorization the
  kernel is built around, so `run` refuses before spending a trial and names the
  rung to use. ReleaseSafe keeps its bounds checks but still vectorizes, so it
  measures memory and is allowed.
- **The ladder itself.** A 16 KiB working set that streams no faster than a 512
  MiB one has not resolved a cache hierarchy, whatever it measured. There is no
  threshold to argue over — L1 read bandwidth exceeds DRAM read bandwidth on
  every machine that has both — so `L1 <= DRAM` is refused outright, in the same
  spirit as the absent needle re-checked against `simd.contains`.

A bandwidth roof is a claim about the *machine*, which is what separates it from
Layer B′'s cycles/byte: that one is a claim about the build, so honoring the
caller's `-Doptimize` is right there and wrong here.

## How to Run

Build the optimized probe, then splice its result into the certificate.

```bash
cd <irregex-repo-root>
zig build -Doptimize=ReleaseFast roofline   # → .gist/roofline.json
bench/bounds/roofline/report.py             # splices Layer C into CERTIFICATE.md
sudo zig build -Doptimize=ReleaseFast roofline   # adds kperf's configurable events
```

`-Doptimize=ReleaseFast` is not advice: an unoptimized build refuses to run, for
the reason above.

`sudo` is not required for a measured clock — the unprivileged per-thread
counter tier supplies one; it only buys `kperf`, the single tier that can
program configurable events. When the face package's own Layer A `certify.csv`
is present in the same output directory, `report.py` reads it for the per-class
end-to-end operating points shown alongside the ceiling; absent it, Layer C
still publishes on its own measurements. Never fails the run (mirrors
`pmu.zig`'s discipline): no counter tier ⇒ the GB/s ceilings publish, the
cycles/byte ceilings do not exist, and both the terminal and the artifact say
which backend refused.

## Prior Art

- **John D. McCalpin, "Memory Bandwidth and Machine Balance in Current High
  Performance Computers" (1995), _IEEE TCCA Newsletter_.** The STREAM
  benchmark methodology this layer's read-bandwidth sweep follows.

- **Samuel Williams, Andrew Waterman, David Patterson, "Roofline: An
  Insightful Visual Performance Model for Multicore Architectures" (2009),
  _Communications of the ACM_ 52(4):65-76.** The roofline model itself — a
  kernel's throughput is capped by `min(peak compute, peak bandwidth ×
  arithmetic intensity)`; the engine's low arithmetic intensity puts it on
  the memory ridge this layer measures.

- **The face package's `bench/apparatus/harness/certify.zig`** (Layer A) —
  the per-class cycles/byte this layer's ceiling is optionally checked
  against, and [`../port/`](../port/README.md) (Layer B) — the compute
  ceiling this layer's report reads for the two-ceiling picture.
