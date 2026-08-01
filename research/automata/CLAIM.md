---
doc_radar:
  sentinels:
    - description: "C1 landed: the dependent load is gone, replaced by a bound and one compare. C2's target — the second table — is still there."
      file: src/kernel/regex/linear/dfa/dfa.zig
      contains:
        - "match_hi: u32"
        - "pub inline fn isMatch"
        - "trans_fin: []const u32"
      absent:
        - "is_match: []const bool"
    - description: "C1's permutation, and the one place every producer now establishes the layout invariants — in automata/, which belongs to neither road that builds an automaton"
      file: src/kernel/regex/linear/automata/freeze.zig
      contains:
        - "fn sortMatchFirst"
        - "Match-first renumbering"
        - "belongs to neither and serves both"
    - description: "C3 retired, and DELIBERATELY still here: the bulk clear is the measured-correct algorithm, because closure width exceeds the word count in every wide row. A sparse clear replacing this line would be a regression."
      file: src/kernel/regex/linear/dfa/subset.zig
      contains:
        - "@memset(s.visited, 0)"
    - description: "C3's retirement instrument: the visit count rides out of determinization on the automaton, so mean closure width is a standing column rather than a one-off probe"
      file: src/kernel/regex/linear/dfa/dfa.zig
      contains:
        - "visits: u64 = 0"
    - description: "C4's target: the engine still asks for the START state's dwell only, which is what leaves the interior claim open"
      file: src/kernel/regex/linear/automata/freeze.zig
      contains:
        - "The start state's skippable dwell"
        - "dwell.ofStart("
    - description: "C4's instrument: the survey takes the profitability bar as an argument, which is what separates a shape refusal from a threshold refusal"
      file: src/kernel/regex/linear/automata/dwell.zig
      contains:
        - "pub const min_profitable_stride: u16 = 32;"
        - "pub fn survey(d: *const Dfa, out: []Skippable, min_stride: u16) Census"
        - "unprofitable,"
    - description: "C4's premise is measured on documents that ENTER an interior dwell, not the search slate whose fills park the walk in start"
      file: bench/rungs/automata/bench.zig
      contains:
        - "const dwell_slate = [_]Row{"
        - "fn elidableBytes"
    - description: "C5's real core: ONE file owning both quotient dimensions, with the one-way ordering that is the whole reason they are one file rather than two passes a caller sequences"
      file: src/kernel/regex/linear/automata/reduce.zig
      contains:
        - "pub fn run("
        - "rows first, then columns"
    - description: "C5 landed on the road whose redundancy is structural: the symbolic product reduces, and the pass it used to own is gone into automata/"
      file: src/kernel/regex/linear/symbolic/transcribe.zig
      contains:
        - "reduce.run("
      absent:
        - "minimize."
    - description: "C5 declined on the byte road, and DELIBERATELY still absent: the determinizer freezes Classes.build's partition unchanged, because a collapse here was measured not to move the walk"
      file: src/kernel/regex/linear/dfa/powerset.zig
      contains:
        - "No quotient runs here"
      absent:
        - "reduce.run("
    - description: "C5's retirement instrument: the UTF-8 trie population is measured APART from the ASCII one, and the verdict is a timed walk on both tables rather than a byte count"
      file: bench/rungs/automata/bench.zig
      contains:
        - "const trie_slate = "
        - "fn scanRatio"
        - "const Lowering = enum { ascii, trie };"
    - description: "C8 retired and DELIBERATELY unbuilt: no deserializer exists, and the two layout properties that made a trusted one cost an O(states x classes) validation sweep are exactly the two C1 depends on, so softening them to enable serialization is the trade this retirement forbids"
      file: src/kernel/regex/linear/dfa/dfa.zig
      contains:
        - "entries are premultiplied targets"
        - "The transition tables are NOT total"
      absent:
        - "from_bytes"
        - "fromBytes"
---

# Claim — what is ours, and what we take

Two claims of authorship and eight of intent. The authorship claims are what
already exists here and nowhere else; the intent claims are ordered by whether a
single function's profile can prove them, not by the size of the prize. A win you
cannot attribute to one function is a win you cannot defend against the next
regression.

**All nine carry measured numbers now**, all cited into
[`bench/rungs/automata/`](../../bench/rungs/automata/README.md) — and most did not
survive the measurement. C1 landed at 1.10–1.16× geomean and C6 at 2.32× coarser for
a 2.38× smaller table. **C2, C3 and C4 were retired by the harness built for C1**;
**C5 was retired on the byte road while landing on the symbolic one**; C7 found its
finding half already shipped and landed the offset it was discarding at 16.30×; and
**C9 and C8 were retired last, both on premises that were TRUE** — which is the
harder and more useful kind of retirement. Their sections keep the full mechanism,
the numbers, and the reason, because a claim killed by evidence is the cheapest kind
of progress in this file and deleting the corpse would invite someone to have the
same idea again next year.

The pattern across the retirements is worth naming, because it is the same mistake
most of the way down: each proposed a mechanism whose *premise was a table property*,
and every one of them died on the walk. Area is free at constant breadth (C2); a
sparse clear loses to a bulk one when closures are wider than the bitset (C3); a
skip's ceiling is what the document does, not what the automaton allows (C4); and a
smaller table is not a faster one, even at a quarter-megabyte (C5). A claim in this
lane is not credible until it has been timed against bytes.

**The last two failed one rung up, and name a second mistake.** C9 and C8 both had
premises that survived audit — the literal dispatcher really does ignore the
corpus-priced economics, and the finished table really is serializable — and both
still died, because each named the wrong *currency*. C9 proposed to gate a nine-byte
needle on a statistic calibrated for a byte-class skip. C8 proposed to cache a
construction without ever pricing the cache: measured, the median table is cheaper to
build than to read. So the second rule beside "time it against bytes" is **price both
halves of an exchange** — a claim that measures only the cost it removes, and not the
cost it adds, is not yet a measurement.

**A claim in this file without a citation into `bench/` is a hypothesis wearing a
claim's clothes.** [`TESTING.md`](TESTING.md) says what would have to be true of
each; with C8 closed, none are left in that state.

## Claims of authorship

**A1 — The SP-quotient sieve is ours.** A deliberately non-language-preserving
quotient of the DFA, climbed *past* Myhill-Nerode into the coarse end of the
Hartmanis-Stearns lattice, used as a refutation-only gate. RE2 and
`regex-automata` both minimize (or offer to); neither over-approximates. The
existing proof is [`../crest/PROOF.md`](../crest/PROOF.md)'s neighbor in spirit:
soundness is one-directional and must stay that way.

**A2 — Determinization over a predicate alphabet, transcribed back to bytes.**
`symbolic/` builds minterms of codepoint predicates, determinizes over them, then
products the result with a UTF-8 decoder. The alternative everyone else runs is a
byte-level range trie re-walked per class. This follows D'Antoni & Veanes rather
than Cox, and it is the only symbolic-automata implementation in a production
grep that I know of.

Both stay claims of *construction*, not of speed. The speed claim is C6.

## Claims of intent

### C1 — One compare replaces the per-byte dependent load — **landed**

**Mechanism.** Renumber DFA states at build time so every match state precedes
every non-match one, then answer "did we match?" with `s < match_hi`. The loop
used to do `is_match[s]` — a second load, on the byte immediately after the
transition load that produced `s`, which is maximally unhidable latency; and into
an array that was `ncls`-sparse by construction, one live byte per row, so the
line it pulled in was mostly padding.

**Why ours is better than theirs.** `regex-automata` reaches the same compare by
shuffling its *special* states — dead, quit, match, accelerated, start — into a
contiguous prefix and testing `id <= special.max` (`dfa/special.rs`). It needs a
power-of-two stride to recover an index from a premultiplied ID, and pays for
that padding in every row of every table. We need neither. Premultiplication
`s = id · ncls` is monotone in `id`, so a contiguous ID range is a contiguous
offset range at **any** stride; and one bound suffices, because the low end is
zero. We took the trick and kept the smaller table.

**Measured.** `zig build automata-rung`, 13 patterns that reach the eager tier,
8 MiB match-free document each, min-of-9 interleaved rounds, scalar per-line walk.
Geometric mean **1.10 – 1.16×** over seven runs on a laptop carrying ten coworker
agents. Split by regime, which is the part that matters:

| Regime                   | Example rows                                | Speedup       |
| ------------------------ | ------------------------------------------- | ------------- |
| Self-loop (`seen` = 1)   | `a.*b.*c`, `panic\|0x`, `;$`                 | 0.98 – 1.19×  |
| Wandering (`seen` ≥ 9)   | `[0-9a-f]{8}-[0-9a-f]{4}`, `[0-9a-f]{32}-`   | 1.20 – 1.27×  |

**The self-loop band starts below 1.0, and it is stated that way on purpose.** A
state that never changes turns the removed load into a perfectly-predicted L1 hit
with nothing left to win, so those rows price the *instruction* against measurement
noise, and one of them (`\d+\.\d+\.\d+\.\d+`) came in at 0.979× on one run of three
— 1.044× and 1.057× on the others. Reporting that band as 1.06–1.13× because the
lowest sample was inconvenient would make the number an advertisement. The honest
reading is that the self-loop regime is at parity and the win is entirely in the
regime that walks.

The wandering rows price the recurrence, and they are the shape `crest` already
cares about — a long class run no prefilter can skip. Both arms walk the same
automaton in the same process, and the load arm reconstructs the old array from the
shipped bound, so they are one machine rather than two that ought to agree.

**Cost.** A permutation applied to every table, plus a remap of the start IDs and
the dead ID. Build-time only, and it moves rows by cycle-following so the scratch
is one row rather than a second copy of every table. The renumbering is an
isomorphism and stable inside each group, so discovery-order locality survives.

**What it also bought.** The permutation has to run *before* start acceleration
(which reads state identities) and start acceleration *before* premultiplication
(which destroys them). That ordering was previously transcribed twice — once in
`powerset.zig`, once in `symbolic/transcribe.zig` — giving every layout invariant
two chances to be established and one chance to be forgotten. It now lives once,
in `freeze.zig`, which is the last operation on any determinization.

### C2 — An EOI column instead of a duplicate table — *premise measured and retired*

**Mechanism.** Reserve one alphabet slot for end-of-input and drop `trans_fin`.
Today we carry `trans_in` and `trans_fin` — and their word-context twins — so the
last byte can behave differently for `$`. That is a full duplicate of the table
area to encode one column's worth of information.

**What was claimed, and what the measurement did to it.** The claim above rested
on one inference: *"Area is L1 residency; residency is throughput."* That premise
is false in the regime our automata occupy, and the area sweep in the rung
(`zig build automata-rung -- area`) says so directly.

The sweep prices `[0-9a-f]{k}-` over a match-free hex document, k doubling to the
parser's `max_repeat` ceiling — an 85× growth in table bytes. Each row is priced
twice, because a single column cannot distinguish a cost that tracks the table's
*size* from one that tracks the part of it the walk actually *touches*. A hex run
cannot outlast the line it sits in, so the line length is a clean ceiling on
touched breadth:

| k | dfa | hot B | total B | clipped (48 B lines) | full (640 B lines) |
|---|---|---|---|---|---|
| 4 | 6 | 72 | 144 | 5 seen · 0.738 | 5 seen · 0.800 |
| 32 | 34 | 408 | 816 | 33 seen · 0.746 | 33 seen · 0.809 |
| 64 | 66 | 792 | 1584 | 48 seen · 0.710 | 65 seen · 1.159 |
| 128 | 130 | 1560 | 3120 | 48 seen · 0.732 | 129 seen · 1.246 |
| 512 | 514 | 6168 | 12336 | 48 seen · 0.725 | 513 seen · 1.208 |

Hold touched breadth constant and the table can grow 85× for **free** — the
clipped column has no trend at all, wandering inside 0.65–0.78 ns/byte end to end
with its *lowest* reading at the largest table. Let breadth grow and cost rises
once, precisely where `seen` passes the clip, then goes flat again from 129 to 513
states. The two columns are the control and the treatment, and only one of them
moves: the clipped spread is run-to-run noise on a shared laptop, while the full
column's step at k=64 reproduces in position and size on every run.
**Cost tracks breadth, not area.** Which is the answer to C2,
because halving the table does not narrow a single walk: `trans_fin` is read once
per line, not once per byte, so the duplicate never occupied the hot path whose
throughput the claim was about.

**Status.** Retired as a throughput claim. It survives as a **memory** claim —
resident bytes for the eager tier genuinely halve, which is worth having on its
own terms for the same reason a smaller binary is — but it must be argued and
measured as memory, not smuggled in as speed. Ranked below C3/C4 accordingly, and
the risk below is the price of a benefit we now know is not throughput.

**Risk.** The `$`/`\z` and CRLF distinctions currently live in the second table's
*shape*. They have to move into the gap predicate without widening it. If they
cannot, the claim dies here and gets recorded as closed.

**What this retirement is worth.** The one-column sweep would have shown a step
at k=64 and been read as "area starts to bind past 800 bytes" — which is the
conclusion that justifies building C2. The second column is what turned a
plausible story into a false one, and it cost one extra loop.

### C3 — Sparse-set closure, not `@memset` — *retired: the two conditions cannot co-occur*

**Mechanism.** `subset.zig` clears `visited` and `out` with a full `@memset` per
closure step — O(states/64) words touched regardless of how many states the step
actually visited. On a wide NFA with a narrow closure that is nearly all waste.
Replace with a Briggs-Torczon sparse set (dense array plus index array,
membership in O(1), clear in O(1) by resetting the count) or, if the double array
costs more cache than it saves, a generation-stamped array.

**It has two premises, and the claim needs both.** The `@memset` clears
`wds = ceil(nfa/64)` words, so the waste is `wds` **minus** what a
visit-proportional clear would cost. Reclaiming anything therefore requires `wds`
to be *large* and the closure to be *narrow*. Either alone is nothing: at `wds=1`
the memset is a single store, and at closure-width ≈ `wds×64` the bitset is
already carrying about one bit per visited state, which is what a bitset is for.

**Both premises were measured, and they are anti-correlated.** The rung's `build`
section now reports `wds` beside `vis/step` — mean closure width, from a `visits`
count the automaton carries out of its own determinization:

| pattern | nfa | wds | vis/step | ns/step | memset share |
|---|---|---|---|---|---|
| everyday slate (27 rows) | 3–37 | **1** | 1.8–50 | 56–287 | one store |
| `(?:foo\|bar\|baz\|qux\|quux\|corge){8}` | 209 | 4 | 54.9 | 136 | 7.3% |
| `\w{100}` | 101 | 2 | 155.0 | 333 | 1.3% |
| `(a\|b\|c\|d\|e\|f\|g\|h){10}` | 151 | 3 | 277.9 | 595 | 1.1% |
| `[0-9a-f]{512}-` | 514 | **9** | **686.0** | 968 | 1.3% |

Every row with a large `wds` has a closure *wider than its whole NFA* — 686 visits
over 514 states, because an unanchored walk re-seeds the start each step, so live
positions accumulate. A sparse or generation-stamped clear costs O(visits) and
would be **14× to 75× more work than the `@memset` it replaced**, in every wide row
measured. The existing bulk clear is not the lazy choice; it is the correct one.

**Why they cannot co-occur, which is the real result.** An NFA is wide *because*
the pattern has many positions, and many positions is exactly what makes closures
wide — a bounded repeat's `{n}` states are all live at once mid-run, an
alternation's branches are all live until they disambiguate. "Wide NFA, narrow
closure" describes a program with a large unreachable region, and Thompson
construction over a parsed pattern does not produce one. The condition C3 needs is
not rare here; it is close to structurally impossible.

**What the crate's own architecture already did.** The ~10³-state NFA the `visits`
doc comment cites — a Unicode class's UTF-8 range trie — is the one shape that
*would* have satisfied both premises. It never reaches `subset.zig`: `\p{L}+`
lowers to a 1592-state **codepoint** automaton owned by
`symbolic/determinize.zig`, which is determinized over scalar ranges and only then
transcribed to bytes. The width that motivated the claim was designed out of this
determinizer's path before the claim was written.

**Status.** Retired, and the instrument is kept. `visits` now rides on the frozen
automaton (`freeze.Shape.visits` → `Dfa.visits`) instead of living only where the
eager budget could see it, so `vis/step` is a standing column rather than a
one-off probe. If a future lowering ever does hand this determinizer a wide NFA
with narrow closures, that column shows it and the claim reopens on evidence.

### C4 — A skip out of every skippable dwell, not just the start — *premise true, ceiling measured, threshold already right*

**Mechanism.** A state the scan sits still in is a **dwell**, and the bytes that
leave it are its **exit set**. A dwell with a narrow exit set can `memchr` its way
out instead of walking. We derive this for the unanchored start state only, so
every interior `.*` or `[^"]*` run walks byte by byte through a state that has one
way out. The derivation now lives in
[`linear/automata/dwell.zig`](../../src/kernel/regex/linear/automata/dwell.zig),
which answers it for *any* state over either the pre-freeze or the frozen view.

**What was measured, and it is not what C2 and C3 found.** `automata-rung --
dwell` surveys every state of every slate automaton and then walks a real document
to see where the scan actually is. Two numbers per row: `elide%`, the share of
bytes a skip would delete at the shipped profitability bar, and `ceil%`, the same
with the bar waived. On documents built to *enter* an interior dwell and sit in it:

| pattern | dfa | seen | narrow-exit refusals | `elide%` | `ceil%` |
| --- | --- | --- | --- | --- | --- |
| `a.*b` | 3 | 2 | 2 unprofitable, 0 porous | 0.0% | **97.5%** |
| `a.*b.*c` | 4 | 3 | 3 unprofitable, 0 porous | 0.0% | **96.3%** |
| `foo.*bar` | 9 | 6 | 2 unprofitable, 6 porous | 0.0% | **61.9%** |
| `<[^>]*>` | 3 | 2 | 2 unprofitable, 0 porous | 0.0% | **97.5%** |

C2 and C3 both died because their premise was false — area was not what cost, and
the NFA was never wide. **C4's premise holds.** The interior dwell exists, the walk
enters it, and it occupies ~97% of the document's bytes. Every refusal on those
rows is `unprofitable` — narrow exit set, refused on expected stride — and *none*
is `porous`. So what stands between C4 and a large win is one threshold, not the
automaton's shape.

**Why the threshold refuses.** An interior dwell must stop at every `\n`: a line
matcher never sees `\n` inside its line, and a document scan resolves `$` at one.
Pinning `\n` into the exit set caps the stride at the **mean line length** — no
interior skip can ever run farther than one line. The start dwell has no such cap;
when crossing `\n` is a provable no-op it is omitted, and the skip `memchr`s across
newlines for an unbounded stride. That asymmetry is the whole reason start
acceleration pays, and it is why the bar (`min_profitable_stride = 32`, calibrated
on the start case) was not obviously the right bar for an interior one. At real
source line lengths of ~30–40 bytes an interior skip's stride sits *right on* it.

**So the remaining question was a timing question, and it has now been run.**
`automata-rung -- dwell` builds the skip and times three arms interleaved over the
same buffer: `step`, the scalar walk that differs from the skip arm in exactly one
respect; `ship`, the multi-lane `docMatch` the engine actually runs; and `skip`
itself, with the profitability bar **waived** so every narrow-exit state is armed.
`vs step` is attributable, `vs ship` is what decides. The correctness oracle is
4000 single-mutation rounds per row — half of them splicing a random substring of
the pattern into the document, so a multi-byte tail like `bar` is actually spelled —
and a row whose mutations never produced a match fails instead of publishing a time.

| pattern | observed stride | `vs step` | **`vs ship`** |
| --- | --- | --- | --- |
| `a.*b` | 39.0 B | 2.58× | **1.08×** |
| `a.*b.*c` | 25.7 B | 1.25× | **0.52×** |
| `foo.*bar` | 3.8 B | 0.23× | **0.10×** |
| | | | geomean **0.38×** |

Every figure here is the least-flattering of three fresh runs; they reproduce inside
±3% (`a.*b` 1.08–1.10×, geomean 0.376–0.380×), and the strides are exact rather than
timed, so they do not move at all.

**`vs ship` was re-measured after the doc walk gained its byte-indexed mirror**, which
made the baseline this column divides by ~1.28× faster; `vs step` is unaffected, both
arms there being scalar. The re-measure moves C4 further down (geomean 0.41× → 0.38×,
`a.*b` 1.18× → 1.08×) — the retirement below was already correct and is now correct by
more. That asymmetry is the point of quoting `vs ship` at all: a proposal that must
beat the shipped walk gets harder to justify every time the shipped walk improves.

**At the waived bar C4 is a 2.6× regression, and the observed stride says exactly
why.** The skip is ~10× *slower* on `foo.*bar`, whose interior dwell exits on `b`
— a byte the document actually contains, so the skip elides 3.8 bytes and pays full
vector-kernel entry for each of them. `a.*b` wins only because its fill excludes
`b` outright, which makes the stride the full distance to `\n`. Same exit set,
same build-time prediction, opposite outcomes — and no build-time prior can tell
them apart, because the difference is a property of the *document*.

**The bar is measured-correct to within ~6%, and the mirror moved which side of it
we are on.** A break-even sweep holds the automaton, alphabet, and instruction mix
fixed and moves only the line length, which on an `a.*b`-shaped row is the sole thing
that changes how far the skip runs:

| stride | 4.3 | 7.8 | 11.5 | 15.2 | 23.1 | **31.0** | 47.0 | 79.0 | 159.0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vs ship` | 0.31× | 0.27× | 0.33× | 0.48× | 0.69× | **0.92×** | 1.28× | 1.90× | 2.61× |

`vs ship` now crosses 1.000× between a 31.0-byte and a 47.0-byte stride —
log-interpolating puts break-even at **≈34 bytes**, against a shipped
`min_profitable_stride` of **32**. The crossing sits in the same interval on all three
runs (31.0 reads 0.89–0.94×, 47.0 reads 1.25–1.33×).

**That is a sign flip worth stating plainly rather than smoothing over.** Before the
doc walk gained its byte-indexed mirror this sweep put break-even at ≈30 bytes, just
*below* the 32-byte bar, so the threshold erred toward refusing a skip that would
have paid. A ~1.28× faster shipped walk raises the distance a skip must run to beat
it, and break-even is now just *above* the bar — so 32 errs the other way, and a
stride landing in the 32–34 band is armed while marginally losing. The magnitude is
unchanged (~6% either way) and both ends of that band are inside the noise of the
rows that actually arm, so nothing here is worth a code change on its own; it is
recorded because the bar's *direction* of error is the kind of fact that goes stale
silently, and because it is the first place a faster `docMatch` made a calibrated
threshold slightly optimistic. Any future move on `min_profitable_stride` should
re-run this sweep rather than trusting the ≈30 that used to be here.

**Status. Retired by measurement — and this is the strongest of the three
retirements.** C2 and C3 died because their premises were false. C4's premise is
*true*: the interior dwell exists, the walk sits in it for ~97% of the document, and
the skip is derivable and correct. It is retired because the mechanism was built,
timed at its own ceiling, and the ceiling is 1.08× on a document constructed to
flatter it and 0.38× on the honest set — while the threshold standing in its way is
already right to within ~6%. There is nothing left to build: the engine arms this
skip in precisely the place it pays, which is the start state, where no `\n` caps
the stride.

The residual is a *different* claim, and it should be filed as one rather than
smuggled in here. Every loss above comes from a build-time prior predicting a stride
the document then contradicts; the fix for that is an adaptive skip that measures
its own realized stride and disarms itself, not a wider derivation. That is a
runtime-feedback claim, and it inherits this section's instrument: `observedStride`
is exactly the quantity such a mechanism would have to estimate online.

That claim has since been priced at its own ceiling and retired too — granted a free,
perfect per-state measurement it reads **0.56× vs ship**, because the skip's problem
is the scalar walk it lives in rather than the prior it trusts. See
["The residual C4 named"](#the-residual-c4-named--priced-at-its-ceiling-and-retired-for-a-sharper-reason-than-c4).

### C5 — Minimization on the byte path, from one refinement engine — *core landed on the symbolic road; the byte road declines it, measured*

**Mechanism, as written.** `reduce/` becomes a single partition-refinement core
parameterized by stopping condition: stop at the Myhill-Nerode congruence and you
have Moore minimization; climb past it under the substitution property and you have
the sieve's harvest. Today the first runs only on the symbolic path and the second
only for the sieve, and neither knows the other exists.

**That parameterization does not exist, and the claim was wrong to assume it.** Both
passes live on the lattice of δ-closed partitions, which is the whole resemblance.
Moore **descends** it: start at the accept partition and split until closed, landing
on the greatest closed partition *below* accept. The sieve's SP closure **ascends**
it: start from one merged pair and union until closed, landing on the least closed
partition *above* that pair. Opposite direction, opposite extremum, and therefore
different machinery — refinement wants a signature hash per pass, closure wants a
disjoint-set forest. Worse, the sieve deliberately does **not** respect the accept
partition; merging an accepting state with a rejecting one is precisely what makes
its quotient a sound over-approximation. A shared core would be an enum switch over
two disjoint loops agreeing on a predicate and nothing else, so
[`sieve/quotient.zig`](../../src/kernel/regex/linear/sieve/quotient.zig) stays where
it is and says why in its own header.

**The core that does exist, and it is a better one.** A finished dense table is
over-refined in **two dimensions**, and one file owns both
([`automata/reduce.zig`](../../src/kernel/regex/linear/automata/reduce.zig)):

- **rows** — two states are indistinguishable when no suffix separates them
  (Moore's refinement, i.e. Myhill-Nerode);
- **columns** — two byte classes are indistinguishable when no state routes them
  differently, i.e. their table columns coincide outright.

**The order is load-bearing and only runs one way.** Merging states is what makes
whole columns coincide — two classes that separated only the states that just merged
now route identically — so rows first, then columns. Reversed, both dimensions stay
over-refined: column merging can never create a row merge, because it does not change
which suffixes distinguish a state. That asymmetry is why this is one operation with
a fixed internal order rather than two passes a caller sequences, and it is why the
two halves are one file instead of two.

Moore's, not Hopcroft's: at these sizes (≤ 4096 states) the O(n²) worst case never
materializes and the honest cost is a handful of linear passes, where Hopcroft's
splitter queue would double the code for a win nothing here can measure.

**Landed on the symbolic road, where the redundancy is structural.** The symbolic
product carries a decoder phase the pattern cannot observe, so its rows are redundant
by construction and `transcribe.zig` calls `reduce` with both dimensions.
`symbolic/minimize.zig` is gone into `reduce.zig`, and the symbolic suite's floor was
**tightened** rather than moved: `dfa.ncls <= byte.minimal_ncls` now compares against
the *reduced* byte class count instead of the raw one, so the lane can no longer pass
on the byte road's over-refinement instead of on the language's requirement.

| symbolic case | byte road, raw | byte road, reduced | symbolic raw pairs | symbolic ships |
|---|---|---|---|---|
| `\w+X` | 318 × 105 | 318 × 97 | 948 | **318 × 97** |
| `\w{3,8}` | 1264 × 104 | 949 × 96 | 1264 | **949 × 96** |
| `\p{L}+;` | 300 × 101 | 300 × 96 | 894 | **300 × 96** |
| `é+X` | 4 × 4 | 4 × 4 | 6 | 4 × 4 |

**Declined on the byte road, and the reason is not cost.** The pass is cheap and it
does find things. It is declined because what it finds does not move the walk —
`bench/rungs/automata -- reduce`, three slates, and the same walker timed on the raw
and the reduced table over 2 MiB:

| slate | rows collapse | `%build` for rows | cols collapse | `%build` for cols | table |
|---|---|---|---|---|---|
| everyday + widest ASCII | 1/32, by one state | 19.4% | 1/32 | 1.8% | 1.01x (53,192 → 52,576 B) |
| UTF-8 trie (Unicode forced onto this road) | 1/5 | 2.2% | **4/5** | **0.6%** | 1.08x (1.57 MB → 1.46 MB) |

Rows find nothing on an ASCII program because subset construction interns on the
NFA-state **set**, which has already landed it on the Myhill-Nerode quotient. The
trie is the shape that should have paid, and on the numbers above it looks like it
does — `\w{3,8}` sheds a quarter of its states, 1264 → 949, a 1.0 MB table to 729 KB.

**And the walk does not notice.** That is the result, and it is C2's law holding at a
quarter-megabyte rather than at 85x of nothing. The 27 rows whose table did not change
*at all* scan at 0.97x–1.04x, so this instrument's floor is about ±4% within a run and
±8% across them, and every row whose table did shrink lands inside it:

| trie row | table | scan, four runs |
|---|---|---|
| `\w+X` | 267 KB → 247 KB | 1.00x · 0.93x · 0.99x · 0.98x |
| `\p{L}+;` | 242 KB → 230 KB | 1.03x · 1.17x · 0.95x · 1.00x |
| `\p{Greek}+` | 9.4 KB → 8.1 KB | 1.00x · 1.04x · 1.02x · 1.04x |
| `é+X` (control, unchanged) | 128 B → 128 B | 1.01x · 0.99x · 1.01x · 1.02x |

The one material row collapse cannot be timed honestly at all, and the slate records
that rather than papering over it: `\w{3,8}` accepts any three word bytes, so **no**
alphabet containing a word byte can spell a document it misses — its row prints
`matched`, meaning there was no full-document walk to time, instead of a ratio earned
on a prefix. A table touched for tens of bytes was never going to repay a 190 ms
determinization by being 1.44x smaller.

Nor is that traffic this road's. In production those four rows belong to the symbolic
path, which reaches the same automaton in **144** NFA-state visits where the byte road
spends **68 million** — the byte road only sees a trie when the symbolic path declines
a construct outright.

**The residual ASCII column is a front-end artifact, and that is where it should be
fixed.** The single row that collapses is `(a|b|c|d|e|f|g|h){10}`, 9 columns to 2,
because `compile.zig` lowers the parser's tree — where that alternation is eight
`consume` states — while [`ast/algebra.zig`](../../src/kernel/regex/ast/algebra.zig)
already knows an alternation of byte classes *is* a byte class. Folding it in the
lowering gives one consuming set instead of eight, a narrower NFA, and a
determinization that is not this slate's third slowest at 59 µs for 11 states. A
post-hoc column merge recovers none of that, which is the difference between treating
a symptom and a cause. Filed as its own claim rather than smuggled in here.

**Status.** The core landed and is load-bearing on one of the two roads. The byte
road declines both dimensions, and the instrument that declined it is kept — the
`reduce` section re-prices both passes and re-times both tables every run, so if a
future lowering ever hands this determinizer an automaton whose shape *does* pay, the
`scan` column says so and the claim reopens on evidence rather than on appeal.

**What the original claim got right.** `regex-automata` ships non-minimal DFAs by
default because their Hopcroft costs "an order of magnitude more time than compiling
the initial DFA," and our pass is nothing like that expensive — 0.6% of a trie
determinization, 2% of an ASCII one. Cheap enough to leave on was the right question.
The answer is that we do not need it on, which is a stronger position than theirs:
they decline a pass that would help them; we decline one that would not.

### C6 — The coarser alphabet is worth what I think it is worth — *measured, and it is*

**Mechanism.** Nothing to build; we already refine by transition set while they
cut at range boundaries. What was missing was the measurement: for each pattern in
the slate, our class count versus theirs, and the resulting table area. Their
own comment says the difference "can have a rather large impact on the size of
the DFA" — that sentence is a competitor's estimate of our advantage, and it
should be quantified rather than quoted.

**Falsifier (stated in advance).** If our class counts are not materially lower on
real patterns, A2 and C6 both shrink to curiosities.

**Measured, 27 patterns, both engines built byte-mode and unanchored, theirs given
`--minimize` so the comparison is against their *best* automaton**
([`bar.py`](../../bench/rungs/automata/bar.py), joined against `regex-cli debug
dense dfa` from the vendored clone):

| | geomean |
|---|---|
| Our alphabet is coarser | **2.32×** |
| Our transition table is smaller | **2.38×** |
| We determinize faster | **4.8 – 5.1×** |

The first two are shape, so they are exactly reproducible — 2.32× and 2.38× on
every run. The third is a timing and it is quoted as a band, at the rep count that
is *most generous to them*: their build time is min-of-N fresh processes, and raising
N lowers this ratio because it keeps handing them better minima. An earlier reading
of 6.01× came from a noisier session and is not the number to defend; four runs at
the default `--reps 9` land at 4.85, 4.93, 5.07, 4.85. **The claim is 4.8×**, the
floor of the band, on the principle that a competitive number should be the one that
survives the incumbent's best attempt rather than its average one.

Not a single row loses the alphabet column; the spread is 1.50× (`func\|struct\|enum`)
to 5.00× (`\w{3,8}`). The falsifier is not met — the difference is roughly a factor
of two on real patterns, which is what "rather large impact" turns out to mean.

**One row loses the table column, and it is worth naming: `func|struct|enum` at
0.98×** — 1040 bytes against their 1024. It is the one place in this table where the
incumbent wins, and the cause is exactly C2. Their 15 classes pad to a stride of 16,
which is a 6.7% tax, the smallest it can be; our 13 states × 10 classes is 520 bytes
of transitions carried *twice* for the `$` resolution, which is a flat 100% tax. Take
`trans_fin` away and the row is 1.97× ours. So the single row where they win is the
row where their structural overhead happens to round down to nothing and ours does
not — which is the memory argument C2 keeps, standing on its own without borrowing
a throughput story it cannot support.

**Three things worth separating in that table, because they are not one win.**

*The alphabet* is C6 proper, and it is ours by construction: refining by transition
set cannot be coarser than cutting at range boundaries, so 2.32× is a floor on the
advantage, not a lucky draw.

*The table* is 2.38× smaller, and only part of that is the alphabet. The rest is
their **stride padding**: their premultiplication needs a power-of-two stride to
recover an index from a state id, so a 24-class alphabet is charged as 32 columns.
Ours is premultiplied at the exact class count, because a contiguous id range is a
contiguous offset range at any stride (see C1). That is why `\w{3,8}` reaches 12×
on the table column off a 5× alphabet advantage. And we win this column while
*still* carrying the duplicate `trans_fin` C2 would have deleted.

*Determinization* is 4.8× faster, which the alphabet mostly explains — fewer
classes is quadratically fewer closure steps, since work is `states × classes` and
a coarser alphabet shrinks both factors.

**The unremarked result in that table: our automata are often smaller than their
minimized ones.** `(a|b)*a(a|b){5}` is 64 states for us against their 196 default
and 163 minimized; `(a|b)*a(a|b){8}` is 512 against 1540 and 1283. A DFA cannot be
smaller than the minimal DFA *for the same language and start conditions*, so the
gap is not minimization quality — it is that their automaton answers more
questions than ours does, carrying distinct start states per anchoring and
look-behind class plus quit and dead states in the same id space. That is a real
capability difference and it should be named as one rather than banked as a win:
we are smaller partly because we are narrower. Worth revisiting alongside C7, where
their reverse strategies are what those extra start states are for.

### C7 — Reverse-inner literal search — *finding half already shipped; the offset it discarded is now kept, 16.30× geomean*

**Mechanism as stated.** Extract a literal from the interior of a concatenation,
scan for it, reverse-DFA leftward to find the start, forward-DFA to confirm the
end. Their `ReverseInner`, with the same `min_start` floor to keep it out of
quadratic behavior.

**The claim was two claims, and one of them was already true.** Auditing the
premise (`automata-rung -- inner`) before building anything split it cleanly:

- **Finding** — "use an interior literal as the prefilter." `lower.zig` already
  compiles the pattern's longest mandatory literal into a `.candidate`
  `LiteralSet`, and `ladder/verdict.zig` already consults it ahead of every
  automaton. **25/33 slate rows prove such a literal and the engine already
  searches for it.** This half was shipped before the claim was written; the
  claim's real content was never the prefilter.
- **Bounding** — "use *where* the literal was to bound the automaton." Not
  shipped: the ladder called `presence`, which is *literally* `findRaw(hay, 0)
  != null`. The offset was computed at SIMD bandwidth and thrown away, and then
  the slowest machine in the ladder re-crossed the buffer from byte zero to
  rediscover it.

**The premise holds, and for the reason claimed.** Of the 25 rows with a
literal, **11 are interior** — unreachable by a first-byte skip — and where both
strides are comparable **the literal skips 6.9× further than the first-byte set**
(geomean over 23 unanchored rows). The two accelerators cover *disjoint* rows,
which is the part worth writing down: **29/33 rows have no start dwell at all**,
and a wide first-byte set is simultaneously what makes a literal interior and
what denies the existing skip. The dwell and the literal are not competing for
the same patterns.

**What I built is the cheap half of bounding, and it is not their mechanism.**
A reverse-DFA leftward walk buys a match *start*. The boolean `-l` question does
not need one. It needs a *seam a scan may begin at*, and the per-line model hands
one over for free: no match crosses `\n`, every match contains the mandatory
literal, so every line lying entirely before the literal's first occurrence is
dead. `docMatch` now calls `find` instead of `presence` and hands the machines
below the suffix from `lineStart(doc, p)` — one `lastIndexOfScalar` bounded by a
line, no reverse automaton, no `min_start` floor, and no quadratic case to guard.

```text
inner-lead — same automaton twice, the second handed the suffix (2 MiB docs)
pattern                        lead     ship us    seed us   speedup
[0-9a-f]{8}-...-[0-9a-f]{12}    89%      2791.6       78.6     35.51x
[0-9a-f]{8}-[0-9a-f]{4}         89%      2824.1       83.7     33.74x
\w+X                            89%      2469.5       82.5     29.92x
a.*b.*c                         89%      2417.2       86.1     28.08x
[A-Z][a-z]+ [A-Z][a-z]+          0%      2510.3     2509.5      1.00x  ← control
\d+\.\d+\.\d+\.\d+               0%      2459.7     2484.9      0.99x  ← control

geomean 16.30x over 30 (row x split) pairs, splices at 10/50/90%
```

**The controls are the point.** The two rows reading 1.00× are the ones whose
match-free fill can itself spell the literal, so the first occurrence is at lead
0% and the suffix is the whole buffer. They cost nothing and save nothing —
exactly what a free mechanism looks like when it has nothing to work with. The
adverse arm makes that a measurement rather than an argument: the same documents
with **no** witness spliced, so every row answers `false` and the seam can only
cost. **Worst 0.98× over 11 rows** (noise; `find` and `presence` are the same
scan). There is no document class this trades against.

**End-to-end, on this repo, against the incumbent** — `gist -l` vs `rg -l`, best
of 5, byte-identical file sets verified on all four:

```text
\w+X                     gist 206.4 ms   rg 386.4 ms   1.87x
[a-z]+_[a-z]+_[a-z]+     gist 209.2 ms   rg 453.2 ms   2.17x
if\s+err\s*!=\s*nil      gist 211.5 ms   rg 347.4 ms   1.64x
\w+\.\w+\(               gist 223.9 ms   rg 584.8 ms   2.61x
```

**What is left of C7, and why it is not built.** The residual is the *span*
question — `matchSpan`, where a start really is needed and the caliper's reverse
jaw already answers it. The windowed-confirm shortcut that would make the
offset bound a span needs an interior literal **and** a finite longest match, and
that is **3/33 rows**, all synthetic UUID shapes. `inf` is the common case, which
is precisely why the field builds a reverse automaton instead of a window: there
is no window to confirm inside. So the honest statement is that their
`ReverseInner` earns its complexity on the *span* path and we have not shown the
span path needs it; the boolean path got the whole win for a line-seam slice.

**The divergence I promised, kept the other way.** I said a strategy that loses
its bet should say so. This one cannot lose a bet — there is no heuristic, no
threshold, and no fallback to count, because the work it reuses was already paid
for unconditionally. The telemetry that would have been needed is replaced by an
adverse arm that proves the floor is 1.0×, which is the stronger form of the
same commitment.

### C8 — Serializable tables — *premise measured and retired as speed; the median table is cheaper to BUILD than to READ*

**Mechanism.** A wire format for the finished DFA — validated `from_bytes` with
native-endian and alignment checks — so a table can be built once and embedded or
mmapped. Pairs naturally with the index we already persist.

**Sequenced last on purpose.** It changes no hot loop. It is a product feature
wearing automata clothing, and it should not consume a slot ahead of anything in
C1-C5.

**And sequencing it last is what killed it, because by the time it came up the
instrument to price it already existed.** `automata-rung -- build` times
determinization alone, min of 15, per pattern. A cache is worth the difference
between building a table and loading one, so both halves have to be measured — and
the second half is the one nobody measures.

**The load floor.** A frozen table is row-major `[state][class]` u32. The widest
row on the slate, `[0-9a-f]{512}-`, is 514 states × 3 classes = **6,168 bytes per
table**; a typical row like `return|continue|break` is 18 × 12 × 4 = **864 bytes**.
Artifacts that small are priced by syscall latency, not bandwidth. Measured on this
machine (`open`+`read`+`close`, warm page cache, min of 7 × 20,000):

| artifact | per load |
|---|---|
| 1 KB | 5.62 µs |
| 6 KB | 5.58 µs |
| 25 KB | 6.02 µs |

Flat, as predicted — the size of the thing is irrelevant next to the cost of asking
for it. That 5.58 µs is the *best* sample; repeated six times on a machine ten agents
share, the same load reads 5.89 / 6.38 / 6.40 / 6.42 / 8.85 / 11.09 µs. The floor is
therefore **~5.9 µs at its most favorable and ~11 µs under contention**, and every
number below is computed at the favorable end, where the cache's case is strongest.

**So put the two columns beside each other, and the claim inverts on half the
slate.** Across the 33 shipped rows (build times are min-of-15 and themselves jitter
±0.2 µs run to run, so the tally is given as the range over repeats):

| | |
|---|---|
| median build | **5.5–5.7 µs** |
| best-case load floor | **5.6–5.9 µs** |
| rows where build < load ⇒ **the cache is SLOWER than rebuilding** | **16–18 / 33 (~half)** |
| same tally at the contended floor (11.09 µs) | **23 / 33 (70%)** |
| whole 33-pattern slate, determinized end to end | **2.03–2.09 ms** |

The median pattern's DFA is cheaper to construct than to read back. `;$`, `\w+`,
`[0-9]{4}`, `\w{3,8}`, `[a-f0-9]{2,}` and a dozen more determinize in 1.0–5.0 µs, so
a *perfectly free* cache still loses them microseconds each to the `open` alone. And
that floor is charitable twice over: it is the best of six samples, and it counts no
key derivation over pattern+flags, no path resolution, no staleness check, and no
validation.

**Where it does win, it wins microseconds against tens of milliseconds.** The only
row where build is unambiguously visible is the pathological `[0-9a-f]{512}-` at
~1.5 ms. That pattern's whole tree-wide query is 47.4 ms ± 1.7 ms, so a free table
saves **3.19%** — barely clear of its own run-to-run σ. For the realistic rows the
share is four orders down: median build against a 40.4 ms query is **0.014%**, and
against a 96.6 ms one **0.006%**.

**The best case the tool can express was measured too, and it is also a
millisecond.** If build ever dominates it is where many patterns compile and
nothing is scanned, so: `relate patterns` with an N-regex slate against a zero-byte
file, where scanning is literally free.

| slate | total |
|---|---|
| 1 regex | 6.6 ms ± 0.3 |
| 41 regexes | 7.5 ms ± 0.7 |
| 121 regexes | 7.5 ms ± 0.4 |

120 extra determinizations cost **0.9 ms**, and 80 of those 120 cost nothing
measurable at all — 41 → 121 is flat inside σ. The 6.6 ms floor is process startup,
which no table format touches. There is no workload in this codebase where the
compiler is the cost.

**The architectural closer, which is the part I did not expect.** Table entries are
**premultiplied targets** (`id*ncls`) indexed directly as `trans[s + class[b]]`, and
the tables are deliberately **not total** — a state reached only as a `trans_fin`
target keeps its whole row on `unfilled`. Both properties are load-bearing for C1's
win. Both also mean a table read off disk is an unvalidated array of raw offsets:
trusting it is an out-of-bounds index primitive, and a `from_bytes` that bounds-
checks every entry against `nstates*ncls` while preserving all-or-nothing row
filling is an O(states × classes) sweep — **the same order as the determinization it
was supposed to avoid.** The honest load cost is therefore strictly above the 5.58 µs
floor, on a comparison the floor already loses.

**And the daemon holds the stronger version of the same idea.** The resident
session's answer keep stores the *rendered answer* against a corpus epoch, so a
repeated identical query skips the scan, the render, and the build together —
`relate echoes --unit function --shape distinct` goes 27.5 s → 4.9 ms. A table cache
would reuse the 5.6 µs the keep already skips entirely, one layer below where the
reuse is worth having.

**Verdict: retired as a performance claim, and it keeps the feature.** Nothing above
argues the wire format is *bad* — it argues the format must be justified by a
consumer who cannot run the compiler, not by a stopwatch. An FFI embedder shipping a
fixed pattern set with no parser, or a `--precompiled` mode, is a real product
request and this measurement does not touch it. What is now settled is that such a
format may never be sold as speed, and may never be allowed to soften C1's
premultiplied non-total layout to make serialization easier. That trade runs the
wrong way by the numbers in this section: it would spend a measured 1.10–1.16×
geomean on the hot loop to save a median 5.6 µs of construction.

C8 is the last claim in the order, so with it the ledger is closed: **two landed
(C1, C6), one split (C5), one half-landed (C7), five retired with numbers (C2, C3,
C4, C8, C9)**, plus two residuals discharged (R1 landed, R2 retired).

### C9 — Measured prefilter choice, not a first-match cascade — *premise true, retired on the currency: the gate it names answers backwards on 9 of 11 rows*

**Mechanism.** Their prefilter selection is a fixed cascade (memchr, memchr2,
memchr3, memmem, Teddy, byteset, Aho-Corasick) gated by an `is_fast()` that is a
build-time guess. The literal layer above it is, by its author's own header, "a
black art": a semiring on literal sequences guarded by four hardcoded limits, a
byte-frequency rank table, a poison threshold, an `ATTEMPTS` ladder, and a
revert-if-worse escape.

**The opening.** Every one of those constants is a decision that could be made
from the pattern's own structure and the corpus's own byte statistics, which we
already compute for the sieve's selectivity estimate. Selectivity is the right
currency here, not needle count.

**Honesty about scope.** This is the biggest surface in the crate and the least
finished part of this dossier. It gets a claim number so it is not forgotten, not
because it is ready.

**Premise TRUE, and retired anyway — because the currency it names measures the
wrong thing here.** The audit is `automata-rung -- sift`.

Our side of the criticism holds exactly as written. `scan/literal_set.zig` picks
its kernel by **needle count** and nothing else — 1 ⇒ rare-byte memmem, ≤64 ⇒
grouped Teddy, beyond ⇒ sparse Aho–Corasick — reached through
`lower.literalEngine` with no pricing anywhere on the path. Meanwhile the
corpus-priced `prefilter.Economics` we already compute, whose `beatsDense` is
described as "one fact shared by DFA acceleration, Compose, Parabix, and Sieve",
has exactly one production consumer (`dwell.zig`), and the literal dispatcher is
not among them. The hole C9 points at is real and is where C9 says it is.

The claim still dies, on two measurements:

| pattern · document | kernel | stride | `pays` | armed | stood | armed/stood |
|---|---|---|---|---|---|---|
| 1 needle · anchors everywhere | memmem | 16 | no | 0.6144 | 0.1110 | **0.18×** |
| 1 needle · anchors absent | memmem | 16 | no | 0.0189 | 0.1114 | 5.89× |
| 1 needle · real code | memmem | 16 | no | 0.0187 | 0.1114 | 5.96× |
| 4 needles · leads everywhere | Teddy | 7 | no | 0.0697 | 0.1116 | 1.60× |
| 4 needles · real code | Teddy | 7 | no | 0.0702 | 0.1114 | 1.59× |
| 8 needles · leads everywhere | Teddy | 2 | no | 0.3490 | 0.3813 | 1.09× |
| 8 needles · real code | Teddy | 2 | no | 0.0696 | 0.4573 | 6.57× |
| 64 needles (the ceiling) | Teddy | 537 | yes | 0.3239 | 3.1303 | 9.66× |
| 65 needles (one past it) | Aho | 537 | yes | 1.2827 | 3.0447 | 2.37× |

ns/byte, min-of-N, same compiled program with `literal_scan` nulled for `stood`,
every document match-free by construction. Arming pays on **10 of 11 rows**,
geomean 2.47–2.95× across two runs, and **3.96–4.16× on real-code documents
alone**. The count-keyed cascade is not leaving money on the table; it is right
almost everywhere, and most right exactly where the product lives.

**First measurement — the one loss is not gateable from the pattern.** The single
regression (0.18–0.20×) is `xylophone` against a document tiled from `xy` plus a
space, where
the memmem's two rarest-byte anchors are ubiquitous and every candidate fails its
verify. Its two twin rows are the *same pattern*: same needles, same anchors, same
stride 16, same `pays`. They measure 5.89× and 5.96×. Every number a
pattern-derived gate could read is identical across all three, and their correct
decisions are opposite. The information that separates them is the document's byte
distribution, not the pattern's — so no selectivity computed from the pattern,
corpus-priced or otherwise, can be right on all three. A prior is not the haystack.

**Second measurement — the specific gate would fire backwards.** `beatsDense(32)`
answers **no on 9 of the 11 rows**, including the 1.09–6.57× wins. Wired into this
dispatcher it would disarm nearly the whole slate: on the `xylophone` family it
buys the adversarial row's 5.6× and pays 5.9× on both realistic ones. That is not
a mistuned threshold, it is the wrong statistic. `beatsDense` is calibrated for a
**single-byte-class** skip, where the expected stride between candidates is the
entire economics. A literal prefilter's power comes from needle *length* — nine
bytes verified from two rare anchors — so a dense lead byte costs one cheap
rejected verify rather than a lost skip, and the two cases do not share a unit.

**What that leaves.** The adversarial row is a genuine worst case, and the only
mechanism that could catch it is one that measures the document it is actually
scanning. C4's residual already priced that family: an adaptive skip is learnable
and still reads 0.56× against ship, because the measuring walk is the scalar one.
So the door C9's loss opens is the door R2 closed, which is why both are recorded
retired rather than deferred — and why the honest summary of the literal cascade is
that "needle count" is a poor *justification* for a dispatch that is nonetheless
the right *decision* 10 times in 11.

## The order

```text
C1 → C6 → C5 → C7 → C9 → C8
 ✓     ✓     ½     ½     ✗     ✗
 ✓     ✓     │     └─ FINDING half already shipped; the discarded offset now
 ✓     ✓     │        bounds the boolean scan — 16.30× geomean, 0.98× worst
 ✓     ✓     │        adverse. Residual is the SPAN path, where the caliper's
 ✓     ✓     │        reverse jaw already answers and a window covers 3/33 rows.
 ✓     ✓     └─ one refinement CORE, landed — but for the two dimensions of a
 ✓     │        finished table, not for the two roads, which are duals
 ✓     └─ 2.32× coarser, 2.38× smaller table, 6.01× faster determinization
 └─ build-time permutation, exact oracle — landed, 1.10–1.16× geomean

retired by measurement, not deferred:
 C2 ─ area is not the throughput lever; touched breadth is. Survives only as a
      memory claim, which has to re-argue its way in on those terms.
 C3 ─ needs a wide NFA with narrow closures. Measured: the two are
      anti-correlated, and the one shape that had both was already routed to the
      symbolic determinizer years ago.
 C4 ─ premise TRUE and still retired, which is the rarest of the three. The
      interior dwell holds ~97% of the document's bytes and the skip is correct;
      built and timed at its own ceiling it is 0.38× geomean against the shipped
      multi-lane walk, because `\n` caps the stride at one line. Break-even is a
      ~34-byte stride and the bar already refusing it is 32 — calibrated on the
      start case, and independently right to within ~6%, though the mirror flipped
      which side of the bar break-even sits on. Residual DISCHARGED, and
      it relocates the family's problem: the ADAPTIVE skip is learnable (strides
      separate BETWEEN dwell states, 8 vs 70 inside one pattern) and still reads
      0.53× vs ship granted a free perfect measurement — because the skip lives
      in the scalar walk, 2.4× behind the shipped lanes, and adaptivity can pick
      better states but cannot relocate the walk. See "The residual C4 named".
 C5 ─ half retired, on the road it was aimed at. The core landed and the symbolic
      product needs it; the BYTE road declines both dimensions. Rows find 1
      automaton in 32 for 20% of a build. Columns find 4 trie rows in 5 for 0.6%,
      and the walk is unchanged at ±8% noise on a 267 KB → 247 KB table — C2's law
      again, one order of magnitude up. Residual DISCHARGED: the single-byte
      alternation fold landed in the LOWERING (`oneByteUnion`), and the ASCII
      column collapse went 1/32 → 0/32 rows. See "The residual C5 named".
 C8 ─ priced on BOTH halves, which is the half nobody measures: the median table
      is cheaper to BUILD (5.6 µs) than to READ (5.58 µs open+read+close, flat
      1–25 KB), so a perfectly free cache is a REGRESSION on 16 of 33 rows. The
      whole slate determinizes in 2.09 ms; the one pathological row where build is
      visible saves 3.19% of its own 47.4 ms query, inside σ. Best case the tool
      can express — 121 regexes against a zero-byte file — puts the entire compile
      phase at 0.9 ms of 7.5 ms, flat from 41 patterns on. Closer: premultiplied
      non-total rows make a trusted `from_bytes` an O(states × classes) bounds
      sweep, the same order as the build it replaces. Keeps the FEATURE (an
      embedder with no compiler), loses the right to be called speed.
 C9 ─ premise TRUE — the literal dispatcher really does key on needle count and
      really does ignore the corpus-priced economics sitting one module over — and
      retired anyway, on the currency rather than the threshold. Arming pays on 10
      of 11 rows (geomean 2.47–2.95×; 3.96–4.16× on real code), and the single
      0.18× loss is provably not gateable from the pattern: its two twin rows share
      every pattern-derived number and want the opposite decision. `beatsDense`
      itself answers "no" on 9 of 11 rows, so the specific gate fires backwards —
      it is the right statistic for a byte-class skip and the wrong one for a
      nine-byte needle verified from two rare anchors.
```

C1 went first in the end rather than second: it needed a harness, and building
the harness for it built the harness for C3 and C2 as well — which is how both of
those came to be priced before either was built.

**Four of the first five claims died or half-died, and that is the harness working.**
Each was plausible, each had a mechanism, and each rested on a premise nobody had
measured: C2 on "area is L1 residency; residency is throughput", C3 on "wide NFAs have
narrow closures". Both premises are false here, and the total cost of learning
that was one extra loop in the area sweep and one `u64` carried out of
determinization. The counterfactual is the expensive part — C2 in particular
required moving `$`/CRLF semantics into the gap predicate, a change to the
correctness-critical part of the engine, in exchange for a benefit that does not
exist.

**C4 died differently, and the difference is the point.** Its premise was *true* —
the census found 97% occupancy and every refusal was the threshold rather than the
shape, which is exactly the reading that says "build it". So it was built, in the
harness, and timed against the walk the engine actually runs; and at its own
ceiling, on a document constructed to flatter it, it returns 1.08×, while on the
honest set it returns 0.38×. A claim can clear every premise test and still be
wrong, and the only thing that catches that is building the cheap version and
timing it against the real baseline rather than the convenient one. The three arms
exist for that reason: `vs step` reads 2.58× on the same row where `vs ship` reads
1.08×, and publishing the first would have been true, attributable, and
misleading. **Tying the verdict to the shipped walk also means it stays live**: when
the doc walk gained its byte-indexed mirror, every `vs ship` number here moved
against C4 without anyone re-arguing the claim, which is what a baseline-relative
measurement is for.

**C5 died a third way: on the wrong population, then on the walk.** Priced over the
everyday slate it collapsed 1 automaton in 32 and read like a clear decline. That
slate was silently unrepresentative — five `\p{…}` rows had been failing to compile
for as long as the section existed, so the one shape whose states are indistinguishable
*by construction*, a UTF-8 range trie, had never been measured at all. Measured
separately it collapses 4 rows in 5 and takes a megabyte table down by a quarter, which
reads like a clear land. Both readings are wrong, and the walk settles it: the tables
are smaller and the scan is identical. A slate that cannot build a row must say so —
that silent `catch return` cost more than any of the numbers it hid.

So the ordering's job is not to schedule work; it is to make each claim state a
premise cheap enough to falsify before the work starts. An ordering whose only
outcome is "everything, eventually" is a wish list. This one is allowed to delete
its own entries, and a measurement that deletes one is worth as much as a
measurement that lands one — arguably more, since it is the only kind that returns
effort instead of spending it.

## The residual C5 named — *discharged, and it was the bigger half*

C5's byte road was retired with one loose end written down: the columns a post-hoc
merge could still find came from the **front end**, not from the automaton.
`compile.zig` lowered the parser's tree literally, so `(a|b|…|h)` arrived at the
determinizer as eight `consume` states behind seven splits — while `ast/algebra.zig`
had known for years that an alternation of byte classes *is* a byte class, on a graph
the Thompson construction deliberately does not read.

**Why the analysis graph could not just be lowered instead.** Interning re-associates
and rebalances the alternation spine, and re-association is not leftmost-first-safe —
`ast/intern.zig` says so in its own header, which is exactly why `compile/` still
lowers the parser's bracketing. So the fold had to be made *at* the Thompson seam, on
the parser tree, without re-associating anything.

**The fold that is safe, and the argument that makes it safe.** `oneByteUnion` fires
only when **every** branch of an alternation consumes exactly one byte and flows to the
same continuation. Then each branch's thread reaches the identical (state, position)
pair — which the Pike VM already dedupes — so the surviving thread is the same one
whichever branch had priority. Order is *unobservable* precisely in that case, and
observable in every case the fold declines: `.concat` and `.uclass` consume more than
one byte, `.empty` and the assertions consume none, and a quantifier consumes a
variable count. `a|ab ⇒ a` survives because `ab` is a concat. And the *capture* VM has
its own alternation lowering in `captures.zig`, so no slot boundary is reachable from
here at all.

| `(a\|b\|c\|d\|e\|f\|g\|h){10}` | before | after | |
| --- | --- | --- | --- |
| NFA states | 151 | **11** | 13.7× |
| scratch words (C3's `@memset`) | 3 | **1** | — |
| byte classes | 9 | **2** | 4.5× |
| table bytes | 792 | **176** | 4.5× |
| determinization | 56.9 µs | **3.6 µs** | **15.8×** |
| columns `reduce` still finds | 9 → 2 | **none** | — |

**The whole-slate result is the one that closes C5.** The ASCII column collapse went
from **1 row in 32 to 0 in 32** — the single row that had residual column redundancy
now arrives minimal. That converts C5's diagnosis into a proof: fixing the lowering
removed *all* of it, and it bought 4.5× of table alongside a 15.8× faster build, where
the post-hoc merge bought the same table for 2% of a determinization it had already
paid in full.

Two smaller rows land the same way, and their unchanged columns are the more
interesting part: `(a|b)*a(a|b){5}` goes 21 → 9 NFA states and determinizes 1.40×
faster; `(a|b){8}`'s cousin goes 30 → 12 and 1.52× (175.4 → ~115.6 µs). Their **DFA
state count, accept count, and table bytes are byte-identical** before and after — 64
and 512 states, 32 and 256 accepting, 1536 and 12288 bytes — because the language did
not change and neither did the alphabet (a bare `a` elsewhere in the pattern still
distinguishes `a` from `b`). The win there is purely the closure: fewer NFA states to
walk per determinization step.

`(?:foo|bar|baz|qux|quux|corge){8}` is the control the slate already contained, and it
does not move at all — 209 states, 13 classes, 10088 bytes, 163 µs, columns still
13 → 13 — because its branches are concats. Every other row on the shape slate is
byte-identical in all six columns. The fold is surgical by construction rather than by
tuning: it fires on exactly the shape whose branches are single bytes, which is exactly
where the redundancy was.

**What judged it.** Two new structural tests assert the shape it must produce and the
shapes it must refuse, and both were confirmed load-bearing by deliberately breaking
them (`expected 99, found 1`). The full suite — including the Pike-vs-DFA differential
fuzz and the independent adversarial oracle — is green. Against ripgrep: identical
file sets on ten alternation patterns tree-wide, byte-identical `-o` streams per file,
and 6/6 on the targeted order probes that are the actual hazard — `a|ab ⇒ a`,
`ab|a ⇒ ab`, `e|er|err ⇒ e`, `err|er|e ⇒ err`.

**Where it does not apply, and why that is fine.** The trie rows keep their 4-in-5
column collapse, because a UTF-8 decoder's coincident columns are a real automaton
property rather than a lowering artifact — and C5 already measured that one as not
worth spending on the walk. The symbolic road also still lowers `.alt` to a split
(`linear/symbolic/program.zig`), and it does not need this: `transcribe.zig` runs both
reduction dimensions on its product anyway, for the decoder redundancy the pattern
cannot express.

## The residual C4 named — *priced at its ceiling and retired, for a sharper reason than C4*

C4 was retired with its own loose end: every loss came from a build-time prior
predicting a stride the document then contradicts, so the named fix was an **adaptive
skip that measures its own realized stride and disarms itself**. That claim is
answered here, and it never needed to be built — because a mechanism can be priced by
granting it its measurement for *free and without error* and timing the decision it
would converge on. Anything real is bounded by that.

**The free per-row oracle: 1.03×.** C4's own arm already times `ship` and `skip`
per row, so the best a scheme that adapts per pattern could do is take whichever arm is
faster, i.e. `max(1, vs ship)`. Over the three rows with no banked start skip that is
`a.*b` at 1.08–1.10× and the other two at exactly 1.000× — geomean **1.025–1.033×**
across three fresh runs (1.036–1.055× before the mirror, the whole difference being
`a.*b`'s single winning row shrinking against a faster baseline). Two of the three
contribute nothing at all, on a slate hand-built to be C4's best case.

**But per-row is the weak form, and the per-site numbers said so.** An adaptive skip
decides at each site, not once per pattern. Splitting every armed skip by whether that
skip *alone* cleared the 32-byte bar shows real dispersion behind the mean:

| pattern | skips | mean stride | share of skips that pay | share of the **document** they cover |
| --- | --- | --- | --- | --- |
| `a.*b` | 209 708 | 39.0 B | 51.0% | **88.5%** |
| `a.*b.*c` | 314 462 | 25.7 B | 34.0% | **77.8%** |
| `foo.*bar` | 1 362 293 | 3.8 B | 0.1% | **0.3%** |

`a.*b.*c` loses at ~0.52× armed unconditionally, yet 78% of its bytes sit under
skips that individually pay. So the headroom C4 left behind is real, and `foo.*bar`'s 0.3%
confirms the other half: there, a correct scheme declines essentially every skip.

**The variance is between states, which is what makes it learnable.** Per-state mean
strides are `8 70` for `a.*b`, `8 8 61` for `a.*b.*c`, `4 4` for `foo.*bar`. The
dispersion is not noise inside one dwell — it separates *which* dwell, so a per-state
counter is a sufficient statistic. R2's mechanism is therefore sound in principle,
and that is exactly why the timing below is the decisive number rather than a proxy.

**At its ceiling it still loses, and it loses to the walk it lives in.** Keeping
exactly the states whose own realized stride clears the bar — free measurement,
perfect decisions, zero bookkeeping, no learning error:

| pattern | per-state strides | kept | `vs step` | **`vs ship`** |
| --- | --- | --- | --- | --- |
| `a.*b` | 8, 70 | 1 of 2 | 1.79–1.86× | **0.76–0.79×** |
| `a.*b.*c` | 8, 8, 61 | 1 of 3 | 1.36–1.39× | **0.57–0.58×** |
| `foo.*bar` | 4, 4 | 0 of 2 | 0.76–0.77× | **0.33×** |
| | | | | geomean **0.53×** |

The strides are exact rather than timed and do not move at all; the absolute ns/byte
drifts a few percent with machine load, so every ratio is quoted as the band three fresh
runs produced — the geomean read 0.532×, 0.529×, 0.526×. These are the post-mirror
numbers; before the doc walk gained its byte-indexed mirror the same ceiling read
0.547–0.561×, and only the `vs ship` column moved, since `vs step` divides one scalar
walk by another.

Adaptivity does help *relative to C4* — measured in the same runs, so the comparison
does not inherit that drift: C4's unconditional geomean and R2's ceiling read 0.380 →
0.532, 0.376 → 0.529, 0.376 → 0.526, a stable **1.40–1.41× improvement** (and the same
1.36–1.43× band before the mirror, which is the point: the *ratio between the two
proposals* is invariant to how fast the walk they both lose to is), and `foo.*bar`
recovers 3.2×. It is still a **~1.9× regression** against what the engine already runs
— and `a.*b`, C4's one winner, gets *worse* (1.08–1.10× → 0.76–0.79×), because
disarming its 8-byte state removed a skip that beat stepping even below the bar.

**The reason is structural, and it is the finding.** The skip lives in the scalar
walk, which is ~2.4× slower than the multi-lane `docMatch` the engine ships — a
handicap that *grew* when the doc walk stopped paying for a byte-class lookup, so
every re-measure of this family will find the gap wider, not narrower. Every
version of this claim must pay that handicap down before it can add anything, and
**adaptivity can choose better states but cannot relocate the walk it runs in.**
`foo.*bar` shows the floor of that argument from the other side: with *nothing* armed
the arm still reads 0.78–0.81× of `step`, because merely asking "is this state armed"
costs per byte — here inflated by a division on a runtime `ncls` the harness has not
folded into the state representation. Crediting that tax back in full moves the ceiling
to only ≈0.7×, so the verdict does not depend on the artifact.

**Status. Retired by measurement, and this retirement is cleaner than C4's.** C4 died
on a prior that could not see the document; R2 fixes precisely that and still loses,
which relocates the whole family's problem. The only form that could win is a skip
built *inside* the shipped lanes — and there it would be competing against a
SIMD substring kernel already doing the same job better, which is C9's lane and
C7's evidence, not this one. The instruments stay: `strideProfile` and the per-state
arm are the retirement's evidence, and they are the numbers any future attempt has to
beat before writing a line.

## What would make me abandon the lane

If C6 measures small, C2 turns out to be load-bearing for `$` semantics, and C3
does not move the closure profile, then our automata are already at the shape of
theirs and the remaining wins are in the prefilter and literal layers instead —
which is C9, a different lane with a different oracle. Recording that outcome in
[`../ceiling/CLOSED.md`](../ceiling/CLOSED.md) is a successful result, not a
failed one.
