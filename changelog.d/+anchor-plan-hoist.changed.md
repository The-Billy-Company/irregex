The anchor decision is now a value that is minted once per query instead of
being re-derived inside every scan. `simd.Plan` holds the chosen probe/confirm
pair plus the single-probe eligibility, `simd.planFor` is the one mint every
consumer shares, and a `simd.Gate` carries its plan — so the whole-file drop and
the hit-to-hit `find` loop reuse one decision rather than re-pricing fifteen
candidate pairs against the fitted digraph table per file and per match. The
per-line literal paths in `CompiledQuery`, the one-needle `LiteralSet`, and the
candidate verify hoist the same way, and the wide tier only prices a pair when it
will actually run, so a haystack shorter than one block no longer plans at all.

Measured on one binary against itself via `GIST_NO_PLAN` (a two-build A/B cannot
answer this in a tree many agents edit concurrently): 1.18–1.27× less CPU on
line-dominated single-buffer scans of a 213 MB corpus, cold and warm alike, with
paired per-repetition ratios inside 1%. Many-small-files scans, where the walk's
syscalls dominate and the once-per-file decision is ~0.05% of the run, are
unchanged — 0.998–1.047× median paired ratio over 31 single-threaded reps. Output
is byte-identical in every arm — the pair only chooses which two offsets the block
filter compares, and the `eql` verify is what decides a match.

`simd.planOn` is the document-grain seam `calibrate.zig` was written for, and it
adopts a calibrated pair through `calibrate.refine` rather than `calibrate.best`.
Two defects are recorded there rather than shipped: adopting the sample's
favorite unconditionally was a measured 0.5–1.1% CPU tax with no row it won (the
shipped table is already right on most needles, and swapping off it also forfeits
the single-probe shape), and a purely relative accept margin is a winner's curse —
the argmin of up to 120 noisy estimates of the same density sits several sigma
below the truth, which the randomized suite caught as a claimed 12.5% win over an
incumbent that was in fact better. The margin is now the larger of 12.5% and four
standard deviations of the incumbent's own count.

**Large buffers now reach it on every literal path.** A plan is minted where a
whole document arrives and reused by every scan of it, through three seams:
`simd.Gate.on` re-prices the required-literal gate per body (called by
`Emitter.openOn` for the serial render, the swarm worker, the single-file shard
driver, stdin and the resident session's fold, by `json.emitOne` / `json.soloShard`
for the record stream, and by `verify.gateWide` for the whole-file drop);
`Emitter.lit_plan` carries the sweep decision for the loops that re-enter the scanner
once per match, minted before any shard exists so cutting one file across cores
cannot re-sample it per core; and `PikeScratch.litPlan` memoizes the span walks' plan
on the haystack slice, so `litSpan`'s twenty callers each get one mint per haystack
with no call site to remember. `LiteralSet.findOn` carries the same reasoning to the
fused whole-document literal scan, and `render.anyHit`'s `-q` sweep mints one
directly.

Those per-hit hoists are also a straight cost fix, independent of calibration. Since
`anchor.zig` gained its distance-conditioned joint correction, `anchor.select` costs
~21 ns on a typical 4–8 byte needle rather than ~3.7 ns, and every one of those loops
re-derived it once per HIT before it took a plan.

On a 200 MB buffer whose alphabet is the statically-rare bytes, holding needles whose
locally-rarest byte the shipped table ranks common: **6.9–8.0× less CPU** for
`-Fc`/`-F`/`-Fn`/`-Fo`/`--count-matches`, 7.8× for `--json` and 8.3× for `--json -o`,
7.0× for `-q`, and 4.5–4.7× for `-Fl`, over three needles so no row is one needle's
luck. The kernel sweep underneath is 70 ms on the table's pair
and 3.9 ms re-priced (17.6–17.9×), against 4.09 M block survivors versus 34–42 — and
the table's pair takes the *single*-probe shape there, so the fast loop aimed at the
wrong byte loses to the two-probe loop aimed well by an order of magnitude.

A regex carrying the same required literal gains where it sweeps and not where it
does not: 2.00× on `-o`/`--count-matches`, 4.6× on `-l`, but 1.23–1.26× on
`-c`/`-n`/`-w`/`-U`/`-A` because a 60-byte line is a single block and which two
offsets inside it get compared barely matters. `-i` cannot gain at all —
`containsCaseless` takes no pair. Both ceilings are structural rather than unwired.

Neutral where the table was already right: median 1.002× (min 0.996×, max 1.012×)
across 15 mode×needle rows on a 213 MB many-small-files code tree, where the size gate
declines in two comparisons. That has to be read as a median of repeats rather than a
best-of-N — at ~0.03 s a run one lucky outlier in either arm reads as a 1.4× swing,
which manufactured a phantom `-q` regression that nine paired reps dissolved.
Byte-identical throughout — 411/411 supported-surface
ripgrep parity on both the parallel and serial engines, an unchanged differential
fuzz residual, and 420 in-binary mode×needle×corpus differentials with zero
divergence.
