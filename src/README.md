# irregex/src

This is the prose half of [`../charter.zone`](../charter.zone).
The Zig tree is the LIBRARY the ecosystem's three product faces — exact
search, kinship, and the composed face over both — stand on, organized into
five layers, read bottom-up.
`root.zig` re-exports every tier through the flat C ABI in
`../include/irgx.h`; `../bench/` holds the proof harness, never engine code.

**The teachable sentence:** the kernel answers, the corpus supplies, exec
executes, the surface speaks, the floor instruments.

- **floor** holds `portal.zig` (the OS seam), `assay/` (instrumentation),
  `fault.zig` (the error taxonomy), and the wire floor
  `corpus/index/frame/` (frame · signet · home). See below and
  [`corpus/index/frame/`](corpus/index/frame/README.md).
- [`kernel/`](kernel) is pure compute: no argv, walk, or emit. Its own
  contract declares eight tiers low→high — `math` · `codex` · `scan` ·
  `regex` · `anatomy` · `query` · `rank` · `slate` — and two more of the
  same ward, `kinship` and `compose`, are zoned in the sibling kinship
  package. See [`kernel/README.md`](kernel/README.md).
- [`corpus/`](corpus) decides which bytes are eligible and holds the
  persisted shadows built over them: `scope/` · `read/` · `tree/` ·
  `fresh/` · `index/`. See [`corpus/README.md`](corpus/README.md).
- [`exec/`](exec) holds the runtimes promoted out of surface: `cold/` and
  `retrieval/`-backing `session/`. See [`exec/README.md`](exec/README.md).
- [`surface/`](surface) is vocabulary plus transports: `cli/` · `api.zig` ·
  `ffi/`. The three product faces that used to live here now ship from
  their own sibling repos. See
  [`surface/README.md`](surface/README.md).

`assay/` is the instrumentation floor beneath every tier (imports only
`std`). See [`assay/README.md`](assay/README.md).

## The Anatomy of a Query

What happens when an agent asks a face for `'acmepool\.\w+' services/`:

1. **argv → intent** (`exec/cold/argv/`). One flag catalog drives both the
   parser and the `--schema` manifest; an unsupported flag fails
   loud with exit 2 and the `rg` fallback.
2. **Compile once** (`kernel/query/query.zig`). The pattern lowers into an
   immutable `CompiledQuery`: the match decision *and* the sound trigram
   prefilter come from the same compilation. Two invariants bind the
   core — fail-closed, never fatal (`error.Unsupported` /
   `error.OutOfMemory`), and immutable after compile.
3. **Walk the live tree** (`corpus/tree/haystack.zig` + `exec/cold/`). One
   walk skeleton feeds every consumer; ignore dialect is deliberate
   rg-parity.
4. **Elide reads, never results** (`corpus/index/trigrams/` +
   `math.crest`). Fresh persisted indexes skip files that cannot match
   before `open(2)`. Entire authority: "index is an accelerator, not an
   authority."
5. **Match** (`kernel/regex/` + `kernel/scan/`). Cheapest sound rung first.
6. **Emit** (`exec/cold/emit/`). rg-shaped stdout; diagnostics on stderr.

The warm path short-circuits steps 3–4. A resident daemon holds the corpus and
index in memory, riding this library's `exec/session/` machinery from the face
package's own `session/daemon/`. Any failure falls back to the
certified cold subprocess. The C ABI (`surface/ffi/`) is the same session
in-process.

## Floor — Portal, Assay, Fault, Wire

- **`portal.zig`** absorbs every OS-spelling difference: handle-relative
  open, whole-file map, stat, realpath, argv, stdin readiness, and how
  wide the machine is — one Windows fork at the bottom.
- **`assay/`** provides typed clocks, counters, and the `<prefix>TRACE` lens
  gate — std-only so every tier can consume it.
- **`fault.zig`** is the error taxonomy (the fault-channel taxonomy); it
  reports through assay.
- **`corpus/index/frame/`** is the wire floor: `frame.zig` framing,
  `signet.zig` the one artifact digest, `home.zig` the artifact directory.
  It lives under `index/` on disk (what it frames) but sits just above
  fault on the ward page.

Machine width is a portal question, not a std one. Every parallel stage
sizes its shards from `portal.cpuCount()` rather than
`std.Thread.getCpuCount()`, because on Windows std answers with the
*primary processor group* — 64 logical processors at most, no matter how
many the box has. Nothing fails when that number is wrong; the work just
runs narrow, which is precisely the kind of platform gap a benchmark on a
small runner never surfaces. The seam asks whether *this process* spans
multiple groups (`GetProcessGroupAffinity`) before trusting the all-groups
total, so a pre-Windows-11 process, confined to one group where the total
would overcount, keeps the primary count that is correct for it.

## `kernel/` — Pure-Compute Tiers

No argv, no walk, no emit. Import arrows only point down the ward page.

- [`math/`](kernel/math) is the math floor: bits, mix, the pure glob
  matcher, the crest sieve, misread, forest, lease, parallel, and the
  succinct structures.
- [`codex/`](kernel/codex) is the FM-index composition over the succinct
  floors above, sealed with the wire floor.
- [`scan/`](kernel/scan) holds the SIMD scanners and the literal-lane
  vocabulary they share with the regex composer.
- [`regex/`](kernel/regex) is THE regex package: parser, linear engines
  (dfa/pike/ladder/sieve/symbolic/parabix/caliper/shuffle), the PCRE2
  bridge, `matcher.zig`'s meta dispatcher, and the consumer-facing
  `regex/glean/`; sealed through `regex.zig`. Ambition: beat rust-regex.
- [`query/`](kernel/query) is the shared compiled query every transport
  compiles through.
- [`rank/`](kernel/rank) fuses results and derives cross-language definition
  signals (the ranked view, and the signals the other faces read too).
- [`slate/`](kernel/slate) runs many patterns in one walk: `patterns` ·
  `muster` · `trawl` · `loom`.
- [`anatomy/`](kernel/anatomy) is source anatomy: the parser-free comment/code/
  string span lexer and the line index — what stayed after the unit anatomy
  and its tokens, spans and leans moved to the kinship package.
- The kinship package's `kernel/kinship/` is compression-as-similarity:
  `metric/` · `cluster/` · `recall/`.
- Its `kernel/codex/` is the Ziv–Merhav cento quoter over this
  package's FM-index.
- Its `kernel/compose/` runs set algebra over candidate sets.

## `corpus/` — Eligibility and Persisted Shadows

- [`scope/`](corpus/scope) holds the charter, paths, and `filter.zig` (the
  path-filter half of the old glob).
- [`read/`](corpus/read) decides byte legibility: encodings, inode.
- [`tree/`](corpus/tree) is the walk itself: `corpus.zig`,
  `drain.zig`'s stdout cadence.
- [`fresh/`](corpus/fresh) is the freshness anchor, journal, and sweep,
  promoted out of trigrams.
- [`index/`](corpus/index) holds the persisted artifacts: trigrams ·
  postings · crest · content · phantom · shelf · frame. The kinship-side
  atlas and frag artifacts are persisted by the kinship package instead.

## `exec/` — The Two Runtimes (Plus Shared Retrieval)

- [`cold/`](exec/cold) is one process per query: argv → writ → quarry →
  read → engine → emit.
- The kinship package's `exec/retrieval/` is fingerprint-lexicon retrieval
  shared by its `similar` / `pack` verbs.
- [`session/`](exec/session) is the warm resident session: answer · facet
  · reconcile · warm · watch · conduit. The daemon transport that holds it
  resident lives in the face package's `session/daemon/`.

## `surface/` — Vocabulary, API, FFI

- [`cli/`](surface/cli) is the shared vocabulary: outcome (die/oom),
  jsonstr, flags, manifest, reprise.
- **`api.zig`** is the hosted analytic Zig API.
- **`ffi/`** is this library's own C-ABI plane: a pattern over a buffer the
  host already holds — compile, `is_match`, `find_all`, `captures` — plus
  the status/fault substrate every package's ABI returns. The
  session-shaped ABI and the three product faces build on top of it from
  their own repos.

## The Correctness Spine

- Regex is checked by an independent AST backtracking oracle
  (`kernel/regex/oracle/`) plus DFA↔Pike differentials and live `rg`
  differentials.
- Codex differentials every layer against a naive oracle.
- The product surface is held to ripgrep by rgsuite, equality,
  elision-parity, and stream-contract gates in
  [`../bench/`](../bench/README.md).

See [`../README.md`](../README.md) for products and prior art;
[`kernel/regex/README.md`](kernel/regex/README.md) for the regex engine; and
each face package's own README for the face itself.
