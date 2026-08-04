# irregex — Dominance-and-Fit Certificate

The engine's distance from the limits of the machine it runs on. Each layer
states a bound the hardware or information theory imposes, then measures how
close this build gets to it — so a layer reporting **no remaining headroom** is
as much a result as one reporting a win.

Minted by `bench/certificate/mint/mint.sh`. Every number below is spliced by a
reporter that reads a committed artifact in this bundle; nothing here is typed
by hand. The machine, the tool identities, and the corpus that produced it are
`machine.json`, `tool-versions.txt`, and `corpus-manifest.tsv` beside this file.

Layer A (dominance over the field) and the CLI surface belong to `gist`;
retrieval and multi-pattern to `relate`. A package certifies what it builds.

## Layer B — port-optimality (static µarch bound)

_Static reciprocal-throughput bound from `llvm-mca 22.1.8`, computed by `bench/bounds/port/mca.sh`. gist's two hot loops are byte-faithful copies (drift-guarded by `probes_test.zig`), cross-compiled by Zig to each reference core; llvm-mca scores the marked hot-loop region for port pressure. Lower cycles/byte is better._

| probe | source | target µarch | bound | Block RThroughput (cyc/iter) | bytes/iter | cyc/byte (port bound) |
|---|---|---|---|--:|--:|--:|
| `simd_contains` | `src/kernel/scan/simd.zig` | `znver4` | throughput | 2.0 | 64 | 0.0312 |
| `simd_contains` | `src/kernel/scan/simd.zig` | `neoverse-v2` | throughput | 5.5 | 16 | 0.3438 |
| `dfa_step` | `src/kernel/regex/linear/dfa/dfa.zig` | `znver4` | latency | 1.0 | 1 | 1.0 |
| `dfa_step` | `src/kernel/regex/linear/dfa/dfa.zig` | `neoverse-v2` | latency | 1.0 | 1 | 1.0 |
| `dfa_mirror` | `src/kernel/regex/linear/dfa/dfa.zig` | `znver4` | latency | 1.0 | 1 | 1.0 |
| `dfa_mirror` | `src/kernel/regex/linear/dfa/dfa.zig` | `neoverse-v2` | latency | 1.0 | 1 | 1.0 |

> **Throughput-bound vs latency-bound.** `simd_contains` has independent iterations (only the cursor carries), so its `Block RThroughput` **is** the floor — no scheduling of those vector ops on that core runs faster. `dfa_step` is a **latency-bound pointer chase**: the transition `s = trans_in[s + class[b]]` is a loop-carried dependency, so its real floor is the recurrence latency (the dependent-load chain), which is *higher* than the port `Block RThroughput` shown here. For the DFA, `Block RThroughput` is the port-pressure ceiling; the binding constraint is the dependent-load latency llvm-mca reports per instruction. See `bench/bounds/port/README.md`.

> **Why not this machine (Apple Silicon).** LLVM ships **no real scheduling model for any Apple CPU** — every core from the A7 to the M4 is modeled as the 2013 *Cyclone* ([LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)). So `llvm-mca -mcpu=apple-m4` would be fabricated precision. Layer B is therefore a static bound over two cores LLVM **does** model precisely — AMD Zen 4 (`znver4`) and Arm Neoverse V2 (`neoverse-v2`, the core behind AWS Graviton4 / Google Axion) — cross-compiled by Zig, not a pretend M-series number.

### Layer B′ — port bound, measured on this machine

**cycles/byte: cross-checked (reference cores), NOT measured on this machine.** The empirical runner has not been run here. Rung: `cd <irregex-repo-root> && zig build -Doptimize=ReleaseFast portbound` (the unprivileged per-thread counters supply cycles; root is needed only for kperf's configurable events, which this lane does not use), then re-run `bench/bounds/port/mca.sh` to splice.

## Layer C — roofline (measured headroom)

_The roofline model (Williams, Waterman & Patterson, CACM 2009) supplies an upper bound: min(peak compute, peak bandwidth × arithmetic intensity). Layer C measures gist's distance from that bound. It does **not** infer saturation from low arithmetic intensity. A matched ladder separates raw STREAM bandwidth, the dual-window load/compare shape, production on contiguous DRAM, and production over corpus documents._

- machine: `aarch64` · zig `0.16.0` · corpus 22.4 MiB
- **measured memory ceiling (single core, pure read):** L1 **166.3 GB/s** · L2 **101.4 GB/s** · DRAM **77.0 GB/s**
- clock: **3.648 GHz measured here** — measured (thread_selfcounts, cycles ÷ ns under memory load)
- DRAM ceiling in cycles/byte (derived, measured clock GHz ÷ measured tier GB/s): **0.0474 cyc/byte** — the ideal pure-read floor; search instructions and load shape can impose lower ceilings
- **compute bound (Layer B, cross-machine):** the `simd_contains` loop's static llvm-mca port bound — znver4 0.031 cyc/byte (≈117 GB/s) · neoverse-v2 0.344 cyc/byte (≈11 GB/s). These are *reference cores* modeled by llvm-mca, not observations of any core (LLVM has no Apple-Silicon model), so they are a low-intensity **cross-check**, not a same-axis ceiling on this `aarch64` roofline; they confirm the scan is a tight, few-cycle/byte port-bound kernel, but do not identify this machine's binding bottleneck.

**Matched ceiling ladder** (same process; logical input GB/s):

| stage | GB/s | % of corpus-sized roof | % of matched control |
|---|--:|--:|--:|
| corpus-sized STREAM roof | 93.3 | 100% | 109% |
| matched gate control | 85.3 | 91% | 100% |
| production contiguous | 83.6 | 90% | 98% |

**gist's SIMD scan on the roofline** (real `scan/simd.zig` `contains` over the corpus):

| scan | GB/s | % of corpus-sized roof |
|---|--:|--:|
| full-scan (0 matches, pure streaming) (`0x00x32…`) | 68.3 | 73% |
| with matches (early-exit + verify) (`func…`) | 50.8 | 54% |
| with matches (early-exit + verify) (`})…`) | 61.7 | 66% |

**Verdict — material headroom remains.** The full scan reaches **68.3 GB/s = 73% of the 93.3 GB/s single-core pure-read roof**. That is below the pre-registered 80% near-roof threshold, so Layer C does **not** certify DRAM saturation, a binding memory bottleneck, or hardware optimality. The matched ladder shows where throughput falls before corpus fragmentation; optimize and remeasure those stages before making a stronger claim.

> No `certify.csv` in this bundle, so the per-class end-to-end operating point is not shown. That table is Layer A's artifact and Layer A is minted by `gist`; the ceilings and the verdict above are measured here and do not depend on it.

## Layer D — algorithmic lower bound (information-theoretic floor)

_Generated by `gist-lowerbound` + `bench/bounds/lowerbound/report.py`. Every row is a measured byte count, not a claim. Fail-closed: the harness exits non-zero if any candidate byte is read more than the single-pass floor, or if the independent single-pass reference disagrees with gist's real verify on any document._

**The floor (two parts).**

1. **Verify is Ω(candidate bytes), one pass.** Any algorithm that correctly decides whether a pattern occurs in a candidate document must, in the worst (adversarial) case, examine every byte of it — an unread byte could be the match, or could break one (the adversary sets it after the algorithm commits). This is the classical exact-match floor of Knuth-Morris-Pratt (1977, *SIAM J. Comput.*) and Boyer-Moore (1977, *CACM*): linear-time in the worst case, Ω(n) reads to certify absence (Boyer-Moore is sublinear on *average* — Ω(n/m) reads — but the verify-stage guarantee is Ω(candidate bytes)). gist's fused byte-class DFA (`src/kernel/regex/linear/dfa/dfa.zig`) reads each candidate byte **exactly once** — a single forward pass, detecting `\n` inline, with none of the memchr-then-rescan double byte-traffic a per-line matcher pays. The SIMD literal path (`src/kernel/scan/simd.zig`) reads **≤ N** (vector first/last-byte skips, early exit on the first hit).

2. **The trigram filter makes total work sublinear.** gist reads far fewer than the corpus's bytes because the trigram index prunes the candidate set *before* verify runs — the technique of Russ Cox, *"Regular Expression Matching with a Trigram Index, or How Google Code Search Worked"* (2012), gist's direct ancestor. `cand%` below is the fraction of corpus bytes admitted; `100% - cand%` is pruned away untouched.

**Conclusion.** gist's two-stage design — trigram prune, then a single fused verify pass — matches the information-theoretic floor: it reads the minimum candidate set the filter can prove necessary, and verifies each candidate byte with one pass (DFA) or fewer (SIMD-skip literals).

- corpus: 1241 files · 22.4 MiB · single-thread verify
- method: `candidate bytes` = Σ lengths of the docs the trigram filter admits (the full-scan verify floor); `passes` = bytes an independent single-pass reference touches ÷ candidate bytes — **exactly 1.0000 for the fused DFA** (each candidate byte once, no double traffic), **≤ 1 for the SIMD literal path** (skips + early exit). The reference's match verdict is asserted equal to gist's real verify on every document.

| class | engine | corpus bytes | candidate bytes | cand% (pruned) | passes / candidate byte | hits | verdict |
|---|---|--:|--:|--:|--:|--:|:--|
| `literal-rare` | simd (≤ 1-pass) | 22.4 MiB | 1.8 MiB | 8.11% (91.89% pruned) | 0.3065 | 60 | ✅ at floor |
| `literal-dotted` | simd (≤ 1-pass) | 22.4 MiB | 1.2 MiB | 5.53% (94.47% pruned) | 0.2933 | 38 | ✅ at floor |
| `literal-common` | simd (≤ 1-pass) | 22.4 MiB | 6.3 MiB | 28.08% (71.92% pruned) | 0.2813 | 366 | ✅ at floor |
| `literal-punct2` | simd (≤ 1-pass) | 22.4 MiB | 22.4 MiB | 100.00% (0.00% pruned) | 0.7460 | 550 | ✅ at floor |
| `regex-decl` | dfa (fused 1-pass) | 22.4 MiB | 6.3 MiB | 28.08% (71.92% pruned) | 1.0000 | 51 | ✅ at floor |
| `regex-dotted` | dfa (fused 1-pass) | 22.4 MiB | 1.2 MiB | 5.27% (94.73% pruned) | 1.0000 | 6 | ✅ at floor |
| `regex-anchored` | dfa (fused 1-pass) | 22.4 MiB | 6.3 MiB | 28.08% (71.92% pruned) | 1.0000 | 49 | ✅ at floor |
| `regex-classcount` | dfa (fused 1-pass) | 22.4 MiB | 22.4 MiB | 100.00% (0.00% pruned) | 1.0000 | 3 | ✅ at floor |
| `regex-alternation` | dfa (fused 1-pass) | 22.4 MiB | 13.6 MiB | 60.57% (39.43% pruned) | 1.0000 | 862 | ✅ at floor |
| `regex-dense-scan` | class-run (dfa-ref 1-pass) | 22.4 MiB | 22.4 MiB | 100.00% (0.00% pruned) | 1.0000 | 1241 | ✅ at floor |
| `regex-eol` | dfa (fused 1-pass) | 22.4 MiB | 22.4 MiB | 100.00% (0.00% pruned) | 1.0000 | 679 | ✅ at floor |
| `regex-litalt` | dfa (fused 1-pass) | 22.4 MiB | 22.4 MiB | 100.00% (0.00% pruned) | 1.0000 | 316 | ✅ at floor |

> **At the floor on every class.** 8 classes touch every candidate byte exactly once (passes ≡ 1.0000 — a single fused pass, no re-scan) — 1 of them a dense class the production SIMD class-run kernel serves, proven equal on every document to an independent one-pass DFA reference; the 4 SIMD literal classes stay strictly below it (early exit + vector skips). No implementation can verify a candidate set in fewer than Ω(candidate bytes) reads, and gist reads that minimum — the trigram filter having already pruned the rest of the corpus untouched.

<!-- CREST-LAYER-START -->
## Layer E — crest sieve (the trigram blind spot, measured)

_The one place gist's index math is new rather than borrowed: the **crest sieve** (`src/kernel/math/crest.zig`, theorem in `research/crest/PROOF.md`). `zig build crest` links the **real** engine, builds the production crest sidecar, and walks the real corpus. It is **fail-closed**: for every file `matched ⇒ ¬pruned` against the production `Regex.docMatch`, over the fixed slate plus randomized adversarial `(pattern, file)` pairs in all four alphabet × case modes — a single false negative exits non-zero, so a spliced Layer E is itself the soundness receipt. These are the literal-free class-repetition patterns the trigram index prunes 0% on (Layer A `regex-classcount`, cand% = 100%). **RUN** is the sieve (longest per-class run); **CNT** is the weaker count-cousin at the same forced bound ĝ, carried to prove the run — not the population — is the right necessary condition. Lower `sieve ms` is better; same matcher both sides, so the speedup is purely avoided work._

- machine: **Apple M4 Max** · zig `0.16.0` · corpus 760 files · 14.8 MiB
- sidecar: 8 byte-classes · 16 bytes/file · built by the same parallel pass `gist index` persists as `crest.bin`

| query | pattern | RUN prune% | CNT prune% (cousin) | full ms | sieve ms | speedup |
|---|---|--:|--:|--:|--:|--:|
| hex-8  (uuid/sha) | `[0-9a-f]{8}` | 84.1% | 0.0% | 1.2 | 0.3 | 3.7x |
| hex-12 (mac/hash) | `[0-9a-f]{12}` | 89.5% | 0.0% | 1.3 | 0.1 | 13.2x |
| digit-4 (year) | `[0-9]{4}` | 56.0% | 9.9% | 0.3 | 0.1 | 3.5x |
| digit-6 | `[0-9]{6}` | 87.0% | 12.4% | 0.8 | 0.1 | 6.1x |
| upper-4 (CONST) | `[A-Z]{4}` | 10.1% | 0.9% | 0.1 | 0.0 | 1.3x |
| upper-6 | `[A-Z]{6}` | 22.2% | 1.1% | 0.2 | 0.1 | 2.1x |
| ci-hex-8  (?i)uuid | `[0-9a-f]{8}` | 84.1% | 0.0% | 1.5 | 0.4 | 3.5x |
| ci-hex-12 (?i)mac | `[0-9a-f]{12}` | 89.5% | 0.0% | 1.6 | 0.1 | 14.4x |
| ci-upper-6 -iu A-Z | `[A-Z]{6}` | 0.0% | 0.0% | 0.0 | 0.0 | 0.9x |
| word-3 (wide) | `\w{3,8}` | 0.0% | 0.0% | 0.0 | 0.0 | 0.9x |
| alpha-5 (wide) | `[A-Za-z]{5}` | 0.0% | 0.0% | 0.0 | 0.0 | 0.9x |
| alt hex-12|rule-60 | `[0-9a-f]{12}|~{60}` | 80.4% | 0.0% | 3.7 | 1.3 | 2.8x |
| alt digit-6|CONST-6 | `[0-9]{6}|[A-Z]{6}` | 19.9% | 0.4% | 0.3 | 0.2 | 1.5x |
| \d{6}  -u default | `\d{6}` | 64.1% | 3.4% | 2.4 | 1.2 | 2.0x |
| \d{4}  -u default | `\d{4}` | 41.7% | 2.4% | 1.0 | 0.5 | 1.9x |
| \w{8}  -u (wide) | `\w{8}` | 0.0% | 0.0% | 0.0 | 0.0 | 1.0x |
| \s{4}  -u | `\s{4}` | 5.3% | 0.0% | 1.2 | 1.2 | 1.0x |
| [0-9]{6} -u (twin) | `[0-9]{6}` | 87.0% | 12.4% | 0.8 | 0.1 | 6.4x |

**Narrow class-repetition slate (14 patterns): the crest sieve prunes a geomean 45% of files the trigram index prunes 0% on, for a **3.3× geomean end-to-end speedup** — while the count-cousin at the same ĝ prunes only 2.9%, the gap that proves the run is the necessary condition.**
The 4 wide rows are kept honest: their forced run is too short to sieve, so crest correctly prunes ~nothing (≈1× — no manufactured win). In the shipped integration the win is larger still: a pruned doc's read is elided entirely (serial `IndexSkip` / parallel `Elide`), not just its match call.

> Sound by construction — everything in ĝ rounds **down** (any construct the calculus cannot certify contributes nothing; unsafe caseless folds and non-ASCII Unicode classes decline to 0⃗), so under-pruning is the only failure mode. Theorem, min-of-max calculus over the AST, and the refereed priority review live in `research/crest/PROOF.md`; the harness is `bench/crest/bench.zig`.
<!-- CREST-LAYER-END -->

<!-- SCALE-LAYER-START -->
## Layer J — positional + substring index tiers at scale (vs zoekt)

### J.1 — the substring (sliver) tier, in Layer D's unit

_Layer D records classes at **cand% = 100%** because the needle is thinner than a trigram (`literal-punct2` = `})`) or carries a branch that is (`regex-litalt` = `panic|0x`). `zig build scale` measures what the **sliver tier** (`src/corpus/index/trigrams/sliver.zig`) recovers in candidate BYTES delivered to verify — Layer D's own unit, same corpus, same imported probe set. `tiered` calls the **same** `sliver.candidates` production entry point, so a number here cannot drift from shipped behavior._

- machine: **arm64** · zig `0.16.0` · corpus 1241 files · 22.4 MiB
- index: 150351 trigram groups · 3007810 postings · **0 new bytes on disk** — the tier reads the directory that already exists

| class | pattern | cand% directory | cand% tiered | reduction | matches | sound |
|---|---|--:|--:|--:|--:|:--:|
| literal-rare | `pgxpool` | 8.11% | 8.11% | — | 60 | ok |
| literal-dotted | `context.Context` | 5.53% | 5.53% | — | 38 | ok |
| literal-common | `func` | 28.08% | 28.08% | — | 366 | ok |
| literal-punct2 | `})` | 100.00% | 39.58% | 2.53x | 550 | ok |
| regex-decl | `func\s+\w+\(` | 28.08% | 28.08% | — | 51 | ok |
| regex-dotted | `pgxpool\.\w+` | 5.27% | 5.27% | — | 6 | ok |
| regex-anchored | `^func\s` | 28.08% | 28.08% | — | 49 | ok |
| regex-classcount | `[0-9a-f]{8}-[0-9a-f]{4}` | 100.00% | 100.00% | — | 3 | ok |
| regex-alternation | `return|continue|break` | 60.57% | 60.57% | — | 862 | ok |
| regex-dense-scan | `\w{3,8}` | 100.00% | 100.00% | — | 1241 | ok |
| regex-eol | `;$` | 100.00% | 100.00% | — | 679 | ok |
| regex-litalt | `panic|0x` | 100.00% | 63.01% | 1.59x | 316 | ok |

**2 of 12 classes move, and they are the Layer D rows at cand% = 100%: `literal-punct2`, `regex-litalt`.** The classes that do *not* move are the honest half of the table: a sliver tier can only be as selective as the byte it filters on, so `regex-eol` (`;$`) and `regex-classcount` engage, price the union, and correctly decline to claim a win, and `regex-dense-scan` (`\w{3,8}`) offers no literal at all.

> **Sound by construction.** A sliver must sit inside one of its document's trigrams, so the union of the trigram families that could contain it over-approximates the answer. The premise fails only for a document too short to own a trigram, and those are carried unconditionally in a rescue set proved from the crest sidecar (`max ρ(d) ≥ 3` witnesses a length ≥ 3; anything unprovable is admitted). Over-admission costs a read, under-admission would cost a match, so the asymmetry runs the safe way by construction. Attacked directly in `src/corpus/index/trigrams/sliver_test.zig`, including a run with the rescue set deliberately removed to prove it is load-bearing rather than superstition.

### J.2 — multi-GB scale, head to head with zoekt and csearch

_Corpus: shallow clones of the Linux kernel, LLVM, the Go tree and the Rust tree — **352,316 files / 5.5 GiB on disk**, against the certificate corpus's 20.6k files / 204.6 MiB. Fairness per `bench/races/_compete.sh`: `GIST_UNCAP=1` so gist's agent-context output budget cannot clip a repo-wide result and flatter its own timing, and every engine answers in files-with-matches mode, the one output shape all three share. Medians, bootstrap CIs and the Mann-Whitney verdict come from `stats.py`; nothing statistical is reimplemented._

| engine | build wall | peak RSS | index | index / its own text | 
|---|--:|--:|--:|--:|
| gist | 26.0 s | 4.56 GiB | 358 MiB | 10.4% |
| csearch | 56.3 s | 2.86 GiB | 401 MiB | 10.5% |
| zoekt | 235.6 s | 1.70 GiB | 8909 MiB | 158.0% |

**gist builds the smallest index the fastest** — 3.35 GiB of text in 26.0 s, 2.2x faster than csearch and 9.1x faster than zoekt, at 10.4% of the text it indexed where zoekt's comes to 8.7 GiB. **Memory is still the lane it loses**: 4.56 GiB peak RSS while indexing, 2.7x zoekt and 1.6x csearch. That is the real scale ceiling in this table and it is not normalized away.

| class | gist | zoekt | csearch | gist vs csearch | verdict |
|---|--:|--:|--:|--:|:--|
| literal-rare | 1361 ms (0) | 79 ms (0) | 4 ms (0) | 0.00x | loss |
| literal-dotted | 1647 ms (260) | 122 ms (262) | 59 ms (260) | 0.04x | loss |
| literal-common | 3316 ms (89,389) | 617 ms (102,839) | 2432 ms (90,339) | 0.73x | parity |
| literal-punct2 | 2060 ms (27,927) | 92 ms (0) | 34025 ms (28,077) | 16.52x | win |
| regex-decl | 2182 ms (9,990) | 287 ms (10,090) | 1480 ms (10,047) | 0.68x | loss |
| regex-dotted | 1160 ms (0) | 82 ms (0) | 5 ms (0) | 0.00x | loss |
| regex-anchored | 2073 ms (10,285) | 1787 ms (10,390) | 1432 ms (10,346) | 0.69x | loss |
| regex-classcount | 1998 ms (870) | 7286 ms (1,154) | 7313 ms (869) | 3.66x | win |
| regex-alternation | 4153 ms (130,541) | 667 ms (94,936) | 4039 ms (131,380) | 0.97x | parity |
| regex-dense-scan | 7793 ms (338,799) | 1666 ms (21,684) | 30212 ms (344,663) | 3.88x | win |
| regex-eol | 7985 ms (215,344) | 561 ms (62,360) | 31673 ms (216,841) | 3.97x | win |
| regex-litalt | 3377 ms (83,328) | 6570 ms (57,181) | 31856 ms (85,121) | 9.43x | win |

Cells are `median (files matched)`. Against csearch — the rival that agrees with ripgrep on what exists — gist **wins 5, ties 2, loses 5** of 12 classes, and the wins are the hard end of the suite: `literal-punct2` **16.5x**, `regex-litalt` **9.4x**, `regex-eol` 4.0x, `regex-dense-scan` 3.9x, `regex-classcount` 3.7x. The losses are the cheap-literal classes, and they have a single cause named in J.3.

**Read the zoekt column with its hit counts, never as a bare ratio.** zoekt is a timing reference and not a correctness oracle (`_compete.sh` says so), and at this scale it is visibly incomplete: **0 files** for `})` where ripgrep finds 28,124, 21,684 for `\w{3,8}` where the truth is ~344k, 62,360 for `;$` where the truth is ~216k. Some of its speed is work it did not do.

**gist's own shortfall, disclosed rather than rounded away.** Against csearch gist is short on 8 classes, worst 2.1% (`regex-litalt` 2.1%, `regex-dense-scan` 1.7%, `literal-common` 1.1%, `regex-eol` 0.7%). That is *not* index unsoundness, and the distinction is measured rather than asserted: for every one of those classes the indexed and `--no-index` answers are **byte-identical** (md5 of the sorted file list, `scale_elision.tsv`), so the index only ever elided reads. The gap is the corpus walk's ignore/binary heuristics — with `-uu` gist reaches 28,148 of ripgrep's 28,156 on `})`, closing 197 files to 8 — and belongs to the lane that owns `src/corpus/tree/**`. Layer J fails closed above a 3% gap and refuses entirely if the parity proof is missing, so this can be seen but not hidden.

_Two metrics, because only one of them is a cost. **maxrss** (`maximum resident set size`) charges an engine for clean, instantly-evictable mmap pages it walked through; an engine that reads with `read(2)` is never charged for the same page cache, because `read` does not map the file into the process. **footprint** (`peak memory footprint`) is the dirty, anonymous memory the process actually owns and the OS cannot reclaim. Both come from `/usr/bin/time -l`._

| query | gist maxrss | gist owned | csearch maxrss | csearch owned | zoekt maxrss | zoekt owned |
|---|--:|--:|--:|--:|--:|--:|
| `kmem_cache_alloc` (rare literal) | 580 MiB | **93 MiB** | 11 MiB | 5 MiB | 374 MiB | — |
| `func` (corpus-wide literal) | 566 MiB | **96 MiB** | 55 MiB | 10 MiB | 2266 MiB | 558 MiB |
| `})` (sub-trigram literal) | 577 MiB | **96 MiB** | 5 MiB | 3 MiB | 370 MiB | — |

**The index is not the toucher — and neither is walking.** An earlier draft of this layer read gist's flat ~575 MiB as "the signature of loading a 389 MiB index rather than paging it". That was wrong, and it is retired here by measurement rather than quietly restated. `vmmap` over a live query shows `index.gist` at 354.9 MiB mapped but **11.5 MiB resident — 3.2% of the postings blob**: it is demand-paged exactly as designed, since `Index.fromTrustedMappedBytes` borrows the mapping and validates only the directory. Two controls finish the argument:

| control | gist maxrss | gist owned |
|---|--:|--:|
| `pgxpool` — zero-candidate, index elides every read | 583 MiB | 96 MiB |
| `pgxpool` — zero-candidate, --no-index (no index mapped) | 535 MiB | 82 MiB |

`pgxpool` does not occur in this corpus, so the trigram filter elides **every read** — and the query still costs 583 MiB. The same needle with `--no-index`, mapping no index at all, still costs 535 MiB. So the index accounts for ~48 MiB of maxrss and ~14 MiB of owned memory; the rest is there without it.

A second draft blamed the remainder on gist's **live tree walk over all 336,780 files**, which every query re-runs to honor *a stale index can accelerate a live tree without owning truth* — one touched byte costing a full 16 KiB page, so residency would track file count rather than query or index size. That reasoning predicts any engine walking a tree pays this bill, and **ripgrep walks one and does not** — which made the remainder gist's own, and findable. The matched pair below is the instrument that settled it: same needle, same `-uu` scope, same cwd, both counting, both a fresh process with no index and no daemon, so the only difference left is the implementation of walking. It is measured on its own tree rather than the race corpus above, because what it isolates is walk cost per file and it must be re-runnable anywhere:

| scanner over `.etc` (239,162 files) | maxrss | owned |
|---|--:|--:|
| `rg -uu --no-messages -F -c pgxpool .` | 33.9 MiB | **31.9 MiB** |
| `gist --no-index -uu -F -c pgxpool .` | 54.1 MiB | **37.5 MiB** |

So walking is not what costs it — gist's *implementation* of walking was, and that is now closed to **1.18x rg on owned memory**, the metric that is a cost, and **1.60x on maxrss**, which charges an engine for clean evictable page cache a `read(2)`-based scanner is never billed for. What closed it was naming the retention rather than the phase: the walk was holding every large file it had mapped until the process exited, so its resident set tracked the corpus instead of the query. A worker now drops each mapping in the frame that rendered it. The freshness defense was never the answer here — rg has perfect freshness, it reads the tree every time and trusts nothing, and it is cheap — which is exactly why rg is the honest denominator for a walk-cost claim.

> **The honest score, on the metric that is a cost.** gist's owned working set is **93–96 MiB, flat across every query class** — a rare literal, a corpus-wide literal, a sub-trigram needle and a zero-candidate probe all land within 3 MiB of each other. That is ~10x csearch, and **5.8x better than zoekt**, whose 558 MiB of owned memory for a single common term is the largest working set in this table. Against csearch gist loses maxrss outright, and that is the standing shortfall: csearch does not walk, so it is not charged for a tree it never reads. The residual in-lane waste is bounded and named: `crest.bin`'s 5.3 MiB is walked eagerly at load to derive the sliver rescue set that only a 1–2 byte needle consumes, worth ~1% of the number and left alone because making it lazy would entangle that set's base-table lifetime with the codicil merge its soundness proof depends on.

### J.3 — the positional tier: measured, priced, and declined

_A positional tier stores where in a document an ngram occurs, so a filter can narrow from "which files" to "which regions" — the axis Layer D calls the floor. The question is never whether that helps; it is what it costs. This surface sweeps two axes over the certificate corpus: a trigram carries block positions only if its document frequency is below **T** (selective coverage), and at most **cap** blocks are stored per (trigram, document); an over-cap posting drops its constraint, which is sound because dropping a constraint only ever widens the admitted region. Sidecar bytes are measured at real delta+varint encoding, not estimated._

| cap | df ≤ T | sidecar | % corpus | `pgxpool` | `context.Context` | `func` | `panic` |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 8 | 0 | 0.0 MiB | 0.0% | 12.3M | 25.5M | 108.7M | 41.5M |
| 8 | 64 | 7.1 MiB | 3.8% | 12.3M | 25.5M | 108.7M | 41.5M |
| 8 | 256 | 16.5 MiB | 8.8% | 12.3M | 25.5M | 108.7M | 41.5M |
| 8 | 512 | 24.4 MiB | 12.9% | 12.3M | 25.5M | 108.7M | 41.5M |
| 8 | 1024 | 35.0 MiB | 18.6% | 4.9M | 25.5M | 108.7M | 41.5M |
| 8 | 2048 | 49.2 MiB | 26.1% | 4.9M | 25.5M | 108.7M | 41.5M |
| 8 | 4096 | 66.9 MiB | 35.5% | 4.9M | 15.7M | 108.7M | 22.0M |
| 8 | 8192 | 89.1 MiB | 47.3% | 4.9M | 15.7M | 80.5M | 19.7M |
| 8 | 16384 | 108.2 MiB | 57.5% | 4.9M | 15.7M | 80.2M | 19.7M |
| 8 | uniform | 108.8 MiB | 57.8% | 4.9M | 15.7M | 80.2M | 19.7M |
| inf | 0 | 0.0 MiB | 0.0% | 12.3M | 25.5M | 108.7M | 41.5M |
| inf | 1024 | 74.9 MiB | 39.8% | 0.5M | 25.5M | 108.7M | 41.5M |
| inf | 4096 | 136.0 MiB | 72.3% | 0.5M | 7.2M | 108.7M | 0.9M |
| inf | uniform | 245.8 MiB | 130.6% | 0.5M | 7.2M | 29.8M | 0.7M |

**The cheap end of the curve buys nothing, and the reason is structural.** A threshold only carries a literal's positions if it reaches that literal's *rarest* trigram, and measured over this corpus those floors are high: `pgxpool`'s rarest trigram is in **560** documents, `WalletService`'s in **686**, `context.Context`'s in **2,405**, `panic`'s in **3,933**, `func`'s in **7,671** of 19,440. Trigrams are 3-byte windows over a small alphabet, so document frequency floors out in the hundreds — there is no population of ultra-rare trigrams to annotate for free. Below T=1024 every probe is unchanged at any cap.

So the anti-correlation that motivated a selective tier is real on the **cost** side — 98% of distinct trigrams are only ~32% of posting bytes — but the **benefit** needs exactly the mid-frequency trigrams whose positions are expensive. The big reductions do reproduce (`panic` 46x, `pgxpool` 25x, `WalletService` 170x) and they cost **39.8% of corpus at T=1024 and 72.3% at T=4096**, rising to **130.6% uncapped and uniform — a sidecar larger than the text it indexes**. Capping to 8 blocks per document holds the price to 18.6–57.8% and guts the benefit to 1.4–2.5x.

**Declined, and the trade is the reason.** The classes positions can help are the ones gist is *already* fastest on: `literal-rare` admits 6.5% of the corpus before any positional work, and at multi-GB scale csearch answers it in 4 ms. The classes that actually cost seconds at scale — `regex-dense-scan` 7.8 s, `regex-eol` 8.0 s — carry no rare literal, and `func` measures **1.0x at every threshold below uniform**. Spending 40–130% of corpus to accelerate the queries that are already cheap, while the expensive ones are untouched, is zoekt's trade; the same table shows zoekt paying 8.7 GiB of index for it and still returning 0 files for `})`. Contrast the sliver tier in J.1: **0 new bytes on disk**, and at scale it is the 16.5x win over csearch. gist's postings stay document-level **by choice, at a measured price** — not for want of a design.

> This decision is gated, not asserted. The audit above rejects the whole layer if any threshold costing ≤10% of corpus is ever measured delivering ≥2x on any probe, so if the curve moves the narrative cannot quietly survive it.

<!-- SCALE-LAYER-END -->

<!-- INDEXQ-LAYER-START -->
## Layer L — index quality head-to-head (vs csearch)

_The claim under test: **"your trigram index is csearch-class, not better."** csearch (Google Code Search, Russ Cox 2012) is gist's acknowledged trigram ancestor, and the honest axis for comparing two indexes is **not** wall time — that confounds the index with the walk, the IO and the matcher — but **filter quality**: the candidate BYTES a query admits, and the precision of what it admits. So `zig build indexq` holds everything else fixed — one corpus, one built index, one evaluator (`Index.queryPlan`), one verifier (the production matcher) — and varies only the boolean formula over trigrams. csearch's arm is **csearch's own formula**, lifted verbatim from `csearch -verbose` by `bench/sieve/csearch_plan.py` and replayed against gist's postings: not a reimplementation, not a proxy. `gist-base` is gist's pre-Layer-L planner (one required literal, else the alternation cover), carried so each improvement is attributable._

- machine: **arm64** · zig `0.16.0` · corpus 1241 files · 22 MiB
- **5 classes won, 0 lost, 15 tied** · total candidate bytes **0.194 GB vs csearch's 0.219 GB** (gist admits 11.2% less), from 0.264 GB before Layer L
- index size 1.00× csearch · build 8.6× faster than csearch

### The certificate's own twelve classes

_The slate Layers A and D already publish, reported first and unedited: nobody can call it chosen to flatter gist. Eight of the twelve cannot separate two planners at all — four are single-literal (every planner emits the same run) and four are structurally unfilterable (literal-free `\w{3,8}`, sub-trigram `})` and `;$`, and `panic|0x` whose two-byte branch makes the disjunction vacuous), where the only sound answer is "no filter" and both tools give it._

| class | pattern-shape | gist-base cand% | **gist cand%** | csearch cand% | gist bytes | csearch bytes | gist prec. | csearch prec. | verdict |
|---|---|--:|--:|--:|--:|--:|--:|--:|:--|
| `literal-rare` | literal | 8.11% | **8.11%** | 8.11% | 2 MiB | 2 MiB | 100.00% | 100.00% | tie |
| `literal-dotted` | literal | 5.53% | **5.53%** | 5.53% | 1 MiB | 1 MiB | 95.00% | 95.00% | tie |
| `literal-common` | literal | 28.08% | **28.08%** | 28.08% | 6 MiB | 6 MiB | 99.73% | 99.73% | tie |
| `literal-punct2` | literal | 100.00% | **100.00%** | 100.00% | 22 MiB | 22 MiB | 44.32% | 44.32% | tie |
| `regex-decl` | regex | 28.08% | **9.75%** | 9.75% | 2 MiB | 2 MiB | 49.51% | 49.51% | tie |
| `regex-dotted` | regex | 5.27% | **5.27%** | 5.27% | 1 MiB | 1 MiB | 54.55% | 54.55% | tie |
| `regex-anchored` | regex | 28.08% | **9.75%** | 9.75% | 2 MiB | 2 MiB | 47.57% | 47.57% | tie |
| `regex-classcount` | regex | 100.00% | **83.14%** | 95.23% | 19 MiB | 21 MiB | 0.46% | 0.31% | **gist −12.7%** |
| `regex-alternation` | regex | 60.57% | **60.57%** | 60.57% | 14 MiB | 14 MiB | 99.54% | 99.54% | tie |
| `regex-dense-scan` | regex | 100.00% | **100.00%** | 100.00% | 22 MiB | 22 MiB | 100.00% | 100.00% | tie |
| `regex-eol` | regex | 100.00% | **100.00%** | 100.00% | 22 MiB | 22 MiB | 54.71% | 54.71% | tie |
| `regex-litalt` | regex | 100.00% | **100.00%** | 100.00% | 22 MiB | 22 MiB | 25.46% | 25.46% | tie |

### The planner-stress slate

_Eight shapes a real code search produces, chosen because csearch's planner has a real, non-obvious answer for each — the AND-of-OR boundary-trigram products that make csearch a strong planner rather than a caricature. Declared in `bench/sieve/stress.zig`; csearch's rendered query for every row is in the run log._

| class | pattern-shape | gist-base cand% | **gist cand%** | csearch cand% | gist bytes | csearch bytes | gist prec. | csearch prec. | verdict |
|---|---|--:|--:|--:|--:|--:|--:|--:|:--|
| `stress-errcheck` | regex | 61.34% | **6.59%** | 6.59% | 1 MiB | 1 MiB | 57.69% | 57.69% | tie |
| `stress-zigfn` | regex | 63.56% | **30.60%** | 30.60% | 7 MiB | 7 MiB | 95.24% | 95.24% | tie |
| `stress-isodate` | regex | 100.00% | **34.39%** | 59.74% | 8 MiB | 13 MiB | 67.52% | 31.60% | **gist −42.4%** |
| `stress-hexlit` | regex | 100.00% | **34.93%** | 100.00% | 8 MiB | 22 MiB | 29.95% | 4.75% | **gist −65.1%** |
| `stress-url` | regex | 28.99% | **28.32%** | 28.60% | 6 MiB | 6 MiB | 100.00% | 96.10% | **gist −1.0%** |
| `stress-sectioncite` | regex | 10.15% | **9.43%** | 9.43% | 2 MiB | 2 MiB | 89.77% | 89.77% | tie |
| `stress-prefixalt` | regex | 53.31% | **27.06%** | 28.26% | 6 MiB | 6 MiB | 98.71% | 94.72% | **gist −4.2%** |
| `stress-undefwall` | regex | 45.76% | **45.76%** | 45.76% | 10 MiB | 10 MiB | 50.00% | 50.00% | tie |

### Index cost (same file list, `bench/sieve/indexcost.sh`)

| tool | index | per corpus byte | build | peak RSS |
|---|--:|--:|--:|--:|
| gist | 5.0 MB | 0.214 | 0.08 s | 10.5 MB |
| csearch | 5.0 MB | 0.214 | 0.71 s | 1.5 MB |

Both indexes cover the byte-identical file list (1241 files — gist's own persisted `paths.list`, the fairness contract `bench/races/_compete.sh` already owns). The RSS figures are not like-for-like and are reported as measured: `cindex` is driven in 400-path batches (its own documented shape, forced by argv limits), so its peak is one batch, while gist's is the whole corpus in a single parallel pass.

> **What is disproven.** The two planners are not the same planner. csearch stops at 3-byte boundary trigrams and takes ONE window out of a class-punctuated run; gist's conjunctive cover (`src/kernel/query/cover.zig`) keeps every mandatory run, reads `x?` as the finite set {ε, x} so a scheme factors into whole literals, and emits every sound clause so the **cost-ordered evaluator** — which knows real posting cardinalities — picks and declines. Soundness is the fixed point, not the variable: `matched ⇒ never pruned` is brute-forced against the production matcher over an exhaustively enumerated document space (`cover_test.zig`), and the harness independently fails closed if any arm's verified hit count differs.

> **And it is the product, not a harness — on both tiers.** The cover is wired onto the cold query path: `gate.winnow` derives it from the effective pattern under `arm.linearOptions` — the same flags the matcher compiled with, so the plan cannot disagree with the engine — and `elide.askIndex` puts it to the index ahead of the flat OR, which stays the fallback. A run's whole answer is unchanged: `bench/conformance/gates/parity/cover_parity.sh` holds the wired path byte-identical to the pre-wiring prefilter, to gist's own `--no-index` read, and to ripgrep across 21 cases on a frozen real-source corpus — including `-i`, `-U`, `-F`, multi-`-e`, PCRE2 and the unprovable patterns, each of which exercises a different stand-down. Caseless and PCRE2 deliberately keep their existing prefilters (a folded-AST cover and a foreign-grammar cover are each a soundness argument this layer has not made), so they are certified as unchanged, not as improved. The resident daemon asks the same question in the same order (`gather.candidateIds`, off the same one-parse `query.winnow`), and `bench/conformance/gates/parity/warm_parity.sh` certifies that separately: 27 cases byte-identical against a SECOND daemon with both prunings stood down — the knobs are read where the pruning is derived, so a client-side baseline would have been a copy of the arm under test.
<!-- INDEXQ-LAYER-END -->
