# `bench/rungs/multipattern` — the Hyperscan race (Layer K)

Three files, one question: **when N patterns must be found with per-pattern
attribution, who is faster and why?** The named champion is Hyperscan (Intel;
portable fork [Vectorscan](https://github.com/VectorCamp/vectorscan)), which owns
this problem in the literature. gist's answer is `PatternSet`
(`src/kernel/slate/`), the fused literal sieve in `muster.zig`, and the index.

The honest framing is that there are **two** questions, and only one of them is
the user's:

| arm        | question                                             | who should win                                                                    |
| ---------- | ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| per byte   | same resident bytes, N patterns, who matches faster? | Hyperscan's home turf — it is a stream scanner, and this is what it was built for |
| end to end | "find these N patterns across the corpus"            | gist, because it never reads most of the corpus                                   |

Publishing only the second would be a strawman; publishing only the first would
miss the workload. The harness runs both and the certificate prints both,
including the N at which gist loses.

## The files

| file        | what it is                                                                                                                                                                                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pack.py`   | packs one deterministic blob (`corpus.bin` + `corpus.idx`) from gist's persisted `paths.list`, so both matchers see identical bytes in identical order. Without this the "race" is really a comparison of two tree walks.                                         |
| `bench.zig` | gist's arm. Links the REAL kernel (`@import("irregex")`) and times `PatternSet.docMask` per document. `--verify` re-derives the whole attribution vector from N **independent** single-pattern `CompiledQuery` runs and exits non-zero on the first disagreement. |
| `vscan.c`   | the Vectorscan arm. `hs_compile_lit_multi` / `hs_compile_multi` + `hs_scan` per document, printing the same per-pattern document-count vector `bench.zig` prints — so cross-tool agreement is a diff, not a promise.                                              |

Both arms emit one JSON object on stdout with the same keys (`gbps`, `doc_hits`,
`docs`, `bytes`), which is what makes the two columns comparable at all.

## Running it

Vectorscan is a **competitor, not a dependency**: it is never vendored and never
enters a dependency trust plane. The harness finds it through
`pkg-config libhs` and skips every Vectorscan cell with a stated reason when it
is absent.

```bash
brew install vectorscan                     # optional — the rival column
cd <irregex-repo-root>
zig build -Doptimize=ReleaseFast lab        # builds the `multipattern` arm
bash ../gist/bench/dominance/races/multipattern.sh            # both arms, sweeps N=4,8,16,32,64
bash ../gist/bench/dominance/races/multipattern.sh -n 8,64 -m 32 services libs   # narrower
```

The harness writes `perbyte.tsv`, `meta.json`, and hyperfine exports under
`.local/gist-compete/multipattern/`, then prints the certify invocation. To
splice Layer K into the certificate:

```bash
python3 ../gist/bench/certificate/report/multipattern.py \
  --perbyte .local/gist-compete/multipattern/perbyte.tsv \
  --raw     .local/gist-compete/multipattern/raw \
  --meta    .local/gist-compete/multipattern/meta.json \
  --certificate ../gist/bench/certificate/artifact/CERTIFICATE.md \
  --csv         ../gist/bench/certificate/artifact/multipattern.csv
```

### Wiring it into the mint

This lane does not edit `gist/bench/certificate/mint/splice.sh` — the parent
wires all five new layers. The block to add, in that file's existing idiom
(`MULTIPATTERN_OUT` is honored by the harness, so the whole layer stays inside
`${OUT}`):

```bash
# Layer K — multi-pattern simultaneous matching (vs Hyperscan/Vectorscan). Both
# arms are fail-closed by construction (the race refuses to time an answer it has
# not proven); the report re-asserts K1-K4 and refuses to splice on any violation.
note "Layer K — multi-pattern vs Hyperscan/Vectorscan (fail-closed)…"
MULTIPATTERN_OUT="${OUT}/multipattern" bash "${HERE}/../../dominance/races/multipattern.sh" \
  || die "multipattern race failed (attribution violation) — fix src/kernel/slate, never weaken the sieve"
python3 "${HERE}/../report/multipattern.py" \
  --certificate "${CERT}" \
  --perbyte "${OUT}/multipattern/perbyte.tsv" \
  --raw "${OUT}/multipattern/raw" \
  --meta "${OUT}/multipattern/meta.json" \
  --csv "${OUT}/multipattern.csv" \
  || die "multipattern.py failed (Layer K invariant violated)"
```

`Layer K` also has to join the shared roster in
`gist/bench/certificate/guard/layers.py`, which the completeness gate and the
ledger both read — otherwise the section splices and the gate never notices it
exists.

## The measurement hazard that nearly published a fake number

Arm 2 times gist with **`GIST_NO_KEEP=1`**, and that is not hygiene. When a
`gist serve` daemon is resident, the pure `relate` verbs consult its **answer
keep** — a memo of rendered stdout for a query already asked against an
unchanged corpus. The harness gates arm 2's answer by running the identical
query immediately before timing it, which primes that memo, so hyperfine would
then measure ten recalls: **0.00 s warm against 0.14 s of real work**, i.e. a
~180× "win" over Vectorscan that is a hash lookup racing a search. The keep is a
genuine gist feature and stays on in normal use; it is simply not what this arm
claims to measure, and no competitor in the field has one. If you add a column
here, ask what it caches before you believe it.

## The one invariant that is not about speed

A `PatternSet` answer **is** N independent single-pattern gist answers, per
pattern, bit for bit. That is the contract `relate patterns` sells, and it is
gated in three places, deliberately overlapping:

- `src/kernel/slate/patterns_test.zig` proves it on hand-written documents with
  the sieve both armed and stripped, against a live single-query oracle.
- `bench.zig --verify` proves it at corpus scale against N real
  `CompiledQuery` runs.
- `certify_multipattern_report.py` refuses to splice any timing unless the
  sweep re-asserted it at every N (K1) and Vectorscan agreed on the same
  per-pattern counts (K2).

The sieve may only ever say _"this pattern cannot match"_. Never weaken it to win
a number.
