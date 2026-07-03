# gist/bench

Benchmark, verification, and competitive-proof harness for the `gist`
code-locator kernel — no engine code lives here (that's all under `src/`).
Eight concerns, eight folders:

| Folder                                | Concern                                                                                                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`harness/`](harness/README.md)       | The native `gist-bench` Zig binary — corpus load + latency slate, the microscopic cycles/byte certificate, PMU counters, bootstrap statistics, the shared probe registry. |
| [`races/`](races/README.md)           | The competitor registry (`_compete.sh`) + the three multi-tool field races (warm, cold literal, cold regex).                                                              |
| [`gates/`](gates/README.md)           | Permanent correctness/contract gates: the `gist ≡ rg` equality oracle, the scan-path regression, the stdout/stderr stream-contract check.                                 |
| [`certify/`](certify/README.md)       | The macroscopic half of the Layer-A optimality certificate — races the whole field per pattern class with a fail-closed statistical verdict.                              |
| [`rgsuite/`](rgsuite/README.md)       | The `gist rg` ⇄ real-ripgrep drop-in proof — mined `rgtest!` correctness replay plus the performance scoreboard.                                                          |
| [`portcert/`](portcert/README.md)     | Layer B — port-optimality: cross-compiled `llvm-mca` static microarchitectural bound on gist's two hot loops, drift-guarded against production.                           |
| [`roofline/`](roofline/README.md)     | Layer C — roofline: this machine's measured STREAM read-bandwidth ceiling vs gist's real scan throughput.                                                                 |
| [`lowerbound/`](lowerbound/README.md) | Layer D — algorithmic lower bound: a fail-closed structural audit proving gist's verify touches the information-theoretic floor of candidate bytes.                       |

```bash
cd pkg/kernels/gist
zig build -Doptimize=ReleaseFast bench                  # default Billy source roots
zig build -Doptimize=ReleaseFast bench -- services libs  # scope to specific dirs
```

The run step sets cwd to the repo root, so dir arguments are repo-root-relative.
The candidate count `harness/bench.zig` reports is a **sound superset** of
`rg`'s true match-file count; the gap is the trigram filter's false-positive
rate (verified away by the caller's real regex). Set the numbers against a
correctly-scoped `rg` baseline (scope to source dirs — an unscoped `rg` from
repo root drags through ~99 GB of `target/` caches and is not a fair
comparison).

## The field — who gist races

`races/`, `gates/`, and `certify/` all race gist against the same **seven**
code searchers, split by whether they keep an index. The registry, fairness
scoping, and per-tool invocations live in **[`races/_compete.sh`](races/_compete.sh)**
(sourced by every script below except `equality.sh`); columns auto-skip when a
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

| Script                      | Race                                                                                                                                                                                                                                              |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `races/headtohead.sh`       | **warm**: gist resident-index p50 vs the unindexed scanners (the long-lived agent-session model)                                                                                                                                                  |
| `races/coldquery.sh`        | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed)                                                                                                                                          |
| `races/regex_headtohead.sh` | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                                                                                                                                                |
| `gates/equality.sh`         | **correctness**: gist ≡ `rg` over a byte-exact corpus snapshot (the soundness oracle, INDEX path)                                                                                                                                                 |
| `gates/scan_regress.sh`     | **scan-path regression + race**: the no-prefilter live-tree scan ≡ `rg` (gate, exits 1 on FN/FP) + min-of-N vs `rg` + the straggler-balance canary                                                                                                |
| `gates/streams.sh`          | **output contract** (gate, exits 1 on violation): results→stdout, diagnostics (`—` summary / `[pipeline]` / guidance)→stderr across the literal, rank, and scan paths — the `rg`-conventional split that makes gist composable in agent pipelines |
| `certify/certify.sh`        | **statistical certificate**: the same field, per regex class, with a fail-closed bootstrap-CI + Mann-Whitney verdict vs ripgrep                                                                                                                   |

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,regex,warm}.csv` for your own analysis. See
`races/README.md` and `gates/README.md` for the scenario-level detail.

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

## Certificate of Optimality (Layers A–D)

The race scripts above report _means and ratios_. The **certificate** turns that
into a claim that is beyond reproach — every number carries a 95% bootstrap
confidence interval and (vs ripgrep) a Mann-Whitney significance test, so a
"win" is **statistically real**, not box noise. It is built in four layers,
cheapest evidence first, and **all four are now implemented**:

| Layer | Claim                                                                 | Status         |
| ----- | --------------------------------------------------------------------- | -------------- |
| **A** | empirical dominance — fastest in class on real workloads, fail-closed | ✅ implemented |
| **B** | port-optimality — hot loop matches the static µarch bound (llvm-mca)  | ✅ implemented |
| **C** | roofline — cycles/byte sits on the hardware ceiling                   | ✅ implemented |
| **D** | algorithmic lower bound — matches the information-theoretic floor     | ✅ implemented |

Every layer writes into the same `.local/gist-verify/CERTIFICATE.md`. Layer A
has two halves — the **microscopic** half (`zig build certify`,
`harness/certify.zig` + `harness/pmu.zig` + `harness/stats.zig`, see
`harness/README.md`) and the **macroscopic** half (`certify/certify.sh` +
`certify/certify_stats.py`, see `certify/README.md`). **Layer A's run
rewrites the whole file**, so re-splice B/C/D afterward, in this order:

Always build **`-Doptimize=ReleaseFast`** — a Debug build is not vectorized and
its cycles/byte + bandwidth numbers are meaningless (a Debug scan measures loop
overhead, not the memory hierarchy). The report splicers resolve `.local/` at the
repo root, so they run from anywhere.

```bash
cd pkg/kernels/gist

# Layer A — microscopic (cycles/byte; wall-clock fallback without sudo)
zig build -Doptimize=ReleaseFast certify                 # installs + runs; wall-clock without sudo
sudo zig-out/bin/gist-bench certify                      # re-run the installed ReleaseFast binary for cycles

# Layer A — macroscopic (whole field, fail-closed vs ripgrep)
RUNS=20 bench/certify/certify.sh

# Layer B — port-optimality (static llvm-mca bound; needs `brew install llvm`)
bench/portcert/portcert.sh

# Layer C — roofline (this machine's memory-bandwidth ceiling)
zig build -Doptimize=ReleaseFast roofline && bench/roofline/roofline_report.py

# Layer D — algorithmic lower bound (fail-closed byte-touch audit)
zig build -Doptimize=ReleaseFast lowerbound && bench/lowerbound/lowerbound_report.py
```

Each layer degrades gracefully rather than failing the whole pipeline: Layer A
without `sudo` reports wall-clock only; Layer B without `llvm-mca` prints a
documented skip; none invents a number for hardware it can't measure (e.g. no
fabricated Apple-Silicon `llvm-mca` model — see `portcert/README.md`).
