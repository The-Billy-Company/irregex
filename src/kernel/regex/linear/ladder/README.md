# linear/ladder — who answers the question

Dispatch, and **only** dispatch. Three nested versions of the same decision —
_which machine is the cheapest one that can soundly answer this?_ — with no
semantics of their own: every rung answers identically to the Pike VM, and a rung
that cannot decide a haystack falls through instead of guessing.

| File                                     | Rung                                                                                                                                                              |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`../../matcher.zig`](../../matcher.zig) | **Which backend** (at the regex package root). Tagged union over linear `Regex` and opt-in PCRE2 `Pcre` (`-P`), dispatched once per line / span — never per byte. |
| `verdict.zig`                            | **Which rung inside the linear arm.** Cost order: end-of-line certainty → SIMD class-run → accelerator tier → byte-class DFA → Pike VM.                           |
| `rungs.zig`                              | **Which accelerator inside that.** Optional machines behind one interface so the handle carries one field.                                                        |

The `*Fused` predicates (`docMatchFused`, `countRunFused`) let a caller with its
own per-line loop ask _which_ machine would answer **before** paying a line
split — the reason a whole-buffer scan can skip work a line-oriented one cannot.

Callers of the linear engine never import `verdict.zig`: `../program/core.zig`
adopts `lineMatch`, `docMatch`, and the fused predicates onto `Regex`. `Matcher`
is imported directly, by name, from the surface layer.

## The rung protocol

Three-valued, and it unifies the two kinds of accelerator exactly rather than
papering over their difference:

- A **decider** answers `.hit` or `.miss` completely for the patterns it accepts,
  and declines at _compile_ time by being absent. It may never say "not sure"
  mid-scan.
- A **sieve** answers `.miss` (proven no match) or `.unproven`, and structurally
  cannot say `.hit`, because an over-approximating quotient admits supersets.

Both meanings of `.miss` are "return false", which is why one enum serves both
and the walk needs no per-kind branch. Correctness never depends on a rung being
present: an empty tier is the engine exactly as it was.

Admission lives in `rungs.zig` rather than in any rung, because what a rung is
worth is only visible from outside it. Every decider that can represent the
pattern is built, each prices itself as an `Offer`, and **exactly one is kept** —
they are alternatives, not a pipeline, so a second would cost compile time and
memory to be unreachable. The fallback is an offer too, priced from the
prefilter's expected stride, which is what lets a rung lose to a start skip
instead of merely standing down beside one. The sieve is not in that contest: it
narrows without deciding, so it is offered the winner's per-byte cost and applies
its own survival inequality against it.

## What a rung costs — `price.zig`

The auction was structurally real and numerically invented: the bids were
hand-written literals (`30_000`, `500 + 30_000/stride`, `4_400`/`8_000`,
`9_000 + ops/8`) that no run had produced. An auction settled in a currency
nobody minted can be internally consistent and still buy the wrong machine.

`price.zig` is that currency. One module owns **every** number the ladder reasons
with, in two halves that are not allowed to mix:

- A `Calibration` — one struct of **measured coefficients**, each a cycles-per-byte
  (or per-line, per-candidate, per-unit-built) figure minted on a named machine on
  a named date. `active` selects the one for this target; `unmeasured` exists only
  so the arithmetic is total on an unported host, and it withholds `measured`.
- A `price(Machine) Cost` function — the **structural** half, which reads a
  pattern's own facts (table bytes against the L1 residency threshold, skip
  stride, `^`, transformation width, end-of-line index, stripe ops, conjunct
  count) and combines them with those coefficients. No literal in it is a
  performance claim; every one is a shape.

So a bid is now `measured coefficient × this pattern's structure`, and the two
are separable: a port re-mints the calibration without touching the cost model,
and a new rung adds a model without re-measuring anything.

Two consequences worth stating, because both replaced a boolean:

- **The fallback is priced by which walker it actually is.** One constant used to
  cover the eager DFA, the lazy DFA _and_ the Pike VM; measured, they are 1.18,
  9.50 and 29.63 cyc/B — a **25×** range a challenger was previously bidding
  blind into. `^` is priced as what it actually is, too: a per-**line** seed
  behind a `memchr`, not a per-byte walk. That single axis took the auction's
  worst misprice from **2.82×** to **1.00×**.
- **The walk is _not_ priced by its table's footprint, and that is a measurement
  too.** The plane shipped a residency axis first — a resident step, a spilled
  step, and the table size between them — because "a table too big for L1 walks
  slower" sounds like the fact a walk turns on. The sweep built to fit that curve
  refuted it: a **1.4 MB** table and a **216-byte** table both walk at 1.18
  cyc/B, and the whole 6-point spread (1.02–1.21 over a 19,000× footprint range)
  tracks automaton shape. It could not have been otherwise — the step is one
  dependent load from `table[state·stride + class[byte]]`, so the working set is
  the rows a haystack _visits_ times the classes it _uses_, and a 1795-state
  pattern cycles through a handful on real text. The axis is gone, `Machine.walk`
  has no footprint field to misuse, and the sweep stays in `mint` printing its
  spread — so a host that really is cache-sensitive shows the knee before
  anything silently misprices.
- **A pattern nothing in the ladder answers is priced by whatever does.** Above
  the tier sit two kernels that can decide a whole haystack outright — an
  `.exact` literal set and a saturating class run — and for those patterns the
  auction is not merely lost, it is unreachable. Pricing the incumbent DFA there
  quotes a machine that never runs. So `Selection` carries a `settled` member
  and `Admit.settled` names **which** kernel took the pattern; `build` returns
  before any candidate is constructed, with `selected_cost` set to that
  kernel's own measured price. `fallback_cost` still holds the real walk, which
  is what a bench comparing "settled vs. the machine it displaced" needs.
  The tag is a **classifier**, not a name: `settle_literal_one` is 0.073 cyc/B
  and `settle_literal_many` 0.517 — a 7.1× spread between `memchr` and Teddy —
  and `settle_class_ranges` 0.146 against `settle_class_nibbles` 0.178, so
  `lower.zig` reads `LiteralSet.arity()` and `ClassRun.backend` rather than
  pricing both halves of a kernel with one number. A single `settle_literal`
  coefficient mispriced `Qzxjvw` by 12×, and the regret gate is what found it.
- **Compose's dwell gate is gone.** `if (dfa.start_dwell != null) return null`
  was a boolean standing in for an inequality it could not state. The stride-priced
  fallback now simply outbids composition on those patterns, and loses to it on
  patterns where the skip is weak — an outcome the boolean could not express in
  either direction. `Compose.lower` is the only entry point; there is no second
  dispatch judgment inside the rung.

### Minting, verifying, and regret — `zig build ladder-price`

Three verbs, and the third is the one that matters:

- **`mint`** measures each coefficient in isolation — one probe per coefficient,
  min-of-N against a fixed synthetic haystack, two-point linear fits where a
  cost has both an intercept and a slope (`skip_verify`, `anchor_line`) — and
  prints the `Calibration` literal to paste back. Coefficients it could not reach
  on this host are reported as unreachable rather than defaulted.
- **`verify`** re-measures and fails on drift, so a stale calibration cannot
  silently keep pricing.
- **`regret`** is the honest gate. For each pattern on a slate it builds **every**
  machine the ladder could have chosen, measures each one, and reports
  `chosen ÷ measured-fastest`. A model that agrees with itself and disagrees with
  the machine fails here — which is exactly how the anchored misprice above was
  found, and how the fix was proven. Worst regret is currently **1.00×** across
  the slate, ceiling 1.25×.

### Arming is evidence-shaped, not arch-shaped

A vector rung used to arm on `builtin.cpu.arch`, which answers a question nobody
asked: whether the kernel _compiles_. What the auction needs to know is whether
its bid means anything — and it does not, on a host with no calibration. So
`compose_armable` / `parabix_armable` are the conjunction of both facts (kernel
exists **and** this target was minted), and a rung with no evidence is not built
at all rather than built and priced with borrowed numbers.

## Which question a rung answers

The second axis, and the one where a mistake produces a wrong answer instead of
a crash. `lineMatch` asks _does the pattern match a substring of exactly these
bytes_, with `^`/`$` bound to the slice's own edges. `docMatch` asks the per-line
question _does any `\n`-delimited line of this buffer match_. They coincide only
on a `\n`-free haystack, and nothing in the ladder promises one.

So each rung declares a `Model`. A **byte** rung reads `\n` as an ordinary byte
and carries no anchor, so it serves both entries — `parabix` earns this from its
admission gate, which refuses every assertion and every class containing `\n`. A
**per-line** rung re-seeds at a terminator, which _is_ the document question and
is wrong for a slice; `compose` is one, because its `\n` table row maps every
lane back to start.

That is the rung KIND's model, and holding a whole kind to its worst case cost
real throughput, so an instance may prove better: `compose.lower` checks whether
the reset row is what the DFA would do on a `\n` anyway (unanchored, no `$`
resolved by the second table, and no live lane stepping `\n` into a live or
accepting state) and, when it is, publishes `sliceSafe`. `rungs.zig` looks that
method up by name at comptime, so a rung that never grows one is simply held to
its static model — conservative by construction. Measured worth of the
refinement on the production `lineMatch` (a same-`Regex` A/B — answer with the
tier armed, blank `re.rungs`, answer again — over 64 MiB / 1.74M lines of CPython
source plus Russian prose, min of 5, arms alternated, the two answers checked
equal inside the timing loop): **2.13–2.52×** on five slice-safe field patterns,
against controls at 0.94–1.05 where the tier correctly stands down.

`-U` (`pike/search.zig`'s `bufMatch`) is the third caller, and it asks the slice
question about a whole file. It consults the tier under exactly the guard the
DFA already sits behind there — an assertion-free program, where the buffer is
one haystack — and `lower.zig` withholds the tier only from assertion-bearing
multiline, which has no DFA to lower in the first place. Measured **4.84–11.42×**
on flat `-U` patterns, measured with non-matching tails so the scan covers the
whole buffer rather than a prefix.

## Which rungs actually arm

Every rung arms on the population it prices best, and the costed gate stands one
down at _compile_ time wherever a start-skip or the DFA would win — the point of
offers over booleans. Each claim below is a **committed, reproducible proof**
(`zig build <step>`) rather than a one-off scratch measurement, run against the
207.7 MiB corpus on this machine:

| Rung      | Proof          | Arms on / Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compose` | `compose-rung` | class-alternations, bounded digit/hex runs — every armed row agrees on the whole buffer. **The workhorse:** 6.76–6.82x on the class-alt family (\|Q\| 9–15), 3.3x on hex/digit (\|Q\| 17–22). Declines `uni-prop` (literal skip beats retiring) and `dot-star-chain` (build refuses; the ladder keeps the accelerated DFA). Also on `lineMatch` and `-U` for the instances that prove `sliceSafe`.                                                                                                  |
| `parabix` | `parabix-rung` | `emailish` `dot-lead` `alnum-alt` `bounded` `digit-run`, plus `word-gap`/`line-gap` assertions compose cannot serve. **Now armed.** 230,978 document verdicts byte-identical to the shipped ladder; s2p ~13.8 GB/s, full 2.5–5.65 GB/s (1.6–4.7x vs the negative-case DFA). Refuses `nested-star` (star-height 2) and `uni-class` (codepoint class).                                                                                                                                                |
| `sieve`   | `sieve`        | profitable quotients only. **Armed, and mostly self-declining.** 0 soundness violations over 1.60 B byte-positions; the costed gate now declines **6 of 9** as `unprofitable` — including `digit-40` and `iso-date`, which the pre-plane boolean armed. One row (`uuid`) still arms into a measured 0.89×, and the bench publishes it as a loss: the arithmetic is minted cycles, the residual is the selectivity estimate's memoryless byte prior. See [`../sieve/README.md`](../sieve/README.md). |
| `crest`   | `crest`        | literal-free class runs where the trigram extractor yields no requirement. Forced-class-run sieve: 0 false negatives across the corpus + 96,000 randomized (pattern, file) pairs; prunes 84–96%, up to 28.2x. Correctly near-1.0x (stands down) on wide single-class patterns like `word-3`.                                                                                                                                                                                                        |

Ahead of every rung sit the literal populations: an `.exact` literal-set decides
a whole line/buffer in one SIMD/Teddy/Aho scan with no automaton, and a
`.candidate` set (cover union or required literal) rejects a haystack outright
before any rung runs — `../program/lower.zig` builds it, `verdict.zig` dispatches
it. The lazy DFA's per-thread cache admits adaptively, so a pattern that would
thrash a fixed budget quits to the Pike VM instead of churning.

No rung is dormant: every one has a green proof on its own population, and the
costed offers are what let an unprofitable candidate lose to a cheaper rival
rather than arm unconditionally. Re-run the four `zig build` proof steps above to
refresh any figure before quoting it as current.
