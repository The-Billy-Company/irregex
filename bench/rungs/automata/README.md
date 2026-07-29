---
doc_radar:
  sentinels:
    - description: "the harness proves its own premise: no row publishes a number unless its document provably cannot match, since a boolean scan returns at the first hit"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn statesVisited"
        - "document MATCHES"
        - "fn walkLoaded"
        - "fn walkCompared"
    - description: "the sections, including the four premise-checking arms that retired C2 (area), C3 (width + closure cost), C4 and its adaptive residual (dwell + cost + break-even sweep + adaptive ceiling), C5's byte road (reduce), and the body × width × table-shape race the doc walk's layout is chosen on (burst)"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn runArea"
        - "fn runWidth"
        - "fn runBuild"
        - "fn runShape"
        - "fn runBurst"
        - "fn runDwell"
        - "fn runDwellCost"
        - "fn runStrideSweep"
        - "fn runStrideProfile"
        - "fn runReduce"
        - "fn runInner"
        - "fn runSift"
        - "shape, build, search, burst, area, width, dwell, reduce, inner, sift, all"
    - description: "the burst race prices the SHIPPED mirror rather than a local prototype, and cannot pass without proving that mirror cell-exact against the classed table it stands in for"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn mirrorFaithful"
        - "fn burstAgrees"
        - "Dfa.Wide.stride"
    - description: "C7's bounding half is priced with its own control and its own adverse arm, because a mechanism that costs nothing has to be shown costing nothing on the documents it cannot help"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn runLead"
        - "fn leadAdverse"
        - "MATCHED a match-free document"
        - "REGRESSED"
    - description: "and the engine keeps the offset it used to discard — the ladder calls find, not presence, and hands the machines below the line that holds the literal"
      file: pkg/kernels/irregex/src/kernel/regex/linear/ladder/verdict.zig
      contains:
        - "fn lineStart"
        - "set.find(doc, 0)"
    - description: "C5's byte road is judged on the walk, not the byte count: three populations kept apart, and a witness-spliced oracle that proves agreement about MATCHING lines before any table is allowed to shrink"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "const trie_slate"
        - "fn scanRatio"
        - "fn witness"
        - "fn reducedAgrees"
        - "will not compile as"
    - description: "and the byte road declines it — powerset.zig runs neither dimension, while the symbolic road's transcribe.zig runs both"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/powerset.zig
      absent:
        - "reduce.run"
    - description: "C4's skip is judged against the walk the engine actually runs, and only after a mutation oracle proves the two agree on documents that MATCH"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn walkDwelling"
        - "fn agreeUnderMutation"
        - "fn observedStride"
        - "the oracle proved nothing"
        - "d.docMatch(doc)"
    - description: "and C4's residual is priced at its ceiling rather than built: a free, perfect per-state measurement is handed over, so the timing bounds every real adaptive scheme from above"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn runStrideProfile"
        - "fn strideProfile"
        - "FREE PERFECT per-row oracle"
        - "FREE PERFECT per-state skip"
    - description: "C9's premise is priced by pairing documents against one pattern, so a gate computed from the pattern can be shown unable to separate them; the literal dispatcher it audits still keys on needle count alone"
      file: pkg/kernels/irregex/bench/rungs/automata/bench.zig
      contains:
        - "fn runSift"
        - "fn teddyCeiling"
        - "const code_unit"
        - "cannot be gated by anything derived from the pattern"
    - description: "and the dispatch it audits is unpriced — literal_set chooses on needles.len with no economics on the path"
      file: pkg/kernels/irregex/src/kernel/scan/literal_set.zig
      contains:
        - "needles.len == 1"
        - "needles.len <= teddy_mod.max_buckets"
      absent:
        - "beatsDense"
    - description: "the invariant this rung prices — the match test that replaced a dependent load"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/dfa.zig
      contains:
        - "pub inline fn isMatch"
        - "match_hi: u32"
      absent:
        - "is_match: []const bool"
---

# bench/rungs/automata

Every other rung here races an accelerator against the shipped DFA. This one
races the DFA against itself.

The reason is attribution. The claims in
[`research/automata/CLAIM.md`](../../../research/automata/CLAIM.md) are each
about **one function** — a closure, a match test, a table — and a binary race
cannot tell you which one moved. Neither can a whole-suite rerun. So both arms
here walk the *same* automaton, in the *same* process, interleaved round by
round, min-of-N, and the only difference between them is the line under test.

```bash
zig build automata-rung              # every section
zig build automata-rung -- search    # the match test, both forms
zig build automata-rung -- burst     # the doc walk's body × lane width × table shape
zig build automata-rung -- build     # determinization alone, + closure width
zig build automata-rung -- width     # how wide an NFA reaches the byte determinizer
zig build automata-rung -- area      # does table SIZE cost throughput?
zig build automata-rung -- dwell     # skippable states, the skip's cost, break-even, adaptive ceiling
zig build automata-rung -- reduce    # what the finished table still contains, and whether shedding it pays
zig build automata-rung -- inner     # the literal C7 searches for, then what keeping its offset is worth
zig build automata-rung -- sift      # does the count-keyed literal cascade ever arm a prefilter that loses?
zig build automata-rung -- shape     # TSV, for the cross-engine join
```

## What it reports

Ten sections, deliberately not mixed:

**`shape`** — NFA states, byte classes, DFA states, how many accept, table bytes,
determinization time. No search timing. This is the section that crosses the engine
boundary: [`bar.py`](bar.py) joins it against `regex-cli debug dense dfa` from the
rust-`regex` clone, so the coarser-alphabet claim is measured against theirs rather
than asserted. Emitted as TSV so that join needs no column-width guessing.

**`build`** — determinization alone, re-run over the same lowered NFA the shipped
compile produced, min-of-N. Read `ns/step`, not `ns/state`: one state costs `cls`
closure steps, so `ns/state` conflates alphabet width with closure cost. Beside it
`vis/step` reports mean closure *width*, read from the visit count the automaton
now carries out of its own determinization.

This arm also retired **C8** without a line of serialization being written, because
its `build_us` column is one half of the exchange a table cache proposes. The other
half is what a load costs, and at these sizes that is a syscall rather than a
transfer: a frozen table is row-major `[state][class]` u32, so the widest row on the
slate is 6,168 bytes and a typical one is 864, while `open`+`read`+`close` measures
5.6–5.9 µs at best — flat from 1 KB to 25 KB, and 11 µs when the machine is busy. Put
the columns together and the **median build (5.5–5.7 µs) is the best-case load
floor** — 16–18 of 33 rows determinize faster than they could be read back (23 of 33
at the contended floor), so a perfectly free cache is a regression on half the slate,
and the whole 33-pattern slate determinizes in ~2.05 ms total. See
[CLAIM.md](../../../research/automata/CLAIM.md#c8--serializable-tables--premise-measured-and-retired-as-speed-the-median-table-is-cheaper-to-build-than-to-read).

**`width`** — how wide is the NFA that actually reaches `subset.zig`, in the u64
scratch words its per-closure `@memset` clears. A premise-checking section: it
exists because a claim about that `@memset` is worthless if the answer is 1.

**`area`** — does table size cost throughput, or only the part of the table the
walk touches? Every row is priced twice, at two line lengths, because one column
cannot tell those two apart.

**`dwell`** — four passes over one claim, because a premise, a cost, a threshold,
and *the ceiling on fixing it* are four different questions.

The *census* surveys every state's exit set, walks a real document to find which
states the scan occupies, and reports two shares of it: `elide%` at the shipped
profitability bar and `ceil%` with the bar waived. The pair separates "no state has
a narrow exit set", a fact about the automaton, from "narrow, but the corpus prior
says stepping is cheaper", a fact about one threshold. It came back *positive*:
97.5% `ceil%`, and every refusal the threshold rather than the shape.

The *cost* arm then builds the skip and times it, because a positive premise is not
a result. Three arms interleaved: `step` (the scalar walk, differing from the skip
in exactly one respect, so `vs step` is attributable), `ship` (the multi-lane
`docMatch` the engine actually runs, so `vs ship` is what decides), and the skip
itself with the bar waived. On the same row those read 2.58× and 1.08×, which is
the whole reason both are printed.

The *break-even* sweep closes it. `a.*b` over an alphabet with no `b` makes the
realized stride exactly the distance to `\n`, so moving only the line length moves
only the stride — and `vs ship` crosses 1.000× at ≈34 bytes, against a shipped
`min_profitable_stride` of 32. That crossing sat at ≈30 bytes until the doc walk
gained its byte-indexed mirror; a faster `ship` raises the distance a skip must run
to beat it, so the bar went from marginally conservative to marginally optimistic
without a line of dwell code changing. Re-run this sweep before touching the bar.

The *adaptive ceiling* prices C4's residual without building it. C4 died on a
build-time prior that cannot see the document, so the named fix was a skip that
measures its own stride and disarms itself. A mechanism like that can be priced by
handing it its measurement **free and without error** and timing the decision it
would converge on — anything real is bounded by that. Per-state mean strides show the
variance is *between* dwell states (`8 70` inside `a.*b`), so a per-state counter is a
sufficient statistic and the mechanism is sound; keeping exactly the states that pay
still reads **0.53× geomean vs ship**, and C4's one winner gets *worse*. The skip
lives in the scalar walk, ~2.4× behind the shipped lanes, and adaptivity picks better
states without relocating the walk.

**`reduce`** — how much redundancy a *finished* byte table still holds, in both
dimensions `automata/reduce.zig` can quotient: rows Moore's refinement would merge,
columns the coincidence pass would. Each priced against the determinization that
produced the table, then — the part the byte counts cannot answer — timed, with the
same walker over the raw and the fully reduced table. Three populations are summarized
apart, because they answer differently and the common case buries the interesting one.

**`inner`** — C7, in the order that keeps a shipped feature from being re-claimed.
The *premise* arm asks, per row, what mandatory literal exists, whether it is
interior (out of a first-byte skip's reach), how much further it skips than the
first-byte set, whether a finite longest match could bound a window, and which
ladder rung answers today. The *lead* arm then prices the one thing the premise
turns out to license, with a control built into the slate: rows whose match-free
fill can itself spell the literal have their occurrence at lead 0%, so they must
read 1.00×. The *adverse* arm runs the same documents with no witness spliced, so
every row rejects and the mechanism can only cost.

**`search`** — the match test, both forms: the shipped `s < match_hi` compare
against the `is_match[s]` load it replaced. The load arm reconstructs the exact
array the old automaton allocated, *from the shipped bound*, so the two arms are
provably one machine rather than two that ought to agree.

**`burst`** — the multi-line document walk, raced on the three axes it could have
been built on: the lockstep **body** (`bk` copies `prev` and bumps a cursor per
lane per byte and tests each lane; `pl` peels `prev` to the burst's last step,
shares one induction variable, and folds the tests into a min), the **lane
width** (4 · 8 · 12 · 16), and the **table shape** — `·d` steps the shipped
byte-indexed mirror (`Dfa.Wide`), where a raw byte indexes a row, against the
classed tables, where a class load sits in front of the transition load that
consumes it. `4bk` is the baseline every column is quoted against, because it is
what the engine shipped before the mirror existed.

It settled two things in opposite directions. The mirror pays — 1.27×–1.29×
geomean over repeat runs, no row slower — so it ships. The other two axes
**cost** what they were supposed to save: `pl` is slower than `bk` at four lanes,
because aarch64 already folds the cursor bump into a post-indexed load, move
elimination retires the copy, and the four compares fuse into one branch
cluster, so there was no bookkeeping there to delete. And width is a genuine
tie that the automaton cannot break — twelve lanes hold a flat ~0.31 ns/byte at
every table size, which beats four on the rows that wander and loses badly on
the rows that park, and nothing available at freeze time predicts which a given
*document* will do. So the engine carries one body at one width, and the
`win`/`ship` gap stays printed as the standing measurement of what a
working-set-aware walk would recover.

Two things make the row trustworthy. `agree` is the mutation sweep: every arm
*and* the shipped `docMatch` must match a scalar per-line oracle, counted only
over the rounds that **actually matched**, so a row that proves parity purely on
match-free text shows it in the column. Reaching those rounds means planting a
string the automaton really accepts, which is why the planter walks the
transition table breadth-first for a shortest accepted witness instead of
splicing in slices of the pattern source — `\d+\.\d+` does not match the four
characters `\d+`. And `mirrorFaithful` checks the mirror the engine will actually
walk, cell by cell across every state × all 256 bytes, so an arm can never
publish a time for a table that isn't the one it stands in for.

## Read `seen` before `speedup`

`seen` is how many distinct states the walk actually entered. It is the column
that makes the rest of the table honest, because a pattern can determinize to 512
states and spend every byte in one of them — and a state that never changes turns
the load being removed into a perfectly-predicted L1 hit. Those rows price the
*instruction*, nothing more. The rows that wander are where the recurrence does
real work.

Measured on an M-series laptop carrying ten coworker agents, seven runs:

| Regime                       | Rows                                    | Speedup       |
| ---------------------------- | --------------------------------------- | ------------- |
| Self-loop (`seen` = 1)       | `a.*b.*c`, `panic\|0x`, `;$`, …          | 0.98 – 1.19×  |
| Wandering (`seen` ≥ 9)       | `[0-9a-f]{8}-[0-9a-f]{4}`, `[0-9a-f]{32}-` | 1.20 – 1.27×  |
| Geometric mean, whole slate  | 13 rows                                 | 1.10 – 1.16×  |

The wandering rows are the ones to judge it by, and they are also the shape the
`crest` lane cares about — a long class run that no prefilter can skip.

The self-loop band crosses 1.0, and that is the number rather than a defect in it.
A state that never changes leaves the removed load perfectly predicted and L1-hot,
so those rows measure an instruction against noise; one of them scored 0.979× on
one run and 1.04–1.06× on the next two. A band quoted from only its favourable
samples is an advertisement, so it is quoted from all of them, and the conclusion
that survives is narrower and truer: **parity where the walk stands still, 20–27%
where it moves.**

## The cross-engine column

`shape` is TSV so [`bar.py`](bar.py) can join it against `regex-cli debug dense
dfa` from the vendored rust-`regex` clone. Both engines are built byte-mode
(`(?-u)` in the pattern, `-b -B` on their CLI) and unanchored with captures off,
and theirs is given `--minimize`, so the comparison is against their *best*
automaton rather than their default one. Their build time is min-of-N for the same
reason ours is — a single cold run measures process startup.

```bash
python3 bench/rungs/automata/bar.py            # 27 patterns, both engines
python3 bench/rungs/automata/bar.py --reps 5   # more rounds for their build time
```

| Geomean over 27 patterns    | Ratio         |
| --------------------------- | ------------- |
| Our alphabet is coarser     | **2.32×**     |
| Our transition table is smaller | **2.38×** |
| We determinize faster       | **4.8 – 5.1×** |

The first two are shape and reproduce to the digit. The third is a timing, and
raising `--reps` *lowers* it, because more fresh processes keep handing their
determinizer better minima — so the band is quoted from the default rep count and
the claim is its floor. A ratio that improves when you measure the incumbent less
carefully is not a ratio worth quoting at its peak.

Not one row loses the alphabet column. Three caveats the script prints rather than
hides. Part of the table ratio is *their* stride padding (a power-of-two stride is
what their premultiplication needs to recover an index, so a 24-class alphabet is
charged as 32 columns), and we win that column while still carrying the duplicate
`trans_fin` above — which is why `func|struct|enum` is the one row we *lose* it, at
0.98×: their 15→16 padding is the cheapest it ever gets while our duplicate is a
flat doubling. And where our state count comes in under their *minimized* one, that
is not minimization quality — their id space also holds per-anchoring start states,
quit, and dead. We are smaller there partly because we answer fewer questions, which
belongs in the record as a capability difference.

## The four claims this rung killed

`search` is the arm that landed C1, and `inner` is the arm that landed half of C7
after establishing that the other half was already in the product. `area` and `build`/`width` are the arms that
retired **C2** and **C3** — and retiring a claim before building it is the cheapest
thing this rung does. `dwell` retired **C4** the expensive way, by building it,
which is a different and more important result: it is the case where every premise
test passed and the thing was still wrong. `reduce` retired the byte-road half of
**C5** a third way: the premise held, the pass worked, the table got smaller, and
the walk did not notice.

**C2 (fold the duplicate `trans_fin` into an EOI column) rested on "area is L1
residency; residency is throughput".** The `area` sweep grows a table 85× while
holding the alphabet, document, and per-byte instruction count still. Priced with
the walk clipped to a constant breadth, all 85× of that growth is **free** — no
trend, 0.65–0.78 ns/byte, and the fastest reading of the sweep is at the *largest*
table. Priced with breadth free to grow, cost steps once, exactly where breadth
passes the clip, then goes flat again from 129 to 513 states. The clipped column is
the control; its spread is laptop noise, where the full column's step reproduces in
both position and size every run. Cost tracks *touched breadth*, not area; and halving the table narrows no
walk. `trans_fin` is read once per line, not once per byte, so the duplicate was
never in the hot path the claim was about.

**C3 (sparse-set closure instead of `@memset`) rested on "wide NFAs have narrow
closures".** It needs both — the memset clears `wds = ceil(nfa/64)` words, so a
visit-proportional clear only wins when `wds` is large *and* the closure is narrow.
`width` found `wds > 1` at all only for bounded repeats and wide alternations (max
9). `build` then priced their closures, and every wide row's closure is **wider
than its entire NFA** (686 visits over 514 states, because an unanchored walk
re-seeds the start each step). A sparse clear would cost 14–75× more than the
`@memset` in every measured row. The bulk clear is not the lazy choice; it is the
right one.

Both premises were false, and neither costs anything to have checked: one extra
loop in `area`, one `u64` carried out of determinization for `build`. The
counterfactual is where the savings are — C2 required moving `$`/CRLF semantics
into the gap predicate, in the correctness-critical part of the engine, for a
benefit that does not exist.

`width` also found the shape that *would* have satisfied C3's premises, and why it
never mattered: `\p{L}+` is a 1592-state NFA, but a Unicode class lowers to a
**codepoint** automaton owned by `symbolic/determinize.zig` and never reaches this
determinizer at all. The width that motivated the claim had been designed off this
path long before the claim was written.

## C4, and why a true premise still isn't a result

`dwell`'s census reports **0.0% `elide%` and 97.5% `ceil%`** on `a.*b` — so C4's
premise holds where C2's and C3's did not, and the only thing between it and a large
win is one threshold. That reading says *build it*, so it got built.

The census needed a second slate first, and noticing why is most of the work. Every
`fill` in the search slate is chosen to make its pattern unmatchable by excluding a
byte the pattern needs *first*, which parks the walk in the start state for the
whole document — `seen = 1`. That is exactly right for C1, whose claim is about the
match test on every step, and exactly wrong for C4, because a skip out of an
interior state cannot pay in a document that never enters one. Run on that slate
alone, C4 reads as dead: `skip = 0`, `hot = 0`, every refusal `porous`.

So `dwell_slate` is built the other way round: each fill contains the pattern's
*opening* byte and omits a later one, so the walk leaves start immediately, lands in
a `.*`-shaped state, and sits there to end of line without matching. On those rows
the refusals flip from `porous` to `unprofitable` — narrow exit set, refused on
expected stride — which is a completely different verdict about the same claim.

One row could not be built and saying why is the rule: there is no `/\*.*\*/` row,
because an alphabet that can spell the opening `/*` necessarily holds both `*` and
`/`, so a random fill eventually spells the closing `*/` and the document matches.
Every row here needs its unmatchable byte to be one the opening does not also need,
which is why `{`/`}`, `<`/`>`, and `"`/`;` work where a symmetric delimiter cannot.
The harness checks the claim with `docMatch` rather than trusting the comment, so a
fill that can spell its pattern fails the run.

**Then the cost arm answered the timing question, and the answer was no.** An
interior dwell must stop at every `\n` — a line matcher never sees one inside its
line, and a document scan resolves `$` at one — so pinning `\n` into the exit set
caps an interior skip's stride at the **mean line length**. The start dwell has no
such cap: when crossing `\n` is a provable no-op it is omitted and the skip runs
across newlines freely. So the census's 97% was always going to be spent in strides
of one line, and whether that pays is a question about the fixed cost of entering
the vector kernel — which only a timing can settle.

With the bar waived, so every narrow-exit state is armed, the skip is **0.38×
geomean** against the multi-lane `docMatch`. The `stride` column says why in one
number: `foo.*bar`'s interior dwell exits on `b`, its document *contains* `b`, so
each skip elides 3.8 bytes and pays full kernel entry for them — ~10× slower. `a.*b`
wins 1.08× only because its fill excludes `b` outright and the stride becomes the
whole distance to `\n`. Same exit set, same build-time prediction, opposite outcomes,
and the difference is a property of the document that no build-time prior can see.

**And the threshold is right to within ~6%, on the other side of the bar than it used
to be.** The break-even sweep moves only the line length, so the x-axis is exactly
the quantity the bar predicts: `vs ship` crosses 1.000× between a 31.0-byte stride
(0.92×) and a 47.0-byte one (1.28×). Break-even ≈ **34 bytes**;
`dwell.min_profitable_stride` is **32**, calibrated years earlier on the start case
alone. That crossing was ≈30 bytes before the doc walk gained its byte-indexed
mirror, so a ~1.28× faster `ship` turned a marginally conservative bar into a
marginally optimistic one — same ~6% magnitude, opposite sign, no dwell code touched.

So C4 is retired, and the shape of its retirement is the useful part. It is the one
claim here whose premise survived every cheap test — which is precisely why it had to
be built and timed against the walk the product actually runs rather than the
convenient one. `vs step` reads 2.58× on the row where `vs ship` reads 1.08×; both
are true, both are attributable, and only one of them is the answer. And because the
verdict is quoted against the shipped walk, it re-decides itself for free: the mirror
moved every `vs ship` figure further against C4 without the claim being reopened.

**The residual it named is retired here too, and it never had to be built.** C4's loss
came from a prior that cannot see the document, so the fix on the table was a skip that
measures its own stride and disarms itself. The trick that prices it is to hand the
mechanism its measurement *free and without error* — then the timing is an upper bound
on every real version, bookkeeping and learning error included, and a losing bound
retires the claim without writing it.

The per-site numbers say the headroom is real: `a.*b.*c` loses at ~0.52× armed
unconditionally, yet **77.8%** of its bytes sit under skips that individually clear the
32-byte bar. And the per-state strides say it is *learnable* — `8 70` inside `a.*b`,
`8 8 61` inside `a.*b.*c`, so the dispersion separates which dwell rather than hiding
inside one, which makes a per-state counter a sufficient statistic. The mechanism is
sound in principle, and that is what makes the timing decisive instead of a proxy.

Keeping exactly the states whose own realized stride pays reads **0.53× geomean
vs ship** over three fresh runs. It beats C4 by a stable 1.40–1.41× measured in the
same runs (0.380 → 0.532, 0.376 → 0.529, 0.376 → 0.526) and still loses by ~1.9× —
and `a.*b`, C4's one winner, gets *worse* (1.08–1.10× → 0.76–0.79×), because disarming
its 8-byte state removed a skip that beat stepping even below the bar. The reason is
structural: the skip lives in the scalar walk, ~2.4× behind the shipped lanes, so
**adaptivity can choose better states but cannot relocate the walk it runs in.**
`foo.*bar` shows the floor from the other side — with nothing armed the arm is still
0.78–0.81× of `step`, because merely asking "is this state armed" costs per byte. That
last figure is inflated by a division on a runtime `ncls` this harness has not folded
into the state representation; crediting it back in full moves the ceiling only to
≈0.7×, so the verdict does not rest on it.

## C5, and the slate that could not speak for the shape

`reduce` prices both quotient dimensions of `automata/reduce.zig` on the byte road.
Over the everyday slate the answer looks unambiguous: **rows collapse on 1 automaton
in 32** — one state, on `[a-z]+[A-Z]\w+` — for a geomean **19.4%** of the
determinization that built the table. Interning on the NFA-state *set* has already
landed this construction near the Myhill–Nerode quotient, so two reachable states
differ only when their sets do, which is nearly always a suffix difference too.
Columns are cheaper (**1.8%**) and hit just as rarely: exactly one row, an eight-way
single-byte alternation, 9 columns to 2 and 792 bytes to 176.

(Those ASCII figures are the pre-`oneByteUnion` reading, kept because they are what
motivated the lowering fix; the same slate now collapses columns on **0/32** rows.
See the front-end paragraph below.)

That reading is a trap, and finding out why is the section's real result. **The one
shape whose states are indistinguishable *by construction* was silently absent.** A
UTF-8 range trie is not a wider ASCII program; it is a decoder, and wherever two
scalar ranges resume the same continuation its states accept the same suffixes. Five
`\p{…}` rows in `width_slate` were compiled without `unicode`, so they built nothing
and a bare `catch return` dropped them — for as long as the section existed, leaving a
slate that looked complete and read as a clean decline. A row that will not compile now
says `will not compile as ascii` out loud. Forced down the byte road on their own
slate (`symbolic = .off`, which is what production does when the symbolic path
declines a construct outright) the same passes read the other way: **columns collapse
on 4 rows in 5 for 0.6%**, and `\w{3,8}` sheds a quarter of its states — 1264 to 949,
a 1.0 MB table to 729 KB.

**So it was timed, and the table being smaller is not worth anything.** C2 had already
measured table *area* free at constant touched breadth across an 85× sweep; this says
the same law still holds one order of magnitude up. Rows whose table did not change at
all scan at 0.97–1.04×, so the instrument's floor is about ±4%, and every row whose
table *did* shrink lands inside it — `\w+X` at 267 KB → 247 KB reads 0.98×. The one
material row collapse cannot be timed at all, and the slate records that instead of
faking it: `\w{3,8}` accepts any three word bytes, so no alphabet with a word byte in
it can spell a document it misses, and the row prints `matched` rather than a number
earned on a prefix.

The residual ASCII columns are the last piece, and they are a **front-end** artifact
rather than an automaton fact — which is now a measurement rather than a diagnosis,
because the front end got fixed. `compile.zig` lowered the parser's tree, where
`(a|b|…|h)` was eight `consume` states behind seven splits, while `ast/algebra.zig`
already knew an alternation of byte classes *is* a byte class. `oneByteUnion` folds it
at that seam, and the row that motivated this whole paragraph now reads:

| `(a\|b\|c\|d\|e\|f\|g\|h){10}` | before | after | |
| --- | --- | --- | --- |
| NFA states | 151 | **11** | 13.7× |
| scratch words | 3 | **1** | — |
| byte classes | 9 | **2** | 4.5× |
| table bytes | 792 | **176** | 4.5× |
| determinization | 56.9 µs | **3.6 µs** | **15.8×** |
| what `reduce` still finds | 9→2 cols | **nothing** | — |

**The ASCII column collapse went from 1/32 rows to 0/32.** The one row on the whole
everyday slate that had residual column redundancy arrives minimal now, so the claim
that a post-hoc merge was cleaning up after the lowering is settled: fixing the
lowering removed *all* of it, and 4.5× of table went with a 15.8× faster build rather
than being bought back by a pass that costs 2% of one.

`(?:foo|bar|baz|qux|quux|corge){8}` is the control and it does not move — 209 NFA
states, 13 classes, 10088 bytes, 163 µs, columns still 13→13 — because its branches
are *concats*, so the fold declines them. Both facts are the same fact: the fold fires
on exactly the shape whose branches consume one byte, and that shape is where all the
redundancy was.

So the byte road still runs neither reduction pass, `symbolic/transcribe.zig` still
runs both (its product carries a decoder phase the pattern cannot observe, so its rows
are genuinely redundant, and collapsing them is what makes its columns coincide), and
the trie rows' 4/5 column collapse stays where it is — that one is a real automaton
property of a UTF-8 decoder, not a front-end artifact, and C5 already measured it as
not worth spending on the walk.

## C7, and the arm that exists to find nothing

`inner` is the first section here whose first job was to check whether the claim
had already shipped. It had, in half: **25 of 33 rows prove a mandatory literal
and the engine already searches for it**, because `lower.zig` compiles it into a
`.candidate` `LiteralSet` that `ladder/verdict.zig` consults ahead of every
automaton. Pricing that as a win would have been pricing `git log`.

The half that had not shipped is the *offset*. `presence` is
`findRaw(hay, 0) != null` — the position was computed at SIMD bandwidth and
discarded, and then the slowest machine in the ladder re-crossed the buffer from
byte zero to rediscover it. The premise arm says the population is real:
**11 rows have an interior literal**, unreachable by a first-byte skip, and where
both strides are comparable the literal skips **6.9× further** than the first-byte
set. It also says the two accelerators do not overlap — **29 of 33 rows have no
start dwell at all** — because a wide first-byte set is simultaneously what makes
a literal interior and what denies the existing skip.

**And it says what not to build.** A confirmation *window* needs an interior
literal *and* a finite longest match, which is **3 rows in 33**, all synthetic UUID
shapes. `inf` is the ordinary case, and that is the whole reason the field builds a
reverse automaton rather than a window: there is no window to confirm inside. So
the boolean path got the cheap mechanism instead — a line seam, sound because no
match crosses `\n` and every match contains the literal — and the reverse jaw stays
where it already was, on the span path.

The `lead` arm prices it at **16.30× geomean over 30 (row × split) pairs**,
28–37× on the eight rows with an interior literal and a late match. The number
that matters more is the two rows reading **1.00×**: their fill can spell the
literal, so the first occurrence is at lead 0%, the suffix is the whole buffer,
and they save nothing. A mechanism whose control does not read 1.00× is not free,
it is a trade with the losing side unmeasured.

`leadAdverse` closes that off as a measurement. Same documents, **no** witness, so
every row answers `false` and the seam can only cost: **worst 0.98× over 11 rows**,
which is the instrument's noise, because `find` and `presence` are the same scan
with one result kept. It also asserts the direction that would be a *bug* rather
than a slowdown — a suffix that reports a match the whole buffer does not hold
fails the run.

## C9, and the pairing that killed a true premise

The `sift` arm audits one decision: `scan/literal_set.zig` picks its scan kernel by
**needle count** — 1 ⇒ rare-byte memmem, ≤64 ⇒ grouped Teddy, beyond ⇒ sparse
Aho–Corasick — and consults no selectivity at all, even though the corpus-priced
`prefilter.Economics` sits one module over. That criticism is correct, and the arm
confirms it by reading the chosen kernel off the compiled handle.

Then it declines to accept that being *unprincipled* makes it *wrong*. Both arms are
the same compiled program with `literal_scan` nulled for the control, so the only
difference is whether the prefilter exists, and the stood-down arm has to agree on
the verdict or the row is void. Arming pays on **10 of 11 rows**, geomean 2.47–2.95×,
and **3.96–4.16× on real-code documents**.

The design that makes the result more than an aggregate is the **pairing**: each
pattern appears against three documents — one where its anchor bytes are everywhere,
one where they are absent, one of real source text. Rows sharing a pattern share
every number a gate could possibly read: same needles, same anchors, same
corpus-priced stride, same `beatsDense` answer. So when their verdicts disagree, the
disagreement is a proof rather than an observation.

They disagree hardest on the slate's only loss. `xylophone` tiled over the unit
`xy` plus a space reads
**0.18×** — the memmem's two rarest-byte anchors are ubiquitous there, so every
candidate fails its verify — while the same pattern on real code reads **5.96×**.
Identical stride, identical `pays`, opposite correct decisions. What separates them
is the document's byte distribution, which is exactly the thing a pattern-derived
prior does not know.

And the particular gate C9 names would fire backwards: `beatsDense(32)` answers
**no on 9 of the 11 rows**, including the 1.09–6.57× wins, because it is calibrated
for a single-byte-class skip where stride is the whole economics. A nine-byte needle
verified from two rare anchors is a different unit — a dense anchor costs one cheap
rejected verify, not a lost skip.

Which leaves the adversarial row to a document-adaptive mechanism, and that is the
family the `dwell` arm already priced at 0.56× against ship. Same door, closed twice.

## Two premises it refuses to assume

**Documents must be match-free.** A boolean scan returns at the first hit, so
timing a matching haystack measures the match position and not the recurrence.
Each row carries the alphabet its document is drawn from, chosen so the pattern
provably cannot match — and the harness *checks* it. A document that matches
fails the run rather than publishing a number.

**The arms must agree.** A single verdict disagreement exits non-zero. A speed
number on a pattern where the two arms disagree is not a number, it is a bug
report. (The exhaustive proof is elsewhere: the Pike VM differential in
`zig build test`, which cleared 209,700 document decisions and 209,550 line
decisions over 1,397 patterns with zero divergences when this layout landed.)

## Where the superseded code lives

Inside `bench.zig`, and nowhere else. `walkLoaded` is the *old* form of the walk;
keeping it in the engine so a benchmark could reach it would leave a second
transcription of the hot loop for someone to accidentally link. It lives beside
the thing that measures it, which is the only consumer it should ever have.
