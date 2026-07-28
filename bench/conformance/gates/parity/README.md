# bench/conformance/gates/parity

Correctness gates that oracle gist **against `rg`** (or against gist itself) — a
divergence here means the answer is wrong, and each script exits non-zero on any
FN/FP. `scan_regress.sh` sources the shared field registry at
[`../../../dominance/races/field.sh`](../../../dominance/races/field.sh); the
rest are pure gist-side oracles needing no field.

| File                        | Gate                                                                                                                                                                                           |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `equality.sh`               | **index vs `rg`** — gist ≡ `rg` over a byte-exact corpus snapshot; a file in `rg`'s set but not gist's is a trigram-filter false negative, the reverse is an unsound verify. Both must be zero |
| `index_elision_parity.sh`   | **index vs itself** — the auto-indexed run ≡ the same query with `--no-index`, proving the index only elides reads, never changes results                                                      |
| `line_parity.sh`            | **line reporting** — line numbers / `-n` / column output byte-identical to `rg`                                                                                                                |
| `unicode_parity.sh`         | **Unicode drop-in** — `gist <pat>` ≡ `rg <pat>` at rg's default Unicode semantics (fold, classes, `\b`/`-w`, and the `(?-u)` opt-out) over a multi-script fixture, once per engine             |
| `patterns_corpus_parity.sh` | **multi-pattern set** — `relate patterns -e …` covers the exact file set `gist -l` answers over, keeping the dragnet/trawl a true drop-in                                                      |
| `scan_regress.sh`           | **no-prefilter fallback** — the live-tree full-read fallback ≡ `rg (?-u)` (exits 1 on FN/FP) plus a min-of-N speed floor                                                                       |

```bash
cd pkg/kernels/irregex
bench/conformance/gates/parity/equality.sh 150 1
bench/conformance/gates/parity/index_elision_parity.sh
bench/conformance/gates/parity/unicode_parity.sh
```
