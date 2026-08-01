---
doc_radar:
  paths_exist:
    - bench/rungs/sieve/bench.zig
    - bench/rungs/sieve/indexq.zig
    - bench/rungs/sieve/stress.zig
    - bench/rungs/sieve/csearch_plan.py
    - bench/rungs/sieve/indexcost.sh
    - bench/rungs/sieve/cover_parity.sh
    - bench/rungs/sieve/warm_parity.sh
    - src/kernel/query/cover.zig
    - src/kernel/regex/linear/sieve/sieve.zig
  sentinels:
    - description: "the harness fails closed on a missed match, on a retired matching document, and on a ladder that disagrees with the full scan"
      file: bench/rungs/sieve/bench.zig
      contains:
        - "SOUNDNESS VIOLATION"
        - "DOCUMENT VIOLATION"
        - "LADDER DIVERGENCE"
    - description: "Layer L fails closed on a cross-arm hit disagreement — a formula that pruned a real match"
      file: bench/rungs/sieve/indexq.zig
      contains:
        - "a filter elided a real match"
        - "one of the three formulas is UNSOUND"
    - description: "the warm gate compares four arms, refuses a vacuous green (a stack that never fired, a daemon that died mid-run), and derives its baseline from a second daemon rather than a client-side env var"
      file: bench/rungs/sieve/warm_parity.sh
      contains:
        - "start_daemon pre-wiring"
        - "require_daemons"
        - "makes the parity above"
        - "--no-index"
---

# bench/sieve — measuring what a filter declines to read

This folder measures **what a filter declines to read**, from both ends of the
pipeline and on both tiers. `bench.zig` proves the quotient sieve's per-position
rejection inside the matcher; `indexq.zig` measures the trigram index's
per-document selectivity against csearch's; the two `*_parity.sh` gates hold each
wired tier byte-identical to what it replaced. Everything here is fail-closed
against the production matcher — nothing reports a speed number it has not first
proved correct.

- **`zig build sieve`** → the quotient sieve (below).
- **`zig build indexq`** → [Layer L, index quality vs csearch](#layer-l--index-quality-head-to-head-against-csearch).
- **`bash cover_parity.sh`** → the cold tier's cover plan changed no answer.
- **`bash warm_parity.sh`** → [the resident session's copy of that stack](#the-warm-tier-gate--a-daemon-may-not-prune-differently-than-cold).

# The quotient sieve's production proof harness

`zig build sieve` (from ``) links the **real** engine and
the **real** rung, then walks the **real** host corpus. The baseline is the
shipped `Dfa.docMatch`, not a reimplementation, and both arms run in the same
process over the same bytes so the ratio survives a box carrying ten coworker
agents.

This rung is the one that can only say **no**, so its harness is shaped
differently from its siblings': the thing that must be proved is not that a
`.hit` is right — there are none — but that a `.miss` is never a lie.

Three claims, each fail-closed:

1. **Soundness, checked twice and at two grains.** Per byte position: whenever
   the search DFA is in a matching state, every conjunct of the quotient must be
   in an accepting block. Per document: end to end against the production
   matcher, not against the DFA the sieve was derived from — deriving the oracle
   from the same object would let a shared mistake pass. One violation anywhere
   in the corpus exits non-zero, because a false reject is a **missed match**,
   the worst failure this engine has.
2. **Selectivity, measured against the estimate that gates it.** Each row prints
   the share of positions that survive beside the compile-time structural
   estimate used to decide whether the sieve arms at all. The bad rows are
   printed rather than dropped: the distribution is genuinely bimodal, and the
   gate exists precisely because of that.
3. **Speed, and the losses too.** The Sheng-resident kernel against the shipped
   `docMatch` over the same bytes in the same run — plus a ladder check _inside_
   the timing loop, so a fast wrong answer can never be reported as a fast one.

## Two numbers worth reading before trusting the third

**Rejection rate does not predict the ladder; documents kept does.** A pattern
can reject 99% of byte positions and still keep 80% of _files_, because matches
cluster and one survivor costs the whole document. Any prefilter calibrated on
position-rejection is measuring the wrong quantity — a lesson this harness
learned the expensive way and now reports both ways.

**The gate declines most patterns, and that is the result, not a shortfall.**
Where the class-run kernel already runs at ~10 GB/s, fronting it with a sieve
_loses_. The rows that would have lost are among the declined ones; a run with
no false arms is the harness passing, not the rung failing to find work.

Novelty is disclaimed in the source header and in
[`research/ceiling/CLOSED.md`](../../../research/ceiling/CLOSED.md): the
over-approximating-prefilter contract is Luchaup et al. (INFOCOM 2014), Češka et
al. (arXiv:1904.10786), and Hyperscan's `HS_FLAG_PREFILTER`. What is ours is the
SP-partition harvest from an already-built DFA and the measured decision of when
it is worth arming.

---

# Layer L — index quality head-to-head against csearch

`zig build indexq` answers one claim: _"your trigram index is **csearch-class,
not better**."_ csearch (Google Code Search, Russ Cox 2012) is gist's
acknowledged trigram ancestor, so the comparison has to be against what csearch
_actually does_, on the axis that actually defines an index.

**That axis is not wall time.** Wall time confounds the index with the walk, the
IO and the matcher, none of which the claim is about. A filter has three honest
measures: the candidate **bytes** it admits, the **precision** of what it
admits, and what it **costs** to build. This harness measures all three.

## What is held fixed, and what varies

One corpus, one built index, one evaluator (`Index.queryPlan`), one verifier
(the production matcher). The **only** thing that differs between arms is the
boolean formula over trigrams:

| arm         | formula                                                                                                                      |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `gist-base` | the pre-Layer-L prefilter — one required literal, else the per-branch alternation cover (one clause)                         |
| `gist`      | the conjunctive cover (`src/kernel/query/cover.zig`), read off the pattern source with the matcher's own parse options       |
| `csearch`   | **csearch's own formula**, lifted verbatim from `csearch -verbose` by `csearch_plan.py` and replayed against gist's postings |

csearch's arm is not a reimplementation and not a proxy. `csearch -verbose`
prints `index.RegexpQuery(re.Syntax)` rendered by `Query.String()`; the parser in
`csearch_plan.py` reads that grammar and re-emits it in gist's CNF plan shape,
which covers csearch's AND/OR tree exactly.

## Fail-closed, twice

Every arm must verify to the **same hit count** on every class — each formula is
supposed to admit a sound superset, so an arm that finds fewer has silently
elided a real match. The harness exits non-zero on any disagreement, and
`certify_indexq_report.py` re-checks it from the TSV so a stale artifact cannot
launder an unsound run.

Soundness of the planner itself is proved separately and structurally:
`matched ⇒ never pruned`, brute-forced against the production matcher over an
exhaustively enumerated document space (`src/kernel/query/cover_test.zig`),
in the discipline of the crest Sieve Theorem (`research/crest/PROOF.md`).

## Two slates, reported separately

`bench/harness/probes.zig` — the certificate's own twelve classes — is reported
first and unedited, so nobody can call it chosen to flatter gist. But it was
designed to span _scan_ cost (Layers A and D), and on the **planner** axis eight
of its twelve rows cannot separate two planners at all: four are single-literal,
and four are structurally unfilterable (literal-free, sub-trigram, or an
alternation with a sub-trigram branch), where the only sound answer is "no
filter" and both tools give it.

So `stress.zig` adds eight shapes a real code search produces — a Go nil-check,
a Zig signature, an ISO date, a hex constant, a URL, an ADR cite, a method
alternation, a `:=` assignment — chosen because csearch's planner has a real,
non-obvious answer for each. They are reported and spliced under their own
heading, never merged into the twelve.

## Running it

All paths below are relative to this package (this repo); the
artifacts land under the repo-root `.local/gist-verify/` the other layers
already write to, which is `../../../.local/gist-verify` from here.

```bash
cd <irregex-repo-root>
(cd ../../.. && install the sibling `gist` package)   # gist's index over the shared corpus

# csearch's index over the byte-identical file list, then its own formula per probe
python3 bench/sieve/csearch_plan.py \
  --probes bench/harness/probes.zig --probes bench/sieve/stress.zig \
  --index ../../../.local/gist-compete/csearch.idx \
  --out ../../../.local/gist-verify/indexq_csearch.plan

zig build indexq -Doptimize=ReleaseFast   # selectivity + precision → indexq.tsv
bash bench/sieve/indexcost.sh             # size / build / peak RSS → indexcost.tsv
```

`zig build indexq` runs with the repo root as its cwd (`build.zig` sets it), so
its `indexq.tsv` is written to `.local/gist-verify/` regardless of where you
invoked it from.

`indexq` accepts `--cover-class=N`, `--cover-atoms=N`, `--cover-clauses=N` so
the planner's cost ceilings are a **measured frontier** rather than asserted
constants; the shipped defaults are the knees of that sweep.

`indexcost.sh` **sources** `bench/races/_compete.sh` (a library, never executed)
so the fairness contract — csearch indexes gist's exact corpus, the persisted
`paths.list` — is not re-litigated or duplicated here.

## Splicing the certificate

```bash
python3 bench/certify/certify_indexq_report.py \
  --certificate bench/certify/artifact/CERTIFICATE.md \
  --tsv ../../../.local/gist-verify/indexq.tsv \
  --cost-tsv ../../../.local/gist-verify/indexcost.tsv \
  --machine "$(uname -m)" --zig "$(zig version)"
```

`certify_layers.sh` wires it with its own `${OUT}` / `${CERT}` variables, which
already resolve to the same two files.

The reporter refuses to splice a win it cannot substantiate. It exits non-zero,
writing nothing, if gist does not admit strictly fewer candidate bytes in total,
if gist admits **more** on any single class, if any arm's verified hit count
differs, or if gist's index exceeds 1.10× csearch's size or 1.50× its build
time — selectivity bought with a pathologically bigger or slower index is not a
better index.

---

# The warm tier gate — a daemon may not prune differently than cold

`bash warm_parity.sh` guards the day the resident session was given the cold
tier's pruning stack. Before it, warm asked the trigram index exactly one
question — the flat OR of the sound prefilter literals — while cold had been
asking two stronger ones for a while: the conjunctive cover plan and the crest
sieve over per-document ρ(d). A literal-free class repetition like `[0-9a-f]{8}`
forces no trigram, so the daemon read **100% of the corpus** for it while the CLI
beside it read 6%.

Closing that gap means strictly more elision, and a prefilter that elides one
file it should have read is the worst defect a search tool can ship: silent,
total, and indistinguishable from "no match". So the gate asserts the only
property that matters — the answer did not move — on four arms per case:

| arm          | what it is                                                 |
| ------------ | ---------------------------------------------------------- |
| `warm`       | the resident daemon with the stack on                      |
| `pre-wiring` | **a second daemon** with `GIST_NO_COVER=1 GIST_NO_CREST=1` |
| `live`       | `gist --no-index` — no index at all, the semantic oracle   |
| `rg`         | ripgrep, so gist's two tiers cannot agree on a shared bug  |

All four must produce the same line multiset. `warm` vs `pre-wiring` isolates the
two new prunings on ONE binary, so no build difference can confound the result;
`live` is the transitive proof that warm ≡ cold without either path having to
trust a shared index; `rg` is the third-party check.

**The baseline is a second daemon, and that is load-bearing.** Both stand-down
knobs are read where the pruning is derived — inside the resident session — so
exporting them on a client that gets served warm changes nothing at all, and a
baseline arm spelled that way would silently be a copy of the arm under test.
Two sockets, two sessions, one binary.

## Three ways this gate refuses to pass vacuously

1. **A stack that never fired.** Parity is trivially satisfied by a pruning that
   does nothing, so the gate reads the tier and the admitted document count back
   out of the daemon's own `.index` trace — armed on the daemon, relayed to the
   client over the `diag` frame — and fails if either half narrowed nothing. The
   cover's contribution and the sieve's are attributed **separately**, because a
   pattern like `[0-9a-f]{8}-[0-9a-f]{4}` gets both and crediting its whole prune
   to the sieve would overstate the half being introduced.
2. **A daemon that died mid-run.** A dead daemon and a healthy decline are the
   same `[cold]` string at the client, and cold answers correctly — so every
   later case would keep passing while testing nothing. A death is a hard stop
   naming the case that caused it.
3. **A corpus that moved underneath it.** The corpus is real host source copied
   into a throwaway tree and indexed there. ~10 agents edit this branch
   concurrently and a repo-wide arm takes long enough that two _identical_ runs
   already disagree; freezing the bytes is what lets a difference between arms
   mean something.

The case list is the axis list, not coverage theater — each case exercises a
different stand-down: `-i` stands the cover down but keeps the sieve, `-F` and
`-P` stand both down (a fixed string is not regex source; PCRE2 denotes the
pattern under a foreign grammar), `-v` walks every document so the candidate set
must be a positive superset, and the unprovable patterns (`.*`) must be pruned by
nothing at all.

## What it measured

27 cases byte-identical across all four arms on a frozen 5,883-file corpus. The
cover plan narrowed the index answer on 5 patterns (39-93% of the pre-wiring
candidate set), and the crest sieve narrowed it further on 7 (44-94%) — including
the four the trigram index concedes entirely, where `tier=none` and the sieve is
the _only_ thing pruning. `[0-9a-f]{8}` went from every document to 6% of them.

End-to-end that is **1.4-1.9× geomean** over the ten patterns either half can
prune. It is a range because it is a range: two runs on this laptop reproduced
the candidate columns _exactly_ — same tier, same percentages, every row — and
landed at 1.43× and 1.87×. Both arms are the same client spawn and socket
handshake around a 3-18 ms answer, so a fixed cost sitting in both terms
compresses the ratio toward 1, and how much it compresses depends on what else
the machine is doing. Read the candidate columns as the measure of the two
prunings and the milliseconds as what a caller feels; the gate deliberately
asserts the former and only reports the latter.

## Running both parity gates

`the prefilter parity gates under `bench/rungs/sieve/`` is the wired entry point: it builds the ReleaseFast
binary both scripts require and runs them in dependency order — the cold tier's
cover plan first, then the resident session's copy of it. It stays out of
`zig build test`, which is CI-hermetic and needs only Zig, because these two
freeze a multi-thousand-file corpus, index it, and bring up resident daemons.
`rg` is optional (a missing ripgrep drops that arm and keeps the other three);
`rsync` is not, since it is how the corpus gets frozen, so the target skips
rather than measure a tree ten agents are editing.

```bash
the prefilter parity gates under `bench/rungs/sieve/`                # both gates, binary built for you

cd <irregex-repo-root>                 # or one at a time, mid-edit
zig build -Doptimize=ReleaseFast
bash bench/rungs/sieve/cover_parity.sh
bash bench/rungs/sieve/warm_parity.sh   # KEEP=1 leaves the corpus + daemon logs
```
