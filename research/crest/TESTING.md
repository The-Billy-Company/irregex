# Crest — the complete testing story

Every layer of Crest is tested at the level where its failure would be
invisible elsewhere, and every soundness gate is **fail-closed**: a violation
exits non-zero, and the fix is always the calculus, never the assertion
(sins.mdc Sin #2 — no bandaids).

The one property that matters is **soundness**: `matched ⇒ ¬pruned`, for
every document, every pattern, every mode. A false *positive* (a survivor the
matcher rejects) costs only time; a false *negative* (a pruned match) is a
wrong answer from gist. Every suite below exists to make a false negative
unable to hide.

---

## 1. Kernel unit tests — `src/math/crest_test.zig` (rides `zig build test`)

Hand-computed oracles against the calculus, one test per load-bearing rule:

| test | pins |
|---|---|
| crest vector: longest per-class run | `ρ(d)` against hand-counted runs, all 8 classes, including the 0-run absent class |
| forced-crest: class repetition | `[0-9a-f]{8}` ⇒ ĝ(hex)=8 and every superclass (word) inherits |
| forced-crest: concatenation straddle | `S(E₁)+P(E₂)` — the cross-seam term — against hand-derived values, incl. the `all_in` guard collapsing it |
| forced-crest: alternation | componentwise min; `all_in` survives only if both branches are all-in |
| soundness by degradation | backreferences, lookaround, POSIX classes, octal escapes, unknown escapes ⇒ `ĝ = 0⃗` (never a guess) |
| escapes | `\d`/`\w`/`\s` (ASCII mode), `\n`/`\t`/`\r`/`\f`/`\v` as literal bytes, class-internal escape-range refusal |
| unicode mode certification | in `.unicode = true`, `\d`/`\w`/`\s` and any class reaching ≥ 0x80 contribute ĝ=0 (Alphabet Contract); pure-ASCII explicit classes still certify |
| tightness gap is under-prune | `[0-9](?:)[0-9]`: ĝ=1 < g=2 — incompleteness demonstrated as *under*-pruning, pinned so a "fix" that over-tightens fails |
| sieve decision + saturation monotonicity | `pruned` at the u16 saturation boundary: saturated crests only ever *survive* more, never prune more |

## 2. Sidecar codec tests — `src/index/crest/sidecar_test.zig` (rides `zig build test`)

The persistence layer is where silent corruption would become a wrong answer
years later, so it gets the adversarial treatment the trigram loader gets:

- **Round-trip identity** — `build → writeInto → decode` reproduces every
  vector bit-for-bit.
- **Fail-closed decode** — every malformed blob (truncated header, wrong
  magic, wrong K, wrong doc count, torn tail, misaligned body) decodes to
  `null`, which the loader treats as "no sidecar": the sieve silently
  disables rather than pruning on garbage.

## 3. Production proof harness — `bench/crest/bench.zig` (`zig build crest`)

Links the **real** engine (`Regex.docMatch`) and walks the **real** Billy
corpus (52.7k files, ~494 MiB) via the same `corpus.load` the optimality
certificate uses. Four gates per run:

1. **Corpus-wide soundness, fail-closed.** For every file × every slate
   query: if the production matcher matches, the sieve must not have pruned.
   One violation → exit 1. This is Theorem 1 checked against the shipped
   matcher on every file, not a model of it.
2. **Randomized adversarial sweep, both modes.** 400 random class-repetition
   patterns (random classes, counts, concatenation, alternation) × 60 random
   files × **both** engine modes — byte/ASCII and rg-default Unicode — each
   mode paired with its own ĝ exactly as the production `crestSieve` pairs
   them (Alphabet Contract). 48,000 (pattern, file) checks per run.
3. **Ablation.** The count-population cousin at identical thresholds, kept
   permanently so the "why the run, not the count" claim stays measured
   (hex-8: 0.7% vs 91.4%).
4. **Speed.** Full-scan wall time vs sieve+survivors wall time, same matcher
   both sides — the ratio is purely avoided work. Results → `crest.csv`.

## 4. Integration correctness (the wiring, not the math)

The sieve rides both read-elision oracles (`serial.zig` `IndexSkip`,
`parallel.zig` `Elide`) behind gates that each default to *not pruning*:

- **Caseless** (`-i`): sieve disabled (ĝ=0⃗) — case-folding changes class
  membership, so no certification is attempted.
- **Unicode default**: ĝ computed under `.unicode = true`, which certifies
  only constructs whose byte and codepoint semantics coincide (explicit
  ASCII-only classes); everything else contributes 0.
- **Fresh files** (changed since the index was built): exempt from crest
  pruning — their persisted vectors are stale, so they are always read
  (`fresh_ids` from the freshness overlay).
- **Missing/invalid sidecar**: `decode` → null → sieve off. An old index
  without `crest.bin` keeps working, just without the new pruning.
- **Content transforms** (`-z`/`--pre`/`-E`): the sieve is computed from the
  *effective* pattern only when no transform rewrites the bytes the matcher
  sees; otherwise disabled.

End-to-end: the full `zig build test` suite — including the rg-parity
differential/adversarial oracles that diff gist's match sets against
independent oracles — runs with the sieve live in the engine, so any wiring
false negative breaks parity loudly.

## 5. Lineage — the Python spike (`spikes/classrun-formula/`)

Before a line of Zig: a Python reference implementation with a
**240,000-pair randomized property suite** (random regex × random text,
oracle = Python `re`), the count-cousin ablation, and the Erdős–Rényi
selectivity model validated against measured prune rates. Zero violations.
The spike dossier also carries the originality referee trail (PRIOR_ART.md).

## 6. Reproduce everything

```bash
cd pkg/kernels/irregex
zig build test        # §1 + §2 + engine parity suites
zig build crest       # §3 — prints the gates, writes .local/gist-verify/crest.csv
gist index && gist status   # §4 — sidecar persisted alongside index.gist
```
