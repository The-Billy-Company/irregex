# linear/sieve — the SP-quotient sieve

**A rung that can refute a match but never confirm one.** `scan` answers `.miss`
— proven, nothing in this haystack matches — or `.unproven`, and the ladder
falls through unchanged. There is deliberately no `.hit`: the machine it runs is
an _over-approximation_ of the pattern, so a survivor proves nothing and a
rejection proves everything.

[`../../../math/crest.zig`](../../../math/crest.zig) is the same shape one
abstraction down — it prunes whole DOCUMENTS by class-run length. This prunes
POSITIONS by automaton quotient, which is why it can front patterns crest has
no shape for.

## Why a quotient is sound

Partition the DFA's states so that the partition is **closed** under the
transition function: if `p ≡ q` then `δ(p,b) ≡ δ(q,b)` for every byte. This is
the substitution property (Hartmanis & Stearns, _Algebraic Structure Theory of
Sequential Machines_, 1966); the SP partitions of a machine form a lattice under
refinement. Any SP partition induces a well-defined quotient automaton on the
blocks, and if every block containing an accepting state is made accepting, the
quotient accepts a **superset** of the language. So:

> the real automaton reaches an accepting state ⟹ every quotient does.

Contrapositive: if any quotient fails to accept anywhere in the haystack, no
match exists. A conjunction of quotients is therefore a sound **necessary
condition** — and strictly stronger than either conjunct, because the kernel
asks for one position where _all_ of them accept, not for each of them accepting
somewhere.

## What is ours and what is not

The contract — over-approximate, reject early, verify survivors exactly — is
**not novel**, and the adversarial referee for this lane found it substantially
anticipated. It is prior art three times over:

- **Luchaup, De Carli, Jha & Bach, INFOCOM 2014** — CODFA / DFA-trees
  ([10.1109/INFOCOM.2014.6847977](https://doi.org/10.1109/INFOCOM.2014.6847977)).
  Their Definition 7 is exactly `|D'| < |D|` with `L(D) ⊆ L(D')`; matching stops
  at the first rejecting node and leaves verification to an exact matcher; the
  paper itself calls its shrunk DFAs "a special case of quotient automaton", and
  measured 4.7×. **This is the same idea.**
- **Češka, Havlena, Holík, Lengál & Vojnar, arXiv:1904.10786 (2019)** — a
  multi-stage cascade of small crude over-approximating NFAs, approximation
  chosen by a probabilistic model of the traffic.
- **Hyperscan `HS_FLAG_PREFILTER`** — shipping, for years: matches are a
  superset, the caller confirms with an exact matcher.

What this module claims as its own is narrow and deliberately so: the **SP-
lattice harvest** as the source of the approximation (rather than a hand-built
tree of shrunk DFAs or a learned model), the **≤16-state Sheng-resident
conjunction selection** that makes the filter cost one shuffle per byte with no
memory for state, and the **training-free compile-time selectivity gate** for
single-pattern per-byte scan. Nothing here observes traffic, learns, or disables
itself at runtime.

## Aborting when worthless

A filter that rejects nothing is not neutral — it is pure addition on every
byte, and its worst case is the case where everything survives to verification.
CODFA measured +26% in exactly that shape. Our own harvested selectivity is
**bimodal**, which means the hazard is live rather than theoretical: on the
lane's slate the sieve retires 99.98% of positions on one pattern and 37% on
another, with nothing in between that a single policy could straddle.

It is also decidable before the scan starts, and that is the mitigation.
`fallthroughRate` computes each quotient's stationary distribution over its own
transition table (Cesàro-averaged, so a periodic quotient converges) under two
byte priors — uniform and English-ish text — and the pessimistic one decides.
The sieve then arms only if fronting the decider is cheaper than the decider
alone:

```text
sieve  +  (1 - (1-f)^grain) · exact   <   exact
```

Three terms, each a measured number rather than a stand-in. `sieve` is this
candidate's own price from [`../ladder/price.zig`](../ladder/price.zig) at its
conjunct count **and** its grain — two axes, because `survives1`/`survives2` per
line and the four-lines-at-once `survivesDoc` are four different kernels that one
ratio could not tell apart. `exact` is whatever actually won the ladder's
auction, lifted to the grain being judged, so a sieve is weighed against the
machine it would really front instead of against an assumed dense DFA. And
because both sides are absolute cycles, the inequality stands the sieve down in
front of a cheap decider **on its own** — the outcome the old
`Above.skip_armed` boolean produced by prohibition, without needing to name the
rival.

This replaced `(1-f)^nominal_doc > speed_ratio`, which was the right _shape_ only
while one constant stood for both sides. That constant claimed the sieve was
2.5× the dense walk; measured, the buffer kernel is 0.742 cyc/B against the
walk's 1.199 — **1.62×**, and one conjunct per line is 1.201, i.e. no advantage
at all at that grain. Both numbers are minted by `zig build ladder-price`, and
`speedRatio` is now a quotient of them rather than a rival to them.

The arithmetic lives on `CostFact.pays`, which admission retains whether the
candidate arms or declines — so the gate, the census row, and the bench's
published banner are one expression instead of three that agree by hand.

### The residual is `f`, not the arithmetic

Six of the nine slate patterns now decline, and one still arms into a measured
loss (`uuid`, 0.89× the shipped ladder). That row is worth keeping visible,
because the bench publishing it is the only reason the defect is known — and
because the arithmetic above is not what is wrong. Every term in the inequality
is a minted cycle count; the input `f` is an estimate, and it is the estimate
that misses:

| pattern        | required run | est `f`  | measured `f` | optimism |
| -------------- | ------------ | -------- | ------------ | -------- |
| `alnum-alt`    | 1 class byte | 2.45e-2  | 2.62e-2      | 1.1×     |
| `two-Capitals` | 2            | 8.04e-2  | 1.06e-1      | 1.3×     |
| `iso-date`     | 8 digits     | 1.46e-3  | 9.45e-3      | 6.5×     |
| `uuid`         | 8 hex        | 4.32e-7  | 1.55e-2      | 3.6e4×   |
| `digit-40`     | 40 digits    | 7.32e-22 | 1.93e-4      | 2.6e17×  |

The pattern in that column is the diagnosis. `fallthroughRate` walks each
quotient's stationary distribution under a **memoryless** byte prior — every
position drawn independently — so a `k`-byte requirement is priced as `p^k`.
Real bytes are not independent: measured over this corpus's 3,564 text files
(399 MB), the probability that a byte's class repeats is 4–13× its marginal
share (digits 0.046 marginal → 0.364 persistent, 7.9×; spaces 13.1×). A
memoryless prior therefore under-counts every long run by roughly that factor
raised to the run length, which is precisely a residual of 1× at one byte and
1e17 at forty. No scalar correction covers a slate spanning seventeen orders of
magnitude; only a persistence-aware prior (a first-order chain over byte
classes, harvested the same way the quotient is) closes it, and that is a
separate piece of work rather than a knob on this one.

**That prior has since been built and measured, and the diagnosis holds.** It
lives in a separate Rust sheng sibling (not shipped in this repo) —
this rung ported onto `regex-automata`, done in a standalone crate precisely so
both residuals could be attacked without destabilizing the shipped ladder. The
chain carries the byte's **class** in its state and runs on (block, class) pairs,
so a `k`-byte run stops being priced `p^k`; under a memoryless prior it collapses
back to exactly this rung's arithmetic, which makes it a strict generalization
rather than a rival model. Minted over the same corpus, class persistence lands
in the same 1.3–66× band measured above (`Lower` 1.3×, `Digit` 20.8×, `High`
66×) — a transition matrix now, instead of a warning. On a thirteen-pattern slate
the ported gate classifies perfectly: three armed at 1.42×, 1.28× and 1.98×, ten
declined, every declined row independently measured below 1.0× when forced to
arm, geomean **1.532×** with no armed losses. Porting it back here is real work —
the chain has to be harvested beside `fallthroughRate`'s stationary walk — but it
is no longer a conjecture about what would close `uuid`.

The second half of the `uuid` loss is on the other side of the inequality: the
fronted eager DFA bids 1.37 cyc/B — its minted full-scan cost — and walks the
real corpus at 0.81, because a matching document exits early and a
`start_dwell` skips bytes a full scan pays for. So the sieve is credited with
retiring bytes that the machine it fronts was never going to walk. That gap was
tested for the obvious cause and it is not byte skew: re-minting every
coefficient against a haystack drawn from the corpus's own measured byte shape
moved `dfa_step` 2% (1.373 → 1.397, inside the clock's noise) while
destabilizing `dfa_line` and `anchor_line` by 2.7× and 2.3×. That experiment and
its refutation are recorded in
[`bench/rungs/price/probe.zig`](../../../../../bench/rungs/price/probe.zig).

**This one has a measured fix shape too, from the same port.** The Rust gate does
not price its rival at that machine's full-scan cost; it asks the engine which
bytes it intends to skip (`Automaton::accelerator` on the start state) and prices
the skip, plus an **excursion coefficient** for what a tripped skip really costs —
the engine enters the DFA, walks a run, returns, and restarts the scan, and the
restart dominates at that granularity. Omitting that term under-priced a
common-byte accelerator by 8×, which declined patterns that genuinely paid. The
coefficient was solved rather than chosen, by inverting the accelerated blend
across eleven lead bytes spanning two orders of magnitude of frequency; read at
byte-class resolution the eleven answers spanned 3.6–35.2, and at per-byte
resolution they collapsed to 7.06–11.78, which is the evidence that the term is
real and the spread was the approximation talking. The analogue here is the
`start_dwell` this rung already knows about but does not charge for.

Until both are ported the honest posture is the one the bench already takes:
publish the row, name it a loss, and let the gate stay fail-closed on the six it
gets right rather than widen it to hide the one it does not.

## Worth is a license per grain

Grain is load-bearing, and each grain is a **different kernel at a different
price**: `survives1`/`survives2` walk one line at ~1.27 cyc/B, `survivesDoc`
takes four lines at a time at 0.729, and on every row of the production slate the
buffer total comes out the cheaper of the two. So the inequality is evaluated
once per grain and the field is admitted if **either** pays, with each path
enforcing its own half — `lineSafe` before the ladder's line walk, `docSafe`
before it ever hands the rung a multi-line buffer.

That corrected a real disagreement. This README, the doc comment on
`nominal_line`/`nominal_doc`, and the bench banner all said arming was judged at
the buffer grain; `finish` gated on `.line`, the dearer kernel. Since the line
total exceeds the buffer total on every measured row, the effect was a silently
**stricter** gate: wherever the incumbent's price fell between the two totals,
the sieve was withheld from the document path — the path `docMatch` actually
takes, and the one the bench publishes. The premise the old wording rested on ("a
sieve serves both paths from one field, so it must pay at the harder grain") had
already been retired by `doc_ok`, which is exactly the per-grain license that
makes serving one path without the other safe; `lineSafe` is its missing twin.
Re-running `zig build sieve` after the change reproduced the slate exactly — same
6 of 9 declined, same single `uuid` loss, 0 violations over 1.60 B byte-positions
— because no pattern on it lands in that band. The defect was latent, and the
gate now matches what it publishes.

`doc_ok` remains two independent halves, and only the first is about correctness:
every state must reset on `\n` (a continuous run _is_ the per-line model) and the
buffer-grain inequality must hold. `line_ok` has no correctness half at all —
`scan` is valid on any haystack — so it gates the ladder and never an assert.
Per-position rejection still does not translate into buffer retirement:
`[0-9]{4}-[0-9]{2}-[0-9]{2}` rejects 99.03% of positions and keeps 80.6% of
documents, because dates cluster.

Failing the inequality at both grains leaves the field null. So do all three soundness refusals:
no register-resident shuffle on this target, no closed partition small enough,
and any `project` precondition the walk cannot honor.

## Files

| File             | Role                                                                                                                                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sieve.zig`      | The entry seam: `Verdict`, the compiled `Sieve`, the cost policy, and the four-part compile-time gate. The only file the ladder above needs to know about.                                                                                  |
| `quotient.zig`   | The harvest. `project` states the soundness preconditions and reduces the DFA to a walkable core; `harvest` climbs the SP lattice from the coarsest closed partitions and selects the conjunction; `fallthroughRate` estimates selectivity. |
| `sheng.zig`      | The register-resident kernel — Langdale's Sheng shape applied to a quotient. One `tbl`/`pshufb` per byte per conjunct, newline-split lanes for whole-buffer scans, and the scalar transcription the differential test holds it to.          |
| `sieve_test.zig` | Unit cases, kernel ≡ scalar agreement, the worthless-abort proof, and randomized differential fuzz against the Pike VM.                                                                                                                     |

The 16-wide shuffle itself is **not** here: it is `../../../scan/lanes.zig`'s
shared primitive, which imports nothing but `std` and `builtin` precisely so a
sibling rung can take the instruction without taking the rung.

## Proving it

`zig build sieve` walks the real host corpus and checks, at every byte position
of every document, that the DFA being in a matching state implies every quotient
accepting. One violation exits non-zero. It publishes the measured selectivity
beside the compile-time estimate that gates it — including the rows where the
sieve is worthless, because a table with no ≈0% row is hiding something — and
times the kernel against the shipped engine in the same run on the same machine.
