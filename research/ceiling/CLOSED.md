# Closed roads

Each entry is a route past the [execution ceiling](README.md) that was
proposed, refereed, and shut — recorded so the argument is not repeated. The
form is deliberate: **what was claimed, what closes it, and what genuinely
survives**, because a killed idea usually leaves a residue and the residue is
the only part worth carrying forward.

Novelty was refereed by an independent adversary with a kill mandate _before_
any proof was attempted. Every entry below died in that pass, which is the
cheapest place to die.

## Two verdicts, never one

Every entry carries a **novelty verdict** and an **adoption verdict**, and
they are independent. Conflating them is the standing failure mode of a
research record like this one, so it is worth stating flatly:

> _Someone else got there first_ is a reason not to claim a result. It is
> never, by itself, a reason not to use one.

A forty-year-old theorem that nobody has implemented on SIMD is evidence the
math is **sound** — the most encouraging thing a prior-art search can return.
An idea dies for adoption only on a real engineering ground: a proven cost
blow-up, a measured loss, or a payoff shape absent from our corpus. Read each
entry for which of those it actually earned. All three below lose the priority
claim; only some of them lose the engineering argument, and those lose it for
reasons that have nothing to do with who was first. Entry 3 loses the claim and
keeps the build.

---

## 1. Cascade decomposition into parallel prefix scans

**Claimed.** Matching is a monoid morphism — μ(uv) = μ(v)∘μ(u) — so it is
associative, hence a scan rather than a loop, and the serial chain measured in
the README is an artifact of evaluation order rather than something inherent.
Krohn–Rhodes decomposes any finite transformation monoid into simple groups
and resets; Schützenberger's theorem says an aperiodic monoid (equivalently, a
star-free language) has no group factors at all, only resets; reset
composition is "last non-identity wins", which is a prefix scan with the copy
operator — branch-free and, crucially, needing no per-byte gather. Star-free
matching should therefore compile to a depth-_d_ pipeline of prefix scans
whose throughput is governed by _d_ rather than by |Q|.

**The two citations first offered against it do not hold.** Both were
re-attacked deliberately, and both failed — recorded here because a wrong
citation left standing is worse than no citation at all.

- **Chandra, Fortune & Lipton** (STOC 1983; JCSS 30(2):222–234, 1985) prove
  constant-depth polynomial-size circuits for group-free semigroup product,
  but in an **unbounded fan-in, non-uniform** model, and the size bound is an
  inverse-Ackermann trade-off — depth 4 at size 2n·log\*(n) in one
  instantiation against size nˡ in the generic Barrington–Thérien
  construction, three orders of magnitude apart in practical meaning. It is a
  classification, not an algorithm. The sharper theorem in the model that
  actually matters cuts the other way: **Bilardi & Preparata** (JACM
  36(2), 1989) characterize the prefix problem for _bounded_ fan-in Boolean
  networks and **lift the Ω(log N) time floor entirely for semigroups whose
  recurrent subsemigroup is right-zero** — the reset/flip-flop semigroup,
  which is precisely this mechanism. Their companion result shows constant
  depth at _linear_ size needs no monoidal cycle, strictly stronger than
  group-freeness. How network complexity scales with semigroup size is the
  authors' own stated open problem.
- **Maler & Pnueli** (FOCS 1990) give tight exponential bounds on holonomy
  cascade size for counter-free automata — worst-case over _all_ of them.
  Measured on regex-derived automata, it does not bind: across 229 patterns
  (208 harvested from this repository), 215 measured cleanly and **all 215
  were aperiodic**; cascade size came out linear in |Q| and per-level width
  never exceeded 7, comfortably under the 16-lane `vqtbl1q` bound. The single
  non-star-free pattern holds a genuine mod-3 counter. The pre-registered kill
  criterion — median literal-free depth above 8 — **passed**, at 4.0.

**What actually closes it, and it is none of the above.** The load-bearing
claim was that throughput is governed by depth rather than state count.
Measured, **depth ≈ state count**: median d/|Q| = 0.875, p90 = 1.000, and the
counter sweep is exact, with `[0-9]{k}` giving depth exactly k. The cascade was
then built rather than argued about — a fair NEON implementation with
carry-independent block-local scans reaches 0.33 cycles/byte per level, which
matches its op count at peak issue rate, so there is no implementation slack
left to find. Break-even against the shipped engine arrives at depth ≈ 11, and
against plain 4-way DFA interleaving at ≈ 6. The idea dies empirically, on its
own central premise, rather than on anyone's theorem.

**Residue — and the first item is now a live result, not a hope.**

- **A conjunction of small SP-partition quotients is a sound, gather-free
  sieve, and it works.** Any closed (substitution-property) partition yields a
  quotient accepting a superset, so a conjunction of ≤16-state quotients is a
  _necessary condition_ — a filter, to which no decomposition lower bound
  applies. Verified sound on 671M byte-positions with zero violations; five of
  ten patterns reject ≥99.4%, three are _exact_, one is worthless. The
  distribution is bimodal, which is the good case, because it is decidable at
  compile time. **Soundness is a theorem and survives the provenance warning
  below** — every SP-partition over-approximates whatever DFA it quotients, so
  a merged alphabet yields a sound sieve for a different language, never an
  unsound one. **The selectivity percentages do not survive it**: rejection
  rates are per-pattern measurements, and the two-classes-in-sequence patterns
  are exactly the ones the merge corrupts. Treat the bimodality as the
  load-bearing claim and the specific rates as provisional until re-measured
  against the real engine. The Sheng-form NEON kernel measured 2.5–3.0× the full DFA.
  This is the shipped `crest/` sieve one abstraction up — crest prunes
  documents by class-run length, this prunes positions by automaton quotient.
  **Refereed as substantially anticipated, and worth building anyway** — see
  below.
- **The morphism itself was never refuted — only the decomposition — and it
  then measured 7.0×.** A transformation Q→Q is a |Q|-byte vector, and
  composing two of them is `(f∘g)[i] = f[g[i]]`, a single `vqtbl` byte shuffle
  on AArch64: the monoid formulation with nothing decomposed, which no
  citation above reaches. Built and measured at **1.94 B/cycle against a
  same-machine 0.276 baseline** on the 9-state no-skip pattern, byte-identical
  over 317,940 differential cases. Two premises died with it. _Composition
  does not cost more than a fold_ — matching is a **reduction, not a scan**,
  and a tree reduction over n leaves has the same n−1 combines as the serial
  fold, so re-association buys a quarter of the dependency depth for free and
  saturates at chunk 4. And the ceiling is not cache: the widest table is
  32 KiB of a 128 KiB L1D. It is the **`TBL4` instruction at |Q| = 31**, where
  a 64-lane composition needs four `TBL4`s at ⅓ throughput and the bottleneck
  flips from load port to shuffle port in a single step.
- **~~One unclosed gap could bring the whole idea back.~~ CLOSED, with
  equality — and the entry above is wrong about why Weir died.** The gap was
  stated as holonomy's depth ≈ |Q| against a floor of about log₇|Q| ≈ 2, "13×,
  unclosed in both directions". A follow-up lane closed it from the floor side
  and found the statement understated its own case twice over.

  **The 13× was an artifact of the decomposition algorithm, not a fact about
  the algebra.** Permitting a saturating-counter factor collapses the counter
  chains from depth exactly _k_ to exactly `ceil(log₁₆(k+1))` — 1 or 2 for
  every _k_ from 2 to 64, across `[0-9]{k}`, `[a-z]{k}` and `.{k}`. That is not
  merely better than _k_; it is **the information-theoretic floor attained with
  equality**. `[0-9]{40,}` goes from holonomy depth 40 to depth 2. The
  bounded-gap family refutes it independently: `.*a.{k}` has |Q| = 512 at
  serial depth 0. So "depth ≈ |Q|" measured holonomy's output, and holonomy is
  one algorithm rather than a lower bound.

  **The denominator was also wrong, in the direction that flatters the kill.**
  The 7 in log₇ was simply the widest level holonomy happened to emit; the real
  cap is the NEON shuffle table at 16 or 64. The true floor is _lower_ than
  quoted, so the gap the entry reported was understated. Three replacement
  bounds are proved and machine-checked, and the honest frontier is that
  **nothing forces scan depth ≥ 2 on any specific automaton.**

  **The revival still fails its own corpus bar, which is why this stays
  closed.** Median corpus depth improves 10.0 → 8.0 and the fraction under
  depth 6 goes 27.9% → 45.1% — short of the pre-registered "below 6". That
  median is bimodal: on the 50 patterns where the synthesizer found a cascade
  it is **depth 2.0, 98% under 6, a projected ~10× over the shipped DFA**, but
  42% of the corpus fell back to holonomy, 89 of those 91 from a single shape
  (literal prefix then unbounded run over a wide alphabet). That is a limit of
  the search, not of the algebra, and the lane explicitly declines to claim the
  bar would clear if it were fixed.

- **What survives is a compiler pass, not an engine.** The counter factor _is_
  Parabix's `MatchStar`: every level of every interesting cascade came out
  width 2, i.e. one bitstream, and a width-2 affine-reset scan is exactly one
  long-stream addition. **There is no second kernel to build.** But the two
  _compilers_ genuinely differ — Parabix walks the syntax tree and pays star
  height as runtime fixpoint iteration, while the cascade starts from the
  minimized DFA, where determinization has already erased star height. The
  exact expression that collapses Parabix to 0.061 B/cycle has a **6-state DFA
  and a verified depth-5, all-width-2 cascade: a projected 0.74 B/cycle, ~12×
  Parabix and 2.7× our own DFA**, oracle-checked at 12,804 byte positions.

**Novelty: anticipated as a classification, and the classification is
encouraging.** **Adoption: the cascade-as-engine stays dead, but it dies of a
failed corpus bar now, not of the depth law this entry first cited.** The
correction matters more than the verdict it leaves standing. Weir was recorded
as dying on its own central premise — that depth beats state count — and that
premise was never actually tested: what was tested was one decomposition
algorithm's output, which a counter factor beats by up to 20× down to the
proven floor. Reopening requires clearing the corpus bar, not re-arguing depth.
The residue that ships is the DFA→cascade **front-end** for the Parabix
back-end, gated on star height ≥ 2 with a small minimized DFA.

> **Measurement provenance warning.** The corpus statistics in this entry — the
> `d/|Q|` medians above, and any per-pattern row from the re-attack lane —
> come from a pipeline whose `byte_classes` keyed its alphabet-compression
> signature by each state's _local_ edge index, so two states' first edges
> collided and distinct classes merged. Reproduced: `[A-Za-z]+[0-9]+` compiles
> to a single 62-byte class holding both `a` and `5`. **Single-class patterns
> such as the `[0-9]{k}` counter sweep are unaffected** (one class cannot
> merge with itself), so the exact-_k_ and exact-`log₁₆` results above stand;
> multi-class corpus aggregates do not. The follow-up lane's numbers come from
> a corrected pipeline validated at 61,215 byte-positions against Python `re`.

### Third look: the front-end priced, and the bar restated as a coefficient

The residue above shipped as a recommendation, never a measurement. Both prior
closures were about cascade-as-an-**engine**; neither priced the **front-end**,
so "reopening requires clearing the corpus bar" was a bar for a different
machine. It has now been priced in the currency the ladder actually bids in.

**The realizable population is 6 patterns.** Of 1,076 regexes harvested from the
tree (1,047 parseable), 179 are refused by `admit.zig` on AST shape and 13 for
star height specifically. Of 186 shape-refused patterns put through the depth
lane's synthesizer, 24 got a verified cover, 14 had a real scan level, and 6
carried no residual `newline_class`/`unicode` refusal of their own. Two of the
six are the same language spelled two ways, so it is 5 distinct problems.

**The bar.** The eager DFA sits at `dfa_step = 1.373` cyc/B — 2,533 stripe ops at
`parabix_op = 0.555` over `stripe_width = 1024`. The transposition alone is 832
of those (0.451 cyc/B) and is the floor for anything in the Parabix family.
Lowering each synthesized cascade into `stripeOps`' own currency puts 4 of the 6
over that budget and the other 2 at 1.11× and 1.01×, against a static model whose
worst error against the rung's published table is 13.4%. Neither is a win worth a
rung.

**The re-entry condition.** Every pattern in the slice clears the DFA at
`parabix_op ≤ 0.241`. One of the six is separately hard-refused — its derived
levels need 44, 65 and 66 gates against `stencil.max_gates = 40`, which no op
price touches — and the remaining five clear at **`parabix_op ≤ 0.444`**, a 1.25×
cheaper op. That is the number a fourth look should test, and testing it needs no
re-derivation: re-price the slice against a freshly minted coefficient.

**Where the cost is.** Not the levels — the **class streams**. A cascade is built
over the DFA's byte-class partition, which is finer than the two or three literal
class terms a regex writes, and each cell costs 34–139 ops per block. Three to
seven of them plus the 832-op transposition exhausts the DFA's whole budget
before a single level runs. That is also why the shipped gate looks as it does:
`max_classes = 6` and the star-height refusal keep Parabix on patterns needing
two or three class streams.

**Is 1.25× available? Not on the obvious route.** `parabix_op = 0.555` against
~0.25 cyc for a 128-bit NEON op on four vector pipes leaves ~2.2× on paper, and
`parabix/README.md` books ~3× against the research lane. That gap was originally
diagnosed as the generic class-circuit interpreter; the diagnosis is wrong, and
`parabix/README.md` now records why — every class in the measured family is a
catalogue shape that returns from `Circuit.eval` before the gate loop, so the
interpreter is dead code for exactly the patterns the ~3× was measured on.
Static instruction counts locate the real cost: the striped path
(`Parabix.match`, with `stripe` and `transposeStripe` inlined) carries 3,224
spill instructions against 6,446 vector ops, where the per-block path carries 22
against 1,099 — a `[8]plane.Wide` basis is 64 q-registers against a file of 32,
where `[8]plane.Basis` is 8. The inference that the class phase should therefore
run at block grain **is already refuted**: `plane.zig` records that exact
argument being made, benched and lost, because gate dispatch is scalar work that
a spilled vector load is cheaper than. Per-block vector op counts are identical
across grains (1.00–1.02×), so the grain trades spill traffic for dispatch and
the bench says the stripe wins that trade.

**So the front-end is downstream of the emitter, and the emitter has no cheap
rung left.** This stays closed, but the condition is now a coefficient rather
than a corpus verdict: `parabix_op ≤ 0.444`, earned by beating the interpreter
*without* changing the grain.

---

## 2. A unified register algebra for counting and captures

**Claimed.** Counting-set automata hold _sets_ of counter values in registers;
tagged deterministic automata hold _position tags_ in registers. Both restrict
register updates precisely so that determinization stays polynomial. So there
should be one determinizability criterion covering both, letting bounded
repetition and capture groups live in a single determinized machine — the
composition the counting literature lists as open.

**What closes it.** The restriction already exists under three names. Alur,
D'Antoni, Deshmukh, Raghothaman & Yuan, _Regular functions and cost register
automata_ (LICS 2013) define copyless CRA and gloss it verbatim as the
"single-use restriction". Bojańczyk & Stefański (ICALP 2020) make single-use a
headline theorem — it is exactly what restores the constructions that fail for
unrestricted register automata. Decisively, Holík, Síč, Holíková & Vojnar
(FoSSaCS 2023) already apply that restriction **to counting-set registers**:
their non-replication condition and its linear-simulation theorem _are_ the
proposed contribution. The same group's Register Set Automata (PLDI 2026)
publish a general set-valued-register determinizability criterion.

**And the second half is not merely anticipated, it is false.** Tagged
determinization _requires_ the register replication that counting-set automata
_must forbid_, and survives only because tagged registers are persistent
prefix trees where copying is O(1) — a device counting-set automata cannot
adopt, because their amortization argument depends on discarding the source
list after a merge. So genuine counting-plus-captures composition should be
expected to cost a **log factor per byte** rather than being free. That is a
sharper and falsifiable statement of the obstacle than "it is open", and it is
the one new thing the attempt produced. Worth noting separately: the counting
and tagged-submatch literatures have never cited each other in either
direction, so the gap is sociological rather than an unclaimed theorem.

**Residue — and why we are not building counting automata.** The payoff shape
was measured and then looked for, and it is not in our corpus. Bounded
repetition only cliffs on the bounded-_gap_ form `.*a.{n}z`, which
determinizes to exactly 2^(n+1) states and falls off the eager driver at
n = 16; at n = 1000 on adversarial input it runs 0.4 MiB/s, roughly 1900×
slower than n = 8 — while showing no cliff at all on benign input. A census of
first-party patterns for that shape returns essentially nothing: one
`^`-anchored open-ended repetition, which is linear rather than a powerset
blow-up, and our own adversarial syntax test. The class-bounded forms that
_are_ everywhere — `[0-9a-f]{32}` trace ids, `[0-9a-f]{12}` — are the
provably-linear families, and the first of those is already the shipped
`crest/` sieve's home ground at 27.8×.

Counting-set automata were therefore costed (≈5–7 kLOC, one to two
engineer-months, dominated by a doubly-exponential determinization that can
abort, plus a mutable-register model that conflicts with the scratch-free
shared-automaton invariant) and **declined**. The cheap substitute is to adapt
the eager state ceiling for the provably-linear families.

One further escape, noted for the record: a bit-parallel NFA makes this cliff
vanish without any of that machinery, since `.{n}` costs n _bits_ rather than
2^(n+1) states.

**Novelty: dead.** **Adoption: declined on the census, not on the citations —
and the citations are an asset.** The prior art here is a _finished, published
criterion_: if we ever do want counting or determinized captures, non-
replication and copylessness are specifications to implement rather than
mathematics to invent, which makes the work smaller than it would have been.
What actually declines it is that the cliff shape is absent from our corpus.
Should that change — should bounded-gap patterns with n ≥ 16 start appearing —
this reopens immediately, and reopens cheaply.

---

## 3. The quotient sieve — novelty closed, adoption green

Listed here because its _priority claim_ is shut, not its engineering case.
This is the one entry on the page we intend to build.

**Claimed.** A conjunction of ≤16-state SP-partition quotients as a sound,
register-resident, gather-free prefilter (the residue of entry 1, measured
there: zero soundness violations over 671M byte-positions, ≥99.4% rejection on
five of ten patterns, three exact, 2.5–3.0× the full DFA's kernel speed).

**What closes the claim.** The logical core — a compact over-approximating
automaton as a sound reject stage in front of an exact verifier — is
established three times over.

- **Luchaup, De Carli, Jha & Bach**, INFOCOM 2014 ([CODFA / DFA-trees](https://doi.org/10.1109/INFOCOM.2014.6847977)):
  Definition 7 is `|D′| < |D|` with `L(D) ⊆ L(D′)`; matching stops at the first
  rejecting node and leaves verify. The paper explicitly describes its shrunk
  DFAs as "a special case of quotient automaton". Measured 4.7×.
- **Češka et al.**, [arXiv:1904.10786](https://arxiv.org/abs/1904.10786) (2019):
  a multi-stage cascade of small crude over-approximating NFAs feeding more
  precise stages — the architectural twin of a conjunction of small
  over-approximations.
- **Hyperscan `HS_FLAG_PREFILTER`** ships exactly this contract: matches are a
  superset, to be confirmed by an exact matcher. Hyperscan also ships Sheng for
  ≤16-state DFAs.

Two corrections to the record, both worth stating plainly. Our own
`crest/PRIOR_ART.md` does **not** contain this kill — crest signatures are a
different object (class-run lengths, not quotients), so the survey we already
own gave no warning. And the claim that production prefilters are all
literal-based is **false**; `HS_FLAG_PREFILTER` is an automaton-level
over-approximation in a shipping product.

**Residue that may still be claimed** — and it is thin: harvesting the SP
partition _lattice_ specifically, selecting a Sheng-resident conjunction from
it, and gating on a training-free compile-time selectivity estimate for
single-pattern per-byte scan. Not the filter contract, which is not ours.

**Novelty: substantially anticipated.** **Adoption: build it.** The prior art
is the strongest argument _for_ the technique — CODFA measured 4.7× on the
same shape, and the failure modes are already mapped rather than waiting to be
discovered. The known one is a worthless filter that rejects nothing and
becomes pure overhead when everything survives; our bimodal selectivity
distribution is exactly that hazard, and it is decidable at compile time,
which is the mitigation. Build the residue, cite the rest.
