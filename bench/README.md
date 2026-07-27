---
doc_radar:
  counts:
    - description: "bench concern folders, one per row of the table below"
      glob: pkg/kernels/irregex/bench/*/
      unit: dirs
      min: 19
  sentinels:
    - description: "the Layer B′ measured rung exists as a build step"
      file: pkg/kernels/irregex/build.zig
      contains: 'b.step("portbound"'
---

# gist/bench

Benchmark, verification, and competitive-proof harness for the `gist`
code-locator kernel — no engine code lives here (that's all under `src/`).
One concern per folder:

| Folder                                | Concern                                                                                                                                                                                                                                                  |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`harness/`](harness/README.md)       | The native `gist-bench` Zig binary — corpus load + latency slate, the microscopic cycles/byte certificate, PMU counters, bootstrap statistics, the shared probe registry.                                                                                |
| [`corpora/`](corpora/)                | Multi-corpus fetcher (`fetch.sh` + `torture.py`) — pinned external trees (linux/cpython/typescript/subtitles/torture) under `.local/gist-corpora/` so differential sweeps aren't Billy-home-corpus-only.                                                 |
| [`races/`](races/README.md)           | The competitor registry (`_compete.sh`) + the six multi-tool field races (warm, cold literal, cold regex, cold PCRE, cold `-z`, relate).                                                                                                                 |
| [`gates/`](gates/README.md)           | Permanent correctness/contract gates: the `gist ≡ rg` equality oracle, the scan-path regression, the stdout/stderr stream-contract check.                                                                                                                |
| [`certify/`](certify/README.md)       | The macroscopic half of the Layer-A dominance certificate — races the whole field per pattern class with a fail-closed statistical verdict.                                                                                                              |
| [`session/`](session/README.md)       | The **resident-session** certificate — the honest warm-product path (persistent client → `gist serve` daemon over a Unix socket), the only sound basis for a warm-speedup claim (ADR-352 rung 2.5).                                                      |
| [`rgsuite/`](rgsuite/README.md)       | The `gist rg` ⇄ real-ripgrep drop-in proof — mined `rgtest!` correctness replay plus the performance scoreboard.                                                                                                                                         |
| [`matrix/`](matrix/README.md)         | The **CLI-shape admission matrix** — one machine-readable row per supported shape (mode × flags × walk-scope × emit × selectivity), driven as real argv three ways (gist-idx / gist-noidx / rg) with a parity-first gate + per-shape statistical floors. |
| [`portcert/`](portcert/README.md)     | Layer B — port-optimality: cross-compiled `llvm-mca` static microarchitectural bound on gist's two hot loops, drift-guarded against production, plus Layer B′ — the same probes **measured on this machine** under the PMU (`gist-portbound`).           |
| [`roofline/`](roofline/README.md)     | Layer C — roofline headroom: STREAM roof plus matched dual-window, contiguous-production, and corpus-production stages.                                                                                                                                  |
| [`lowerbound/`](lowerbound/README.md) | Layer D — algorithmic lower bound: a fail-closed structural audit proving gist's verify touches the information-theoretic floor of candidate bytes.                                                                                                      |
| [`crest/`](crest/README.md)           | Layer E — the **crest sieve** production proof (`zig build crest`): soundness, pruning, speed, ablation, and randomized sweeps over the literal-free class-repetition blind spot every trigram index concedes.                                           |
| [`relate/`](relate/README.md)         | The **relate** proof (`relate-knn`) — the real cross-parse / LZJD / pivot engine run as a k-NN classifier; the measured basis for the compression-vs-embeddings verdict (`spikes/compression-vs-embeddings/`).                                    |
| [`codex/`](codex/README.md)           | The **self-index** at-scale proof (`codex-scale`) — the real `src/corpus/index/codex/` FM-index over ~187MB of repo source: entropy-bound space vs gzip/bzip2/zstd/xz, flat-in-n count latency, byte-exact restore from the index alone.                 |
| [`evaluate/`](evaluate/README.md)     | The operational-envelope matrix — index lifecycle cost, resource footprint, scaling shape, and concurrency; the complement to the certificate's speed/correctness proof.                                                                                 |
| [`diag/`](diag/README.md)             | The diagnostic-template golden net — normalizes volatile stderr values away and diffs the template words against committed goldens, so a format typo breaks CI but a changed timing does not.                                                            |
| [`compose/`](compose/README.md)       | Rung proof (`compose-rung`) — the transformation-composition scan against the shipped `Dfa.docMatch`, interleaved in one process, failing closed on disagreement _and_ on the dispatch gate arming where a literal skip already wins.                    |
| [`parabix/`](parabix/README.md)       | Rung proof (`parabix-rung`) — the bit-parallel scan against both baselines it must beat (the whole `Regex.docMatch` ladder and the raw DFA under it), with its refusals published beside its wins.                                                       |
| [`sieve/`](sieve/README.md)           | Rung proof (`sieve`) — the only rung that cannot say yes, so the harness proves a rejection is never a lie: per-position and per-document soundness over the real corpus, plus selectivity against the estimate that gates it.                           |

```bash
cd pkg/kernels/irregex
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

`races/headtohead.sh` times gist's **in-process** engine (the microsecond
ceiling — no transport, no process spawn), which no client actually rides. The
honest warm-**product** path — a persistent client dialing a `gist serve` daemon
once and replaying the slate over that warm connection — is certified separately
in [`session/`](session/README.md) (`make bench-gist-session`), the only sound
basis for a "warm is Nx faster than ripgrep" claim.

## Fairness — stated, not hand-waved

Every tool is scoped to the same source roots (`$GIST_ROOTS` when set, else the
tree's own roots — `_compete.sh` resolves them once, mirroring
`corpus.resolveRoots`) and given its honest fastest path:

- **rg / git grep** honor `.gitignore` natively (skip the gitignored ~99 GB of
  build artifacts). **ag** is handed `--path-to-ignore .gitignore` (the root
  ignore set `rg` reads for free). **ugrep / GNU grep** have no per-file
  gitignore, so they get the heavy dir-exclude set (`$XDIRS`) — they still scan a
  slightly _larger_ file set (gitignored individual files `rg` skips), which only
  makes them do **more** work, so gist's win over them is conservative.
- **gist / rg** additionally run under `--no-ignore-vcs` plus the root
  `.gitignore`, so a multi-root race can't hit ripgrep's nondeterministic
  parent-ignore re-anchoring. That also discards every _nested_ `.gitignore`,
  which is why `_compete.sh` re-applies the build-output exclusions as globs
  (`$SCOPE`): without them these two alone walk build artifacts the root ignore
  never names — Elixir `_build`/`deps`/`cover`, Electron `out/` — that
  `gist index` prunes and csearch therefore never indexes. Not the whole of
  `$XDIRS`, because `vendor` holds tracked Billy source; mix output is anchored
  per `mix.exs` root for the same reason rule-of-five anchors it.
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

## Dominance-and-Fit Certificate (Layers A–G)

The race scripts above report _means and ratios_. The **certificate** turns that
into a checkable claim — every number carries a 95% bootstrap
confidence interval and (vs ripgrep) a Mann-Whitney significance test, so a
"win" is **statistically real**, not box noise. What it certifies is named in
its title: measured **dominance** over a stated baseline, and each layer's
**fit** against a stated bound. It is not a proof of universal or hardware
optimality, and no layer claims one. It is built in seven layers,
cheapest evidence first, and **all seven are now implemented**:

Its headline (Layer A macroscopic) is the fresh-process, cold `gist` exact-search
path across the shared 12-class literal/regex probe registry. The narrower
surfaces that path used to disclaim now each carry their own **fail-closed**
section, so no claim ships without a receipt — the warm resident daemon and the
`--rank` lane are certified sub-sections of Layer A, the codex self-index is
Layer F, and the relate face is Layer G (a retrieval-quality contract, not a
dominance claim). Only `--include-zero` and composed `irregex` stay outside;
rgsuite parity proves `--include-zero` correct, which is not a speed claim.

| Layer | Claim                                                                                                                                                                   | Status         |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| **A** | empirical dominance over ripgrep on registered workloads, fail-closed (+ warm-tier dominance + the `--rank` lane's no-fabrication/def-boost/demotion/overhead/beats-rg) | ✅ implemented |
| **B** | port-optimality — hot loop matches the static µarch bound (llvm-mca)                                                                                                    | ✅ implemented |
| **C** | roofline — measures and decomposes distance from the hardware roof                                                                                                      | ✅ implemented |
| **D** | algorithmic lower bound — matches the information-theoretic floor                                                                                                       | ✅ implemented |
| **E** | crest sieve — fail-closed pruning of the literal-free class-repetition blind spot every trigram index concedes (index completeness)                                     | ✅ implemented |
| **F** | codex self-index — compressed below the order-0 entropy coder yet searchable, n-free O(m) count, byte-exact decodable, self-recognizing (cento)                         | ✅ implemented |
| **G** | relate — retrieval by description length: boundary (paraphrases outside exact search) + recall@1 + anti-redundant pack (a contract, not a race)                         | ✅ implemented |

Every layer writes into the same `.local/gist-verify/CERTIFICATE.md`. Layer A
has several lanes — the **microscopic** half (`zig build certify`,
`harness/certify.zig` + `harness/pmu.zig` + `harness/stats.zig`, see
`harness/README.md`), the **macroscopic** half (`certify/certify.sh` +
`certify/certify_stats.py`, see `certify/README.md`), the warm resident tier, and
the `--rank` lane. **One command** mints or refreshes the whole thing — Layers
B/B′/C/D/E/F and the warm/`--rank`/relate lanes are spliced automatically and
`check_artifacts.py` fail-closes if any section is missing.

Always build **`-Doptimize=ReleaseFast`** — a Debug build is not vectorized and
its cycles/byte + bandwidth numbers are meaningless (a Debug scan measures loop
overhead, not the memory hierarchy). The report splicers resolve `.local/` at the
repo root, so they run from anywhere.

```bash
# Refresh Layers B/B′/C/D/E/F onto an existing Layer-A bundle (the common path):
make bench-gist-certify
# or:  bash pkg/kernels/irregex/bench/certify/certify_layers.sh

# Full mint (A micro + PMU if sudo + A macro race + warm + --rank + B–F + relate) + publish:
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify
# or:  CERT_PUBLISH_DIR=bench/certify/artifact CERT_SUDO=1 \
#        bash pkg/kernels/irregex/bench/certify/certify.sh
```

Run a full mint in a clean, stable checkout or isolated worktree. A live
coworking tree is not a benchmark corpus: files can change between tools,
invalidating equivalence, timing, and corpus hashes. `CERT_ALLOW_DIRTY=1`
permits local exploratory evidence only; it does not make a dirty result a
publishable, commit-reproducible certificate.

`CERT_SUDO=auto` (default) uses passwordless `sudo -n` when configured, else
degrades loudly; `CERT_SUDO=1` prompts once; `CERT_SUDO=0` never escalates.
Each layer degrades gracefully rather than failing the whole pipeline — but
**loudly in the artifact**: Layer A without `sudo` reports wall-clock only and
the certificate states _"cycles/byte: NOT measured on this machine"_; Layer B
without `llvm-mca` prints a documented skip; Layer B′ without `sudo` records
wall-clock ns and fail-closed labels cycles as cross-checked-only. None invents
a number for hardware it can't measure (no fabricated Apple-Silicon `llvm-mca`
model, no wall-clock dressed up as cycles via an assumed frequency — see
`portcert/README.md`).
