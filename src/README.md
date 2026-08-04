# irregex/src

This is the prose half of [`../contract/irregex.zone`](../contract/irregex.zone).
The Zig tree holds three product faces (`gist` · `relate` · `irregex`) over one
shared stack organized into **five layers**, read bottom-up. `root.zig`
re-exports every tier through the flat C ABI in `../include/irgx.h`;
`../bench/` holds the proof harness, never engine code.

**The teachable sentence:** the kernel answers, the corpus supplies, exec
executes, the surface speaks, the floor instruments.

| Layer | What lives there | README |
| ----- | ---------------- | ------ |
| floor | `portal.zig` (OS seam) · `assay/` (instrumentation) · `fault.zig` (error taxonomy) · wire floor `corpus/index/frame/` (frame · signet · home) | below + [`corpus/index/frame/`](corpus/index/frame/README.md) |
| [`kernel/`](kernel) | Pure compute — no argv, walk, or emit. Ten tier packages low→high: `math` · `scan` · `regex` · `query` · `rank` · `slate` · `anatomy` · `kinship` · `codex` · `compose` | [`kernel/README.md`](kernel/README.md) |
| [`corpus/`](corpus) | Which bytes are eligible + persisted shadows: `scope/` · `read/` · `tree/` · `fresh/` · `index/` | [`corpus/README.md`](corpus/README.md) |
| [`exec/`](exec) | Runtimes promoted out of surface: `cold/` · `retrieval/` · `session/` (incl. daemon) | [`exec/README.md`](exec/README.md) |
| [`surface/`](surface) | Vocabulary + transports + faces: `cli/` · `api.zig` · `ffi/` · `face/{gist,relate,irregex}` | [`surface/README.md`](surface/README.md) |

`assay/` is the instrumentation floor beneath every tier (imports only `std`).
See [`assay/README.md`](assay/README.md).

## The anatomy of a query

What happens when an agent types `gist 'pgxpool\.\w+' services/`:

1. **argv → intent** (`exec/cold/argv/`). One flag catalog drives both the
   parser and the `--schema` manifest; a flag gist doesn't support fails loud
   with exit 2 and the `rg` fallback.
2. **Compile once** (`kernel/query/query.zig`). The pattern lowers into an
   immutable `CompiledQuery`: the match decision _and_ the sound trigram
   prefilter come from the same compilation. Two invariants bind the core:
   **fail-closed, never fatal** (`error.Unsupported` / `error.OutOfMemory`) and
   **immutable after compile**.
3. **Walk the live tree** (`corpus/tree/haystack.zig` + `exec/cold/`). One walk
   skeleton feeds every consumer; ignore dialect is deliberate rg-parity.
4. **Elide reads, never results** (`corpus/index/trigrams/` + `crest/`). Fresh
   persisted indexes skip files that cannot match **before open(2)**. Entire
   authority: _"Index is an accelerator, not an authority."_
5. **Match** (`kernel/regex/` + `kernel/scan/`). Cheapest sound rung first.
6. **Emit** (`exec/cold/emit/`). rg-shaped stdout; diagnostics on stderr.

The **warm path** short-circuits steps 3–4. `gist serve` holds the corpus and
index resident (`exec/session/`, daemon under `session/daemon/`). Any failure
falls back to the certified cold subprocess. The C ABI (`surface/ffi/`) is the
same session in-process.

## Floor — portal, assay, fault, wire

| Piece | Job |
| ----- | --- |
| `portal.zig` | Every OS-spelling difference (handle-relative open, whole-file map, stat, realpath, argv, stdin readiness, **how wide the machine is**) — one Windows fork at the bottom |
| `assay/` | Typed clocks, counters, `GIST_TRACE` — std-only so every tier can consume it |
| `fault.zig` | Error taxonomy (the fault-channel taxonomy); reports through assay |
| `corpus/index/frame/` | Wire floor: `frame.zig` framing, `signet.zig` the one artifact digest, `home.zig` artifact directory. Lives under index on disk (what it frames) but sits just above fault on the ward page |

**Machine width is a portal question, not a std one.** Every parallel stage sizes
its shards from `portal.cpuCount()` rather than `std.Thread.getCpuCount()`,
because on Windows std answers with the *primary processor group* — 64 logical
processors at most, no matter how many the box has. Nothing fails when that
number is wrong; the work just runs narrow, which is precisely the kind of
platform gap a benchmark on a small runner never surfaces. The seam asks whether
*this process* spans multiple groups (`GetProcessGroupAffinity`) before trusting
the all-groups total, so a pre-Windows-11 process — confined to one group, where
the total would overcount — keeps the primary count that is correct for it.

## `kernel/` — ten pure-compute tiers

No argv, no walk, no emit. Import arrows only point down the ward page;
`compose/` is the only kernel tier allowed to know all the others.

| Package | Job |
| ------- | --- |
| [`math/`](kernel/math) | Math floor: bits, mix, glob matcher, crest sieve, misread, forest, lease, parallel, succinct |
| [`scan/`](kernel/scan) | SIMD scanners + `lanes.zig` literal-lane vocabulary |
| [`regex/`](kernel/regex) | THE regex package — parser, linear engines, matcher meta dispatcher; sealed through `regex.zig`; ambition is to beat rust-regex |
| [`query/`](kernel/query) | Shared compiled query every transport compiles through |
| [`rank/`](kernel/rank) | Result fusion + definition signals (`gist --rank`) |
| [`slate/`](kernel/slate) | Many patterns, one walk (was `batch/`) |
| [`anatomy/`](kernel/anatomy) | Source anatomy: comments, token vocabulary, leans |
| `relate/src/kernel/kinship/` | Compression-as-similarity |
| `relate/src/kernel/codex/` | FM-index / wavelet / RRR / SA-IS codebook math (was under `corpus/index/codex`) |
| `relate/src/kernel/compose/` | Set algebra over candidate sets |

## `corpus/` — eligibility + persisted shadows

| Package | Job |
| ------- | --- |
| [`scope/`](corpus/scope) | Charter, paths, `filter.zig` (PathFilter half of the old glob) |
| [`read/`](corpus/read) | Byte legibility: encodings, inode |
| [`tree/`](corpus/tree) | The walk, `corpus.zig`, `drain.zig` stdout cadence |
| [`fresh/`](corpus/fresh) | Freshness anchor + journal + sweep (promoted out of trigrams) |
| [`index/`](corpus/index) | Persisted artifacts: trigrams · postings · crest · atlas · frag · content · phantom · shelf · frame |

## `exec/` — the two runtimes (+ shared retrieval)

| Package | Job |
| ------- | --- |
| [`cold/`](exec/cold) | One process per query: argv → writ → quarry → read → engine → emit |
| `relate/src/exec/retrieval/` | Fingerprint-lexicon retrieval shared by `similar` / `pack` |
| [`session/`](exec/session) | Warm resident session: answer · facet · reconcile · warm · watch · conduit · **daemon/** |

## `surface/` — vocabulary, API, FFI, faces

| Piece | Job |
| ----- | --- |
| [`cli/`](surface/cli) | Shared vocabulary: outcome (die/oom), jsonstr, flags, manifest, reprise |
| `api.zig` | Hosted analytic Zig API |
| `gist/src/surface/ffi/` | C-ABI session + analytic plane |
| `gist/src/surface/face/` | Thin product faces; gist verbs live flat in `face/gist/verbs/` |

## The correctness spine

- Regex checked by an independent AST backtracking oracle (`kernel/regex/oracle/`)
  plus DFA↔Pike differentials and live `rg` differentials.
- Codex differentials every layer against a naive oracle.
- Product surface held to ripgrep by rgsuite, equality, elision-parity, and
  stream-contract gates in [`../bench/`](../bench/README.md).

See [`../README.md`](../README.md) for products and prior art;
[`kernel/regex/README.md`](kernel/regex/README.md) for the regex engine;
`gist/src/surface/face/gist/README.md` for the gist face.
