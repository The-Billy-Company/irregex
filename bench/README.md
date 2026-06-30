# gist/bench

Benchmark harness for the `gist` code-locator kernel. `bench.zig` loads a real
corpus (every code file under the given dirs), builds the T0 trigram `Index`,
and times the query slate — reporting corpus size, one-time build cost, index
footprint, and per-query candidate count + median latency.

```bash
cd pkg/kernels/gist
zig build -Doptimize=ReleaseFast bench                 # default Billy source roots
zig build -Doptimize=ReleaseFast bench -- services libs # scope to specific dirs
```

The run step sets cwd to the repo root, so dir arguments are repo-root-relative.
The candidate count is a **sound superset** of `rg`'s true match-file count; the
gap is the trigram filter's false-positive rate (verified away by the caller's
real regex). Set the numbers against a correctly-scoped `rg` baseline (scope to
source dirs — an unscoped `rg` from repo root drags through ~99 GB of `target/`

- caches and is not a fair comparison).

## The field — who gist races

Three race scripts pit gist against **seven** code searchers, split by whether
they keep an index. The registry, fairness scoping, and per-tool invocations all
live in **`_compete.sh`** (sourced by every script); columns auto-skip when a
binary isn't installed.

| Tool         | Kind      | Notes                                                                                      |
| ------------ | --------- | ------------------------------------------------------------------------------------------ |
| **gist**     | indexed   | our kernel — resident RAM index (warm) or instant cold-load (cold)                         |
| **csearch**  | indexed   | Google Code Search (Russ Cox) — gist's direct trigram ancestor; the apples-to-apples rival |
| **zoekt**    | indexed   | Sourcegraph's production indexed search (trigram + ctags symbols)                          |
| **rg**       | unindexed | ripgrep — the gold-standard parallel scanner                                               |
| **ugrep**    | unindexed | claims-fastest grep; SIMD + PCRE2-JIT                                                      |
| **ag**       | unindexed | the_silver_searcher                                                                        |
| **ggrep**    | unindexed | GNU grep (`ggrep` on macOS) — the classic baseline                                         |
| **git grep** | unindexed | the in-repo dev-workflow default                                                           |

Install the optional ones: `brew install ugrep grep` ·
`go install github.com/google/codesearch/cmd/{cindex,csearch}@latest` ·
`go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest`.

| Script                | Race                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `headtohead.sh`       | **warm**: gist resident-index p50 vs the unindexed scanners (the long-lived agent-session model)                                                   |
| `coldquery.sh`        | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed)                                           |
| `regex_headtohead.sh` | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                                                 |
| `equality.sh`         | **correctness**: gist ≡ `rg` over a byte-exact corpus snapshot (the soundness oracle, INDEX path)                                                  |
| `scan_regress.sh`     | **scan-path regression + race**: the no-prefilter live-tree scan ≡ `rg` (gate, exits 1 on FN/FP) + min-of-N vs `rg` + the straggler-balance canary |
| `streams.sh`          | **output contract** (gate, exits 1 on violation): results→stdout, diagnostics (`—` summary / `[pipeline]` / guidance)→stderr across the literal, rank, and scan paths — the `rg`-conventional split that makes gist composable in agent pipelines |

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,regex,warm}.csv` for your own analysis.

## Fairness — stated, not hand-waved

Every tool is scoped to the same source roots (`services libs clients contracts
scripts quality`) and given its honest fastest path:

- **rg / git grep** honor `.gitignore` natively (skip the gitignored ~99 GB of
  build artifacts). **ag** is handed `--path-to-ignore .gitignore` (the root
  ignore set `rg` reads for free). **ugrep / GNU grep** have no per-file
  gitignore, so they get the heavy dir-exclude set (`$XDIRS`) — they still scan a
  slightly _larger_ file set (gitignored individual files `rg` skips), which only
  makes them do **more** work, so gist's win over them is conservative.
- **csearch** indexes gist's **exact corpus file list** (the persisted
  `paths.list` doc→path table) → byte-for-byte the same files → result sets ≈
  `rg`'s. It is the faithful indexed twin (the small delta is the few files
  csearch's own binary heuristic drops: 16,696 of 17,112).
- **zoekt** has no file-list input, so it indexes the roots tree under the same
  heavy ignore set; its corpus is a documented superset (no per-file gitignore +
  ctags symbol indexing). Quoted-literal counts still match `rg` on selective
  needles — treat it as a production-grade **timing reference**, not a
  correctness oracle (`rg` + `csearch` are).
- Timing is `hyperfine` mean, warm page cache, fresh process. Every command's
  output is drained (`… | wc -l`) so ugrep's lazy multithreaded `-l` actually
  scans (it short-circuits when a harness discards its stdout) and a needle
  _miss_ (grep exits 1) doesn't abort the run. **Ratios** are the headline
  number — robust to this shared dev box's load because each query's tools run
  back-to-back under the same conditions.

## Scenarios

- **Warm/oracle slate** (`bench.zig`): 20 adversarial literals (rare symbol,
  dotted ident, 2-byte punctuation, guaranteed miss, repeated-char pathological,
  cross-language keywords) + 30 regex shapes spanning every feature tier.
- **Cold literal slate** (`coldquery.sh`): a guaranteed miss (pure index win),
  very-selective symbols, medium, common tokens touching thousands of files, and
  a 2-byte punctuation needle (the `<3 B`, no-trigram-filter fallback).
- **Cold regex slate** (`regex_headtohead.sh`): 22 patterns grouped by tier —
  literal-prefix, anchored `^`/`$`, counted `{n,m}`, dense classes (`\w{3,8}` —
  the byte-class DFA's home), alternation cover sets, and a prefilter-less
  mixed alternation.

`equality.sh` has gist emit its verified matching-file set per pattern **plus a
byte-exact snapshot of the files it indexed** (the corpus is regenerated live by
coworker agents — the snapshot freezes the bytes so the diff can't race), then
runs `rg` over that identical snapshot and diffs. A file in rg's set but not
gist's = a trigram-filter false negative (the one unforgivable bug); a file in
gist's but not rg's = an unsound verify. Both must be zero.

`scan_regress.sh` is the companion oracle for the **other** code path: a regex the
trigram index can't prefilter (`\w{3,8}`, `[a-f0-9]{2,}`, `panic|0x`, …) skips the
index and scans the live tree directly (`scan.zig`), so `equality.sh`'s index-path
proof doesn't cover it. The script (a) asserts each pattern still **routes** to the
scan path, (b) diffs gist's scan match-set against `rg (?-u)` over the identical
corpus and **exits 1 on any FN/FP** (a file rg matches past the 4 MiB
`per_file_cap` is a documented cap-skip, not a failure), and (c) races min-of-N vs
`rg` while printing `scan.zig`'s worker-span Δ — the **straggler canary** that
catches any regression of the fused work-stealing pipeline back toward an
unbalanced scan. Built ReleaseFast (release-vs-release with rg). Run it:

```bash
cd pkg/kernels/gist
bench/scan_regress.sh         # gate + race, default runs=12
bench/scan_regress.sh 20      # tighter timing
```

```bash
cd pkg/kernels/gist
bench/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus snapshot, per needle
bench/scan_regress.sh        # SCAN path: no-prefilter regex ≡ rg (gate) + min-of-N race + balance
bench/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/coldquery.sh           # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/regex_headtohead.sh    # COLD regex: same field, per feature tier
zig build -Doptimize=ReleaseFast bench   # build cost, footprint, latency p50/p95/p99
```

## Certificate of Optimality (Layer A)

The race scripts above report _means and ratios_. The **certificate** turns that
into a claim that is beyond reproach — every number carries a 95% bootstrap
confidence interval and (vs ripgrep) a Mann-Whitney significance test, so a
"win" is **statistically real**, not box noise. It is built in four layers,
cheapest evidence first; **Layer A is implemented**, B–D are the roadmap toward
"mathematically the fastest it can be":

| Layer | Claim                                                                 | Status         |
| ----- | --------------------------------------------------------------------- | -------------- |
| **A** | empirical dominance — fastest in class on real workloads, fail-closed | ✅ implemented |
| **B** | port-optimality — hot loop matches the static µarch bound (llvm-mca)  | pending        |
| **C** | roofline — cycles/byte sits on the hardware ceiling                   | pending        |
| **D** | algorithmic lower bound — matches the information-theoretic floor     | pending        |

Layer A has two halves, written into one `.local/gist-verify/CERTIFICATE.md`:

- **Microscopic** (`zig build certify`) — for each of 11 regex classes, times
  gist's real verify kernel **single-threaded** over the RAM-resident corpus and
  records retired **cycles + instructions per byte** (the bridge number Layers
  B–C bound), `IPC`, and a 95% bootstrap-CI median (200 reps, seeded). Hardware
  counters come from Apple's `kperf` via `dlopen` (`bench/pmu.zig`) — **run under
  `sudo` for cycles**; without root it degrades to wall-clock and says so, never
  failing. The statistics live in `bench/stats.zig` (bootstrap CI + Tukey
  outliers + Mann-Whitney), unit-tested under `zig build test`.

  ```bash
  sudo pkg/kernels/gist/zig-out/bin/gist-bench certify   # cycles/byte (run from repo root)
  zig build certify                                        # wall-clock fallback (no sudo)
  ```

- **Macroscopic** (`bench/certify.sh`) — the same 11 classes, process-vs-process
  vs the whole field, fresh-process cold query. `certify_stats.py` (a stdlib
  mirror of `stats.zig`) computes a per-class bootstrap-CI median + Mann-Whitney
  verdict **gist vs ripgrep** (fail-closed: a win needs a lower median _and_
  p<0.05) and splices the table into the certificate. Every class is shown —
  losses and the indexed-twin (csearch/zoekt) context included.

  ```bash
  RUNS=20 bench/certify.sh        # default RUNS=20 WARMUP=3; raise RUNS to tighten CIs
  ```
