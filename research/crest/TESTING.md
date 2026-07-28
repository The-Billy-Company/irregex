# Crest — the complete testing story

Every layer of Crest is tested at the level where its failure would be
invisible elsewhere, and every soundness gate is **fail-closed**: a violation
exits non-zero, and the fix is always the calculus, never the assertion
(sins.mdc Sin #2 — no bandaids).

The one property that matters is **soundness**: `matched ⇒ ¬pruned`, for
every document, every pattern, every mode. A false _positive_ (a survivor the
matcher rejects) costs only time; a false _negative_ (a pruned match) is a
wrong answer from gist. Every suite below exists to make a false negative
unable to hide.

---

## 1. Kernel unit tests — `src/kernel/math/crest_test.zig`

Hand-computed oracles against the calculus, one test per load-bearing rule:

| test                  | pins                                                                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| document crest        | hand-counted runs for all eight classes                                                                                                         |
| class repetition      | `[0-9a-f]{8}` forces hex and word runs of 8                                                                                                     |
| concatenation         | saturated seam addition and exact epsilon identity                                                                                              |
| optional certificates | digit and non-digit optionals cannot be confused across `?`, `*`, `{0,m}`, or `{0,0}`                                                           |
| alternation           | componentwise minima and conjunctive `only_c_cert` inside an expression; a `Swell` disjunction at the root                                      |
| disjunction           | a swell prunes only what clears no alternative, dominates the retired fold on 8,192 random vectors, and goes inert when one branch demands `0⃗` |
| degradation           | unsupported syntax and unsafe case folds yield `0⃗`; case-closed caseless classes remain active                                                 |
| escapes and Unicode   | real escaped bytes plus the byte/codepoint alphabet contract                                                                                    |
| counted repetition    | malformed bounds degrade; 70,000 copies saturate without a 4,096 clamp                                                                          |
| profile constructors  | epsilon certifies every class; unknown certifies none                                                                                           |
| common saturation     | 70,000-byte query and document values both compare as 65,535                                                                                    |

## 2. Sidecar codec tests — `src/corpus/index/crest/sidecar_test.zig`

The persistence layer is where silent corruption would become a wrong answer
years later, so it gets the adversarial treatment the trigram loader gets:

- **Round-trip identity** — `build → writeInto → decode` reproduces every
  vector bit-for-bit.
- **Fail-closed decode** — every malformed blob (truncated header, wrong
  magic/version/schema hash, wrong K/width/doc count, nonzero reserved byte,
  torn/padded tail, misaligned body) decodes to `null`, which the loader treats
  as "no sidecar": the sieve disables rather than pruning on garbage.
- **Semantic identity** — the pinned hash preimage includes class order, all
  256 membership masks, the 65,535 cap, element interpretation, and format
  version; `GISTCRS1` is rejected rather than guessed compatible.

## 3. Production proof harness — `bench/crest/bench.zig` (`zig build crest`)

Links the **real** engine (`Regex.docMatch`) and walks the **real** Billy
corpus via the same `corpus.load` the optimality certificate uses. Six gates
per run:

1. **Fixed production regression.** The real matcher accepts `1a2` for
   `[0-9][a-z]?[0-9]` and Crest retains it. The positive precision control
   `[0-9][0-9]?[0-9]` derives a digit threshold of 2. The disjunctive control
   `[0-9]{3}|~{3}` derives two alternatives and prunes `1a2` on both.
2. **Corpus-wide soundness, fail-closed.** For every file × every slate
   query: if the production matcher matches, the sieve must not have pruned.
   One violation → exit 1. This is Theorem 1 checked against the shipped
   matcher on every file, not a model of it.
3. **Randomized adversarial sweep, all four modes.** 400 random class-repetition
   patterns (random classes, counts, concatenation, alternation) × 60 random
   files × byte/ASCII and rg-default Unicode × case-sensitive and caseless,
   each paired with its own ĝ exactly as production `crestSieve` does
   (Alphabet Contract). 96,000 (pattern, file) checks per run.
4. **Ablations.** The count-population cousin at identical thresholds, kept
   permanently so the "why the run, not the count" claim stays measured; and
   the retired single-vector fold (componentwise min over the alternatives), so
   the disjunction's gain is a measured column rather than a story.
5. **Dominance, fail-closed.** A row where the disjunction left more survivors
   than the fold exits non-zero — Corollary 4 checked on the live corpus.
6. **Speed.** Full-scan wall time vs sieve+survivors wall time, same matcher
   both sides. Ordered raw samples, seeds, differentials, and medians are
   preserved in `crest-run.json`; aggregates remain in `crest.csv`.

## 4. Integration correctness (the wiring, not the math)

The sieve rides both read-elision oracles (`serial.zig` `IndexSkip`,
`parallel.zig` `Elide`) behind gates that each default to _not pruning_:

- **Caseless** (`-i`): explicit ASCII atoms are case-closed before
  certification. Case-closed classes remain active; upper/lower and unsafe
  Unicode k/K/s/S folds decline to 0.
- **Unicode default**: ĝ computed under `.unicode = true`, which certifies
  only constructs whose byte and codepoint semantics coincide (explicit
  ASCII-only classes); everything else contributes 0.
- **Fresh files** (changed since the index was built): exempt from crest
  pruning — their persisted vectors are stale, so they are always read
  (`fresh_ids` from the freshness overlay).
- **Missing/invalid sidecar**: `decode` → null → sieve off. An old index
  without `crest.bin` keeps working, just without the new pruning.
- **Content transforms** (`-z`/`--pre`/`-E`): the sieve is computed from the
  _effective_ pattern only when no transform rewrites the bytes the matcher
  sees; otherwise disabled.

End-to-end: the full `zig build test` suite — including the rg-parity
differential/adversarial oracles that diff gist's match sets against
independent oracles — runs with the sieve live in the engine, so any wiring
false negative breaks parity loudly.

These tests deliberately keep the three proof obligations separate:
`crest_test.zig` checks the **Calculus theorem**; sidecar and generation tests
check the **Artifact theorem**; filesystem freshness suites check the
conditional **Freshness theorem**. Only their conjunction authorizes read
elision (`PROOF.md` §2.1).

## 5. Independent exact-automaton oracle (`spikes/ridge-spectrum/ridge.py`)

The tightness measurement (PROOF.md §3.6) is refereed, not asserted, by an
**independent** implementation of the exact forced run `g(R,C)` — built from a
_separate_ Thompson NFA compiler, so the AST calculus never grades itself:

- `g_exact` decides `g_i(R,C)` by emptiness of `NFA(R) × monitor(C,r,i)` (the
  monitor DFA counts maximal C-runs reaching length `r`), binary-searched over
  `r` — a textbook min-over-a-max-automaton value (Kuperberg–Vanden Boom;
  Mohri–Riley N-best for the rank), claimed by neither Crest nor Ridge.
- `ridge.py --oracle` asserts `ĝ_i ≤ g_i` on thousands of random (regex, class,
  rank) triples. Its 2026-07-19 pre-repair run was sound on every case and
  98.0% tight (mean gap 0.043); rerun it before assigning that percentage to
  the repaired epsilon/optional-certificate calculus.
- `ridge.py --selftest` runs the Spectrum Sieve property suite — **160,000**
  (regex, text) pairs, oracle = Python `re`, `matched ⇒ ¬pruned`, 0 false
  negatives.
- `ridge.py --bench` is the base-vs-ridge ablation (q=1 = shipped Crest vs
  q=4), soundness re-asserted per row.

## 6. Lineage — the Python spikes

Crest before a line of Zig: `spikes/classrun-formula/` — a Python
reference with a **240,000-pair** randomized property suite (oracle = Python
`re`), the count-cousin ablation, and the Erdős–Rényi selectivity model
validated against measured prune rates. Zero violations. The run-spectrum
extension (Ridge) and the exact oracle above come from
`spikes/ridge-spectrum/`. Both dossiers carry the originality referee
trail (PRIOR_ART.md §7–8).

## 7. Reproduce everything

```bash
cd pkg/kernels/irregex
zig build test        # §1 + §2 + engine parity suites
zig build crest       # §3 — exploratory raw evidence in .local/crest-evidence/
gist index && gist status   # §4 — sidecar persisted alongside index.gist
python3 spikes/ridge-spectrum/ridge.py --oracle --selftest  # §5 — oracle + property suite
cd ../../..
python3 pkg/kernels/irregex/bench/crest/evidence/crest_evidence.py package
# clean committed HEAD only: source archive + manifests + samples + monograph
```
