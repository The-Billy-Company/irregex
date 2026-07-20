---
doc_radar:
  counts:
    - description: "the six concern tiers under src/: math · corpus · index · search · runtime · cli"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 6
    - description: "search/ keeps its five kernels: match · rank · similarity · batch · compose"
      glob: pkg/kernels/irregex/src/search/*
      unit: dirs
      equals: 5
    - description: "index/ keeps its seven packages: trigrams · postings · codex · atlas · crest · frame · frag"
      glob: pkg/kernels/irregex/src/index/*
      unit: dirs
      equals: 7
  sentinels:
    - description: "the linear engine's eager-DFA cap the prose quotes (past it, Pike verifies)"
      file: pkg/kernels/irregex/src/search/match/regex/linear/powerset.zig
      contains: "pub const max_states: u32 = 4096;"
    - description: "the elision contract the whole index tier is built on"
      file: pkg/kernels/irregex/src/runtime/cold/engine/README.md
      contains: "Index is an accelerator, not an authority."
    - description: "the shared query core keeps its two binding invariants"
      file: pkg/kernels/irregex/src/search/match/query.zig
      contains: ["error.Unsupported", "immutable after"]
---

# irregex/src

This is the source map. The Zig tree holds three faces (`gist` · `relate` ·
`irregex`), four indexes, and one shared floor. `root.zig` re-exports
every module through the flat C ABI in `../include/irregex.h`;
`../bench/` holds the proof harness, never engine code.

I organized the tree **by concern, not by product**. Every binary is a thin
face over the same kernels: `gist` finds exact patterns; `relate` finds
compression kinship; `irregex` composes both (exact narrows, compression
reasons inside). None gets a private corpus walk, scope layer, or index.

| Tier | What lives there | README |
| ---- | ---------------- | ------ |
| [`math/`](math) | Shared identity floor: `bits` + crest sieve calculus | [`math/README.md`](math/README.md) |
| [`corpus/`](corpus) | Shared source substrate: `tree/` walk + `scope/` `-g`/`-t` | [`corpus/README.md`](corpus/README.md) |
| [`index/`](index) | Candidate / self / kinship indexes (accelerator only) | [`index/README.md`](index/README.md) |
| [`search/`](search) | Pure kernels: match · rank · similarity · batch · compose | [`search/README.md`](search/README.md) |
| [`runtime/`](runtime) | Execution hosts: cold · session · ffi | [`runtime/README.md`](runtime/README.md) |
| [`cli/`](cli) | Thin product faces: `gist` · `relate` · `irregex` | [`cli/README.md`](cli/README.md) |

## The anatomy of a query

The layout makes sense once you follow a real query. Here is what happens when
an agent types `gist 'pgxpool\.\w+' services/`:

1. **argv → intent** (`runtime/cold/argv/`). One flag catalog drives both
   the parser and the `--schema` manifest; a flag gist doesn't support fails
   loud with exit 2 and the `rg` fallback. A misunderstood flag must never look
   like a convincing empty result.
2. **Compile once** (`search/match/query.zig`). The pattern lowers into an
   immutable `CompiledQuery`: the match decision _and_ the sound trigram
   prefilter come from the same compilation, so the cold CLI, the warm
   session, and the FFI face cannot drift on what matches or what is safe to
   prune. Two invariants bind the core: **fail-closed, never fatal** (typed
   `error.Unsupported` / `error.OutOfMemory`; a bad pattern can never exit an
   embedding host) and **immutable after compile** (N walk workers share one
   query with per-worker `Scratch`).
3. **Walk the live tree** (`corpus/tree/haystack.zig`, `runtime/cold/walk/`).
   One walk skeleton, adapted from ripgrep's haystack split, feeds every
   consumer: the parallel work-stealing search, the index build, and the
   freshness stat-walk all drive the same `Walker` with different per-file
   actions. The ignore dialect (`.gitignore`/`.ignore`/`.rgignore` precedence,
   `!` re-includes, anchoring) is a deliberate rg-parity reimplementation,
   certified by the mined rgsuite corpus rather than trusted.
4. **Elide reads, never results** (`index/trigrams/` + `index/crest/`). If a
   fresh persisted index covers the searched roots, files whose trigrams —
   or whose crest vectors, for the literal-free class repetitions trigrams
   can't see — prove they can't match are skipped **before open(2)**. That is the entire authority the
   index has: _"Index is an accelerator, not an authority."_ The walk decides
   the file set, `--no-index` forces the pure scan, and
   `bench/gates/index_elision_parity.sh` mechanically asserts indexed ≡
   unindexed output. A stale index degrades to slower, never to different
   bytes.
5. **Match** (`search/match/`). Take the cheapest sound rung first; see below.
6. **Emit** (`runtime/cold/emit/`). rg-shaped `path:line:text` on stdout;
   diagnostics, timing, and the coaching channel (`gist: try -i …`) on stderr
   only; a soft output budget protects the agent's context window
   (`GIST_UNCAP` lifts it for harnesses).

The **warm path** short-circuits steps 3–4. `gist serve` holds the corpus and
index resident behind a Unix socket (`runtime/session/`, a length-prefixed
versioned protocol), the client classifies argv for eligibility, and _any_
failure (decline, timeout, TTY, wedged daemon) falls back to the certified
cold subprocess, byte for byte. The resident session reuses the cold walk's
file-set machinery and the cold `Emitter`, so warm output cannot be a second
opinion. The C ABI (`runtime/ffi/`) is the same session in-process: typed
statuses, per-call arenas, never `exit()`.

## `search/`: the two engines' kernels

| Folder               | Concern                                                                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `search/match/`      | the exact-match engine: the transport-neutral compiled query (`query.zig`) every face executes through, over `regex/` (linear-time NFA + byte-class DFA + Pike + PCRE2 `-P`) and `scan/` (SIMD substring presence + fused parallel verify) |
| `search/rank/`       | **T4** ranked output: weighted Reciprocal Rank Fusion over intrinsic, language-agnostic signals (`gist --rank`)                                                                                                                           |
| `search/similarity/` | the compression-kinship math: `sketch` (symmetric LZJD relatedness), `lexicon` (corpus-priced fingerprint recall), `zipper` (suffix-automaton Ziv–Merhav cross-parse)                                                                     |
| `search/batch/`      | the closed set ops (ADR-363): `patterns` (N intents compiled once, exact per-pattern attribution) and `loom` (a filter → group → sort → limit plan executed engine-side)                                                                  |

**The match ladder.** A fixed string (`-F`, caseful) never builds an automaton;
`scan/` answers presence with a memchr-style first+last-byte SIMD gate. A regex
compiles to a Thompson NFA from the RE2/rust-regex lineage. It is linear by
construction, so catastrophic backtracking is impossible. The NFA then
eagerly determinizes into a **byte-class DFA** with premultiplied transition
rows and start-state acceleration: one table lookup per byte, newlines
detected inline in a single fused pass. Three shapes step down to the **Pike
VM** instead: word-boundary asserts (`\b`/`\B`; a word-context-aware DFA is
the recorded next rung), multiline mode, and patterns whose powerset build
exceeds the `max_states = 4096` cap (an eager build must bound itself;
rust-regex pays that cost lazily per haystack instead, a real trade taken
knowingly). Lookaround and backreferences escalate to the vendored, hermetic
**PCRE2 10.47** JIT (`-P`, or `--engine auto` to try linear first) with match
and depth limits so `-P` cannot ReDoS the host. Unicode is default-on at rg
parity: case folding, `\b`, `\w`/`\d`/`\s`, `\p{…}` over codepoints, via
Thompson/Cox UTF-8 range decomposition into the same byte NFA the DFA
determinizes; `(?-u)` or `--no-unicode` reverts to bytes.

**Ranking** (`rank/`). `--rank` is the one native shape rg cannot express:
weighted RRF (Cormack et al. 2009) over intrinsic signals: lexical density, a
definition boost (a decl line outranks its 200 call sites), path centrality,
and an authored boost that sinks codegen (`*_pb2.py`, `*.sql.go`, …) below
hand-written code, class-split tie-aware so it stays neutral within a class.

**Similarity + batch** are relate's kernels: `lexicon` nominates candidates by
corpus-priced winnowed fingerprints, `zipper` decides with an exact
Ziv–Merhav cross-parse, `sketch` gives the symmetric LZJD metric behind
`similar`/`dups`; `patterns` compiles N intents through the same
`query.zig` core with exact per-pattern attribution behind a fused gate that
can only _skip_ work, never change an answer, and `loom` shapes the rows
engine-side. Design rules and measurements:
[ADR-363](../../../../docs/architecture/3-decisions/363-irregex-primitives.md).

## `index/`: the candidate, self, and kinship indexes

| Folder            | Concern                                                                                                                                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `index/trigrams/` | **T0** trigram candidate index: n-gram extraction, posting-list build/query, zero-copy `mmap` persistence, + the T3 mtime freshness overlay                                                                   |
| `index/postings/` | the compact posting-body codecs: LEB128 varint (`varint.zig`) + the persisted-blob layout (`persisted_blob.zig`) the trigram index rides                                                                      |
| `index/codex/`    | the compressed self-index: SA-IS → BWT → RRR wavelet tree; `count`/`find`/`restore` at entropy space, O(m) flat in corpus size (the Shannon rung under both engines)                                          |
| `index/atlas/`    | relate's persisted kinship index: one LZJD sketch per corpus file behind `relate index`/`status`, folded fresh at query time through the same T3 stat walk ([`index/atlas/README.md`](index/atlas/README.md)) |
| `index/crest/`    | the crest sidecar (`crest.bin`): one forced-class-run vector per doc (16 B), generation-atomic with the trigram pair; prunes the literal-free class-repetition patterns trigrams concede (theory: [`../research/crest/PROOF.md`](../research/crest/PROOF.md))    |
| `index/frame/`    | the shared wire discipline the persisted artifacts are framed with: little-endian ints behind a fail-closed cursor, length-prefixed u64 payloads, the NUL-joined path/roots catalogs, and the `onDisk` deletion gate every folded view checks                     |
| `index/frag/`     | relate's persisted **fragment** atlas (`concepts.frag`): one structural silhouette per authored function behind `relate concepts`, folded fresh at query time through the same T3 stat walk ([`index/frag/README.md`](index/frag/README.md))                       |

**Trigrams** (`trigrams/trigram.zig`). A file containing a literal must
contain every trigram of that literal, so the AND of per-trigram posting
lists is a _sound candidate set_: false positives expected and verified away,
false negatives impossible for literals ≥ 3 bytes. The persisted shape is
csearch's own (google/codesearch `index/write.go`): a CSR directory over
delta-varint posting bodies. On this repo, **195.0 MiB flat → 30.1 MiB
(6.5×)**. It loads through zero-copy `mmap`, so a cold query faults in only the
posting groups it touches. Queries seed from the **rarest** trigram and
intersect outward, which collapses dense tails.

**Freshness** (`trigrams/fresh.zig`). The overlay that lets a persisted index
stay sound under ~10 coworker agents committing mid-session, without git and
without rebuilding: the build stamps a wall-clock anchor _before_ reading the
corpus. A file is conservatively fresh, and forced through live verification,
when its mtime **or** ctime reaches the anchor or either is unreadable;
a missing anchor fails closed by seeding _every_ doc fresh. The guarantee is
explicitly scoped to the documented model (a local filesystem whose ctime
advances on ordinary writes); deliberately backdated clocks and network-FS
incoherence are outside it, and the module header says so rather than
rounding up.

**Codex** (`codex/`). The corpus stored at entropy-bound size, 1.95 bits/char
at 128MB, answering exact `count`/`find` in O(m) rank steps, flat in corpus
size, and restoring the original bytes from itself alone. The full
mathematics, layer table, differential-oracle test suite, and at-scale tables
live in [`index/codex/README.md`](index/codex/README.md); the two product
tiers riding it are `gist codex` (proof-of-absence: `count == 0` under a clean
freshness walk, zero corpus I/O) and `relate quote` (corpus-global
attribution priced in bits).

## `corpus/` + `math/`: the shared floor

`corpus/tree/` owns loading and the one walk skeleton (`haystack.zig`) every
consumer drives; on macOS the freshness stat-walk rides `getattrlistbulk` so
directory enumeration and metadata come from the same syscalls.
`corpus/scope/` is the `-g`/`-t` glob and type machinery shared by both
binaries. `math/bits.zig` is the two's-complement bit-set floor (set-bit walks,
word-packed sets, width-edge-safe masks) that SA-IS, RRR, and the DFA share
instead of five hand-rolled copies.

## `runtime/`: cold, resident, and embedded execution

`cold/` owns the rg-compatible argv → walk → read → emit execution path;
`session/` keeps the same corpus and kernels warm behind the daemon protocol;
`ffi/` exposes that resident session in-process. The CLI imports these runtime
surfaces; runtime never imports the CLI.

## `cli/`: the product faces

| Folder        | Concern                                                                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cli/gist/`   | the `gist` binary: entrypoint, `--schema`, `index`/`status`/`serve`/`codex` lifecycle, and the unified search engine (rg-DEFAULT drop-in) over `search/`, plus the daemon client/serve transport |
| `cli/relate/` | the `relate` binary: thin dispatch (`main.zig`) over the `similar`/`dups`/`patterns`/`search`/`quote` verbs, with its own `--schema` manifest                                                    |

Faces stay thin on purpose: argv classification and output shaping live here;
every match decision, prefilter, and index consultation happens in the tiers
above, where both binaries and the warm/FFI faces share it.

## The correctness spine

I do not let the implementation grade itself:

- The regex engine is checked by an **independent AST backtracking oracle**
  (`search/match/regex/oracle/`; shares only the parser, never the
  compiler/DFA/Pike) plus differential fuzzing between the DFA and Pike rungs,
  plus live differentials against installed `rg` at its Unicode defaults. The
  oracle has caught real shipped bugs; the file header documents one.
- The codex differentials every layer against a naive oracle: SA vs
  comparison sort, RRR rank vs prefix popcount, wavelet vs literal scan,
  count/find/restore vs `std.mem`, all under a seeded property-fuzz loop.
- The product surface is held to ripgrep by construction: the mined rgsuite
  replay, the byte-exact equality gate, the elision-parity gate, and the
  stream-contract gate all live in [`../bench/`](../bench/README.md) and run
  against the real installed `rg`.

`root.zig` is the package/C-ABI root: it re-exports each tier, pins
`irregex_abi_version`, exposes `irregex_trigram_count` (the cross-language
parity oracle), and aggregates every `*_test.zig` so `zig build test`
type-checks the whole tree.

See [`../README.md`](../README.md) for what the products are, why they exist,
and the prior-art map; [`cli/gist/README.md`](cli/gist/README.md) for the gist
face; [`search/match/regex/README.md`](search/match/regex/README.md) for the
regex engine internals.
