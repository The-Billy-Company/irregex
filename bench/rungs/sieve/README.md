---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/bench/sieve/bench.zig
    - pkg/kernels/irregex/bench/sieve/indexq.zig
    - pkg/kernels/irregex/bench/sieve/stress.zig
    - pkg/kernels/irregex/bench/sieve/csearch_plan.py
    - pkg/kernels/irregex/bench/sieve/indexcost.sh
    - pkg/kernels/irregex/src/kernel/query/cover.zig
    - pkg/kernels/irregex/src/kernel/regex/linear/sieve/sieve.zig
  sentinels:
    - description: "the harness fails closed on a missed match, on a retired matching document, and on a ladder that disagrees with the full scan"
      file: pkg/kernels/irregex/bench/sieve/bench.zig
      contains:
        - "SOUNDNESS VIOLATION"
        - "DOCUMENT VIOLATION"
        - "LADDER DIVERGENCE"
    - description: "Layer L fails closed on a cross-arm hit disagreement — a formula that pruned a real match"
      file: pkg/kernels/irregex/bench/sieve/indexq.zig
      contains:
        - "a filter elided a real match"
        - "one of the three formulas is UNSOUND"
---

# bench/sieve — two proof harnesses over the same corpus

This folder holds the two harnesses that measure **what a filter declines to
read**, from the two ends of the pipeline: `bench.zig` proves the quotient
sieve's per-position rejection inside the matcher, and `indexq.zig` measures the
trigram index's per-document selectivity against csearch's. Both are fail-closed
against the production matcher; neither reports a speed number it has not first
proved correct.

- **`zig build sieve`** → the quotient sieve (below).
- **`zig build indexq`** → [Layer L, index quality vs csearch](#layer-l--index-quality-head-to-head-against-csearch).

# The quotient sieve's production proof harness

`zig build sieve` (from `pkg/kernels/irregex/`) links the **real** engine and
the **real** rung, then walks the **real** Billy corpus. The baseline is the
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
[`research/ceiling/CLOSED.md`](../../research/ceiling/CLOSED.md): the
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
| `gist`      | the conjunctive cover (`src/kernel/query/cover.zig`), read off the pattern source with the matcher's own parse options |
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

All paths below are relative to this package (`pkg/kernels/irregex`); the
artifacts land under the repo-root `.local/gist-verify/` the other layers
already write to, which is `../../../.local/gist-verify` from here.

```bash
cd pkg/kernels/irregex
(cd ../../.. && make install-gist)   # gist's index over the shared corpus

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
