# Pincer — proof and measurements

Anchor selection for the two-probe SIMD substring filter. The claim is that
the throughput of a literal scan is decided by *which* needle offsets the
vector unit is asked to compare, not by the instruction sequence that compares
them — and that the standard way of choosing those offsets is systematically
wrong for a reason that is measurable and fixable.

## 1. The setting

`src/kernel/scan/simd.zig::indexOfPos` filters the haystack in 64-byte blocks.
It picks two needle offsets `o1, o2`, broadcasts `needle[o1]` and `needle[o2]`
into vectors, and for each block computes two lane masks and their conjunction.
A block whose conjunction is empty is skipped whole; each surviving lane
position pays an exact `eql`.

Two costs follow from the choice of `(o1, o2)` and from nothing else:

- **hot blocks** — blocks whose conjunction is non-empty. Each pays a movemask
  and a survivor walk on top of the two loads every block pays.
- **survivors** — lane positions passing the conjunction. Each pays an `eql`.

Everything else per block is fixed. So `(o1, o2)` is the entire lever, and it
can be priced exactly rather than argued about.

### 1.1 The exact price

A 64-byte kernel block is precisely one `u64` word of a per-offset match
bitvector: bit `p` of word `w` of vector `k` is set iff `hay[64w + p + k] ==
needle[k]`. Then for a pair `(i, j)`

```
survivors = Σ_w popCount(B_i[w] & B_j[w])
hot       = Σ_w [ (B_i[w] & B_j[w]) ≠ 0 ]
```

which is the same arithmetic the kernel performs, counted instead of branched
on. Building `n` bitvectors costs `n` SIMD passes and lets all `C(n,2)` pairs be
priced without re-reading the corpus. This is what `probe.zig` does, and it is
why the **oracle** — the best pair that exists for this needle on this corpus —
is available as a denominator.

## 2. The defect

### 2.1 Independence is assumed and text violates it

A conjunction filter over two positions has selectivity `P(a at i ∧ b at i+d)`.
Choosing the two bytes by *individual* rarity — the Rust `memchr` crate's rare-
byte heuristic, and `rarity.zig`'s `density[256]` here — implicitly prices that
as `P(a)·P(b)`, i.e. assumes the two draws are independent. Text is the worst
case for that assumption: byte correlation is strongest at exactly the
distances a short needle offers, because the correlated unit *is* the word. The
digraph `st` in code, or `th` in prose, occurs far more often than the product
of its marginals predicts, so a unigram-minimising selector walks into a
correlated pair and the conjunction degenerates toward a single-byte filter.

**This diagnosis is not ours.** Startin (2018) built byte-pair adjacency
matrices from real corpora, generated correlated text from order-1 Markov chains
over them, and showed the naive first-byte heuristic degrading on exactly this
mechanism — in this domain, eight years before this dossier. He stopped at the
aggregate observation and shipped a fixed `0:1` pair; he never inverted the
bigram table to *select* offsets. `memchr`'s author reasoned about probe
correlation too, and handled precisely one degenerate case of it — a structural
`index1 != index2` guard, with no distance term. See `PRIOR_ART.md`.

### 2.2 The clamp turns that bias into a collapse

`rarity.zig` stores `density[b] = min(255, round(P(b) · 32768))`. The
saturation is not benign:

```
clamped at 255: 31 bytes, 30 of them printable
  ' ' ( ) , . / 0 : S _ a b c d e f g h i l m n o p r s t u x y
lowercase clamped: 20/26     unclamped: j=66 k=108 q=55 v=224 w=187 z=61
```

The module doc says *"only the coarse ORDERING matters; exact counts don't"* —
but for a lowercase identifier the clamp destroys the ordering entirely: every
byte ties at 255. `simd.zig` then breaks ties with strict `<`, so the loop never
displaces its initialisers and returns

```
o1 = 0, o2 = 1
```

the **adjacent** pair — the maximally correlated choice available, and the one
case where the conjunction buys almost nothing over a single byte. Measured
frequency of that outcome: **122/177 code needles, 78/90 prose needles.**

So the two failure modes compound. Even with perfect unigram data the selector
would ignore correlation; with the clamp it doesn't get to express a preference
at all, and the fallback is precisely the worst pair.

**Correction (2026-07-29): the collapse is a *conjunction*, and this section
originally over-attributed it to the table.** It takes the saturating cell **and**
a tie-break that resolves to the adjacent pair. Either defect alone is survivable:
with real dynamic range the old strict `<` rarely sees a tie at all, and with a
tie-break that prefers separation a saturated table degrades gracefully instead of
to the worst available pair. That is why the two repairs measure as redundant rather
than additive — see §10.2, which prices all four corners.

## 3. Measured selectivity

Corpus: 214 MB of a large polyglot monorepo (code, binaries excluded) × 177 needles drawn
from real identifiers; and 134 MB of English prose × 90 needles stratified
across the frequency spectrum. Pair statistics for the table-based selectors are
fitted on a **held-out** half in both regimes. `probe.zig` prices every
selector against the oracle.

| regime | selector | survivors | hot % | vs oracle | median | worst | exact |
| --- | --- | --- | --- | --- | --- | --- | --- |
| code | first+last | 38,711,720 | 5.717% | 3.04× | 3.06× | 297× | 36/177 |
| code | **unigram (shipped)** | **58,631,034** | **8.007%** | **4.61×** | 2.84× | 241× | 37/177 |
| code | census (unclamped unigram) | 18,968,329 | 2.795% | 1.49× | 1.17× | 62.9× | 76/177 |
| code | joint skip-gram | 12,788,558 | 1.940% | 1.01× | 1.00× | 13.4× | 154/177 |
| code | oracle | 12,714,366 | 1.928% | 1.00× | — | — | 177/177 |
| prose | first+last | 15,668,641 | 7.675% | 3.35× | 3.59× | 141× | 13/90 |
| prose | **unigram (shipped)** | **32,585,616** | **13.043%** | **6.97×** | 4.51× | 1475× | 9/90 |
| prose | census (unclamped unigram) | 8,228,971 | 4.063% | 1.76× | 1.18× | 42.0× | 42/90 |
| prose | joint skip-gram | 4,672,311 | 2.361% | 1.00× | 1.00× | 1.00× | 89/90 |
| prose | oracle | 4,672,159 | 2.358% | 1.00× | — | — | 90/90 |

Three things to read off this table.

**The shipped selector is worse than the fixed first+last it replaced** — in
both regimes, on every summary statistic. The module doc justifies rarity
anchoring by noting first+last would anchor on `_` (49% block density); the
clamp means it anchors on something worse.

**Dynamic range alone is most of the repair.** The census differs from
production only in not saturating — same greedy rule, same independence
assumption, 512 bytes instead of 256. It takes code from 4.61× to 1.49× and
prose from 6.97× to 1.76×.

**A joint model is the oracle.** Trained in-distribution on a held-out half,
skip-gram selection picks the exact optimal pair for 89 of 90 prose needles,
with worst case 1.00×. The residual gap on code (1.01×, 154/177) is
heterogeneity: one code corpus is many languages, and a single joint table
averages them.

Worst individual cases, shipped vs oracle:

```
code   tau_allostatic  0:1    610,172  →  2:3      2,528    241×
       stepSec         0:1  1,465,519  →  3:4      6,131    239×
       copyright       0:1    911,658  →  3:4      4,220    216×
prose  helpful         0:1  3,815,369  →  3:4      2,587   1475×
       throat          0:1  2,614,209  →  1:2     26,730     98×
```

## 4. Measured wall clock

`timeit.zig` runs the kernel's dual-probe wide tier over the same corpora with
the anchor pair as the only variable.

| regime | selector | time | throughput | vs shipped | median | best | regressions |
| --- | --- | --- | --- | --- | --- | --- | --- |
| code (37.8 GB) | unigram (shipped) | 2.088 s | 18.1 GB/s | 1.00× | — | — | — |
| code | census | 1.207 s | 31.3 GB/s | 1.73× | — | — | — |
| code | joint | 1.064 s | 35.5 GB/s | **1.96×** | 1.23× | 8.3× | 5/177 (worst 0.91×) |
| prose (12.1 GB) | unigram (shipped) | 0.925 s | 13.1 GB/s | 1.00× | — | — | — |
| prose | census | 0.450 s | 26.8 GB/s | 2.06× | — | — | — |
| prose | joint | 0.362 s | 33.4 GB/s | **2.56×** | 1.77× | 21.1× | 0/90 |

Worst shipped throughputs, and where the repair puts them:

```
code   return    4.4 GB/s → 14.9    error    4.6 → 20.2    instances  5.1 → 24.8
prose  helpful   2.4 GB/s → 50.5    thunder  2.8 → 31.1    thought    2.9 → 21.5
```

The framing this dossier answers observes that `memchr` "often gets throughputs
at around several gigabytes a second". On its worst needles the shipped kernel
is *at that number* — 2.4 GB/s — while holding a 64-byte-per-iteration vector
filter that runs at 30–50 GB/s when it is pointed at the right two bytes.

## 5. Confirmed in the shipped binary

The harness varies the anchor pair directly, which requires a patch. To confirm
the defect is production-visible without one, exploit the fact that the
selector's choice is a function of the needle: run the real `gist` on a single
1.7 GB file and compare needles that select well against needles that collapse.

```
gist -uu --no-index -c <needle> big.txt        # 1.7 GB, warm page cache
```

| needle | len | true hits | shipped pair | time | throughput |
| --- | --- | --- | --- | --- | --- |
| `stepSec` | 7 | 464 | 0:1 | 90.7 ms | 18.8 GB/s |
| `instruments` | 11 | 872 | 0:1 | 93.2 ms | 18.3 GB/s |
| `resource` | 8 | 21,480 | 0:1 | 87.3 ms | 19.6 GB/s |
| `pgxpool` | 7 | 8,856 | 0:1 (`pg` is rare) | 64.4 ms | 26.5 GB/s |
| `WalletService` | 13 | — | selective | 63.8 ms | 26.8 GB/s |
| `authorization` | 13 | — | selective | 65.8 ms | 25.9 GB/s |

`stepSec` and `pgxpool` are the control: **same length**, both selecting offsets
`0:1`, and `pgxpool` has **19× more true matches** to verify — yet it runs 41%
faster. More real work, less time. The only remaining variable is how many
false candidates the pair admitted, so the gap is prefilter waste and nothing
else.

This also explains why the Certificate never caught it: its literal probe is
`pgxpool`, whose first two bytes happen to form a rare digraph. The blind spot
is a probe-selection artifact, not a measurement error — the certificate's
`literal-rare` rung samples the lucky corner of the needle space.

## 6. Compaction is not the answer, and the measurements say why

A full skip-gram census over 15 gaps is 4 MB of `u32` — too large to ship as a
static table in a kernel. Two natural compactions were measured, and **both
lose to the 512-byte census**:

| selector | table | code vs oracle | prose vs oracle |
| --- | --- | --- | --- |
| census (unclamped unigram) | 512 B | 1.49× | 1.76× |
| truncate: joint for `d ≤ 4`, independence beyond | 257 KB | 2.31× | 4.00× |
| window: joint for `d ≤ 8`, candidates restricted to it | 512 KB | 1.27× | 2.91× |
| joint, all gaps | 4 MB | 1.01× | 1.00× |

They fail for opposite reasons, and both are instructive.

**Truncation** mixes two scales. A modelled pair is priced by its true joint
count (honest, high); an unmodelled pair is priced by the independence product
(optimistic, low). The argmin therefore walks straight into the unmodelled
region — the selector is *biased toward exactly the gaps it knows nothing
about*. Adding gaps monotonically helps only because it shrinks the region where
the bias operates.

**Windowing** removes that bias by restricting candidates to the modelled
window, and it does pick the oracle pair more often than the census does
(139/177 vs 76/177 on code). It still loses on aggregate — 2.91× on prose —
because the aggregate is carried by a few needles whose only decorrelated pair
is the *widest* one. For `helpful`, every adjacent pair is a common English
digraph; the decorrelated pair is `3:4` against a span the window cannot reach.

Together these say something sharper than "compaction is hard": the value of a
joint model lies **specifically in its ability to choose wide, low-correlation
pairs**, so any compaction that shortens the reachable span discards the benefit
it was built to deliver. Byte correlation in text does not decay fast enough
within a 16-byte needle to be truncated away, because the correlated unit is the
word itself.

## 7. The design the measurements point to

Stop shipping a distribution. Price the candidate pairs on a **sample of the
buffer actually being searched**, then scan with the winner. Same arithmetic as
§1.1, applied to a few thousand blocks instead of all of them.

**This is adoption, not invention, and that is the argument for it.** The
referee killed self-calibration as a novelty claim outright (`PRIOR_ART.md`,
claim 2): zoekt already selects its two trigram probes by reading *live
posting-list lengths from the index being searched*, optimising intersection
size rather than marginal rarity; Optimal Seed Solver already runs a DP over
seed positions against frequencies read from the real reference index, beating
four earlier self-calibrating schemes; and `memchr` ships
`HeuristicFrequencyRank` as a public trait specifically so a caller can
substitute a table computed for their own data. The rust `regex` docstring even
records the opposite decision *and its reason* — *"doing frequency analysis on
the haystack is far too expensive"* — which is publication of the considered
alternative. What the measurements below add is not the idea but the price: that
objection is quantified at **0.2% of the scan** (§7.1), which is the number that
decides it.

Sampling must be **stratified** — small windows spread across the whole buffer,
not a prefix. A prefix of a concatenated tree is one file's language:

| budget | placement | code vs oracle | prose vs oracle |
| --- | --- | --- | --- |
| 64 KB | prefix | 1.36× | 1.05× |
| 1 MB | prefix | 1.37× | 1.01× |
| 64 KB | stratified (4 KB windows) | 1.11× | 1.08× |
| 1 MB | stratified | **1.01×** | **1.00×** |
| 16 MB | stratified | 1.00× | 1.00× |

Prose is homogeneous, so a prefix suffices there; code is not, and prefix
sampling plateaus at 1.37× no matter how much of it you buy. Stratifying the
same 1 MB budget takes code to 1.01× — and the resulting selector

- **matches the 4 MB in-distribution joint table in both regimes** (1.01×/1.00×
  vs 1.01×/1.00×), with **no static table at all**;
- carries **no distribution assumption**, so base64 blobs, minified bundles, and
  prose are all handled by construction rather than by a table that describes
  none of them;
- has full oracle-class detail: 146/177 and 81/90 exact-oracle picks at the 1 MB
  budget.

### 7.1 Cost and the amortisation threshold

Calibration scans `n × budget` bytes for an `n`-byte needle, in the same SIMD
equality loop as the scan itself — so its cost is the *measured* scan rate at
oracle-class selectivity, **28.2 µs/MB (35.5 GB/s)** from §4, not an assumed
figure. Needle lengths in the code slate: mean 7.4, median 7, max 16.

| budget | n | calibration | break-even buffer | overhead on a 214 MB scan |
| --- | --- | --- | --- | --- |
| 64 KB | 7 | 12.3 µs | 0.9 MB | 0.20% |
| 64 KB | 16 | 28.2 µs | 2.0 MB | 0.47% |
| 256 KB | 7 | 49.3 µs | 3.5 MB | 0.82% |
| 1 MB | 7 | 197 µs | 14.0 MB | 3.28% |
| 1 MB | 16 | 451 µs | 32.0 MB | 7.49% |

Break-even is `buffer > 2 · n · budget` — the point where half the scan saved
exceeds the calibration paid. The 64 KB budget is the striking row: it pays
**0.2%** and still lands at 1.11×/1.08× of oracle, against the shipped
4.61×/6.97×. Nearly all of the available win is purchasable for almost nothing;
the 1 MB budget buys the last few percent and only pays for itself past ~14 MB.

That implies a tier, not a replacement:

- **under ~2 MB** — the unclamped census table (512 B). Fixes the clamp, costs
  one L1 pass over the needle, no sampling. Already 1.49×/1.76×.
- **~2 MB and up** — stratified calibration at a 64 KB budget: 0.2–0.5%
  overhead, 1.11×/1.08×.
- **~32 MB and up** — widen the budget to 1 MB for the last few percent
  (1.01×/1.00×), where it has room to pay for itself.

The kernel already contains the philosophical half of this: `indexOfPos` keeps a
runtime probe-hit counter that *demotes the filter shape* when the static table
mispredicts the buffer. Pincer extends that same instinct one step upstream —
from correcting the shape after the table is wrong to **choosing the anchors from
the data in the first place**.

### 7.2 Correction: three of the numbers above are wrong, and the tier is a call shape

The design in §7 was built and measured (`kernel/scan/calibrate.zig`, with tests).
Building it falsified three of the claims above, and then integrating it hit a
fourth problem that is more serious than any of them.

**7.2.a — 4 KB windows are the wrong grain.** The table above tests placement
(prefix vs stratified) but holds the window at 4 KB and never varies it. At a
fixed 64 KB budget, smaller windows win in every regime: 256 B lands at
1.03×/1.02×/1.04× (code/prose/heterogeneous) where 4 KB lands at 1.11×/1.08×/1.05×
and 16 KB at 1.19×/1.05×/1.11×. Same bytes, 256 strata instead of 16, and 16×
less stack for the bitvector. The shipped grain is **256 B**.

**7.2.b — the break-even is ~6× k·budget, not `2 · n · budget`.** Two errors
compounded in §7.1. The saving term used §4's 1.96×/2.56× speedups, which are
against the **clamped** table; against the unclamped table that `anchor.zig` now
matches, the honest speedup is 1.13×/1.25×, so `1 − 1/speedup` is 0.12–0.20 rather
than 0.49. And `R_cal/R_scan` measures ~1.0, not the ~2.9 assumed from cache
residency. Break-even is **6.4× k·budget on code, 3.5× on prose** — so the
"under ~2 MB / ~2 MB and up" tier boundary is off by roughly 4×. The shipped gate
is `16 × k × budget`, which takes break-even with 2.5–4.6× of margin on purpose,
because the static table already picks the oracle pair on 80/177 code needles and
the gate has to bound that pure-loss case.

Both of the next two subsections' per-needle counts were measured against the
selector §10 repaired, which `anchor.zig`'s own table now labels the *baseline* at
1.50×/1.29× of oracle. The shipped selector is a distance-conditioned joint one at
1.13×/1.29×, so it agrees with the oracle on strictly more needles than 80/177 — the
pure-loss population the gate has to bound is **larger** than these numbers say, and
the case for both the conservative gate and 7.2.e's improvement test is stronger, not
weaker. Neither count was re-derived, so read them as bounds in the direction that
favours declining to calibrate.

**7.2.c — "dominates everywhere" is too strong.** Calibration loses to the table
on 28/177 code needles, worst case 10.7× its survivor count. None is material
(largest is +0.014 pp of survivor density) and the net is negative in all three
regimes, but the defensible claim is aggregate dominance with no material
per-needle regression — not dominance.

**7.2.d — the tier cannot be expressed at the call site it was designed for.** §7
reasons about "the buffer actually being searched" as though a scan is one call over
one large buffer. It is not. `query.zig::countGeneric` calls
`simd.contains(line, needle)` **once per line**; the literal path also has a
once-per-document gate. So a size gate evaluated on the slice handed to
`indexOfPos` sees tens of bytes per call and declines forever — while removing the
gate inverts the problem and re-pays 3.5–36.8 µs *per line*. The measured
1.04×/1.03×/1.03× was taken by calibrating once over a 213 MB buffer, which is a
call shape production does not have. That is the same error class as the two
recorded defects in `simd.zig` (a control measuring a path production never takes),
arrived at from the other direction.

The fix is a **per-scan plan**, not a bigger gate: calibrate once when a document
is admitted, thread the pair through every line of that document
(`indexOfPosWith(hay, from, needle, pair)`), keep `indexOfPos` static so
`bench/bounds/roofline`'s published control cannot drift out of sync with the
kernel, and gate on document size.

**7.2.e — that plan is now built, and the integration taught two things §7 did not
know.** `simd.Plan` is the decision as a value, `simd.planOn` the document-grain
mint, and three seams carry it to every literal scan: `simd.Gate.on` (the
required-literal gate, re-priced per body), `Emitter.lit_plan` (the hit-jumping
sweeps, minted before any shard exists so cutting one file across cores cannot
re-sample it per core), and `PikeScratch.litPlan` (the span walks, memoized on the
haystack slice). `indexOfPos` kept its static behaviour, so the roofline control did
not drift.

A third property is a consequence rather than a lesson, but it is why the per-hit
hoists carry their own weight: §10's repaired selector became a **distance-conditioned
joint** one, and `anchor.select` now costs ~21 ns on a typical 4–8 byte needle where
the two-pass marginal selector cost ~3.7 ns. Every hit-jumping loop re-derived that
decision once per match before it took a plan, so the hoist is a straight cost fix on
match-dense bodies even with calibration switched off — and a one-literal set is
exactly the case that pays it, since an alternation anchors each needle on its own
first+last and never calls `select` at all.

First lesson: **adopting the sample's favourite unconditionally is a tax, not a
win** — a measured 0.5–1.1% CPU regression with no row it won, because 7.2.b's
"80/177 needles the table already gets right" is not merely a break-even case but a
strictly losing one (the swap also forfeits the single-probe block shape, which
`singleProbeWorthwhile` prices against the static table and cannot judge for a
calibrated byte). So the integration is an **improvement test**: the incumbent is
pinned into the candidate set, priced on the same sample, and displaced only on a
material win. 7.2.c's "aggregate dominance with no material per-needle regression"
is therefore now enforced per call rather than argued in aggregate.

Second lesson: **a purely relative accept margin is a winner's curse.** The argmin
of up to 120 noisy estimates of one underlying density sits several sigma below the
truth even when every pair is truly identical; the randomised suite produced a
claimed 12.5% win over an incumbent that was in fact 0.3% better. The bias scales
with `√count`, which no relative floor can see, so the margin is the larger of 12.5%
and four standard deviations of the incumbent's own sampled count.

Measured after integration (M4, single-threaded, in-binary A/B via
`GIST_NO_CALIBRATE`, child CPU, best of 7, interleaved) on a 200 MB buffer whose
alphabet is the statically-rare bytes, over three needles whose locally-rarest byte
the table ranks common — `zeqXtj`, `tzeQjq`, `ezQtj`:

| arm | ratio |
| --- | --- |
| `-Fc` / `-F` / `-Fn` / `-Fo` / `--count-matches` | 6.9–8.0× |
| `--json` / `--json -o` | 7.8× / 8.3× |
| `-q` (presence, one jump) | 7.0× |
| `-Fl` (exits at the first hit) | 4.5–4.7× |
| bare kernel sweep (`sweep.zig`) | 17.6–17.9× (70 ms → 3.9 ms) |
| regex w/ required literal, `-o` / `--count-matches` / `-l` | 2.00× / 2.00× / 4.6× |
| regex per-line (`-c` `-n` `-w` `-U` `-A`) | 1.23–1.26× |
| `-i` (no pair to choose) | 1.00× |

Selectivity underneath: 4.09 M block survivors on the static pair against 34–42 on
the calibrated one — and the static pair takes the *single*-probe shape, so §5's fast
loop aimed at the wrong byte loses to the two-probe loop aimed well by an order of
magnitude. **Median 1.002×** (min 0.996×, max 1.012×) across 15 mode×needle rows on a
213 MB many-small-files code tree, where the gate declines in two comparisons — so
7.2.b's margin behaves as designed. Output is byte-identical: 411/411
supported-surface ripgrep parity on both engines, an unchanged fuzz residual, and 420
in-binary differentials with zero divergence.

One methodological note that cost a false alarm: on the code tree a run is ~0.03 s, so
a **best-of-N** statistic is the wrong one — a single lucky outlier in either arm reads
as a 1.4× swing. A `-q` row that appeared to regress 0.60× on best-of-5 came back at
median 1.005× over nine paired reps, with the `off` arm's minimum sitting 0.18 s below
its own cluster. Best-of-N is right for the adversarial rows, where the signal is 8×
and the spread is 1%; it is not right for a neutrality claim.

Two ceilings remain, and both are structural rather than unwired. `-i` has no pair
to choose, because `containsCaseless` is a different kernel. The per-line engine
modes cap near the whole-file gate's contribution because a 60-byte line is one
block, and which two offsets inside a single block get compared barely moves
anything. The split is visible *within* one engine mode, which is what makes it a
statement about scan shape rather than about the literal/regex boundary: `-o` and
`--count-matches` sweep and reach 2.00×, while `-c` and `-n` over the same pattern
stay at 1.25×. Every 7–8× row is a whole-buffer hit-jumping sweep, which is the shape
the anchor pair actually governs.

## 8. What this says about the original question

The `memchr` framing treats candidate identification as an instruction-selection
problem: is a SIMD `memchr` as fast as an explicit `PCMPESTRI` loop? The
measurements here say the instruction sequence was never the binding constraint.
A 64-byte two-probe block filter is at 77% of this machine's DRAM roof *when its
anchors are chosen well*, and at 2.4 GB/s when they are not — a 20× spread with
the instruction sequence held fixed.

So the answer is neither "keep `memchr`" nor "replace `memchr`". It is that the
interesting variable sits one level up, in the statistics used to aim it, and
that the standard aiming heuristic — per-byte rarity, shared by the `memchr`
crate and by this kernel — is wrong in a specific, measurable way: it assumes
independence between the probes, and adjacent bytes in text are the most
dependent pair available.

Nor is Boyer-Moore's shift table the lever. With a well-chosen pair the filter
already skips 64 bytes per iteration in 98.1% of blocks; a precomputed shift
distance of 7 or 11 is not competitive with a vector width, and the question
"how do I skip characters instantly" resolves to "choose a pair that makes whole
blocks disappear", which is a statistical question rather than an
instruction-set one.

Both halves needed were already in the tree — a corpus-derived rarity table and
a two-probe conjunction filter. What was missing was the recognition that the
table prices the pair as if the two draws were independent.

## 9. What is actually ours

A dated adversarial referee pass (`PRIOR_ART.md`, 2026-07-29) settles this, and
it is worth stating plainly because two of the three interesting parts are not
novel.

- **The defect is ours.** The clamp, the tie-break, and the `0:1` collapse are
  local bugs in `rarity.zig` and `simd.zig`. So is the Certificate blind spot
  that hid them.
- **The diagnosis is Startin's** (2018), in this domain, with real-corpus bigram
  tables. We rediscovered it; he published it.
- **The repair by self-calibration is standard practice** in adjacent fields —
  zoekt, Optimal Seed Solver — and an explicitly provided extension point in
  `memchr`. **Claim killed.** It should be adopted precisely because it is
  known-good, and what we contribute is the measured price that the incumbent's
  stated objection ("far too expensive") assumed without measuring.
- **Narrowly unclaimed:** selecting the offset *pair* by minimising
  `P(X_i = a ∧ X_{i+d} = b)` — a distance-conditioned joint over **concrete byte
  values** of the specific needle, at the specific gap — as the direct objective,
  for a **conjunctive** filter. Four axes separate it from the nearest art
  simultaneously (raw-byte alphabet; gap-conditioned rather than
  overlap/no-overlap; per-needle rather than a reusable template; conjunction
  where independence is a real error, not disjunction where additivity is exact),
  and no single prior work has more than two. Buhler–Keich–Sun (2003) and iedera
  already choose filter positions under an empirical Markov background, so the
  *general move* is 23 years old.

Patent coverage in that pass is weak — one web query, no USPTO/EPO search — so
nothing here should be asserted externally until that is closed.

## 10. The tie-break repair, measured in the kernel

The cheapest rung landed first, and alone: selection moved into `kernel/scan/anchor.zig`,
and ties are now broken toward the **widest separation** instead of falling through
a strict `<` to the adjacent pair. No table change, no calibration — the clamp is
still in place. So this measures exactly one thing: what the degenerate `0:1`
fallback was costing.

Eight all-tied needles (every byte saturated, so the old selector returned `0:1`),
`timeit` over the 213 MB code corpus, best-of-N, all configurations required to
agree on the hit count:

| needle | hits | `0:1` | first+last | speedup |
|---|---:|---:|---:|---:|
| `internal` | 18,205 | 40.70 ms | 9.54 ms | **4.27×** |
| `container` | 5,715 | 24.28 ms | 8.85 ms | **2.74×** |
| `metadata` | 7,599 | 19.48 ms | 7.31 ms | **2.67×** |
| `statement` | 1,900 | 34.84 ms | 14.41 ms | **2.42×** |
| `resource` | 2,955 | 38.98 ms | 18.51 ms | **2.11×** |
| `settings` | 4,190 | 27.63 ms | 13.62 ms | **2.03×** |
| `parameters` | 1,070 | 12.97 ms | 8.17 ms | **1.59×** |
| `namespace` | 9,744 | 12.27 ms | 18.62 ms | **0.66×** |

Geometric mean **2.07×**. In throughput the worst cases move from ~5.2 GB/s
(`internal` at `0:1`) to ~22.4 GB/s, and `metadata` reaches 29.2 GB/s.

**`namespace` regresses 1.52×, and that is the honest headline of this table.**
`na` is a rarer digraph than `n`-then-`e`-at-8, so for that one needle the adjacent
pair really was the better filter. This is the independence assumption biting in
the opposite direction, and it is the sharpest available proof that **separation is
a tie-break, not a selectivity model**: it is the right thing to do when the table
has no opinion, it is worth 2× on average, and it cannot be trusted per-needle.
Only real pair statistics — measured, not assumed — get to 1.00×. Anyone tempted to
promote "prefer wide separation" from tie-break to policy should start here.

The same table is also a correctness check: `timeit` fails closed with
`AnchorChangedTheAnswer` if two anchor choices disagree on the hit count, and all
three configurations agreed on every needle. The anchor pair selects which filter
runs, never which positions match.

### 10.1 End to end, in the shipped binary

§5's defect signature was a ratio between two 7-byte needles: the degenerate
`stepSec` ran **1.41×** the time of `pgxpool` while finding an order of magnitude
fewer real matches. That ratio is the whole defect in one number, so it is also the
cleanest closure test. Re-measured on the built binary with the tie-break repair
**and** the unclamped table in place, `gist --no-index -c` over the 213 MB corpus,
interleaved, best-of-7:

| needle | true hits | best | |
|---|---:|---:|---|
| `stepSec` (trap) | 58 | 142.8 ms | |
| `pgxpool` (control) | 1,107 | 144.1 ms | |

**Ratio 0.991, from 1.41.** The trap is now marginally *faster* than the control,
which is the correct ordering — it does 19× less verification work, and with a sane
filter that finally shows up in the time. Measured independently at 1.007 by the
probe-coverage work on the same tree, so two harnesses agree.

This is the combined number, and it is the one that matters: the two repairs
interact, because removing the clamp means far fewer needles tie at all, which makes
the separation tie-break fire less often than when §10's 2.07× was measured.

### 10.2 Both corners priced: the two repairs are redundant, not additive

The table repair and the tie-break repair were measured independently, by different
harnesses, days apart. Putting all four corners in one place — survivors as a
multiple of the best-possible pair for each needle, lower is better, 1.00× optimal:

| | old tie-break (adjacent on a tie) | separation tie-break |
|---|---:|---:|
| **clamped table** (`u8`, ×32768) | 4.61× / 6.97× | **2.55×** / — |
| **unclamped table** (`u16`, ×65535) | 1.49× / 1.76× | **1.50×** / 2.21× |

(code / prose where both were measured.)

Two things fall out, and both are load-bearing:

**The independent agreement is the strongest validation in this dossier.** My spike
measured unclamped-plus-old-tie-break at 1.49× on code; the table work measured
unclamped-plus-new-tie-break at 1.50×, from its own corpus census and its own
oracle. Two harnesses, two implementations, one number.

**The repairs overlap almost completely.** Fixing only the tie-break takes 4.61× to
2.55×; fixing only the table takes 4.61× to 1.49×; doing both lands at 1.50×, which
is the table fix's number and not better than it. The bottom row barely moves
because with real dynamic range there is hardly ever a tie for the tie-break to
resolve. So this is **defense in depth, not a stacked win** — and the honest reading
is that the table was the larger of the two defects, while the separation tie-break
is what keeps the failure graceful if a future census ever re-introduces ties. Do
not report 2.07× and 1.5× as though they multiply.

**The consequence for whoever maintains this: redundancy masks single regressions.**
Because either repair alone holds most of the win, losing *one* of them will not show
up as a throughput cliff — the survivor absorbs it, and the trap/control ratio in
§10.1 stays plausible. A census regenerated with a narrower cell, or a tie-break
quietly reverted to strict `<`, would each be nearly invisible to the benchmark that
originally exposed this. That is an argument for guarding both **structurally** rather
than by watching a ratio: assert monotonicity and no-saturation over the table
directly, and assert on a known all-tied needle that the selected pair is separated.
A perf number cannot see the difference between one repair and two.

The prose column also carries a caveat worth keeping: 2.21× is a *cross-distribution*
number. A prose-fitted census reaches 1.76× on prose where the shipped code prior
reaches 2.21×. The shipped table is deliberately a code prior for a code-search
tool; the gap is the price of one prior, not a defect, and it is the standing
argument for §7's per-buffer calibration, which pays no such price.

### 10.3 The ratio is only readable interleaved

**Do not compute this ratio from two rows of a sequential results table.** Whichever
needle is timed first pays a colder page cache, worth ~10–15 ms on a ~190 ms cell —
enough to cross the alarm line on its own. Measured on the same healthy binary:
**1.031** trap-first, **0.984** control-first, **1.384** from a cold start, and
**1.007** interleaved. The cold-start figure is indistinguishable from the 1.41
defect signature.

So the guard has a real failure mode in both directions: it can cry wolf on a healthy
kernel, and a genuine regression could hide inside the same bias. Only pairwise
interleaved samples carry the signal. `scanner.sh` interleaves the cells within a
class but runs classes sequentially, so the caveat is live in its output and is
written next to both probe sets.

## 11. Status and threats to validity

**Integrated:** selection extracted to `kernel/scan/anchor.zig` with the
separation tie-break (§10), the unclamped `u16` density table with
`single_probe_max` rescaled to the same 0.15% probability it always meant, and the
selector-quality probe classes that make the defect visible to the benchmark suite
at all. The closure is measured end to end (§10.1).

**Also integrated:** the calibrating selector, reached through `simd.planOn` as an
improvement test over the static pair, with the plan minted per document and carried
by three seams (§7.2.e for the shape, the two lessons the integration taught, and the
measured 6.9–8.0×). `anchor_test.zig` and `calibrate_test.zig` both exist, so the
regression guard for this entire defect — an all-tied needle must never select
adjacent offsets — is enforced by a test rather than by §10.1's benchmark ratio alone.

**Not yet integrated:** the pair-aware policy; the ~1.5×-to-1.0× gap against the
oracle is still open for the static table, and calibration closes it only where the
size gate fires.

- Selectivity is measured exactly; wall clock is measured on this machine
  (Apple M4) only, for the dual-probe wide tier. The single-probe fast path
  (`density ≤ 48`) is a different loop shape and its interaction with a
  recalibrated selector is unmeasured.
- Table-based selectors are fitted on held-out halves, so their numbers are not
  self-fitted. The **oracle and the sampling selectors are in-corpus by
  construction** — the sampling selector genuinely reads the buffer it will
  scan, which is the proposal, but it means its ratio to the oracle is a measure
  of sample sufficiency, not of generalisation.
- Needle slates are 2–16 bytes. The kernel's own doc cites 2–4 byte needles as
  dominant traffic; very short needles have few pairs and less to gain.
- The 1.7 GB single-file production run is warm-cache and single-threaded. It
  establishes that the defect is visible in the shipped binary; the end-to-end win
  is §7.2.e's in-binary A/B, on a different (adversarial) corpus.
- §7.2.e's end-to-end ratios are **child CPU time in one binary against itself**
  via `GIST_NO_CALIBRATE`, not a two-build comparison — deliberately, because this
  tree is edited concurrently by many agents and a two-build A/B cannot hold the
  rest of the binary fixed. Wall clock on a 200 MB mmap is mostly page-fault noise,
  which is why CPU is the reported quantity.
- The 6.9–8.0× rows are measured on a **constructed adversarial buffer** — an
  alphabet of statically-rare bytes holding needles whose locally-rarest byte the
  shipped table ranks common. That is the regime calibration exists for, not a
  typical one; the typical regime is the 1.00× code-tree rows in the same table,
  and both belong to the claim. The three needles also **do not occur** in the
  buffer, so those rows are pure prefilter waste with the verification term held at
  zero — deliberately, since that is the term the anchor pair governs, but it means
  they are not a claim about a match-heavy scan.
- The break-even model in §7.1 assumes calibration and scan run at the same
  bytes/second. Calibration touches `n` streams over a small region and should
  be more cache-friendly than a full scan, which would make the real threshold
  *lower* than tabulated — but that is unverified, so the table is the
  pessimistic reading.

Provenance of the numbers, since the harnesses that produced them were
pre-production spikes and do not ship here. The defect and the selector sweep
(§3, §4) ran on the first: a corpus builder that concatenated 214 MB of real
code and 134 MB of English prose behind NUL separators and diverted every fifth
file to a held-out fitting half; an exhaustive `probe` that imported the
production `rarity.zig` and priced every offset pair against the oracle by
popcounting per-offset match bitvectors; a timing harness that varied only the
anchor pair through the kernel's dual-probe loop; and an aggregator for the
per-needle ratios and the degenerate-pick census. The integration (§7.2.e) ran
on a second: a `sweep.zig` timing one hit-to-hit kernel sweep under the lazy,
static and calibrated plans that refused to report until all three hit counts
agreed, a per-needle headroom probe, the in-binary CPU A/B against
`GIST_NO_CALIBRATE`, and the 420-invocation output differential. What ships in
place of them is the part that must keep holding: `anchor_test.zig`,
`calibrate_test.zig`, and the parity suites. See `TESTING.md`.
