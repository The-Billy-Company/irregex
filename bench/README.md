# irregex/bench

Benchmark, verification, and competitive-proof harness for the search kernel —
no engine code lives here (that's all under `src/`). Three evidence-genre
buckets live in this repo. The ones that oracle the *product* rather than the
engine — dominance, certificate, and conformance — live in the sibling `gist`
repo (`gist/bench/…`), because what they measure is a binary this package does
not build. Sorted by what a folder _proves_, not by the mechanism it proves it
about:

| Bucket                                  | What it holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`apparatus/`](apparatus/README.md)     | The instruments: [`harness/`](apparatus/harness/README.md) — the three shared modules both repos import (`probes` the 12-class registry, `pmu` the hardware counters, `stats` the bootstrap/Mann-Whitney verdict math) — plus `roots.sh`, which answers where this package's siblings are. The corpora fetcher went with `conformance/`, its only consumer, and the `gist-bench` binary went with the product it drives.                                                                     |
| `gist/bench/conformance/` | Fail-closed correctness — **no timing claim lives here** (sibling `gist` repo): `gates/` (parity · contract · oracle), `rgsuite/` the rg drop-in replay, `diag/` the stderr goldens, `shapes/` the CLI-shape admission matrix, `targets/` the cross-compile matrix, and `apparatus/corpora/` the multi-corpus fetcher they run over. It oracles the `gist` binary against `rg`, so it lives with the package that builds one. The Layer G retrieval contract lives in the sibling `relate` repo under `relate/bench/conformance/relate/`. |
| `gist/bench/dominance/`     | Measured product performance in the world (sibling `gist` repo): `gist/bench/dominance/races/` the competitor field (`field.sh`) + the multi-tool head-to-heads, `gist/bench/dominance/session/` the warm resident-daemon tier, `gist/bench/dominance/evaluate/` the operational envelope (lifecycle cost, footprint, scaling, concurrency).                                                                                                                                    |
| `gist/bench/certificate/` | The published Dominance-and-Fit claim (was `certify/`, sibling `gist` repo): `gist/bench/certificate/mint/` the mint + layer splicers, `gist/bench/certificate/report/` `stats.py` + the layer report writers, `gist/bench/certificate/guard/` roster/artifact/release/ratio checks, `gist/bench/certificate/ledger/` the mint history, and `gist/bench/certificate/artifact/` the **frozen** published receipts.                                                                                 |
| [`bounds/`](bounds/README.md)           | Layers B–D — distance from a stated limit: [`port/`](bounds/port/README.md) the `llvm-mca` static + measured µarch bound, [`roofline/`](bounds/roofline/README.md) the memory roof, [`lowerbound/`](bounds/lowerbound/README.md) the information-theoretic candidate-byte floor. Layer F (codex self-index vs the order-0 entropy bound) lives in `relate/bench/bounds/codex/`.                                                                                                                   |
| [`rungs/`](rungs/README.md)             | Per-mechanism production proofs: [`crest/`](rungs/crest/README.md) Layer E + its evidence bundle, plus [`sieve/`](rungs/sieve/README.md), [`shuffle/`](rungs/shuffle/README.md), [`parabix/`](rungs/parabix/README.md), [`multipattern/`](rungs/multipattern/README.md), and [`sliver/`](rungs/sliver/README.md).                                                                                                                                                                      |

Every lane installs on its own named step, and `zig build lab` installs all of
them at once. A bare `zig build` builds only the library and its C ABI:

```bash
cd <irregex-repo-root>
zig build lab                                    # all 15 → zig-out/bin
zig build -Doptimize=ReleaseFast crest           # one production rung
zig build -Doptimize=ReleaseFast roofline        # one certificate layer
zig build -Doptimize=ReleaseFast portbound       # Layer B′ with real cycles
```

Each run step sets cwd to the package root, so path arguments are
package-relative. Certificate layers honour whatever `-Doptimize` you ask for,
since a cycles/byte number is a claim about *this* build; production rungs
default to `-Dlab-optimize=ReleaseFast` because a rung that races the shipped
ladder has to be compiled the way the shipped ladder is, or the ratio is about
the build mode rather than the machine.

The one certificate layer that is **not** a claim about this build is the memory
roof: `bounds/roofline/` measures the machine's bandwidth, and a Debug build of
its vector reduction measures its own codegen instead — flat across all three
cache tiers, roughly an order of magnitude low, and indistinguishable from a
real hierarchy once it is JSON. It therefore refuses to run unoptimized rather
than publish, so the `-Doptimize` above is not advice.

The corpus-slate lane (`zig build bench`) moved to the `gist` package with the
`gist-bench` binary. The candidate count it reports is a **sound superset** of
`rg`'s true match-file count; the gap is the trigram filter's false-positive
rate, verified away by the caller's real regex.

## The field — who gist races

`gist/bench/dominance/races/`, `conformance/gates/`, and `gist/bench/certificate/` all race gist
against the same **seven** code searchers, split by whether they keep an index.
The registry, fairness scoping, and per-tool invocations live in
**`gist/bench/dominance/races/field.sh`** (sourced by every
script below except `equality.sh`); columns auto-skip when a binary isn't
installed.

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

### Which rival, exactly — the identity a mint records

`@latest` names no version, so the roster above does not pin itself: the rival is
whatever the machine happened to have. Every mint therefore writes each tool's
identity to **`tool-versions.txt`** beside the receipts — the version the tool
reports of itself **and** the sha256 of the executable that resolved. Both,
because either alone degrades quietly:

- A **digest alone** can name the wrong file. Under a version manager
  `command -v csearch` resolves to the multiplexer, not the rival — a `mise` shim
  is a symlink to `mise` — so shimmed tools hash to one launcher while still
  reading as exact pins. Measured here: `csearch`, `zoekt`, and `zig` all
  recorded the single digest `20d3bc06…`, which is `mise`. `guard/artifacts.py`
  now fails closed when two tool ids share a digest, and identity resolution
  walks `PATH` for a candidate whose name survives symlink resolution (a
  multiplexer renames itself; a real install does not), so the digest names the
  rival rather than the launcher.
- A **version alone** cannot distinguish two local builds of one release. Both
  csearch copies on this box are module `v1.2.0` compiled by different Go
  toolchains, and only the digest separates them.

csearch and zoekt carry **no version flag at all**, so their pin is the embedded
Go module version, read from build metadata rather than by running them —
`csearch version` treats `version` as the _regexp_ and prints a matching corpus
line, which scraped a bogus `26.3.0` into an identity before the probe order was
fixed. Expect `github.com/google/codesearch v1.2.0` and a
`github.com/sourcegraph/zoekt` commit pseudo-version.

| Script                                     | Race                                                                                                                                                                                                                                              |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist/bench/dominance/races/warm.sh`                  | **warm**: gist resident-index p50 vs the unindexed scanners (the long-lived agent-session model)                                                                                                                                                  |
| `gist/bench/dominance/races/cold.sh`                  | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed)                                                                                                                                          |
| `gist/bench/dominance/races/regex.sh`                 | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                                                                                                                                                |
| `conformance/gates/parity/equality.sh`     | **correctness**: gist ≡ `rg` over a byte-exact corpus snapshot (the soundness oracle, INDEX path)                                                                                                                                                 |
| `conformance/gates/parity/scan_regress.sh` | **scan-path regression + race**: the no-prefilter live-tree scan ≡ `rg` (gate, exits 1 on FN/FP) + min-of-N vs `rg` + the straggler-balance canary                                                                                                |
| `conformance/gates/contract/streams.sh`    | **output contract** (gate, exits 1 on violation): results→stdout, diagnostics (`—` summary / `[pipeline]` / guidance)→stderr across the literal, rank, and scan paths — the `rg`-conventional split that makes gist composable in agent pipelines |
| `gist/bench/certificate/mint/mint.sh`                 | **statistical certificate**: the same field, per regex class, with a fail-closed bootstrap-CI + Mann-Whitney verdict vs ripgrep                                                                                                                   |

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,regex,warm}.csv` for your own analysis. See
`gist/bench/dominance/races/README.md` and `conformance/gates/README.md` for the
scenario-level detail.

`gist/bench/dominance/races/warm.sh` times gist's **in-process** engine (the microsecond
ceiling — no transport, no process spawn), which no client actually rides. The
honest warm-**product** path — a persistent client dialing a `gist serve` daemon
once and replaying the slate over that warm connection — is certified separately
in `gist/bench/dominance/session/`, the only sound
basis for a "warm is Nx faster than ripgrep" claim.

## Fairness — stated, not hand-waved

Every tool is scoped to the same source roots (`$GIST_ROOTS` when set, else the
tree's own roots — `field.sh` resolves them once, mirroring
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
  which is why `field.sh` re-applies the build-output exclusions as globs
  (`$SCOPE`): without them these two alone walk build artifacts the root ignore
  never names — Elixir `_build`/`deps`/`cover`, Electron `out/` — that
  `gist index` prunes and csearch therefore never indexes. Not the whole of
  `$XDIRS`, because `vendor` holds tracked source; mix output is anchored
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

Every layer writes into the same `.gist/CERTIFICATE.md`. Layer A
has several lanes — the **microscopic** half (`zig build certify` in the sibling
`gist` repo, whose `certify.zig` reads this package's `pmu` and `stats` modules
from `apparatus/harness/`), the **macroscopic** half (`gist/bench/certificate/mint/mint.sh` +
`gist/bench/certificate/report/stats.py`, see `gist/bench/certificate/README.md`), the warm resident tier, and
the `--rank` lane. **One command** mints or refreshes the whole thing — Layers
B/B′/C/D/E/F and the warm/`--rank`/relate lanes are spliced automatically and
`guard/artifacts.py` fail-closes if any section is missing.

Always build **`-Doptimize=ReleaseFast`** — a Debug build is not vectorized and
its cycles/byte + bandwidth numbers are meaningless (a Debug scan measures loop
overhead, not the memory hierarchy). The report splicers resolve `.local/` at the
repo root, so they run from anywhere.

```bash
# Refresh Layers B/B′/C/D/E/F onto an existing Layer-A bundle (the common path):
bash ../gist/bench/certificate/mint/splice.sh

# Full mint (A micro + PMU if sudo + A macro race + warm + --rank + B–F + relate) + publish:
CERT_PUBLISH_DIR=../gist/bench/certificate/artifact CERT_SUDO=1 \
  bash ../gist/bench/certificate/mint/mint.sh
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
`bounds/port/README.md`).
