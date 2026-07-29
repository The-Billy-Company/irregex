The ladder's auction now settles in a currency someone minted. Every bid was a
hand-written literal — `30_000` for any DFA, `500 + 30_000/stride` for a skipping
one, `4_400`/`8_000` for composition, `9_000 + stripe_ops/8` for Parabix, and a
`speed_ratio` constant standing for both sides of the sieve's inequality — and
the sieve's arming condition still carried a `delete this when measured` comment.
An auction can be internally consistent in an invented currency and still buy the
wrong machine, which is exactly what it was doing.

**One plane, two halves that may not mix.** `ladder/price.zig` owns a
`Calibration` of measured cycles-per-byte coefficients, each minted on a named
machine on a named date, and a `price(Machine)` function that is purely
structural — it reads a pattern's own facts (skip stride, `^`, transformation
width, end-of-line index, stripe ops, conjunct count, grain) and multiplies. No
literal in the cost model is a performance claim and no coefficient knows what a
pattern looks like, so a port re-mints the calibration without touching a model
and a new rung adds a model without re-measuring anything. `unmeasured` exists
only so the arithmetic is total on an unported host, and it withholds `measured`
— which is what a vector rung consults before bidding, so arming is now the
conjunction of _the kernel exists_ and _this target was minted_ rather than an
`builtin.cpu.arch` check answering a question nobody asked.

**What the measurements changed, as opposed to confirmed.** One constant covered
the eager DFA, the lazy DFA and the Pike VM; measured they are 1.37, 9.52 and
29.57 cyc/B, a 25× range challengers were bidding blind into. `^` is a per-_line_
seed behind a `memchr`, not a per-byte walk — an anchored pattern was bid at 2.98
and measures 0.31, so composition kept winning auctions it lost by **2.82×** in
fact. Composition's `if (dfa.start_dwell != null) return null` gate was a boolean
standing in for an inequality it could not state; the stride-priced fallback now
outbids composition on strong-skip patterns and loses to it on weak ones, an
outcome the boolean could not express in either direction. And a pattern decided
_above_ the ladder by a literal set or a saturating class run is priced by the
kernel that actually answers, classified by which backend that kernel chose:
`memchr` at 0.073 cyc/B against Teddy at 0.517 is a 7.1× spread that one
`settle_literal` coefficient had been quoting as a single number, which mattered
because that price is the divisor in the sieve's survival inequality.

**A residency axis shipped and was refuted, which is the more useful half.** The
plane's first draft priced the walk by table footprint on the reasonable theory
that a table too big for L1 walks slower. The sweep built to fit that curve
killed it: a 1.4 MB table and a 216-byte table both walk at ~1.18 cyc/B, and the
whole six-point spread over a 19,000× footprint range tracks automaton shape. It
could not have been otherwise — the step is one dependent load from
`table[state·stride + class[byte]]`, so the working set is the rows a haystack
_visits_ times the classes it _uses_. The axis is gone and `Machine.walk` has no
footprint field to misuse, but the sweep stays in `mint`, printing its spread
every run, so a host that really is cache-sensitive shows the knee before
anything silently misprices.

**`zig build ladder-price` is the gate.** `mint` times each coefficient alone
against a fixed 8 MiB synthetic haystack (min-of-9, two-point fits where a cost
has both an intercept and a slope) and prints the calibration literal to paste
back; `verify` re-times and reports drift; `regret` ignores the model entirely,
builds _every_ machine each slate pattern admits, measures each, and fails when
the auction's pick is more than 1.25× off measured-best. Regret is what found
both mispricings above, and worst regret across the slate is now **1.00×**.
`mint` is deliberately not the default verb, for the same reason a verifier may
not produce the proof it judges. The whole lane costs no corpus load, no
multi-gigabyte table, and about twenty seconds.

**Downstream, the sieve gate declines two more patterns than it used to** —
`digit-40` and `iso-date`, both of which the pre-plane boolean armed — because
`selected_cost` now names the machine that would really front them instead of an
assumed dense walk. One row (`uuid`) still arms into a measured 0.89× and the
production proof publishes it as a loss rather than widening the gate around it:
every term in the inequality is a minted cycle count, and the residual is one
input — `fallthroughRate` prices each position under a _memoryless_ byte prior,
where real bytes cluster 4–13× above their marginal share, so its error is
exponential in the run a pattern requires (1.1× at one byte, 6.5× at eight,
2.6e17 at forty). Only a persistence-aware prior closes that, and it is its own
piece of work. The obvious cheaper fix was tried and refuted: re-minting every
coefficient against a haystack drawn from the corpus's own byte shape moved
`dfa_step` 2% while destabilizing `dfa_line` and `anchor_line` by 2.7× and 2.3×.
