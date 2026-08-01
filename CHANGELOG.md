# Changelog

All notable changes to the `irregex` kernel (formerly `gist`; the gist CLI is its flagship face) are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track `build.zig.zon`.

<!-- towncrier release notes start -->

## [0.2.0] - 2026-07-24

### Added

- A SIMD class-run kernel for dense character classes
  (`src/kernel/scan/classrun.zig`) — the family the byte-class DFA was
  slowest on. A pattern that _is_ a class repetition (`\w+`, `[a-z]{3,}`,
  `[0-9a-f]{8}` — decided algebraically by `analysis.classRunShape`) is no
  longer an automaton problem: boolean match reduces to "≥ min consecutive
  members of one byte set", classified 64 bytes at a time (two-compare range
  lanes for ≤ 4 contiguous ranges, Hyperscan-truffle nibble shuffles otherwise;
  on aarch64 the four chunk verdicts fold into the block mask via the simdjson
  `addp` chain instead of per-chunk movemask ladders) with shift-AND run
  detection and a cross-block carry — load _bandwidth_ instead of the DFA's
  loop-carried load latency. Unicode codepoint classes go further than a
  projection: the analysis carries the class's full codepoint ranges, so the
  kernel resolves ≥ 0x80 spans itself (scalar UTF-8 with an inlined 2-byte
  decode + a direct ≤ 0x7FF membership bitmap; ASCII blocks stay pure SIMD) —
  Unicode `\w{3,8}` compiles skip powerset determinization exactly like `(?-u)`
  ones (was ~168 ms of dead-weight subset construction per compile), and no
  verdict ever defers. The kernel also ships a STREAMING whole-buffer
  `countLines` (rg `-c` line model): membership and newline masks from one
  pass, lines settled with segment bit-tests — no `memchr` re-read, no per-line
  restart — and the emit layers answer `-c`/`-l` for these patterns from the
  whole buffer with no line split at all. The kernel also EXTRACTS spans:
  `analysis.classSpanShape` proves the strictly stronger window rule — for a
  concatenation of same-class quantifiers (`\w+`, `[a-z]{3,8}`, `\w\w+?`;
  alternations/anchors decline), the leftmost-first match at `p` is exactly
  "run(p) ≥ min, cut at lazy ? min : min(run, max)" — so `nextSpan` chunks
  member runs straight off the membership masks (codepoint-counted,
  byte-addressed in Unicode mode) and
  `-o`/`--count-matches`/`--column`/`--vimgrep`/`--json` never run the Pike
  VM's per-byte thread closures for these patterns; a fused whole-buffer doc
  pre-gate settles span-mode misses without walking a single line. `force_dfa`
  keeps the determinizer's own proof harness honest. Held by scalar-oracle
  differential fuzzes (boolean, per-line count, codepoint-mode with junk-byte
  corpora, and byte/codepoint span-window fuzzes — all on both backends), a
  kernel-vs-Pike `matchSpan` iteration fuzz, and the 446-case rgsuite at 100%
  parity on both engines. Measured vs ripgrep 15.1.0: dense `-c '(?-u)\w{3,8}'`
  2.4–2.8× faster (was 1.5× _slower_), Unicode-mode `-c '\w{3,8}'` 2.5× (was
  **8.5× slower**), miss-heavy Unicode `-c` 1.7× (was 19× slower), miss-heavy
  `-c`/`-l` 1.7–2.0×, a 50%-non-ASCII adversarial corpus 1.12×; spans: dense
  `-o '\w+'` 1.8–1.9× (was 3.1× slower), Unicode `-o '\w{3,8}'` 1.9–2.1× (was
  **~100× slower**), `--count-matches` 1.9–2.2×, miss-heavy span modes at
  parity.
- A fused parallel walk+read corpus loader (`corpus/tree/loadpar.zig`), now the
  default path for every build verb that funnels through `corpus.load` (`gist
  index`, `relate index`, `codex build`). The serial loader walked one
  directory at a time with a single cursor for the whole tree — ~⅓ of the
  index-build wall clock, but every core but one idle. The new loader fuses
  walking and reading into one work-stealing pipeline: each worker pops a
  directory, opens it ONCE, and reads that directory's member files through the
  still-open directory fd (`openat(dirfd, name)` — one-component namei) before
  donating its surplus subdirectories to idle peers. On the whole-repo corpus
  (20,497 files · 196 MiB) that cuts the index build from ~1.78 s to ~1.39 s
  (~22%), with the load phase itself dropping ~575 ms → ~170 ms; 8 workers is
  the sweet spot (the walk is syscall/namei-bound, so 12/16 add contention
  without shortening the tail). Membership is byte-identical to the serial
  `haystack.Walker` by construction — the ignore verdict comes from the SAME
  `ignore.zig` rule core (a frozen base `Ignore` plus the immutable
  per-directory `IgNode` chain each worker builds as it descends — the
  parallel-walk plumbing now lives in `ignore.zig`, one source shared with the
  search engine so the two walkers cannot drift), directory pruning applies
  `haystack.isSkipDir` then the ignore verdict in the same order, and file
  admission reuses the shared `corpus.per_file_cap`/`corpus.isBinary`
  predicates. Doc ids are assigned by sorting on path, so the build is
  deterministic run-to-run (reproducible index bytes) despite the
  nondeterministic walk order. A hermetic fixture test pins the parallel
  membership to the serial oracle across gitignore
  (anchored/slash-less/negated), nested per-dir ignores, hidden files, the
  build-dir skip list, binary, empty, and oversize files.
  `GIST_NO_PARALLEL_LOAD` forces the serial reference (parity gate + escape
  hatch, mirroring the engine's `GIST_NO_PARALLEL`); `GIST_WORKERS` overrides
  the worker count.
- A new `relate concepts` verb drops kinship from the file to the FUNCTION:
  where `clusters`/`echoes` answer "which files are forks?",
  `concepts` answers the finer question an agent actually asks — "which
  functions across the tree are the same idea (the repeated engine, the
  duplicated JSON dump, the copy-pasted validator), regardless of name or
  file?" The comparison unit is the function fragment (`regions.extractAll`
  over authored brace-family + Python source): a helper cloned into six files
  surfaces as one six-member family, not six unrelated files. With no `TEXT` it
  returns package-wide families ranked by consolidation opportunity —
  conservative `repeated_lines` (shortest member span × redundant copies) then
  channel confidence, never a fused score; with `TEXT` it retrieves the nearest
  fragments to that concept. `--lens structure|bytes|echo` picks the channel
  (structure is default and warm-only; byte sketches are computed only for the
  fragments a query nominates, never a repo-wide byte pass). It reuses the
  shared silhouette/sketch channels, seed nomination, and the union-find
  `components` pass, over a new persisted **fragment atlas** (`concepts.frag`)
  folded for freshness exactly like the kinship atlas, so function-level
  discovery answers warm with `--no-index`-identical bytes. Documented in
  `contract/search_api.toml` `[irregex.verbs]`/`[irregex.lifecycle]` and
  advertised by `--schema`; `relate index` builds it and `relate status`
  reports its readiness.
- A new `src/engine/query.zig` deep module owns the transport-neutral compiled
  query: a `(pattern, fixed, ignore_case, mode)` spec lowers once
  into an immutable matcher (literal SIMD fast path, else the linear-time regex
  engine, escaping a `-F -i` literal), exposing the sound trigram `prefilter`
  for index candidate pruning and the per-doc `docMatches`/`countLines`
  decision. It is fail-closed (a pattern outside the linear-time syntax is
  `error.Unsupported`, never a `die()`) and thread-safe (immutable query;
  per-worker `Scratch` is caller-owned), so the cold CLI and the warm resident
  session now execute through one shared compile → prefilter → match core.
- A new `src/search/` primitives tier makes the engine set-shaped —
  match ∪ relate ∪ weave: `PatternSet` compiles N patterns once through the
  shared `engine/query.zig` core with exact per-pattern attribution
  (`docMask`/`lineHits`) behind a skip-only fused alternation gate; `Sketch`
  measures compression kinship via LZJD (LZ78 phrase dictionary, bottom-k=128
  MinHash, `min_phrase=3` noise floor) with no parsing or language list; and
  `loom.Plan` executes a closed filter → group → sort → limit op set
  engine-side over attributed rows. Three CLI faces surface them through the
  dedicated `relate` binary — `relate similar <path>` (nearest files by
  kinship), `relate dups` (near-duplicate pairs, closest first), `relate
  patterns -e P…` (one pass, N patterns, attributed, loom-shaped via
  `--by`/`--under`/`--top`) — each documented in `contract/search_api.toml`
  `[irregex]`, advertised by `--schema`, and mirrored by typed Python bindings
  (`gist.similar`/`dups`/`patterns`/`pattern_counts`).
- Add a habit-safe search verb: gist search PATTERN PATHS now aliases the same
  engine as gist rg and the bare gist PATTERN shorthand. Previously it
  misparsed the pattern as a path and failed with os error 2; a bare gist
  search with no pattern still searches for the literal word search, so nothing
  regresses.
- Added Layer C (roofline) of the performance certificate under
  `bench/roofline/`: a zero-dependency STREAM-style read-bandwidth
  microbenchmark that measures this machine's single-core L1/L2/DRAM roof and
  gist's SIMD scan throughput. The report records distance from the roof
  without treating a sub-ceiling result as proof of saturation.
- Added a zero-copy emit transport to the warm `gist serve` daemon: a large
  `lines` answer now reaches the client as an anonymous shared-memory fd passed
  over the UDS `SCM_RIGHTS` control channel instead of being copied through the
  socket. After the parallel render, the emit was output-transfer-bound — the
  rendered bytes were copied user→kernel→user twice as `chunk` frames — so the
  daemon gathers the shards straight into one shm buffer (Linux `memfd_create`
  +
  `F_SEAL_*` · macOS `shm_open`→`ftruncate`→`mmap`→immediate `shm_unlink`,
  mapping
  bounded to the exact length) and hands its fd to the client in a single
  `chunk_fd` frame carrying `{length, matched}`; the client mmaps it read-only
  and
  writes it out in one shot, so the answer never traverses the socket.

  The path is a negotiated SESSION capability, not a query flag (the flags byte
  is
  full): the client appends a `cap_fd_transport` byte after the version in its
  HELLO, and the daemon uses the fd path only when the client advertised it AND
  the
  answer clears `fd_transport_floor` (1 MiB). Fail-open, never a new failure
  mode —
  any shm/`sendmsg` error, a below-floor or unadvertised answer, an old peer
  (no
  caps byte), or a non-shm target transparently falls to the byte-identical
  `chunk`
  frames; a peer that never advertises keeps working unchanged (the Python and
  Rust
  UDS clients answer files/count and simply don't advertise).
  `GIST_NO_FD_TRANSPORT`
  opts the CLI client out for A/B.

  Measured warm emit-heavy A/B on macOS (fd vs chunk, same daemon, `the
  --uncap`):
  32 MiB answer (services corpus) 112 → not-copied ≈1.10× to `/dev/null`, and
  1.6× (min-time 1.19×) when the output is actually consumed (`| wc -c`); 68
  MiB
  answer (repo-wide) 528 → 353 ms ≈1.50× piped. The win scales with the emit
  and
  with a real downstream reader, which is the agent-capture workload. The
  committed
  session gate is unregressed (armed geomean 474× vs the 5× floor).

  Byte-identity is the whole ballgame and is proven two ways. Within one render
  the
  fd bytes are byte-for-byte identical to that render's `chunk` framing —
  asserted
  deterministically over a single-doc corpus in `serve_test` (plus an explicit
  forced-fallback test: an injected shm-create failure drops the fd-eligible
  answer
  onto `chunk` frames and the bytes match). Across the live tree the CLI
  answers
  agree on content: warm(fd) == warm(chunk) == cold(`--no-index`) == `rg`
  (sort-normalized, since the parallel render's doc order is unstable across
  separate invocations independent of transport; the only gist↔rg gap is gist's
  pre-existing dotfile skip). New: `shm.zig` portable buffer, `wire.zig`
  `sendWithFd`/`recvFrameWithFd`, the `chunk_fd` opcode + capability
  negotiation,
  `render.renderLinesShm`, and `resident.queryLinesShm`.
  (see also: gist)
- (in `gist`) Added the gist operational-envelope matrix under `bench/evaluate/`:…
- Composed family search now compares exact-hit functions or match windows
  instead of only whole files, ranks families by conservative repeated-line
  opportunity, offers a scope-relative `--brief` worklist and `--only` answer
  filtering, and retains nearest-neighbor receipts for genuinely distinct
  implementations.
- Multi-corpus differential battery (`bench/corpora/`): a pinned fetcher
  installs
  five foreign trees (linux v6.10 · cpython v3.13.0 · typescript v5.8.3 ·
  OpenSubtitles en+ru 256 MiB prefixes · a deterministic adversarial `torture`
  generator) under `.local/gist-corpora/`, and `sweep.py` replays an rg-oracle
  slate on each — 472 cases across both engines, all green. The first runs
  flushed out and fixed at the root: JSON base64 `bytes` for invalid UTF-8 ·
  full `--crlf` terminator parity · rg's implicit-path "No files were searched"
  exit-2 heuristic · `-L` dangling-symlink reporting + ancestor-loop detection
  with rg's message · Unicode-aware `-w` word boundaries · `-M` terminator-
  inclusive width · rg's full binary model (the line-buffer
  **committed-prefix**
  geometry — 3-byte BOM-sniff read, per-fill commit at the last newline, the
  NUL-bearing fill discarded — plus the `-U` slice-vs-line routing keyed on
  whether the pattern can actually match `\n`, explicit-file convert semantics,
  and the byte-count clamps in `--json`/`--stats`) · an uninitialized
  generation
  array in the capture VM that made `-r` nondeterministic under ReleaseFast.
- New `ward` primitive (`kernel/math/lease.zig`): a shared reader/writer
  discipline over `std.Io.RwLock` with `Read`/`Write` lease guards and the
  double-checked `readReconciled` fast-read / upgrade-refresh / downgrade
  dance. The warm resident session now rides it instead of hand-rolling
  `RwLock` lock/unlock pairs at each answer face.
- New one-shot install surface: 'make install-gist' builds the ReleaseFast CLI,
  symlinks it onto PATH (~/.local/bin/gist), and builds/refreshes the persisted
  trigram index — the setup step for agents dogfooding gist as the repo's
  default code search.
- New shared bit-identities primitive src/math/bits.zig: a two's-complement
  floor (ones set-bit iterator via ctz + x&(x-1); edge-safe prefixMask +
  in-word rank; Stream, a shift-window cursor over dense packed bit fields; and
  Field(Word) word-packed bit sets with word-masked setRange over caller-owned
  slices) now backing powerset determinization, PatternSet attribution masks,
  ByteSet (setRange went O(words) instead of O(hi−lo)), SA-IS suffix-type maps,
  RRR bitvectors, and the SIMD survivor walks — one audited implementation, 1
  bit per flag instead of a byte. Profiled on the codex FM-index (macOS sample
  over codex-scale, 16MB): the seek class walk was ~41% of count() samples; the
  Stream cursor with paired 12-bit takes plus an O(1) offset-0 scanBlock fast
  path measured ~5% median / ~14% best count-latency improvement, with the
  evidence pinned in PROFILING-DERIVED comments at each site.
- Structured stderr guidance channel for agents
  (src/runtime/cold/emit/hints.zig): a no-match run now ends with a one-line
  `gist: no matches for '…' · N files scanned · scope: …` summary plus up to
  three ranked suggestion lines in rustc's help/note split — `gist: try <flag
  or move> — <why>` for a concrete retry (`-i` when the pattern carries
  uppercase, `-U` when it spans a line break, `-F` when it has regex
  metacharacters, `-uu`/scope-widening when the walk was filtered) and `gist:
  note: <fact>` for what can't be flagged away (an inverted `-v` miss,
  literal-space semantics) — derived purely from the query's own shape and
  wired into every engine exit seam (serial, parallel, ranked live+indexed,
  stdin, and the warm daemon client via the resident classifier). The
  bad-pattern and truncation diagnostics share the same `gist: error:` / `gist:
  try` / `gist: note:` grammar, `--rank`'s timing line gained the `gist:`
  prefix, `usage()` was reorganized (search views / lifecycle / aliases /
  introspection / channels+env) and moved to stdout, and `--schema` documents
  the new `hints` channel. `GIST_HINTS=0` mutes the channel wholesale;
  `--quiet`/`--json`/`--files` never hint; a query with a hit still emits
  nothing on stderr — asserted by the extended bench/gates/streams.sh contract
  (structured-miss + kill-switch cases).
  (see also: gist)
- The `-P` PCRE2 backend gains a _shadow gate_ (`pcre2/shadow.zig`): every
  backreference/lookaround pattern is rewritten into a provably
  language-containing linear over-approximation — assertions erase, backrefs
  splice a copy of their group's source, atomic/possessive relax to greedy —
  and the compiled shadow's O(1)/byte byte-class DFA rejects lines/buffers
  PCRE2 would have backtracked through, so the backtracking engine only ever
  confirms candidates. The same containment makes the shadow's NFA-derived
  required-literal/cover sound for the PCRE pattern (`(foo)bar\1` now
  prefilters on `foobarfoo`, not `bar`), handing `-P` the trigram index it
  never had. Any construct outside the provable subset (recursion, subroutines,
  conditionals, inline flags) declines silently and PCRE2 runs raw, exactly as
  before. The matrix's one declared structural loss flips: `pcre-backref-files`
  (`(\w{4,})\s+\1`, dominated by ~11 s of catastrophic backtracking both
  engines paid on one 3.6 MB base64 fixture) goes 0.94x parity → **15.7x win**
  (735 ms vs rg's 11.6 s), with byte-identical output across all 19 parity
  shapes; a gated≡ungated differential test holds every primitive on
  adversarial corpora, including caseless folding and `-U` multiline.
- The index loader now fails closed on a corrupt blob, and the benchmark-timer
  fail-closed contract is committed as a runnable gate.
  `Index.fromBytes`/`fromMappedBytes` previously trusted most of a `writeInto`
  body — unchecked `dir_off`, no varint length/canonical bound, doc ids never
  bounded against `doc_count`, and `fromMappedBytes` `@alignCast`ing an
  arbitrary slice — so a corrupt or hostile index (the format is a
  native-endian local rebuildable cache, not a portable/untrusted artifact, but
  still) could panic, be silently accepted, or read out of bounds. Both loaders
  now run one `validateStructure` pass and reject anything that violates it
  with `LoadError.BadFormat`: `posting_count` fits u32; trigrams distinct +
  strictly ascending; every group non-empty, in-bounds, and EXACTLY consumed;
  every posting-body varint canonical, `<= 5` bytes, and `<= maxInt(u32)` via
  the new `varint.decodeBoundedCanonical`; doc ids strictly ascending, `<
  doc_count`, with no wrap; and `sum(dir_count) == posting_count`.
  `fromMappedBytes` also verifies 4-byte alignment before the `@alignCast`
  instead of trapping. A ~30-case adversarial suite
  (`src/index/trigram_load_test.zig`) plus a bit-flip mutation fuzz-lite (both
  loaders must agree, accepted blobs must be safe) exercises all of it — and
  surfaced a pre-existing 1-byte leak where an empty-body index
  (canonical-empty / all-docs-under-three-bytes) allocated `@max(len, 1)` but
  freed a zero-length slice, now fixed in both `fromBytes` and `compact`.
  Separately, `bench/gates/fail_closed.sh` pins the benchmark-timer contract as
  a committed gate: its `run_drained` helper drains output (full work + swallow
  the exit-1 no-match) while surfacing a hard error (exit >= 2), proven against
  pure-shell cases and the wired gist CLI (an unbalanced regex and an unknown
  flag must fail, not be timed as a fast search).
  (see also: gist)
- The resident (warm) session now serves `-P`/`--pcre2`/`--engine=pcre2`
  queries
  warm instead of punting them to a cold process. `CompiledQuery.body` migrated
  from a linear-only regex arm to an engine-neutral `Matcher` union, so the
  shared
  query core compiles, prefilters, and matches through the same PCRE2 JIT
  backend
  the cold path uses — including lookahead, lookbehind, backreferences, and
  negative lookahead. A single `pcre` trailer byte rides the additive
  `query_ext`
  opcode (protocol v4→v5); `request.classify` sets `Request.pcre` and still
  declines `-P`+`--rank` (ranked view stays linear-only). Caseless PCRE
  prefilters
  decline soundly rather than risk a false narrow. Proven byte-exact against
  the
  cold `--no-index` walk across lines/`-n`/`-c`/`-l`/`-c -w` on the live corpus
  —
  the warm hit is identical, just without the per-query trigram-index + corpus
  load.
- The resident session now arms a native macOS **FSEvents** watcher — one
  recursive stream over the roots driven on a private CFRunLoop thread — so
  warm
  queries take the microsecond clean path during quiescent windows instead of
  always paying the corpus-wide freshness reconcile that macOS previously fell
  back to (`src/runtime/session/watch.zig`; frameworks wired in `build.zig`).
  It mirrors
  the Linux inotify backend's fail-closed contract: it only ever calls
  `markDirty`/`armWatcher`, arms the session solely on a fully-started stream,
  and
  degrades to the reconcile-always baseline if the stream can't start — so
  read-your-writes and ripgrep parity are unchanged and soundness never rests
  on
  the watcher.
- The resident-session machinery now carries its unit suite:
  the eligibility classifier's fail-closed boundary, the UDS wire codec's
  lossless round-trip and fail-closed framing, and — over a real directory tree
  — resident==rg parity, read-your-writes, and the watcher-barrier seqlock.
- The rg CLI now prints a stderr note when a bundled -r value looks like a
  grep-style flag bundle (e.g. -rn parsing as --replace=n), pointing at the
  ripgrep semantics instead of leaving silently rewritten output. Parsing is
  unchanged — stdout parity with ripgrep is preserved.
- Warm `lines` mode: the bare default `gist <pattern>` search (and `-n`) now
  routes through the resident daemon, pre-rendered daemon-side through the cold
  Emitter itself and chunk-streamed over the v1 wire — cold's own per-file
  bytes and exit code, in the deterministic `pathLess` file order warm `-l`
  already speaks. The resident corpus became faithful (`session/mirror.zig`:
  full reads with no size cap, BOM/UTF-16 decode, whole-body first-NUL
  offsets), closing latent warm-vs-cold gaps for binary, UTF-16, and >4 MiB
  files across all modes; TTY-stdout and readable-stdin queries decline to
  cold, and an errored walk declines instead of serving a gapped set.
- Warm resident session eligibility for `-v`/`--invert-match`, byte-identical
  to
  cold and now FASTER on the faces the math proves winnable — overturning the
  earlier "keep invert cold" result. The daemon answers `-v` by the
  set-complement
  `non_matching(f) = lines(f) − matching(f)`: the trigram prefilter stays SOUND
  for
  the positive MATCH set (a ruled-out file matches nothing by construction, a
  candidate false positive is corrected by the scan), so `matching(f)` is exact
  and
  the complement is exact. Per-file line counts and the corpus total are
  counted
  once at Mirror load and maintained on reconcile, so `-c -v` = `TOTAL − Σ
  match`
  and `-l -v` (file qualifies iff `match(f) < lines(f)`) subtract cached
  invariants
  with ZERO scan on the ruled-out majority — strictly less work than cold's
  full-corpus `-v` scan. On a 1833-file / 238k-line corpus warm `-c -v` runs
  0.05–5.3 ms vs cold 39–48 ms (9–760×, versus the prior warm 106–286 ms), and
  `-l -v` wins 2.7–10.8×. The bare-`-v` emit selects nearly every line of every
  doc, so it shards its render over cores through `src/math/parallel.zig`
  (`greedyBounds` + `fanOut`, concatenated in original doc order) and stays
  byte-identical to the serial core; end-to-end it holds parity with cold's
  16-core
  scan (output-transfer-bound, winning for common patterns). The v2 query flags
  byte is now fully assigned — `invert` (bit 4) joins `known_flags` alongside
  fixed/ignore_case/line_num/word/smart_case/quiet/max_count — and, with every
  bit
  carrying a semantic, fail-closed now rests on the version handshake plus the
  length/opcode gates. Non-invert hot paths stay byte-for-byte unchanged; the
  session gate is unregressed (geomean 474×). Eligible across the UDS daemon
  (`-l`/`-c`/emit), the in-process FFI, and the Python + Rust bindings
  (`_FLAG_INVERT`, `invert` out of the warm-ineligible set), all proven against
  cold on controlled fixtures.
- Warm resident session protocol v2 with smart-case eligibility:
  `-S`/`--smart-case`
  (and its precedence siblings `-s`/`--case-sensitive`) now route warm,
  byte-identical
  to cold. The v2 query flags byte carries the frozen flag-family table
  (`smart_case`
  bit live; `word`/`invert`/`quiet`/`max_count` reserved) and `decodeQuery`
  fails
  closed on any bit outside `known_flags` (BadFrame → decline → cold), so an
  unimplemented flag is never silently dropped server-side. Smart-case resolves
  at
  exactly one Zig site — `request.Request.effectiveIgnoreCase` (cold's
  `hasUpper`
  fold) — feeding the engine fold, the trigram-prefilter caseless decline, and
  the
  no-match hints; Python/Rust clients ship the raw bit and never re-implement
  the
  fold. The Python eligibility predicate forked: `warm_eligible` (UDS) admits
  smart-case while the new stricter `ffi_eligible` keeps the in-process
  transport
  declining flags its C flag word cannot express.
- `-P`/`--pcre2` selects a vendored PCRE2 10.47 JIT backend
  (`src/regex/pcre2.zig`) for the constructs the linear engine can't express —
  lookaround, backreferences, named captures — with per-thread match scratch
  and
  fail-closed resource ceilings (10M match / 10k depth) so pathological input
  trips a clean no-match instead of hanging. `--engine auto` (and rg's
  deprecated
  `--auto-hybrid-regex` alias) is the hybrid: compile the linear engine first
  for
  its speed + trigram AST, escalate to PCRE2 only for a pattern the linear
  engine
  declines. Crucially, PCRE2 patterns are **trigram-prefiltered** too — sound
  required-literal extraction (`src/regex/pcre2/literal.zig`) skips files that
  provably can't match before PCRE2 runs, making gist the only _indexed_ PCRE
  search in the field: it wins the `bench/races/pcre_headtohead.sh` lookaround
  /
  backreference slate against every PCRE-capable competitor (rg -P, ugrep, ag,
  grep -P, git grep -P), with rg -P as the correctness oracle. `--rank` and
  template replace remain linear-engine-only. The flag catalog, `--schema`,
  `README.md`, and `.cursor/rules/irregex.mdc` now reflect that no ripgrep long
  flag
  is unsupported-fail-loud any more; the fail-loud contract now guards unknown
  flags and patterns outside the chosen engine, always naming the `-P` /
  `--engine
  auto` fallback.
  (see also: gist)
- `GIST_DEBUG_WARM=1` now prints the classifier's routing verdict — `gist:
  [eligible]` / `gist: [ineligible]` — _before_ the daemon dial, so a cold
  outcome from "ineligible argv" is distinguishable from "eligible but no
  daemon listening". This makes `src/runtime/session/request.zig::classify`
  observable independently of any running daemon, giving the cross-binding
  parity test a daemon-free oracle for the exact argv the resident path will
  accept.
- (in `gist`) `bench/gates/freshness_fs.sh` — the live-filesystem half of the "no false…
- `flagbench` gains a `--json` record-emit floor — the hermetic, blocking guard
  that locks in the per-record hot-path shaves (the `pathData` object cache,
  `writeUint`, and the `asciiOnly` UTF-8 pre-check) so they can't silently rot.
  It times the public per-file encoder core `json.emitOne` over the real corpus
  (the exact serial stream every serial/shard/walk path shares, isolated from
  the
  walk/read/fan-out), and self-checks the emitted `match`-record count against
  the
  same independent per-line-hit oracle the `-l`/`-c` floors trust — a
  dropped/duplicated record fails loud, byte-shape parity staying rgsuite's
  job.
  The floor (≥ 500 MiB/s of bytes searched, ~half the observed slowest needle
  so
  the shared coworking box's load never false-trips it) is advisory by default
  and
  blocking under `--gate`, joining the `-i/-n/-v/-l/-c/-o/-w/-r` slate the
  `ci_order.sh` performance phase already runs. Wiring it in also compiled the
  formerly-dormant `-U --json` ripgrep-parity table test into `zig build test`
  (the encoder is now reachable from the module root, so `refAllDecls` reaches
  its
  tests), and made `output.MlHarness`'s constructor/teardown `pub` for the
  cross-module reuse that test always intended.
- `gist index` is now incremental and answers in ~2 ms when nothing changed
  (~450× the ~950 ms full rebuild; ≈1,400× the pre-sweep ~3 s). The default
  path is an AMEND: with a generation-published base for the same roots, it
  derives the changed set since the last freshness anchor and publishes a
  CODICIL (`corpus/index/trigrams/codicil.zig`) — a small delta segment
  carrying re-indexed postings, crest rows, appended new-doc paths, and
  tombstones, hardlinked forward over the base blobs and generation-atomic like
  every publish. Queries union base ∪ codicil ∪ tombstones with byte-identical
  answers (proven against a full rebuild on live-corpus probes). The changed
  set comes from three tiers, each the next one's fallback: (1) the resident
  daemon's new ANNALS — a never-drained `path → last-delivery-instant` ledger
  fed by the live FSEvents stream, queried over the UDS protocol (v6,
  `changed`/`annals` opcodes) behind an `FSEventStreamFlushSync` causal
  barrier, ~0.6 ms; (2) a one-shot FSEvents historical-journal replay from the
  `journal.tok` since-token minted at full-build time (~25 ms); (3) the proven
  stat walk. The annals are fail-closed end to end:
  unarmed/multi-root/pre-coverage/poisoned ledgers decline (sticky doubt on any
  inexact event; eviction advances the coverage floor so an amputated answer is
  impossible), a declined consult auto-spawns the daemon for the next round and
  falls back, and every daemon answer is re-confirmed by live stat and the
  walk's own admission filter before use. A small change amends in ~8–25 ms
  (pair load, delta index, and publish, proportional to accumulated drift; past
  `GIST_AMEND_MAX` it compacts via full rebuild). `GIST_NO_AMEND=1` forces the
  full build and `GIST_NO_ANNALS=1` forces the non-daemon tiers (parity gates
  and escape hatches); full builds also got a bitmap trigram dedup and
  hardlinked stable aliases (~950 ms whole-repo, down ~3×).
- `gist index` now emits a **content shard** (`corpus/index/content/shard.zig`,
  `content.shard`): every corpus body the trigram index already ingested is
  concatenated into one mmap'd blob with a doc→offset catalog, so a query
  serves each unchanged file's bytes from a single memory map instead of
  `openat`+`read`+`close`-ing it. This closes the last full-scan floor — the
  per-file syscall wall on queries with no usable trigram filter (a 2-byte
  literal like `})`, a dense class count, a bare `-c`) where ~20k file opens
  had left gist behind zoekt's static server index. The blob is a read
  accelerator only: a slice is handed back exactly when the same T3 clock rule
  the elide overlay uses proves the file unchanged (`bulkstat.needsLiveRead` —
  `mtime < anchor AND ctime < anchor`), and a
  changed/new/binary/oversize/out-of-scope file misses the lookup and is read
  live, so the walk's answer is identical whether or not a shard loads.
  Self-anchored and fail-open — a missing/corrupt/foreign/future-dated blob
  loads as null; `GIST_NO_SHARD=1` and `--no-index` disable it. Measured
  across-the-board: 2-byte punct full scan (`-cF '})'`) 174.3 ms → 49.3 ms
  (**3.53×**, beating zoekt's ~68 ms) and `-l` **5.33×**; the rare literal (`-c
  pgxpool`) 32.0 ms → 30.4 ms (**1.05×**, beating csearch's 34.4 ms) — the two
  classes gist had been losing. Byte-exact parity vs the `--no-index` live walk
  is held continuously by new `shard-*` and post-index `shard-freshness` cases
  in `bench/gates/index_elision_parity.sh`.
  (see also: gist)
- `irregex blast SYMBOL` — a live symbol blast radius for editing agents:
  the seed's definition + kind, direct dependents (functions
  referencing it, def/use classified) and dependencies (identifiers its body
  resolves), tangential twins (compression kin of its file) and ripple
  (same-language second-hop callers), and comments that mention it — computed
  from CURRENT bytes with no precomputed graph, as compact `--json` or a human
  digest with a `--budget` token cap. Built on a new shared
  `kernel/compose/lexspan.zig` span lexer that also powers `gist --in-comments`
  / `--in-code`.
- `relate` grows a structure channel beside LZJD: every corpus file gets a
  silhouette — identifiers/numbers/strings normalized to `I`/`N`/`S`, comments
  and whitespace dropped, 5-token grams winnowed (w=4) into a k=256 KMV sketch
  —
  so a renamed Type-2 twin lands at exactly distance 0. Surfaced two ways:
  `relate similar --lens bytes|structure|fused` (bytes stays the default), and
  the new `relate echoes` verb, which ranks pairs by `bytes − structure`
  distance
  (`--min-echo`, default 0.15) to report DRY/abstraction candidates that `dups`
  can't see — same skeleton, different vocabulary. The kinship atlas is now v3
  (silhouette rows persisted beside sketch rows, both folded on freshness);
  older
  atlases read as corrupt and degrade to a live build with a `relate index`
  hint.
- `relate` grows from a five-verb sketch face into a standalone engine with two
  new set-shaped verbs: `relate pack <query|file>` selects an anti-redundant
  context set by greedy submodular max-coverage over corpus-priced fingerprints
  — each pick is scored by _marginal_ bits saved given everything already
  chosen, so near-duplicates of a prior pick contribute nothing and never make
  the cut; `relate clusters` union-finds verified near-duplicate pairs into
  fork families (size-sorted, `--min-size`/`--max-dist`/`--json`), turning
  pairwise `dups` output into the restructure-ready unit of work. Both are
  documented in `contract/search_api.toml` `[irregex]` and advertised by
  `relate --schema`.
- `src/index/trigram_fuzz.zig` — the long / nightly companion to the CI-safe
  fuzz-lite. It seeds a corpus (empty index · one trigram/one doc · one
  trigram/many docs · many trigrams/sparse · zero-trigram with `doc_count > 0`
  · a max-width 5-byte doc id · realistic built indexes · the deterministic
  malformed blobs) and mutates it (truncation, bit flips, byte overwrites),
  asserting on every input: `fromBytes` never panics or reads out of bounds (it
  either rejects with `BadFormat` or returns an index `queryLiteral` can walk
  under ReleaseSafe/Debug memory safety); an accepted index also passes an
  **independent** canonical re-walk (`safeCanonical` — deliberately not the
  loader's own `validateStructure`, so a bug that accepts a noncanonical blob
  is caught); and `fromBytes` / `fromMappedBytes` always agree. `fuzz_iters` is
  the CI-safe default budget (10k mutations per `zig build test`); raise it and
  run `-Doptimize=ReleaseSafe` for a nightly/pre-release soak.

### Changed

- **The two search engines merged into one.** `gist`'s certified ripgrep-parity
  walk-and-emit pipeline (`src/runtime/cold/`) is now the _sole_ engine, and it
  gained a second, much faster candidate source: the persisted trigram index.
  When
  a fresh index covers the searched subtree it is used automatically as an
  _acceleration structure_ — reads of files the index can prove cannot match
  (trigram non-candidates unchanged since the index was built) are elided,
  while
  the live walk stays authoritative for path discovery and `.gitignore`
  semantics,
  so output is byte-identical to a pure walk. `--no-index` forces the live
  walk;
  `--index` forces the accelerated path (default: auto-detect). A new
  `bench/gates/index_elision_parity.sh` differential gate proves the core
  safety
  claim continuously — every query's index-accelerated output equals its
  `--no-index` full read across literal / regex / caseless / word / count /
  files-with(out) / context / invert / only-matching / type- / path-scoped
  cases,
  plus the freshness overlay (16/16 byte-identical).

  `--rank[=N]` folds in gist's one output shape ripgrep can't express — the
  definition-first ranked view (RRF fusion over per-file signals, a symbol's
  definition outranking its call sites, codegen demoted) — now a flag on the
  unified engine (`src/runtime/cold/engine/ranked.zig`) instead of a separate
  verb.

  **The `search` verb is gone.** Bare `gist <pattern> [PATH...]` is canonical
  (`index` and `status` remain the only lifecycle verbs); `gist rg` is the same
  engine addressed explicitly. rgsuite parity held at the 278/282 baseline
  throughout and the full `zig build test` slate stays green.
  (see also: gist)
- **Trigram index switches from a flat `(trigram,doc)` pair table to a CSR
  directory over delta-varint posting bodies**
  (`src/index/trigrams/trigram.zig`, new
  `src/index/postings/varint.zig`) — the fix for the README's own documented
  weak point:
  "gist trails csearch/zoekt on the cold literal one-shot because it maps a
  177 MiB index where csearch mmaps 28 MiB." A flat table spent 8 bytes/posting
  (4 tag + 4 doc) and most of the tag was redundant — a distinct trigram
  carries
  dozens of postings on average. The index now stores three parallel arrays
  over
  the `n` DISTINCT trigrams (`dir_tri`/`dir_off`/`dir_count` — csearch's own
  per-trigram index-entry triple, `index/write.go`) plus one `body` blob: each
  group's ascending doc ids are delta-encoded (successor `doc[i]-doc[i-1]`,
  always ≥ 1) and LEB128-varint-packed, so a locally-clustered doc-id run — the
  common case — costs ~1 byte/posting instead of 4, while the zero-copy `mmap`
  load (`persist.zig`) is unchanged: `dir_*`/`body` still alias the mapped
  pages
  directly (`fromMappedBytes`), so a cold query still touches only the handful
  of pages its binary search + a few small per-trigram decodes probe.
  Rarest-first
  query intersection is preserved via the explicit `dir_count` column (sort
  groups by size before decoding, same algorithm as before).

  **Measured on this repo (18,910 files, 160.1 MiB corpus, 343,857 distinct
  trigrams, 25.56M postings):** index footprint **195.0 MiB flat → 30.1 MiB
  CSR+varint (6.5×)** — smaller than `csearch`'s own index over the identical
  corpus (31.1 MiB) for the first time. `bench/coldquery.sh`'s cross-tool cold
  literal race (fresh process, hyperfine mean, 8 runs, 8 needles) moves the
  geomean gist/csearch ratio **0.3× → 0.7×** and gist/zoekt **0.5× → 0.8×** —
  gist now outright _wins_ 7/11 needles against zoekt (up from a near-total
  loss) and still trails csearch geomean, but by roughly half the prior margin.
  The residual gap is no longer index size (gist's is now the smaller of the
  two) — profiling traces it to the corpus-wide freshness `stat()` walk
  (`src/index/trigrams/fresh.zig`) that runs on every cold query regardless of
  hit/miss;
  that is the next rung, tracked separately, not hidden.

  Correctness re-proven: format bumped to `format_version = 2` (a v1 cache is
  rejected, not misread); the full trigram/varint/ngram unit suite (`zig build
  test`, 207/207) and the `gist ≡ rg` equality oracle are green on the new
  format.

  **Confirmed on the fail-closed macro certificate**
  (`bench/certify/certify.sh`
  — fresh-process, hyperfine 20 runs + 3 warmup, gist-vs-rg verdict requires a
  lower median _and_ Mann-Whitney p<0.05): **7 win · 1 parity · 1 loss** across
  9 measured classes (up from a documented 8 win/3 loss at the old index size —
  methodology differs slightly, see README), and the vs-csearch/vs-zoekt split
  moved from "rivals win most cold classes" to a genuine ~50/50 split
  (geomean ≈1.0× csearch, ≈0.8× zoekt). `certify_stats.py` also hardened to
  skip a rival's malformed/empty hyperfine export (a transient hiccup, not a
  real result) instead of aborting the whole certificate for one missing cell.
  (see also: gist)
- A transforming (`-z`/`--pre`/`-E`) pipeline run now scales its worker pool to
  all logical CPUs instead of the 6-worker ceiling tuned for the
  syscall/namei-bound plaintext walk. Per-file decompression (gzip/zstd/xz
  inflate) and transcoding are CPU-bound and embarrassingly parallel — exactly
  like the serial engine's parallel read-shards, which already fan out to
  `min(candidates, ncpu)` — so the old cap throttled decode-heavy codecs
  (xz/zstd) below the serial path on wide machines. On a 16-core box over a
  nested compressed corpus this lifts `-z` past ripgrep AND ugrep on the
  in-process formats (gzip/zstd/xz), where gist decodes in-process while both
  rivals fork a decompressor per file.
- Accelerate the SIMD scan floor on two load-port-bound fronts. First, widen
  the
  single-load byte scanners in `scan.simd` from the 16-byte NEON register to a
  64-byte stride (`scan_vlen`): `memchr` (line-end find), `countByte`
  (line-number
  counter), `countByteWithFlag` (`--json` base pass), the reverse
  `lastIndexOfScalar`
  (line-start walk), and the caseless single-byte find. These issue one load
  per
  block, so the out-of-order core runs the four independent 16-byte loads
  across its
  NEON pipes — measured ~35% faster (17→23 GiB/s, Apple M4). A `vlen`-wide
  second
  tier runs before the scalar tail so a haystack under 64 bytes still
  vectorizes (no
  short-line/small-gap regression). The two-load substring kernel (`indexOfPos`
  &
  co.) deliberately stays at `vlen` — its strided second load already saturates
  the
  ports, so widening measured flat.

  Second, add `scan.teddy` — the Hyperscan/ripgrep Teddy multi-literal
  prefilter —
  and hand the fused any-of gate (`scan.simd.containsAny`/`indexOfAnyPos`, the
  whole-buffer prefilter for needle-less alternations like
  `func|const|return|struct`)
  off to it at 4+ needles. The fused first+last gate pays `1 + N` loads per
  block, so
  its cost grows linearly in the alternation size; Teddy pre-bakes every
  needle's
  first two bytes into nibble→bucket tables and resolves all N with one `tbl`
  (NEON) /
  `pshufb` (SSSE3) shuffle per position, collapsing the block cost to a
  CONSTANT 2
  loads regardless of N. Slim Teddy, one bucket per needle (≤ 8), fixed
  16-wide, with
  a scalar-gather fallback on other arches. The N ≥ 4 handoff is where the
  load-count
  win dominates on every architecture regardless of vector width, so N = 2,3
  keep the
  fused gate (better on wide-vector AVX2/512); both paths are byte-exact — a
  throughput dispatch, not a fallback.

  Byte-exact throughout: the `simd_test.zig` differential oracles stay green
  (the new
  Teddy fuzz vs the `std.mem.indexOfPos` leftmost minimum over random needle
  sets/resume offsets, plus the widened
  `memchr`/`lastIndexOfScalar`/`countByte`
  scanners vs `std`), and `gist` counts match `rg` exactly on 4- and 8-literal
  alternations across ~290k lines. Measured Teddy speedup over the fused path
  on the
  mostly-miss file-gate corpus (Apple M4): N=4 1.6×, N=8 2.2×.
- Add `Ward.reconcileHeld`: a double-checked reconcile that starts from an
  already-held read lease and keeps a live lease on every path (error
  included), returning the refresh error beside the lease rather than in place
  of it. The resident session's `guardExtras` now rides it instead of
  hand-rolling the release/upgrade/recheck/downgrade dance.
- Beat ripgrep on the single-file line-scan modes by adopting the two things
  its
  one-file-one-thread architecture can't: **data-parallel single-file
  sharding**
  and **mmap'd reads**, plus an NFA-free span path. On a 57 MB single-file
  corpus
  (`function|const|return|struct`, warm cache, hyperfine): `-c` 2.0×, `-o`
  2.0×,
  `-b` 1.95×, `--count-matches` 1.96×, `-n` 1.81× faster than `rg` — the
  `--json` match stream stays byte-identical and ahead.

  - **Single-file sharding** (`serial.zig`
  `emitFileSharded`/`lineShardBounds`):
    a lone big file is split at line boundaries into byte-balanced shards, each
    running the line-free literal fast path (`Emitter.fileLit`) over the SHARED
    global body on its own core, then merged in line order (emit modes) or
  summed
    (count modes). Byte offsets, the unterminated tail, and `-n` line numbers
    (each shard's global base via one cumulative `countByte` pass) all stay
    global, so output is identical to the serial scan — this is the win rg
  leaves
    on the table for a single file.
  - **mmap for large files** (`grepfile.mapFile`, wired into
  `readOneCandidate`):
    an untransformed file ≥ 4 MiB is memory-mapped instead of read-loop + arena
    duped, so its pages fault in lazily during the (sharded) scan rather than
    paying a serial ~2× copy up front — ripgrep's large-file strategy.
  - **Parallel binary detection** (`verify.firstNulWide`): the whole-buffer NUL
    scan that gates the fast path is fanned across cores with a
  quit-at-first-NUL
    poll (the binary-detection twin of `gateWide`), so it faults pages in
  parallel
    instead of serializing one redundant full pass ahead of the scan.
  - **NFA-free literal spans** (`output.zig` `litNextSpan`/`emitMatchesLit`,
    `prefixFree`): for a prefix-free literal set (no literal a prefix of
  another —
    so at most one matches at any offset), `-o`/`--count-matches`/`--column`
    resolve each span with one `indexOfAnyPos` jump + a length lookup instead
  of a
    Pike-VM run per line, and never allocate a `SpanSim`. A non-prefix-free set
    (e.g. `con|const|co`) falls back to `matchSpan`, so spans stay byte-exact.
  - **Early-exit presence** (`anyMatch`): `-q` short-circuits on the first
  literal
    occurrence (`indexOfAnyPos`) instead of materializing every line of the
  body
    — an 11× → parity swing on a top-matching 57 MB file.

  Byte-identical to ripgrep — `bench/rgsuite/run.py` 409/409 (parallel and
  serial), full Zig unit + differential-fuzz suite green (new `memchr` /
  `lastIndexOfScalar` / `countByte` / `firstNulWide` oracles vs `std.mem`), and
  span-mode spot-checks over `-o`/`-n`/`-b`/`--column`/`--count-matches`
  including
  the prefix-overlap adverse case. The repo-wide _indexed_ `-l`/`-c` race is
  unaffected and still 6–100× over rg's unindexed walk.
  (see also: gist)
- CREST sidecars now bind their full semantic schema with a canonical SHA-256
  digest under `GISTCRS2`; stale v1 or semantically incompatible caches fail
  closed and rebuild without changing search results.
- Caseless runs (`-i`/resolved `-S`) now ride the same SIMD literal gates as
  case-sensitive ones instead of paying the fold-heavy engine per byte. A new
  ASCII-caseless kernel (`simd.containsCaseless` — first+last byte splatted in
  both case spellings, survivors verified bytewise) backs a `Gate` type
  threaded through every needle consumer (whole-file drop, per-line engine
  bypass, the wide multi-GiB fan-out); the gate literal is the longest
  fold-closed window of the raw (pre-fold) required literal
  (`query.zig::foldClosedWindow` — ASCII-only, `k`/`s` split the window under
  Unicode fold since KELVIN SIGN/LONG S escape ASCII), and when the window is
  the whole pattern and the pattern is one pure literal the gate is a proven
  match equivalence, so caseless `-l` emits with zero engine runs. A
  containment-only gate still drives `-l` hit-to-hit (`gatedDocMatch`: SIMD
  jump to each gate hit, engine on just that line). The warm compiled query
  mines the same gate + caseless trigram variants, so the resident daemon
  prunes and gates `-i` identically. Multi-root caseless `-l` over eight source
  roots: 1.24s → 0.33s (rg 0.45s); matrix `ignore-case-rare-files` holds
  ~4.2–5.0x with 19/19 parity and rgsuite 409/409 intact.
- Chasing the roofline Layer C headroom found the substring kernel paying a
  per-block movemask it almost never needed: on NEON the `@bitCast`-to-integer
  mask emulation is a multi-µop cross-lane sequence, spent on every 16-byte
  block of a miss-dominated stream. Every scan loop (`indexOfPos`, `memchrPos`,
  the fused any-of pair, the caseless kernel) now runs 64-byte blocks gated on
  `anyLane` — a word-wide OR-reduce "did anything hit?" — with the movemask
  paid only inside proven-hot blocks. Anchors got smarter too: a corpus-derived
  byte-density table (`rarity.zig`, the memchr crate's rare-byte idea measured
  over a large polyglot monorepo) picks the needle's two rarest bytes at any offsets
  instead of first+last, a genuinely-rare probe earns a single-load block
  filter, and a runtime hit counter demotes that shape mid-buffer when the
  table misdescribes the bytes (base64, random-looking text) — the
  misprediction collapse that costs, measured on a uniform-random buffer, half
  the throughput. Per-file tails stopped calling `std.mem.indexOfPos`, whose
  Boyer-Moore-Horspool preprocessing built a 256-entry skip table per call — a
  many-small-files corpus paid it ~20k times per scan — replaced by one
  overlapped final vector block. Roofline on M4: contiguous streaming 44.8 →
  53.6 GB/s, per-file corpus full-scan 20.8 → 30.2 GB/s (24% → 36% of the DRAM
  ceiling), matched lanes up 3–5%. Byte-parity proven by `zig build test`, the
  SIMD differential fuzz, `scan_regress.sh` (0 FN / 0 FP), and an rg-parity
  battery over indexed + live paths.
- Close the searcher-loop gap to ripgrep on needle-less literal alternations
  (`function|const|return|struct`) — the case with no single required literal
  for
  the existing per-line gate to skip on, so gist ran the engine on EVERY line
  while `rg` scanned the whole buffer through a Teddy prefilter. A new fused
  multi-literal primitive `scan.simd.indexOfAnyPos` (the position-returning
  twin of
  `containsAny`: one pass, per-needle first+last-byte SIMD fingerprints OR'd
  into a
  survivor mask, leftmost verified survivor wins) drives a whole-buffer
  prefilter:
  one sweep marks the candidate lines around literal hits, and the per-line
  classify then skips ~every non-candidate without an engine run. Wired into
  both
  the text emit (`output.zig` —
  `file`/`onlyMatching`/`countMatches`/`passthru`)
  and the `--json` classification (`json.zig`), gated on `re.lits`
  (`analysis.pureLiterals` — the same match-equivalence set `matchSpan` uses,
  empty
  under `-i`/`-w`/`-U`). The mask is a SUPERSET of the true match set (a hit in
  a
  line's trailing `\r`/terminator maps to that line — the engine still confirms
  each candidate), never a subset, and declines under `-v` (a match LACKS the
  literals) and `--stop-on-nonmatch`, so output stays byte-identical.

  Byte-identical to ripgrep — `bench/rgsuite` `run.py` 409/409 (parallel and
  serial), the `indexOfAnyPos` differential-fuzz oracle green (leftmost-hit vs
  the
  `std.mem.indexOfPos` minimum over random needle sets/resume offsets), and
  49/49
  edge-corpus spot-checks (no-trailing-newline, CRLF, single-line,
  first/last-line
  hits, blank-line runs, empty) across
  `-o`/`-c`/plain/`-n`/`--column`/`-A`/`-v`.
  Measured on a 57 MB single-file corpus (A/B vs the pre-change litSpan
  binary):
  `-o function|const|return|struct` 257→76 ms (3.4×), `--json` 283→102 ms
  (2.8×),
  `-c` 230→51 ms (4.5×). The gap to `rg` on the alternation collapses from
  11.8× to
  3.6× (`-o`), 3.9× to 1.5× (`--json`), and 14× to 3.0× (`-c`).
- Cut the `--json` record stream's serial-engine cost with two byte-identical
  emit-path changes (`src/exec/cold/emit/json.zig`). The classification
  loop now threads the engine's required-literal `simd.Gate`
  (`serial.zig::requiredLiteralGate`, the same gate the line path uses) from
  `run`
  → `runParallel`/shards → `emitOne` → `emitFile`: a line lacking the pattern's
  forced literal skips the NFA entirely. Sound only when non-inverted — exactly
  when the gate exists — so the `-v` classification is unchanged. And each
  matched
  line's spans are now enumerated ONCE at classification and cached on the
  `Line`
  (`matchSpans`), reused for both the `matches` tally (`countMatches` became a
  sum,
  no engine) and `submatches` emission (`emitSubmatches` iterates the cache),
  so a
  matched line pays the engine once instead of up to three times; the dead
  `firstSpan` is removed. Byte-identical to `rg --json` on both engines
  (`bench/rgsuite` core/multiline/pcre cases green). Measured on a frozen 54 MB
  /
  1.7 M-line single-file corpus (read/walk ≈ 0, serial emit isolated, A/B vs
  the
  pre-change binary): `func` 638→124 ms (5.2×), `func\s+\w+` 966→277 ms (3.5×),
  `WalletService` 523→92 ms (5.7×), `import` 591→100 ms (5.9×) — a 3.5–5.9×
  internal emit speedup on top of the earlier `jsonstr` SIMD rewrite. This
  narrows
  but does not overtake `rg --json`, which still leads because `--json`
  disables
  gist's index read-elision (it must tally `searches`/`bytes_searched` for
  every
  searched file), racing rg's parallel walk+search+emit without gist's index
  advantage; the standing `--json` claim remains byte-parity, not a speed win.
- Eliminated Gist's remaining cold-query structural overheads without weakening
  freshness: trusted local indexes now mmap with bounded structural validation
  and defer posting-group decode until queried; the parallel path folds
  freshness into directory enumeration, uses a compact exact path table,
  declines unprofitable/narrow index loads, routes selective work to
  topology-aware worker counts, and reuses compiled regex required literals as
  SIMD file/line gates. The fail-closed 20-run full-field certificate moves
  from 0/11 to 10/11 wins versus ripgrep on the same Apple M2, while the
  140-literal + 70-regex oracle and live dense-scan gate remain 0 FN / 0 FP.

  The adversarial verification pass also fixed two pre-existing rg-parity
  defects the live gate exposed: walked binary files can no longer match after
  the NUL cutoff under `-l`, and unsorted multi-root walks now reproduce
  ripgrep's VCS-ignore re-anchoring. The persisted blob codec/validator moved
  out of `trigram.zig`, dropping the index core below the 500-line cap;
  oversized rg protocol modules are now explicitly registered rather than
  remaining undocumented shape debt.

  The benchmark field now copies the deterministic `zig-out/bin/gist` produced
  by the immediately preceding ReleaseFast build. It no longer guesses among
  hash-named Zig cache artifacts by mtime, which could silently benchmark an
  older intermediate binary and certify code other than the current tree.
- Expand Gist and Relate help into intent-first ergonomics guides so people and
  agents can choose familiar, native, and niche search shapes from the CLI
  itself.
- Files-only searches now stop after the first matching line, and the committed
  performance gate bounds the two known csearch-selective gaps without
  overstating them as wins.
- Generalized the warm session's data-parallelism from the invert emit to EVERY
  positive warm face, so a common token no longer loses to cold purely on core
  count. The invert-only `renderLinesInvertParallel` became the shared
  `render.renderLinesParallel`, and its floor/shard gate was lifted into one
  `math/parallel.zig::shardBounds` primitive that all faces now cross into
  parallelism through: (1) `queryLines` positive emit shards the candidate doc
  slice byte-balanced and renders each shard through the cold `Emitter` into
  its
  own buffer, concatenated in doc order; (2) the `-l`/`-c` fold (`query`)
  splits
  its candidate walk into `eachBase` (sharded, per-thread scratch +
  `Accumulator`
  over the immutable mirror — `-c` sums, `-l` concatenates then sorts once) and
  `eachOverlay` (the bounded mutation set, always serial); (3) the FFI `search`
  record stream collects each shard's per-line spans into its own buffer, then
  feeds the sink SERIALLY in doc order honoring early `halt`, so the stream
  stays
  byte-identical and stops at the same record. All share the 256 KiB byte floor
  —
  below it (or on one core) each face falls straight through to its serial
  core, so
  tiny queries never pay thread-spawn. Every shard is read-only over the mirror
  under the held session lock with its own arena, and the fail-closed per-hit
  existence check is preserved per shard.

  Measured on the live 20k-file / 193 MiB repo corpus (warm files-mode p50,
  serial → sharded): `import` (13838 files) 10.5 → 5.9 ms, `})` (7780) 12.7 →
  5.0 ms
  (2.5×), `def` (4908) 6.4 → 3.0 ms (2.1×), `func` (3690) 5.1 → 2.5 ms (2.0×),
  `context.Context` (1756) 2.8 → 1.4 ms (2.0×); small/rare needles stay on the
  serial core, unchanged. Byte-parity proven `warm == --no-index == rg` (with
  `--uncap` past the soft output budget) on a controlled 400-file fixture
  crossing
  the floor (8/8 cases: `-l`/`-c`/bare/`-n`, large + rare set) and the live
  tree
  (16/16), plus a resident-suite test over a >256 KiB tree asserting the
  sharded
  `-l`/`-c`/emit/stream against ground truth (path-sorted `-l`, exact `-c` sum,
  ascending record stream). The committed session gate is unregressed (armed
  geomean 474×). The now-orphaned invert-only render helper was removed.
- Give the span engine a pure-literal fast path, so every "where is the match"
  operation (`-o`, `--json`, `--column`, `--vimgrep`, `-w`, `-r`, colored
  highlighting) stops paying the Pike VM on literal and literal-alternation
  queries — the code-search common case. `Regex.matchSpan`
  (`src/kernel/regex/linear/pike/span.zig`) now short-circuits through
  `litSpan`
  whenever `re.lits` is non-empty (the `analysis.pureLiterals`
  match-equivalence
  set — an assertion-free alternation of pure literals, per-line only): the
  span
  is found by one SIMD `scan.simd.indexOfPos` per literal (≤ 8) instead of a
  per-byte NFA closure. Leftmost-first semantics are preserved exactly — the
  strictly-earliest occurrence wins (leftmost start dominates branch priority),
  and a positional tie keeps the lowest branch index (pattern order = NFA
  priority), because no literal occurring at the winning position can have an
  earlier occurrence of its own. `-i` folds a literal byte to a non-singleton
  class, so `re.lits` is empty and the shortcut cleanly declines to the Pike
  VM;
  `-U` disables `re.lits` outright, so multiline is untouched.

  Byte-identical to ripgrep — `bench/rgsuite` `run.py` 409/409 (parallel and
  serial), the differential-fuzz oracle green, and byte-exact `-o`/`--column`/
  `--vimgrep`/`-w`/`--json` spot-checks including the `return|ret` tie-break.
  Measured on a 57 MB single-file corpus (A/B vs the pre-change binary):
  `--json TODO` 560→69 ms (8.2×), `--json function|const|return|struct`
  3363→284 ms (11.9×), `--json return|ret` 1452→130 ms (11.2×),
  `-o function|const|return|struct` 2914→256 ms (11.4×). The remaining gap to
  `rg` on these is no longer span-finding but the searcher loop — gist splits
  and
  verifies per line where rg scans the whole buffer through a Teddy/memmem
  prefilter and touches only candidate lines.
- Graduate GIST from a single canary consumer to the repository-wide search
  substrate of the monorepo it was born in: every first-party executable
  ripgrep consumer now drives the certified `gist` engine — lint gates, doc
  freshness wrappers, the relocate/restructure/comment-quality/pentest
  tooling, several shell scripts, and the agent-facing code-search tool
  (resolved binary, with its health probe reporting availability).
  Patternless `rg --files` inventories moved to the git
  index,
  each consumer carries a committed `*_gist_parity.py` guard, and a fail-closed
  `gist-adoption` ratchet ratchets first-party ripgrep executions to zero. Raw
  `rg` survives only as GIST's independent parity/benchmark oracle.
- Index read-elision now engages in two places it used to stand down. Scoped
  roots: `indexElisionWanted` no longer requires a broad root — the
  elide-oracle loader already runs concurrently with the walk and the
  end-of-walk flush never blocks on it, so a nested-root query (`gist Foo
  services/backend/api`) gets its non-candidate reads elided like a rootless
  scan (subtree matrix shape 1.66x → ~4.5–7.8x) while a tiny scope that outruns
  the load pays only the deferral append. Caseless: `-i`/resolved `-S` no
  longer disables the trigram prefilter wholesale — the raw (pre-fold) required
  literal is recovered from a case-sensitive throwaway compile and one window
  of it expands into a ≤16-variant case OR-set the index can query
  (`query.zig::caselessVariants`), with the soundness bounds owned there:
  ASCII-only windows, and `k`/`s` inadmissible under Unicode fold since their
  simple-fold orbits (KELVIN SIGN U+212A, LONG S U+017F) escape ASCII
  (ignore-case matrix shape 1.43x → ~4.9x). Any decline reproduces the old
  no-elision behavior exactly; 19/19 parity holds gist-idx == gist-noidx == rg.
- Profiling the cold `--rank` path on a fat-candidate probe found 4.2 s hiding
  in two places, neither of them ranking. First, freshness: the macOS journal
  replay blocked ~1.9 s in `FSEventStreamFlushSync` before draining a single
  event — the flush is gone, the runloop drain now runs under an explicit
  budget (75 ms per query, 500 ms at daemon boot), a lost race writes a
  per-token `journal.skip` marker so later queries jump straight to the sweep
  walk, and `amend` re-mints the since-token exactly like a full build so the
  replay window stays "since the last amend" instead of growing forever.
  Second, feature extraction: `fileDoc` ran a full per-line pass over every
  candidate and only then consulted `docMatch` — inverted, one fused
  whole-buffer `docMatch` now rejects trigram false positives at the one-pass
  floor and only real matchers fund the per-line signals (also fixing a
  phantom-final-line overcount for `^$`-shaped patterns under rg's line model).
  Cold fat-probe rank drops 4.2 s → ~30 ms with a fresh index (~150 ms on a
  busy tree paying the bounded probe), set-equal with `gist -l` and
  def-boost/gen-demotion invariants intact.
- Purposeful profiling of the per-file pipeline (walk → literal gate → staged
  read → SIMD scan → emit) found the residual multi-root tax living entirely in
  giant mmap'd bodies: the pager faulted the 2.1 GiB blob in one page-cluster
  at a time (13.7 GiB/s) and its whole-file presence gate ran on a single
  worker thread. Two fixes, measured on the live corpus: `mapWhole` now advises
  `MADV_SEQUENTIAL|WILLNEED` (fault-ahead batching, 13.7 → ~40 GiB/s on the
  page-cached blob), and the file-level required-literal gate routes through
  `verify.containsAnyWide` — identical single-thread SIMD kernels below 16 MiB
  (one length compare, no syscalls, no spawn), chunked across cores with
  needle-overlap seams and cooperative early-exit above it. `gist pgxpool
  services libs -l` drops 196 → ~84 ms (rg: ~160–230 ms on the same roots); a
  no-hit scan of the single 2.1 GiB file drops 190 → ~79 ms (rg: ~199 ms).
  Byte-parity proven by the seam-adversarial differential test in
  `simd_test.zig`, `scan_regress.sh` (0 FN / 0 FP over five no-prefilter
  patterns), and `index_elision_parity.sh`.
- Ranked search now identifies declarations from Unicode-aware delimiter
  geometry—including labels, prefix forms, equations, and symbolic
  bodies—instead of a project/language keyword catalogue, and applies
  Relate-style corpus pricing to normalized match-line shapes so definitions
  outrank repeated imports, annotations, and calls across diverse repositories.
- Ranked searches now demote cached source mirrors and identify exact canonical
  duplicates, keeping widened searches focused on editable code.
- Register the Python binding in the parent workspace so development and tests
  import the local package reliably. The production image deliberately omits
  the package, the binary, and the repository corpus, making repository search
  unavailable instead of searching an unrelated container filesystem.
- Replaced the T3 freshness overlay's per-file `readdir()` + `statFile()` walk
  with `getattrlistbulk(2)` batched directory enumeration on Darwin
  (src/corpus/tree/bulkstat.zig — hand-declared FFI, no Zig std binding
  exists), collapsing O(files) metadata syscalls into O(directories) bulk calls
  that return name+type+mtime for every sibling at once. Fails soft,
  directory-by-directory, back to the exact prior stat-based walk on any
  bulk-call error — never a false negative, only a speed trade. Differentially
  tested against the old walk (bulkstat_test.zig) for byte-identical output.
  Measured on this corpus (18.9k files, ReleaseFast, back-to-back A/B toggle
  under identical load): the freshness+cold-load "pre" phase dropped from a
  52-66ms range (median ~57.6ms) to 47-54ms (median ~51ms), an ~11% cut with
  roughly half the variance.
- Replaced the freshness walk's static one-thread-per-root sharding with a
  self-balancing work-stealing pool (src/index/trigrams/fresh.zig:
  buildWorkItems/Worker/workerRun). The old scheme pinned one thread per entry
  in `default_roots` regardless of size — on this repo `services`+`clients`
  outweigh `contracts`+`quality` by 40x+, so wall time tracked the single
  slowest root while the other threads sat idle well before it finished, and
  never used more than 6 threads no matter how many cores were free. The walk
  now breadth-expands roots one directory level at a time (via
  `getattrlistbulk`/`Dir.Iterator` one-level listings) until there are `ncpu *
  8` fine-grained work items, then dispatches them across an atomic-cursor pool
  of `ncpu` workers — self-balancing regardless of which subtree happens to be
  huge, and more resilient under contention since a stalled thread only holds
  up one small unit of work instead of an entire multi-thousand-file root.
  Measured on this corpus (16 cores, real contention from concurrent
  coworking-agent load, load avg ~9.4): the "pre" phase (cold-load + freshness)
  median dropped from ~51ms (post-bulkstat, static shards) to ~40ms, and a
  head-to-head against ripgrep on the same corpus flipped from GIST trailing to
  1.93x faster (σ 9.8ms vs rg's 54ms) on a corpus-saturating literal — the exact
  high-match
  "saturating pattern" the README previously called out as GIST's weak spot —
  and 6.45x faster on a selective literal (`fetchAdd`).
- Rewrote the package root and relate READMEs to the OSS convention (What it is
  / Why it exists / Prior art): measured wins with harness citations, honest
  prior-art framing (csearch/RE2/FM-index/LZJD lineage, Hyperscan and
  embeddings deliberately declined), and the relate corpus-policy asymmetries
  documented.
- Stack-backs common query and worker scratch while reusing retained verifier
  output capacity, removing up to six allocator round trips from repeated
  searches without changing match order or semantics.
- Structural-debt and efficiency sweep across the search planes. The serial
  engine's index-freshness stat-walk now overlaps the gather walk on its own
  thread (mirroring the parallel engine's lazy elide loader) — ~10% faster
  serial runs on a warm indexed corpus. `Emitter` gained a caller-threaded
  reusable `Matcher.Sim` slot (per-worker in the pipeline, per-run in the
  serial
  engine), replacing three allocations per file; `queryAny` branches share one
  lazy `doc_count`-sized decode scratch instead of alloc/freeing per needle.
  The
  last ASCII case-fold twins (`args.lowerDup` / `ignore.lower`) collapsed into
  `paths.lowerDup`. Four >500-line files (`syntax.zig`, `regex/core.zig`,
  `encoding.zig`, `grepfile.zig`) got MONOLITHIC markers + registry rows.
  Byte-parity verified before/after on literals, alternations, and regex
  queries; the rg line-parity, equality, and freshness gates all pass.
- The `gist` CLI — the on-PATH product binary (`~/.local/bin/gist` →
  `zig-out/bin/gist`) whose whole reason to exist is out-running ripgrep — now
  builds **ReleaseFast by default**, so a bare `zig build` (the step that
  refreshes the installed binary) can no longer silently install a Debug build.
  A Debug `gist` is 4–8× slower — a rare literal over the repo took ~4.5 s and
  a
  common substring (`tel`) ~8.3 s — which reads to a caller like a hang ("runs
  forever"). The same queries on the ReleaseFast binary are ~0.9 s (near
  ripgrep's ~0.5 s over the same six roots), the search path it was always
  meant
  to be. The build stays overridable: `zig build -Dcli-optimize=Debug` yields a
  debug CLI for engine work, and tests / kcov coverage / the C-ABI libs keep
  their standard safety-checked, DWARF-carrying default optimize untouched —
  the
  CLI now links a dedicated ReleaseFast engine module so only the product
  surface
  is affected.

  The gitignore matcher (`ignore.zig`) is now bucketed by source directory
  instead of one flat rule list. A candidate path can only be governed by rules
  from its own ancestor directories — a `.gitignore` scopes its subtree, never
  a
  sibling's — so `decide` consults just the CWD/ancestor tier plus each
  ancestor
  dir's bucket (O(path depth)) rather than testing every path against every
  rule
  ever loaded anywhere in the tree (O(paths × rules): rules were never scoped
  back out as the walk unwound). Loaded-dir dedup moved from a linear scan to a
  hash set (O(dirs), not O(dirs²)). Verdicts are byte-identical — the same rule
  sequence per path, minus the sibling rules that could never match — verified
  against the full `rgsuite` differential harness (275 supported-surface PASS,
  no ignore regression) and an unchanged 16 179-file walk set; ~10–13% faster
  on
  whole-tree queries here, and asymptotically far better on deep, ignore-heavy
  trees.
- The `rg`-compatible engine now runs on a parallel fused walk+read+match
  pipeline (`src/runtime/cold/engine/parallel.zig`): work-stealing directory
  walk with immutable per-dir ignore chains + a compiled literal/extension
  ignore tier, bulk-stat listings, inline index/freshness read-elision loaded
  asynchronously, a required-literal SIMD line gate (now also under `-w`), and
  per-worker sorted fragments k-way-merged into byte-identical (sorted) output.
  Ineligible flag combinations fall through to the proven serial engine
  unchanged. Warm-tree result: gist beats ripgrep on every benchmarked shape —
  1.2x on `--files`, 1.5–1.8x on scoped/filtered searches, 2.9–4x on whole-repo
  literal queries.
- The cold engine's match+emit phase now fans out across cores for the modes
  the parallel work-stealing engine leaves on the serial path — `--json`,
  `--stats`, `--sort`/`--sortr`, `-r` replace, and `--files-without-match`.
  Each shards its per-file work over byte-balanced `shardBounds`/`fanOut` (the
  shared `kernel/math/parallel.zig` primitive the warm engine's
  `streamParallel` already proved), renders into a per-shard buffer, and merges
  in file order, so the bytes stay identical to the serial loop. The soft/hard
  output budget is unified into one `corpus.appendBudgeted` helper that cuts
  the merged stream at the same per-file boundary the serial `outputFull` break
  would hit — the parallel truncation point is byte-for-byte the serial one
  (`--json` carries its per-file summary tally to the matching cut).
  `GIST_NO_PARALLEL` forces the serial emit so the parity harness exercises
  both paths against each other.
- The cold walk no longer re-enumerates an unchanged tree. `gist index` now
  publishes `tree.map` — a self-anchored directory-membership snapshot (names +
  kinds, recorded with the query walk's own admission semantics) — and the
  parallel engine proves each recorded directory current with ONE `lstat`
  (POSIX bumps a directory's mtime/ctime on any direct membership change,
  compared conservatively against the snapshot anchor exactly like the T3
  freshness overlay), serving its child list straight from the mapping instead
  of `openat`+`getattrlistbulk`+`close`. Membership only, fail-open everywhere:
  ignore/hidden/glob admission is decided live per entry, a stale or unrecorded
  directory (and any subtree behind a changed level) live-lists and resumes
  phantom below it, admitted files still `lstat` live before index elision may
  skip them, explicit positional roots resolve into the snapshot by name, and a
  missing/corrupt/future-dated `tree.map` (or `GIST_NO_PHANTOM=1`) returns the
  walk to its live path byte-identically. Walk-bound shapes moved most: on the
  home corpus `-g '*.go'`/`-t go` races went 2.2× → **7.6–7.8×** over ripgrep,
  the whole-matrix span is now 2.3×–16.1× (19/19 wins, floors republished), and
  rgsuite holds 409/409 on both engines.
- The in-process C search callback (`irregex_match_fn`) now returns `int32_t`
  instead of `void`: return 0 to keep receiving matching lines, or non-zero to
  STOP the stream early — a bounded / first-match query then returns
  `IRREGEX_MATCH` and leaves the rest of the corpus unscanned, so it costs only
  what it reads. This one general primitive subsumes per-call max-count /
  first-only / exists-early without widening the ABI surface. The callback
  signature change bumps `irregex_abi_version` 1 → 2 (mirrored across
  `contract/search_api.toml`, the Python `ABI_VERSION`, and the Rust
  `ABI_VERSION`); the halt is plumbed through the shared resident match stream
  (`emitDoc`/`search`) and exercised end to end by the C-ABI smoke test.
- The no-prefilter scan floor dropped across the board — every pattern in the
  permanent gate now beats ripgrep by 1.48–2.25×, including the formerly-losing
  sparse `panic|0x` case (0.93× → 1.60×). The structural changes: candidate
  files are read in two stages (a 64 KiB prefix first; `-l` emits from a
  prefix-proven match without reading the tail — 86% of corpus bytes are tails
  of >64 KiB files — and the tail read rescans only unseen bytes plus a
  literal-width seam window), opens resolve one path component against the
  walk's still-open parent directory fd (`openat`) instead of re-walking the
  full path, a pattern that is exactly a pure-literal alternation is answered
  by a fused single-pass SIMD `containsAny` (per-needle first+last-byte
  fingerprints over shared block loads) as a match equivalence with no regex
  engine run at all, and each pipeline worker reuses one match-scratch across
  every file it searches. Match sets stay byte-identical to rg (0 FN / 0 FP on
  the live-tree gate; 140-literal + 70-regex oracle clean; all 11 live certify
  ratio classes clear their committed floors).
- The resident `gist serve` daemon now scales across the coworker fleet and the
  largest corpora without regressing warm latency or the parity contract
  (`resident == gist --no-index == rg`):

  - **Concurrent warm queries.** The poll thread stays the sole connection
  owner
    but now dispatches `query`/`query_ext` frames to a persistent worker pool
    (`min(cpu/2, 8)`, `GIST_SERVE_WORKERS` override, `serve.zig`): an in-flight
    query leaves the poll set, its worker owns the fd and writes the response
    (incl. `chunk_fd`) directly, and a self-pipe wakeup re-registers the fd on
    completion — so one slow scan no longer stalls every other client's
    clean-window probe. `hello`/`status`/`ping`/`changed`/`shutdown` stay
  inline;
    the reconcile/abort counters the poll thread samples are now atomic. The
    session rides the `ward` reader/writer discipline, so readers answer in
    parallel and only a reconcile takes the writer lease.

  - **Shard-backed resident mirror.** `corpus.load` is now a two-tier byte
  store
    (`session/corpus.zig`): an unchanged member binds its bytes to the
  persisted
    `content.shard` mmap (zero heap, page-cache-evictable) and only a
    changed/new/binary/oversize/BOM-carrying doc — or the whole corpus when no
    shard is on disk — heap-reads. Resident heap drops from O(corpus) to
    O(churn + exceptions) with byte-identical ingest (full body, BOM/UTF-16
    decode, whole-body first-NUL offsets, empty docs dropped); no shard ⇒
    fail-open to the old full-heap mirror.

  - **Linux exact scoped reconcile.** The inotify backend realpaths its roots
  and
    `note`s each changed path into the dirty log (unmapped wd / malformed
  record /
    `Q_OVERFLOW` ⇒ doubt), arming exactness on case-sensitive roots
    (`FS_IOC_GETFLAGS`/`FS_CASEFOLD_FL` gates a casefolded root back to
  coarse).
    Linux now reconciles O(changed) like macOS FSEvents instead of always
  walking
    the tree.

  - **Non-ASCII paths scope too.** The `delta` resolver drops its "any byte ≥
  0x80
    ⇒ needs_full" gate: `realpath` canonicalizes macOS case + NFC/NFD aliasing
  to
    the on-disk spelling, so non-ASCII events resolve to normal
    `file`/`subtree`/`gone` verdicts. The one residual hazard — a stale
    normalization/case TWIN of a path the batch never named — is retired by a
    session-side sweep of the (almost always empty) set of non-ASCII corpus
  keys
    through `keyIsCurrent`, O(changed + |non-ASCII keys|). Adversarial
    `scoped_test.zig` cases (case-rename, NFC↔NFD twin, delete-then-recreate
  under
    another normalization) assert scoped answers stay oracle-exact.
- The resident session's freshness proof is now O(changed) instead of O(tree)
  whenever it can be proven sound. macOS FSEvents runs with per-file events and
  feeds an exact dirty-path log (`src/runtime/session/dirty.zig`: bounded,
  deduped,
  overflow/OOM ⇒ sticky doubt); the reconcile drains it and — when the backend
  promised exactness, the batch is doubt-free, one covering full pass already
  ran, and no ignore-semantics path (`.gitignore`/`.ignore`/`.rgignore`, `.git`
  topology) is in the batch — verifies exactly those paths through the cold
  walk's own `Ignore` admission rules (`src/runtime/session/delta.zig`:
  canonical
  realpath mapping, ASCII case-alias tombstoning, subtree enumeration for
  coalesced directory events) instead of re-walking the tree. Every refusal
  degrades to the full walk, never to trusting stale bytes; `.git` internal
  churn (index/objects/refs) now costs a hash probe instead of a full
  reconcile.
  Rootless daemons previously armed an FSEvents stream over an empty path array
  and silently watched nothing (reconcile-always); they now watch `.`. Linux
  inotify stays coarse (never arms exactness) and now poisons the session
  permanently on queue overflow or an unwatchable newly-created directory
  instead of racing a staleness hole. Measured on this 150k-file repo: an
  edit-then-query warm cycle drops from ~290 ms (full covering walk per dirty
  query) to ~6.6 ms (scoped drain), ~44× on the O(changed) path, with
  warm-clean
  latency and the cold/unindexed paths unchanged. Adversarial suite
  (`src/runtime/session/scoped_test.zig`) asserts scoped answers against an
  independent
  on-disk oracle and proves the fail-closed degradations (ignore-source edit,
  doubted/overflowed batch, non-exact backend, poisoned watcher, racing
  writes).
- The unified-search contract (`contract/search_api.toml`) now reports `uds` as
  an `operational-accelerator` rather than `machinery-landed-daemon-planned`:
  the `gist serve` daemon, its fail-open front-door client, and the `gist
  serve` verb are landed, wired into the bare-`gist` path, and covered end to
  end (`src/commands/{serve,client}`, `src/commands/serve/serve_test.zig`), so
  both `subprocess` and `uds` are callable transports today — the warm path
  routes only what it answers byte-identically to cold
  (`-l`/files-with-matches) and falls open to `subprocess` otherwise.
- (in `gist`) The warm resident session (`src/runtime/session/resident.zig`) and the cold…
- Un-hardcoded the corpus roots — gist and relate now index and query any tree,
  not just the monorepo it was born in. `gist index [ROOT...]` / `relate index` take
  roots positionally; with none given, `corpus.resolveRoots` picks per tree (a
  `GIST_ROOTS` env override split on `:`/`,`/space, else `.` — the whole tree).
  Every artifact is now self-describing: the trigram index generation-publishes
  a NUL-separated `roots.list` beside `index.gist`/`paths.list`, and the
  kinship atlas format bumped to v2 with an embedded roots blob — queries,
  read-elision, `--rank`, freshness stat-walks, `status`, and the codex shelf
  all scope to the _persisted_ build roots instead of a compile-time constant.
  A `.` root normalizes to bare relative paths (`joinRoot`), so foreign-tree
  output is byte-identical to a live scan. Legacy pre-roots artifacts (missing
  `roots.list`) fall back to `.` on load — a sound superset (elision keys on
  the persisted path set); atlas v1 reads as corrupt and rebuilds. Verified
  end-to-end on the CPython corpus: `gist index` inside the foreign tree,
  indexed-vs-`--no-index` output parity, and ~4× warm elision (11 ms vs 48 ms).
- Unified the four duplicated corpus walkers (index build, --live, T3 freshness
  stat-walk, no-prefilter live scan) onto one shared Haystack/Walker
  abstraction (src/corpus/tree/haystack.zig), and hand-tuned its two per-call
  hot paths in the process: isSkipDir moved from a 35-entry linear std.mem.eql
  scan to a comptime std.StaticStringMap (18.5ns to 2.8ns/call, 6.6x, measured
  over 1786 real repo directory basenames), and the per-file root/rel path join
  moved from std.fmt.allocPrint to a manual sized alloc + memcpy (20.9ns to
  9.9ns/call, 2.1x, measured over 200k calls) since the walk yields 18.9k files
  but only thousands of directories.
- _2026-07-19_ — Build: **`engineModules` + `twin` for post-hoc decorations.**
  The root/test-twin framework + PCRE2 wiring collapses to one loop; the CLI
  engine is a `kernelkit.twin` at `-Dcli-optimize` instead of a hand-rolled
  `createModule`.
- `--type-list` now prints in ripgrep's exact presentation — type names sorted
  lexicographically (one line per alias) and each type's globs sorted
  lexicographically — over a strict superset of ripgrep's type registry. Most
  rows are byte-identical to `rg --type-list`; the remainder differ only by
  being richer (gist-only types and per-type glob enrichments).
- `-U` multiline now rides the parallel per-file pipeline instead of falling
  through to the serial engine, and an assertion-free multiline pattern
  (nothing positional to resolve — no `^ $ \b \A \z`) determinizes exactly, so
  `bufMatch` answers from the O(1)/byte byte-class DFA instead of a Pike
  re-seed per position; `-U -l` additionally short-circuits at the first kept
  span (`Emitter.buffer` files-only fast path). Both declared `-U` matrix
  losses flip to wins — `multiline-rare-files` 0.84x → ~3.5x and
  `multiline-common-lazy-dotstar-files` (`import \([\s\S]*?\)`, the table's
  deepest loss) 0.36x → ~2.8x — with byte-identical parity held by a new
  assertion-free-multiline differential fuzz lane against the Pike oracle.
- `-w` word searches now ride the required-literal gate (`\bLIT\b` can only
  match where LIT occurs — the boundary check only ever rejects), and the
  emitter gained a per-line SIMD memmem gate so lines without the literal never
  touch the regex engine. `-w Config services/backend` dropped from 72ms to
  43ms (user CPU 297ms → 62ms), 1.5x faster than ripgrep.
- `walkFresh` now runs its first shard inline on the calling thread and only
  spawns workers for the rest, so a single-shard walk (a small tree — the
  common resident-reconcile case, hit on every non-clean query) spawns zero
  threads instead of paying a spawn+join per query, while a multi-shard walk
  still saturates every core with the caller taking a share rather than idling
  on join. Output is byte-identical; this is a scheduling change only.
- `zig build test` is ~4× faster (5.5 min → ~85 s) and a passing run is now
  silent. The unit-test binary is pinned to ReleaseSafe via kernelkit's new
  `test_optimize` knob — the differential-fuzz suites (DFA vs Pike, powerset
  language equivalence, adversarial oracles, index-loader mutation soak) keep
  every safety check at optimized speed; `-Dtest-optimize=Debug` restores a
  debuggable binary and the kcov `coverage` step stays Debug for full DWARF.
  The daemon's "serve: warm" lifecycle line and the `-rn` grep-ism note are
  suppressed under test builds — any stderr from a passing test binary made
  Zig's build runner print a spurious `failed command:` banner on green runs.
- gist: collapse the ripgrep-compatibility matrix to two live categories —
  `supported` (behaves as rg) and `improvements` (identical-or-superset results
  that are strictly better: `--binary`, `-P/--pcre2`, `-z/--search-zip`,
  `--sort`/`--sortr`, `--type-list`). The former "supported-with-differences"
  bucket is gone: the six over-claiming rows were reconciled to parity and
  `--pre` now feeds the file's bytes on the child's stdin as well as the path
  argv (rg's exact contract, deadlock-free via the open file fd), closing the
  last genuine gap. `gist --schema` reports the new `improvements` bucket; the
  transforms parity slate adds an argv-ignoring stdin-only preprocessor case.

### Removed

- Drop the README-only cli/irg umbrella-CLI contract; gist and relate remain
  the product faces.
- Removed the orphaned `scan/sweep.zig` no-prefilter live-scan prototype: its
  fused work-stealing walk+read+scan idiom had already graduated into the
  production `faces/cli/search/engine/parallel.zig` engine, leaving the module
  with zero callers repo-wide (proven via gist + repo-wide grep). The `scan/`
  tier is now exactly the byte-level verify primitives (`simd` + `verify`); the
  READMEs and source comments that cited the dead path are reweaved onto the
  engine that actually drives the fan-out.

### Fixed

- **A leading `(?flags)` inline directive died with a bare `bad pattern`.** The
  README promised rust-regex/rg's leading flag-group syntax was "honored where
  gist can, loud where it can't", but the parser rejected every `(?…)` group
  outright — `gist '(?i)todo'` exited 2 with no reason and no fallback, a
  pattern ripgrep accepts.

  `combinePatterns` now resolves a leading `(?flags)` directive per pattern
  (`stripLeadingFlags`): `(?i)`/`(?-i)` set ASCII caseless run-wide (riding the
  same plumbing as `-i`, overriding a resolved `-S`, exactly rg's
  inline-beats-CLI precedence); `(?m)`/`(?s)` and negations are inert in the
  per-line model (`^$` already anchor every line, no line carries a `\n`);
  `(?-u)` is inert (byte semantics are gist's native behavior). Directives the
  engine genuinely can't reproduce — `(?u)` `(?x)` `(?U)` `(?R)` — and mixed
  per-pattern case demands across `-e`/`-f` patterns (gist compiles one global
  engine; rg scopes flags per branch) fail loud with the reason and the rg
  fallback. Under `-F` the bytes `(?i)` stay a literal, as in rg. The generic
  bad-pattern death (lookaround, backreferences, mid-pattern flags) now names
  the pattern, the reason, and the `rg` fallback instead of a bare
  `bad pattern`. Guarded by unit tests plus a case-twisted black-box exit-code
  guard in `build.zig` (`zig build test`).
- **Finished the search-engine unification the previous entry started.** The
  `search` verb's removal (see `unify-search-engine`) left the old
  `src/commands/search/` package dead (deleted, minus its one still-needed
  `looksLikeRegex` helper, moved into `ripgrep/args.zig`), `root.zig` still
  exporting/testing it, and stale doc comments across `index/persist.zig`,
  `corpus/corpus.zig`, and `corpus/haystack.zig` pointing at it.

  **The bench gates and README were still asserting the pre-unification
  contract.** `bench/gates/streams.sh` and `bench/gates/scan_regress.sh` (plus
  `bench/races/_compete.sh`'s shared invocation helpers) still shelled the
  removed `gist search <pattern> --show files` syntax and asserted the old
  `search` verb's wider-than-`rg` corpus (`--no-ignore --hidden`) and a
  "routes to the live scan" stderr announcement that no longer exists — so both
  gates were silently non-functional (argument-parse failures, not green
  checks) rather than actually verifying anything. Rewrote both against the
  unified engine's real contract: `gist <pattern> -l`, `.gitignore`/hidden
  parity with `rg`'s default, and stderr silent except `--rank`'s timing line.
  `scan_regress.sh` now surfaces real FN/FP counts against `rg` for
  no-prefilter patterns instead of skipping the comparison — worth a follow-up
  look, since a first run found genuine mismatches (binary-file handling
  divergence) it was never actually catching before.

  `README.md`, `bench/gates/README.md`, `src/commands/cli/README.md`, and the
  `project-overview.mdc` navigation line were all rewritten to match: the
  canonical usage is the bare `gist <pattern>`/`gist rg`, `.gitignore` and
  hidden-file semantics now match `rg` exactly (no more documented
  superset-of-`rg` corpus), and `--rank`/`-l` replace the removed `search
  --rank`/`--show files` spelling throughout.
  (see also: gist)
- **`gist` could hang forever with no output.** `readableStdin()` mirrors
  ripgrep's own `is_readable_stdin` check (regular file, FIFO, or socket on fd
  0
  ⇒ search stdin instead of walking the tree) — correct against a real shell
  pipe, but some sandboxed shell/tool-call harnesses wire fd 0 to a long-lived
  socket that never writes a byte and never closes. A blocking `read(2)`
  against
  that blocks indefinitely; an agent-facing tool can't afford that.

  `readableStdin()` now classifies fd 0 by stream type (`stdinKind`) and guards
  _only a socket_: a socket is admitted to the stdin path — and each chunk of
  its
  read loop is gated — through a 200 ms `poll(2)` deadline, so the pathological
  "open forever, silent" control channel times out and falls through to the
  directory walk instead of hanging. A FIFO (pipe) or regular file is
  classified
  readable immediately and block-read straight to true EOF with **no** poll
  guard:
  `cmd | gist pattern` is the canonical stream, a slow or paused writer just
  makes
  `read` wait, and the writer's close is the EOF — byte-for-byte ripgrep, with
  no
  delayed-pipe truncation. (An earlier revision poll-guarded FIFOs too, which
  dropped a producer whose first bytes arrived after the deadline to the walk —
  a
  delayed-pipe false negative this split eliminates.)
- A resident file reconciled into the mutation overlay and then deleted is no
  longer reported off the watcher-clean path: overlay matches are now
  existence-checked with the same fail-closed stat-per-hit the base docs use,
  so a delete that vanishes from the metadata walk can never surface a stale
  hit (preserving resident==rg).
- An explicit PATH arg that can't be opened (missing/unreadable) is now
  reported to stderr and forces exit 2, matching ripgrep; previously such a
  path was dropped silently with a no-match exit 1, which read like an instant
  crash on a typo'd path (e.g. 'gist search tel').
- CREST now distinguishes epsilon, unknown, and optional profiles, preserves
  one-sided class certificates through repetition, and saturates large counted
  powers without the former 4,096-copy precision clamp.
- (in `gist`) Closed the last supported-surface divergences between `gist rg` and ripgrep…
- Cold-query evidence now fails closed before measurement: every gist timing
  cell proves its complete file set against official rg, timed wrappers
  preserve hard failures, and deterministic gates reject both status and
  semantic faults. Line parity generates the cited 265,286- and 147,087-line
  classes on demand and requires exact bytes for explicit files on both
  engines. Certificate bundles now carry microscopic and macroscopic CSVs,
  hashed corpus rows, exact executable identities, raw-cell/command parity, and
  honest runtime-cache versus evidence-workspace accounting, with fresh and
  committed bundles both gated.
- (in `gist`) Fixed a drift risk between Layer A (`certify.zig`) and Layer D…
- Fixed two `rg`-compat bugs found by adversarial-testing against ripgrep's own
  issue history: files at/above the 4 MiB indexing-corpus budget silently
  returned zero matches instead of being searched in full (the read path reused
  `per_file_cap` as a hard ceiling; it now keeps reading past it), and
  `-L`/`--follow` hung forever on a self-referential symlink cycle (the depth
  counter alone didn't stop it; the walk now also tracks each ancestor's
  realpath and refuses to re-descend into one already on the current DFS stack,
  while still following legitimate non-cyclic diamonds).
- Gist's public claims now match its shipped surface: `--schema` renders a
  four-bucket ripgrep compatibility matrix from the parser's own declarative
  flag catalog, including ASCII-only `-i`/`\b`/`\w` differences and fail-loud
  exclusions; the C ABI is documented and gated as the existing two-symbol
  primitive surface, with a real C compile/link/run smoke in `zig build test`;
  and `PRIOR_ART.md` distinguishes Gist's agent-workload composition from
  established indexed, semantic, and structural code-search systems.
- Linux targets build again. Zig 0.16's `std.c` declares no `fstat`/`fstatat`
  on
  Linux and `std.posix.close` is gone, which had silently rotted every
  comptime-pruned Linux leg (`--one-file-system` device ids, `--sort created`
  birth times, stdin classification, the mmap fast path's sizing stat, the
  session reconciler's lstat, and the inotify watcher's fd closes) — invisible
  from the macOS dev boxes. Raw stat now lives behind one portable shim
  (`grepfile.RawStat` + `statPath`/`lstatPath`/`statFd`): `statx(2)` on Linux,
  the exact libc `fstatat`/`fstat` calls it replaced everywhere else, so macOS
  behavior is byte-identical while Linux additionally gains real `statx` BTIME
  birth times for `--sort created`. Watcher closes use `std.os.linux.close`
  directly in their comptime-Linux branches. A `zig build check-linux` drift
  gate (folded into `zig build test`) cross-compiles the full CLI module for
  x86_64-linux as a no-link object — full Sema + codegen over every
  Linux-reachable line in ~1 s warm — proven to fail on exactly this class of
  breakage; x86_64-gnu, x86_64-musl, and aarch64-gnu full builds all verified
  green.
- Made indexed read elision fail closed on local filesystem change metadata:
  Darwin bulkstat and portable stat now carry both mtime and ctime, and a file
  is live-read when either clock is at/after the build anchor or either value
  is unavailable. This closes ordinary preserved-mtime append and same-size
  overwrite false negatives without per-query content hashing. The tracked
  model now qualifies timestamp resolution and concurrent-write semantics,
  while the >1024-file filesystem gate synchronously requires real elision and
  covers mtime/ctime equality, add/edit/delete/rename, unreadable directories,
  and serial-overlay compatibility.
- Multi-root queries that sweep large gitignored files (rg-parity re-anchors
  CWD-tier ignore rules per explicit root, pulling multi-GiB training blobs
  into the scan) no longer pay a copy-loop tax: `readTail` now maps the whole
  regular file read-only via `mmap` and re-views the already-drained prefix
  through the mapping — one consistent snapshot, zero intermediate copies —
  falling back to the old growable-buffer read only when the fd isn't a regular
  mappable file. `gist pgxpool services libs -l` dropped 543 ms → ~190 ms warm
  (rg: ~180 ms), output byte-identical.
- Promote gitignore admission into the shared corpus layer so gist indexes,
  relate, and composed irregex exclude ignored and hidden files with the same
  precedence as live gist search.
- Published certificates now pass through the repository's canonical prose
  formatter before artifact verification, preventing generated Markdown drift.
- Ranked --rank snippets now window around the match instead of taking a
  leading 120-byte prefix, so a hit past column 120 still surfaces the matched
  token (with … markers on truncated edges) instead of a line of filler with
  the token gone.
- Reconciled the C-ABI compatibility integer so every axis agrees on the
  truthful value. The rung-3 match callback (`irregex_match_fn`) had already
  gained its `int32_t` abort return — a breaking signature change the changelog
  documented as stepping `irregex_abi_version` 1 → 2 — but `src/root.zig`'s
  `abi()`, the `build.zig` C smoke assertion, and the Python FFI loader
  (`_ffi._ABI_VERSION`) were never bumped, so the live library reported `1`
  while the contract, the Python/Rust mirrors, and the changelog all claimed
  `2`. `abi()` now returns `2`, the C smoke asserts `2u`, and the loader gates
  on `2`; the contract `[meta]` comment additionally spells out that the C-ABI
  integer, engine semver, UDS protocol version, and persisted index/atlas
  formats are independent version axes.
  (see also: relate)
- Relate search and pack now nominate from the persisted trigram codebook
  instead of rebuilding a whole-corpus fingerprint lexicon per query, recover
  three-byte queries such as `dog`, bound exact cross-parsing to query-bearing
  evidence windows, and choose live sketching automatically when a narrow scope
  is cheaper than loading the global atlas.
  Warm retrieval now shares canonical scope and coverage kernels, distinguishes
  foreign chunks from ubiquitous zero-bit evidence, rejects non-finite
  similarity thresholds, and falls back live instead of retaining stale atlas
  rows after refresh failure.
- The freshness walk (`index/trigrams/fresh.zig`) no longer emits a file twice
  when its parent directory expands to children but no subdirectories:
  `buildWorkItems` re-queued such childless directories as leaf items after
  `expandOneLevel` had already emitted their files, double-visiting every file
  underneath. Surfaced by the kinship-atlas fold tests (a changed file
  re-sketched twice inflated the folded path count); fixed at the walk so every
  consumer of the changed-file report sees each path exactly once.
- The in-process C-ABI session seam is now null-hardened: gist_open with a null
  out (or null roots with nroots > 0) and gist_search with a null pattern
  (pattern_len > 0) return GIST_INVALID instead of dereferencing blind, and
  nroots == 0 / pattern_len == 0 never read their pointer. Also fixed an
  OOM-path leak of the transcoded body in the mirror's readDocOwned.
- The parallel ripgrep engine (pipeline.zig) had regressed two rg-parity fixes
  present in the serial engine: -g/--iglob whitelist overrides for ignore rules
  were not respected, and directory-walk errors (e.g. EACCES) were silently
  swallowed instead of exiting 2 like ripgrep. Both are now ported into the
  parallel engine, and the line_parity, freshness_fs, and rgsuite test
  harnesses now exercise both engines (serial forced via the internal
  GIST_NO_PARALLEL env var), confirming genuine zero-FAIL parity on both.
- The persisted-index loader now verifies the doc→path table matches the index.
  `persist.load` mapped `paths.list` and split it without checking the count,
  so a torn or stale table (fewer or more entries than the index's `doc_count`)
  could let a candidate doc id — bounded `< doc_count` by the index but never
  against the table — index past `paths.items`. `validatePersistedPair` now
  requires `paths.len == doc_count`; a mismatch is treated as a no-usable-index
  miss (fall back to the full walk with rebuild guidance) rather than a
  possible out-of-bounds path lookup. The NUL-split is factored into
  `parsePathTable`, and both are unit-tested in `persist_test.zig`.
- The resident session's reconcile no longer re-reads the whole corpus on every
  query: its freshness cursor is anchored at the session's own load instant
  (captured before the corpus read, so a write racing the load is caught by the
  first reconcile rather than baked into stale base bytes) and advances
  incrementally per reconcile, instead of being pinned backward to the
  persisted index's global build anchor — a different index's clock that
  predates any file touched since the last `gist index` and silently defeated
  the incremental catch-up, forcing a full corpus re-read (and a metadata-walk
  thread pool) on every warm query.
- The resident session's socket writes can no longer kill the daemon (or a
  client) with SIGPIPE when the peer half-closes mid-write: `protocol.writeAll`
  now issues a no-signal send (Linux `MSG_NOSIGNAL`; Darwin/BSD `SO_NOSIGPIPE`
  armed idempotently on the fd), so a broken connection surfaces as EPIPE and
  costs one dropped connection instead of a fatal signal that takes down the
  whole process. The CLI's stdout SIGPIPE (the `gist | head` early exit) is
  deliberately left intact.
- The single-byte legacy decoders (`x-user-defined` and the windows/ISO/KOI/mac
  table family) reserved `buf.len` bytes up front and then used
  `appendAssumeCapacity` for ASCII bytes — but once an earlier high byte
  expands to multi-byte UTF-8 via `appendSlice`, the geometric growth policy
  guarantees no spare headroom, so a long ASCII tail after enough high bytes
  could write past the reservation (undefined behavior in ReleaseFast, an
  assert in Debug). Caught by a 4000-buffer differential fuzz over all 35
  legacy encodings during the decoder consolidation; both paths now use
  bounds-checked appends, decoding byte-identically on every input that didn't
  crash before.
- The soft output budget (the ~25k-token agent-context guard) now applies
  symmetrically across every content-search path. A warm daemon-served answer
  is pre-rendered as one buffer, so the client's single stdout write previously
  let the whole result land — the crossing-fragment-lands-whole straddle
  silently defeated the cap, dumping the full result (e.g. 9.4 MB) where a
  daemon-less --no-index run truncated at ~100 KiB. The warm client
  (emitRaw/emitFd) now bounds via corpus.writeStdoutCapped, cutting at a
  whole-line boundary; because the daemon renders in canonical path-sorted
  order the surviving prefix is the same reproducible cut the cold serial
  loop's outputFull poll produces (stable run-to-run), not the parallel sink's
  order-nondeterministic subset. Under the cap the paths stay byte-identical;
  GIST_UNCAP still lifts it.
- Warm client gates every post-connect recv with a 2s poll deadline so a wedged
  daemon (accepts but never READY) falls through to cold instead of parking
  forever.
- `--json` now disables index read-elision, exactly like `--stats` always has.
  The JSON summary message embeds the same `searches`/`bytes_searched`
  counters, so eliding index-cleared files under-reported both relative to
  ripgrep (which reads every walked file) — acceleration was changing
  observable output, caught by the multi-corpus sweep on CPython. With the gate
  added to `trigramFilter`, the full 472-case sweep (5 corpora × both engines)
  passes clean.
- `--rank` now compiles the pattern through the same regex engine as the line
  search (so `foo|bar` and `claim.*job` rank real matches instead of looking
  for those bytes literally) and honors positional PATH roots when scoping the
  candidate set.
- `codex.Cursor.bytes` guarded reads with `pos + len > buf.len`, which can wrap
  on an adversarial huge length and risk a safety panic instead of a verdict.
  The check is now the overflow-proof `len > buf.len - pos` — identical on
  every non-overflowing input, and a corrupt blob declaring an absurd length
  now fails closed with `error.Corrupt`. Atlas's near-identical private cursor
  (which already used the subtraction form) is deleted in favor of the shared
  `codex.Cursor`, so CDX1/SHLF/ATLS parsing all take the hardened path.
- `engine.count` (the cold oracle behind `gist.count`/`Session.count`) counted
  per-occurrence via `--count-matches`, contradicting its own docstring ("total
  matching lines") and silently diverging from every warm path — the resident
  daemon's `countLines`, and the in-process FFI's per-line stream — on any line
  the pattern hits more than once. It now uses `-c`/`--count` (rg line
  semantics: a line is counted once regardless of repeats), so cold ≡ UDS ≡ FFI
  agree, matching the documented contract and doc_radar's own `count_matches`
  ("number of matching lines"). The doc_radar canary's rg oracle was likewise
  counting `--count-matches` (occurrences) while its docstring claimed
  "matching lines" — a latent mismatch masked only because `gist.count` was
  equally wrong; it now counts `--count` (lines), so the byte-equivalence gate
  checks the real line contract. Caught by the new FFI-vs-cold parity test over
  a corpus with a repeated-hit line, plus the doc_radar canary.
- `gist --rank` now falls back to ranking the normal live-walk matches when the
  persisted index is missing, incomplete, corrupt, or explicitly disabled with
  `--no-index`.
- `gist --rank` now honors ripgrep's default binary-file policy, so the ranked
  view is a true reordering of the `gist -l` set rather than a superset. The
  `--rank` no-fabrication certificate invariant caught the divergence: because
  the ranked read pass scanned every candidate's full bytes, a symbol living
  only in a committed binary's symbol table (e.g. `atomic.(*Int32).Store`
  inside
  `tools/mdns_verify/mdns_verify`) surfaced as a ranked hit
  that
  the locate path — and rg — correctly skip.

  - `ranked.zig`'s `fileDoc` clips a NUL-bearing walked file to the bytes rg's
    quit strategy committed before the NUL (`grepfile.committedPrefix`),
  matching
    the locate default; `-a`/`--text` (`binary_detect = false`) reads the whole
    body as text, exactly as `gist -la` does. The rule threads through all
  three
    rank paths — cold index (`run`), live `--no-index` (`runLive`), and the
  warm
    daemon (`renderLive`, where the resident rank path previously leaked
  binaries
    its own `-l`/`-c` visitors already dropped).
  - The `--rank` certificate lane report (`certify_rank_report.py`) now parses
    ranked rows whose paths contain spaces (`(.+?)` up to the `:line [kind]`
    anchor, not `\S+?`) and decodes captures with `surrogateescape`, so a
    non-UTF-8 source line can no longer abort the whole lane.

  Proven by a new fail-closed `fileDoc` unit test and re-validated end-to-end:
  all six rank probes hold 0 fabrication.
  (see also: gist)
- `gist --schema` and the bare `usage()` banner now document the
  `gist <pattern> [PATH...]` shorthand (no verb, no index required) as a
  first-class capability instead of leaving it undiscoverable — the schema
  manifest gained a `"shorthand"` field and a corrected exit-code description.

  Also fixed several stale doc comments left over from the pre-`search`-verb-
  collapse design that misdescribed the whole-tree `rg`-compatible engine: a
  dead `commands/grep/` reference (the folder itself, empty and unused, is
  deleted), and incorrect claims that the engine ignores `.gitignore` and fails
  loud on `--json`/`--column`, when it actually supports both.
- `gist rg` no longer ignore-filters a positional PATH argument itself — only
  what's found beneath it, matching ripgrep's own depth-0 exemption
  (`crates/ignore/src/walk.rs`'s `add_parents`: ancestor ignore state is loaded
  at the root, but the root entry is never matched against it, only its
  descendants are). Previously, naming a directory that an ancestor
  `.gitignore` happened to match (e.g. `gist rg pat upstream/some-dir` when `upstream/`
  is gitignored at the repo root) silently returned zero results — a
  divergence from real `rg`, which always searches an explicitly-named path
  while still honoring ignore rules nested _inside_ it. This made `gist rg
  --files`/`--iglob` unusable as a `find`/`find -iname` replacement for any
  path under a gitignored ancestor, forcing a fallback to raw `find`.

  Fixed with a new `Ignore.scopeToRoot` in `ignore.zig`: a component-depth
  floor on the rule matcher that exempts a positional root's own path segments
  from CWD/ancestor-sourced rules (`Rule.base == ""`) while leaving rules
  loaded from _within_ the given root's own subtree unaffected. Verified
  byte-identical against real `find -iname` and `rg -n -i <files>` on the
  reproducing case, and against the full `rgsuite` differential-parity harness
  (441 mined ripgrep cases, 278/278 supported-surface parity, zero
  regressions).
- `gist rg` now clears the whole mined rgsuite at ripgrep's own assertion bar —
  **409 PASS / 0 ORDER / 0 FAIL** on both engines. The scoring harness honors
  each mined test's upstream comparison mode (`eqnice!` pins bytes;
  `eqnice_sorted!` compares sorted lines because rg's parallel walk is
  genuinely nondeterministic there), which retires the ORDER bucket as a
  soft-pass class. The multiline (`-U`) emitter closes its last nine
  byte-parity holes: CRLF-aware span collection so `$` anchors at logical line
  ends and remaps to original offsets; block-level `-r` replacement matching rg
  #1311 (adjacent matches coalesce into one sink block, non-matching bytes
  preserved, replaced text re-split into renumbered physical lines,
  `--passthru` widens the window); `--vimgrep` per-match-one-line rows (rg
  #1866) with the filename forced on even for a single explicit file; and
  `--trim`/`-M --max-columns-preview` applied per fragment with rebased match
  offsets. `--sort`/`--sortr` semantics now replicate rg exactly: ascending
  `path` is the walker sort (per PATH argument in argv order, component-wise
  within each root), while `--sortr path` and every time key are global
  collect-and-sort with rg's error-files-last (ascending) placement; a
  multi-root `--sort path` over the live tree is byte-identical to rg and ~2.6×
  faster (parallel reads vs rg's forced single thread).
- `session.warm_eligible` (the Python leg's warm/cold router)
  accepted any non-scoped request regardless of pattern shape, so a `\n`, NUL,
  or empty pattern was routed to the resident daemon — whose whole-document
  engine can match across line boundaries where the cold per-line walk cannot,
  a silent warm≠cold divergence. It now declines an empty, `\n`-, or
  NUL-bearing pattern up front, mirroring `session/request.zig::classify`
  term-for-term, so every request the two accept answers byte-identically on
  both paths.
- gist serve now poll-multiplexes its accept loop (listener + every connected
  client in one poll set, one frame per readable client per wakeup), so an idle
  persistent Session no longer starves other clients in the listen backlog —
  previously one agent's long-lived warm session blocked every other agent's
  connect for minutes. The Python binding's Session also arms a 2 s socket
  deadline on connect/handshake/query (the twin of the Zig client's
  client_io_timeout_ms), failing open to the certified cold path instead of
  blocking indefinitely on a busy or wedged daemon.
- gitignore negation semantics are now entity-only, matching git/ripgrep: a
  rule is tested against the candidate itself (full path for anchored patterns,
  basename for slash-less ones), never against ancestor components or path
  prefixes — ancestor exclusion is the walk's directory pruning. Previously a
  re-include like `!tools/indexer/build/` leaked everything beneath it (e.g.
  its `__pycache__/`) into results in both the serial and parallel engines; two
  rgsuite cases regained byte-identical PASS.
- rg-parity fixes across the regex escape parser: \\0–\\9 (backreference
  syntax), unrecognized letter escapes (\\q, \\e, \\Z, …), and assertion
  escapes inside a class ([\\b], [\\A], [\\<]) now fail loud with exit 2
  exactly like ripgrep instead of silently matching a wrong literal; \\A/\\z
  (haystack anchors) and \\</\\> (word start/end boundaries) are now supported
  with rg-identical semantics in both the per-line default and multiline
  engine.

## [0.1.0] - 2026-07-01

### Added

- **Byte-class DFA — the sole non-Pike engine** (`src/regex_dfa.zig`, tests in
  `src/regex_dfa_test.zig`; supersedes and removes the interim bit-parallel
  Glushkov engine). The Pike VM is O(active-threads)/byte, so on the
  no-prefilter
  scan tail — a *selective but common* first byte (`;$`, `[0-9]{4}`,
  `panic|0x`)
  re-seeds a closure at nearly every byte — it lost to rg's O(1)/byte lazy DFA.
  This determinizes the Thompson NFA (Cox → RE2 / rust-`regex` lineage, an
  eager
  capped variant) into an immutable, scratch-free automaton that spends **one
  table lookup per byte regardless of match density**:
  - **Byte classes** collapse the 256-byte alphabet to the handful of columns
  any
    consuming state actually distinguishes (RE2/rust-`regex` `ByteClasses`),
    shrinking the transition table.
  - **Line anchors without a `.*` hack** — `^` is resolved once in the start
    state's closure (`at_start=true`); `$` by a separate **final** transition
    table closed with `at_end=true` (the single-line analogue of RE2's one-byte
    match delay). Unanchored search re-seeds the NFA start into every
  transition;
    an `^`-anchored program never re-seeds and dead-states to `false` the
  instant
    its thread set drains.
  - **Eager + capped** — built at compile (these patterns are tiny); past
    `max_states=4096` the build bails to null and the Pike VM keeps serving (so
    `{1000}`-style expansion stays linear, only a pathological alternation
  trips
    the cap). One immutable `Dfa` is shared lock-free across all reader
  threads.
  - **Single-pass `docMatch`** — scans the whole file buffer in **one fused
  loop**
    that detects `\n` inline, so each byte is touched exactly once. (The
  per-line
    path memchr-scans for `\n` *and then* re-scans the bytes in the automaton —
    double byte-traffic, the dominant cost of a no-prefilter full scan.)
- **Counted repetition `{n}` / `{n,}` / `{n,m}`** (`src/regex_syntax.zig`):
  parsed
  and desugared into the existing node vocabulary (`min` mandatory copies, then
  `(max-min)` optional copies or a trailing `*` when unbounded) — the `atom`
  pointer is shared across copies (the AST becomes a read-only DAG), so the NFA
  compiler and literal extractor are untouched and `ab{3}c` still prefilters on
  `abbbc`. Expansion is capped at 1000 to bound NFA size. **Mirrors rust-regex
  brace semantics exactly**: an unescaped `{` must begin a valid count or it's
  a
  `BadPattern` (ripgrep errors identically — `interface{}` is rejected, the
  literal is `\{`), while a stray `}` stays literal. Proven byte-identical to
  `rg (?-u)`: the oracle battery adds `[0-9]{4}`, `\w{3,8}`, `x{2,4}`,
  `0x[0-9a-fA-F]{2,}`, `interface\{\}` + a `{0}\w{2,4}` template (0 FN / 0 FP).
- **DFA start-state acceleration** (`src/regex/dfa.zig`,
  `src/regex/powerset.zig`).
  The byte-class DFA's unanchored start state self-loops on most bytes; only a
  few
  "relevant" bytes can begin a match (`trans_in` leaves start) or match at EOL
  (`trans_fin` is a match — the `$`-literal case like `;$`). `powerset`
  collects
  that set and, when ≤ 3 bytes, attaches a SIMD `Prefilter`; the scanner then
  `memchr`/range-skips the dead run to the next relevant byte instead of a
  table
  lookup per byte (the rust-`regex`/RE2 `accel.rs` trick). For unanchored
  patterns
  where `\n` is irrelevant and no empty line matches, the skip **crosses
  newlines** — collapsing `;$` to a single-byte `memchr ;` (rg's exact
  strategy)
  and the prefilter from a two-range scan to one. Sound because a skipped byte
  both
  keeps start in itself *and* can't match under `$`; the byte-at-a-time inner
  loop
  still stops at `\n`, so `$`/line-end resolution is unchanged. **Verified by
  the
  existing doc-level differential fuzz vs the Pike VM** (12k patterns ×
  multi-line
  buffers, *anchors + `$`-literals included*) — **0 divergences**.
  Kernel-level:
  the no-prefilter end-to-end is read-floor-bound (the scan is ~1 % of wall, <
  30 ms
  User vs ~300 ms System), so this makes the automaton optimal without moving
  the
  IO-bound macro number — the lever for that stays the read floor above.
- **DFA transition-table premultiplication** (`src/regex/powerset.zig`,
  `src/regex/dfa.zig`). The dense no-prefilter scan's hot loop is one load-use
  recurrence per byte: `next = trans[state * ncls + class[byte]]`. The `state *
  ncls`
  multiply sat *on* the loop-carried dependency chain — every step had to
  compute
  the row offset before it could issue the load that produces the next state.
  `powerset` now stores every transition target, `start`, and `dead`
  **pre-scaled
  by `ncls`** (a row *offset*, not a state id) and lays `is_match` out
  offset-indexed,
  so the recurrence collapses to a bare `next = trans[state + class[byte]]` —
  the
  `madd` leaves the critical path entirely (the rust-`regex`/RE2
  premultiplied-DFA
  representation). **Correctness:** structural invariants + exhaustive language
  equivalence (`powerset_test.zig`, updated for the offset representation) and
  the
  doc-level DFA↔Pike differential fuzz (12k patterns × multi-line buffers) —
  **0
  divergences** — plus `scan_regress.sh` end-to-end (5 no-prefilter patterns,
  **0
  FN / 0 FP** vs `rg` over the identical 17.5k-file tree). **Measured** (Apple
  Silicon, kperf FIXED_CYCLES/INSTRUCTIONS, min-of-N, real 137 MB corpus,
  `[0-9a-f]{8}-[0-9a-f]{4}`): **6.62 → 3.98 cyc/byte (−40 %, 1.66×)**, ins/byte
  16.89 → 14.99 (−1.9), IPC 2.55 → 3.76. The signature is unambiguously
  latency-bound — instructions fell ~11 % but cycles fell 40 % *and* IPC rose,
  because shortening the recurrence (madd→load ⇒ load) exposed the ILP the
  dependency chain had been hiding. The dense DFA now sits at the scalar-DFA
  hard
  floor (~one L1 load-use per byte), at/ahead of rg's premultiplied lazy DFA.
- **Expanded scenario slates**: the warm/oracle slate (`bench.zig`) grows to 20
  literals (added cross-language keywords `goroutine`/`panic(`/`Result<`/`def`/
  `.unwrap()`) + 30 regexes (added `if\s+err\s*!=\s*nil`, `const\s+\w+\s*=`,
  `\w+\.\w+\(`, `[a-z]+_[a-z]+_[a-z]+`, `[a-z]+[A-Z]\w+`, `[0-9a-f]{8}-…`); the
  cold literal slate adds a guaranteed miss +
  `goroutine`/`SELECT`/`func(`/`})`;
  the cold regex slate grows to 22 tiers (decl, err-idiom, uuid/snake/camel,
  dotted-call). Re-proven sound: **50 literals + 68 regexes, 0 FN / 0 FP** vs
  rg.
- **Latent Pike `.skip` soundness fix** (`src/regex.zig` `eol_empty`). The DFA
  doc-fuzz surfaced it: a nullable prefix flowing into `$` (`\d*$`, `a*`,
  `x|$`)
  matches the zero-width end of **every** line, but skip mode only seeds
  first-byte positions and never evaluated the end-of-line empty match — a real
  false-negative the DFA exposed. `compile` now precomputes whether the start
  epsilon-reaches `match` at `(at_start=false, at_end=true)` and short-circuits
  to
  true (also a fast path for the DFA: no full-line scan for a match-everything
  pattern). `^`-anchored programs correctly stay false.
  - **Verification — two oracles, both fail-closed.** The rg `(?-u)` equality
    battery (135 literals + 64 regexes over 17.1k files / 126 MiB → **0 FN / 0
    FP**) *and* two **differential fuzzes vs the proven Pike VM**, hermetic (no
  rg
    needed): a line-level fuzz (6,000 random patterns — *anchors included* — ×
  10
    inputs) and a **doc-level fuzz** (6,000 patterns × 8 multi-line buffers
  with
    empty lines + trailing newlines) proving the single-pass scan
  byte-identical
    to the per-line path. **Zero divergences** in `zig build test`. The fuzzes
    earned their keep — they caught the Pike `.skip` bug above and a last-byte
    `trans_fin` edge in the single-pass scanner during development.
  - **Measured** (`bench/regex_headtohead.sh` + direct warm-cache query timing,
    17.1k files / 126 MiB, min-of-runs to filter shared-box load): the
    no-prefilter scan tail dropped **7–21%** of query time and now sits **at
  rg's
    own scan floor** (~248–264 ms vs rg ~250–280 ms) — the residual gap is
  purely
    gist's ~27 ms cold-load that rg never pays. The former clear losers flipped
  to
    ties: `[a-z]+_[a-z]+_[a-z]+` 326→258 ms query (355→285 ms total vs rg 278),
    `panic|0x` 313→248 ms. Prefilterable tiers still win outright
  (`pgxpool\.\w+`
    ~3×, `^func\s` ~2.5×, alternations 1.4–1.65×) because the trigram prefilter
    reads a fraction of the corpus while rg re-walks all of it.
  (see also: gist)
- **Line anchors `^` / `$`** (`src/regex_syntax.zig`, `src/regex.zig`):
  zero-width
  assertions resolved during the Pike epsilon-closure from per-position
  (start, end)-of-line flags — `^`/`$` add no NFA bytes, so an anchored
  pattern's
  required literal is unchanged (`^func` ⇒ prefilter "func"). `\^`/`\$` stay
  literal. Fixed `docMatch` to grep's line model (a trailing `\n` *terminates*
  the last line rather than seeding a phantom empty one — otherwise `^$`/`$`
  over-match every newline-terminated file vs rg). Proven byte-identical to
  `rg (?-u)`: the oracle's 52-regex battery now includes 8 anchored shapes +
  `^{0}`/`{0}$`/`^\s*{0}` templates (0 FN / 0 FP), and the cold CLI path
  matches
  rg on `^$` (15,572 files with a real blank line), `^func\s`, `\)$`, `;$`,
  `^}$`.
- **Measured competitive standing (17,112 files · 126.5 MiB, shared dev box,
  hyperfine geomeans):** WARM resident gist beats every scanner
  **1,028×–5,992×**
  (15/15; up to 270,000× on a miss) — uncontested, the indexed rivals have no
  resident CLI. COLD one-shot gist beats every *unindexed* tool **1.9×–9.2×**
  (10–11/11). COLD regex gist lands **≈ csearch (0.9×, 14/22 wins) and faster
  than
  zoekt (1.4×, 13/22)**, **≥ rg (1.3×)** — the old dense floor `\w{3,8}` now
  beats
  both indexed rivals. The **one honest loss**: COLD *literal* one-shot vs the
  indexed rivals (csearch 0.3×, zoekt 0.5× geomean), because gist deserializes
  a
  177 MiB index (30 ms) where csearch mmaps 28 MiB, and runs a corpus-wide T3
  freshness stat-walk they skip — both causes recorded as the next rung, not
  hidden. gist still beats csearch on the dense / 2-byte needles (`})` 1.5×).
- **Multi-literal alternation prefilter** (`src/regex_syntax.zig`
  `requiredAny`,
  `src/trigram.zig` `Index.queryAny`): an alternation has no single mandatory
  literal, so it used to full-scan. Now a cover set is extracted — a set of ≥3
  B
  literals such that *every* match contains one (`foo|bar|baz` ⇒ {foo, bar,
  baz})
  — and the candidate set is the UNION of each literal's trigram candidates.
  Sound
  by construction: the union is a superset of every match, so no true match is
  dropped; the existing verify pass still gates false positives. It's admitted
  only when **every** branch yields a ≥3 B literal (a `<3` or unfilterable
  branch
  ⇒ no cover ⇒ full scan, e.g. `panic|0x`), a single mandatory literal still
  wins
  over a union, and the set is capped at 32 branches. Wired through the cold
  CLI
  (`fresh.candidates` now takes a filter *set*) and the oracle. Proven
  byte-identical to `rg (?-u)`: the battery adds `return|continue|break`,
  `func|struct|enum`, `TODO|FIXME|XXX`, `import\s+\(|^package`,
  `context|errors`,
  `panic|0x` + the `({0}|{1})` template (0 FN / 0 FP over 17,028 files); the
  cold
  CLI on `panic|throttle|leaky` reads only 1,071/17,029 files (union prefilter,
  not a scan) and returns rg's exact 694-file set.
- **No-prefilter regex → direct live-tree scan** (`bench/scan.zig`, dispatched
  from `bench/cli.zig` `runRegex`). A regex with no usable trigram prefilter —
  no
  ≥3 B required literal and no all-≥3 alternation cover (`[0-9]{4}`,
  `panic|0x`,
  `[a-f0-9]{2,}`, `\w{3,8}`, `[a-z]+_[a-z]+_[a-z]+`) — makes the index filter
  *nothing*: every doc is a candidate. The cold index path then paid **two**
  full
  tree traversals — a corpus-wide T3 freshness `statFile` walk **and** a
  candidate
  read of all ~17 k files — where rg pays one (walk + read). The tier is
  IO-bound
  (profiled: System time dwarfs the automaton's User time — the scan engine was
  never the bottleneck, the redundant traversal was), and the freshness
  stat-walk
  is the dominant tax: measured **255 ms → 187 ms** (~67 ms) by toggling the
  anchor on a `panic|0x` full scan. So for that case gist now **skips the index
  entirely** and walks the LIVE tree once, reading + DFA-scanning each file
  like
  rg. This is strictly **more** correct than the index+freshness path — it
  reads
  current bytes, sees files created since the build, honors deletions, with no
  staleness window — so no freshness walk is needed at all. Same skip-dirs /
  NUL-binary / 4 MiB cap as the indexed corpus.
  - **Fused work-stealing pipeline (a tie was never the floor).** The first cut
    was phased — a parallel walk to collect every path, *then* a sharded
  read+scan
    — and profiling (process-internal clock, build-wrapper-independent) caught
  it
    leaking two ways: a **~63 ms walk barrier** overlapping nothing, and **~169
  ms
    of straggler idle** (static file-count sharding stranded the big files on
  one
    core — fastest core done in 158 ms, slowest 327 ms). Rewritten so walkers
    stream discovered paths into a shared MPMC queue while a core-sized pool
  steals
    files in batches and reads+scans *as the walk still runs*: **worker-span
    Δ 169 ms → 2.5 ms** (near-perfect byte-balance) and the walk folded under
  the
    scan — **~1.7× internal speedup**. Oversubscription was *measured, not
    assumed*: warm-cache the tier is CPU/syscall-bound (~190 µs/file
    open+read+close, the DFA pass a rounding error), so ×1 worker/logical-core
  beat
    ×2/×3 on both wall-clock and balance.
  - **Correctness:** byte-identical to `rg (?-u) -l` over the same logical
  corpus
    (rg run with `--no-ignore --hidden` + gist's dir-excludes so both scan the
    same file set): **0 FN / 0 FP** across `[0-9]{4}`, `panic|0x`,
  `[a-f0-9]{2,}`,
    `[0-9a-f]{8}-…`, `[a-z]+_[a-z]+_[a-z]+`, `\w{3,8}`, `x{2,4}` — the only
    residual diffs being 3 multi-MB data blobs (`train_text.txt` 2.2 GB,
    `val_text.txt` 22 MB) whose first match sits past the **pre-existing 4 MiB
    `per_file_cap`** the indexed corpus caps identically.
  - **Measured** (ReleaseFast, release-vs-release vs `rg (?-u) -l` on its
  fastest
    gitignore-respecting path, min-of-N back-to-back, shared dev box; gist
  scans a
    gitignore-*superset*, so it wins while reading **more** bytes): `\w{3,8}`
    **1.3–3.0×** · `[a-f0-9]{2,}` **1.3–1.4×** · `[a-z]+_[a-z]+_[a-z]+`
  **1.2×** ·
    `[0-9]{4}` **1.1×** · `panic|0x` **win-or-tie (~1.0×)** — **0 FN / 0 FP**
  vs rg
    throughout (one `[0-9]{4}` `rg_only` file: a >4 MiB blob past the shared
    `per_file_cap`). gist wins or ties all five. (The earlier Debug-build
  numbers
    understated gist — release-vs-release is the honest race.)
  - **Permanent regression** (`bench/scan_regress.sh`): the scan path is a
    different code path than the index path `bench/equality.sh` proves, so it
  gets
    its own permanent oracle — asserts each pattern still **routes** to the
  scan
    path, diffs gist's scan set vs `rg (?-u)` over the identical corpus and
  **exits
    1 on any FN/FP** (cap-skips excepted by size), and prints the worker-span Δ
  as a
    **straggler canary** so a future regression of the work-stealing balance
  fails
    loudly. Keeps the win honest and the floor measured for the next
  exploration.
  - **Why the verdict is structural (off the data, not vibes):** gist's time is
    **pattern-independent** (~240 ms across all five — it sits at the per-file
    syscall floor, the DFA being a single early-exiting pass), whereas rg's
  swings
    **2–373 ms with match density** (floor + per-byte scan). gist therefore
  wins
    every scan-expensive pattern and ties only the cheapest sparse-literal
    (`panic|0x`), where rg's scan is near-free and both rest on the same read
  floor.
  - **Named next rung (recorded, not hidden):** beating rg on the
  sparse-literal
    tie means dropping *below* the read floor — batch the per-file
    `openat`+`read`+`close` (io_uring / `readv`), since at ~190 µs/file the
    syscalls, not the scanned bytes, are the wall. A prefilter can't help a
  tier
    already at its IO floor.
  (see also: gist)
- **Regex engine gains AST-level ASCII case-folding, so `-i` / `(?i)` matches
  caseless across every backend** (`src/regex/syntax.zig`). Case-insensitivity
  used
  to be handled ad-hoc at the grep layer; it now lives in the engine where the
  NFA, lazy DFA, and Pike capture VM all inherit it from one place.

  - **`ByteSet.foldCase`** admits the opposite-case twin of every letter
  present in
    a consuming class (`a`⇄`A`), and **`foldCaseAst`** walks the AST applying
  it to
    every class (zero-width assertions and structure untouched, `capture` nodes
    recursed transparently). It's idempotent, so re-visiting a shared `{n,m}`
  atom
    in the DAG is harmless.
  - **Trigram soundness preserved**: a folded literal byte becomes a 2-member
  set,
    which the `only`/`required` literal extraction reports as non-singleton —
  so a
    caseless pattern yields an empty required-literal and the query soundly
  falls
    back to a full scan (gist's trigram index is case-sensitive). No false
    negatives from a case-folded search.

  Proven against real ripgrep as the oracle: `-i` cases (ASCII caseless literal
  and
  class) diff to **0 bytes** vs `rg`, with the engine's existing differential
  and
  prefilter-soundness tests still green.
- **Regex parser expands the control + hex escape set (`\f \v \a \0 \xNN
  \x{H..H}`)** (`src/regex/syntax.zig`). ripgrep patterns reach for these
  byte escapes routinely; gist previously only decoded `\t \n \r`, so a legal
  pattern like `\x7F` or `\0` was mis-parsed as a literal `x`/`0`.

  - **Control escapes**: `\f`→`0x0C`, `\v`→`0x0B`, `\a`→`0x07`, `\0`→NUL (rg's
    `\0`), alongside the existing `\t \n \r`.
  - **Hex escapes**: `\xNN` (two hex digits) and the braced codepoint form
    `\x{H..H}` (`hexByte`/`hexVal`). gist is a byte engine, so a value `> 0xFF`
    is a hard `BadPattern` (rg's `(?-u)` byte-mode behavior) rather than a
  silent
    truncation — fail-loud beats a wrong match.

  Proven against real ripgrep as the oracle: the escape cases (`\x` byte,
  braced
  codepoint, `\0`/control) diff to **0 bytes** vs `rg`; over-`0xFF` `\x{…}`
  errors
  loud as designed. The regex engine's differential tests stay green.
- **Regex scan accelerators** (`src/regex.zig`, split into
  `src/regex_test.zig`):
  the verify-time Pike search that used to re-seed the start thread at *every*
  byte — wasted closure work — now compiles three position invariants and
  dispatches `lineMatch` to the cheapest sound strategy (semantics unchanged,
  proven by the rg oracle + an overlapping-start unit battery):
  - **Anchored fast path** — `startsAnchored` (every alternation branch begins
    with `^`) seeds only at line position 0 and bails the instant the thread
  list
    drains, so a non-matching line for `^}$` / `^$` is ~O(1) instead of O(len).
  - **First-byte skip** — `analyzeFirst` walks the NFA for the byte set that
  can
    *begin* a match mid-line (traversing `^`, blocking `$`; the
  over-approximation
    is sound — a mid-line seed of an `^`-only branch dies on the failed
  assertion).
    When the thread list empties the scanner jumps to the next viable start
    instead of stepping dead bytes: SIMD `indexOfScalar` for a singleton set
    (`;$`, `0x…`), a **SIMD range scan** (`lo ≤ b ≤ hi` per `@Vector` window,
  OR'd
    over ≤6 contiguous ranges) for `[0-9]{4}` / `[a-f0-9]{2,}` / `\w{3,8}`,
  else a
    scalar byteset probe. The earlier blocking-`^` version dropped 408
  `^package`
    matches in `import\s+\(|^package` — caught by the oracle, now a regression
  test.
  - **Plain path** — unchanged re-seed-every-byte loop for an empty first set
    (a bare `$`), which the skip can't drive.
  Measured cold head-to-head vs `rg (?-u) -l` at its fastest
  gitignore-respecting
  walk (`bench/regex_headtohead.sh`, hyperfine p-mean, warm cache, 17.1k
  files):
  gist wins **every prefilterable tier robustly** (stable run-to-run) —
  `pgxpool\.\w+` **≈3.0×**, `^func\s` **≈2.5×**, `func\s+\w+\(` **≈1.9×**,
  `func|struct|enum`/`error|panic|fatal` **≈1.5–1.65×**,
  `return|continue|break`
  **≈1.5×** — because the prefilter reads a fraction of the corpus while rg
  re-walks all of it. The **no-literal full-scan tail oscillates around
  parity**
  (≈0.8–1.1×, noise-dominated): with no prefilter for *either* tool both read
  the
  whole 126 MiB, so it's a straight scan race sensitive to the shared dev box's
  load. The skip turned the old clear losses (`^}$` 0.54×, `;$` 0.77×) into
  ties.   The hard floor is `\w{3,8}` — dense matching where `\w` covers most
  bytes
  so the skip never engages and it's Pike-VM-per-byte vs rg's O(1)/byte lazy
  DFA;
  closing it is the identified next rung (a lazy DFA / bit-parallel NFA step).
  (see also: gist)
- **Sub-trigram literals → the same live-tree scan** (`bench/scan.zig`
  generalized to verify a literal via `simd.contains` as well as a regex via
  `docMatch`; `bench/cli.zig` `runQuery` routes `needle.len < 3` there). A `<3
  B`
  literal (`})`, `=>`) has no trigram filter, so the index path seeded every
  doc
  **and** ran the corpus-wide freshness `statFile` walk on top of the read —
  the
  same two-traversals-vs-rg's-one tax the no-prefilter *regex* path already
  escaped. Short literals now skip the index and walk the live tree once
  through
  the proven work-stealing pipeline. **Correctness:** the literal scan is
  byte-identical to the trusted DFA scan over the identical tree (`} )` literal
  vs
  `/\}\)/` regex → same 5,610-file set, 0 diff), and `scan_regress.sh` stays
  green
  (0 FN / 0 FP). The ≥ 3 B indexed path is untouched (`pgxpool` still reads
  409/17,513 files, ~1.7 ms cold-load).
- **T0 trigram candidate index** (`src/trigram.zig`): allocation-light,
  container-API-free positional-trigram inverted index over a fixed document
  set. `Index.build` + `Index.queryLiteral` (sound superset of literal matches
  via posting-list AND), queried by hand-rolled binary search. Filter semantics
  (false positives expected, zero false negatives for literals ≥ 3 bytes) and
  the `NeedleTooShort` fallback contract are covered by unit tests.
- **T1 persistence** (`src/trigram.zig`): `serializedSize` / `writeInto` /
  `fromBytes` — IO-free native-endian local-cache serialization (the harness
  does the file IO; the kernel stays filesystem-agnostic). A session builds the
  index once (~6.4s) and warm-starts from disk in ~28ms (227× faster).
  Round-trip +
  malformed-blob-rejection tests added.
- **T1 rarest-first query** (`src/trigram.zig`): `queryLiteral` now resolves
  every trigram's posting range up front, seeds the candidate set from the
  *rarest* trigram, and intersects outward (AND is commutative, so results are
  identical — the work is just bounded by the rarest gram instead of the
  lexicographically-first one). Collapsed the `context.Context` tail from
  ~530µs
  to ~9µs at libs scale.
- **T2 regex tier** (`src/regex.zig`): a linear-time **Thompson NFA** over
  bytes
  (RE2/ripgrep philosophy — no backtracking, no catastrophic blowup) with a
  recursive-descent parser for literals, `.`, `[...]`/`[^...]` ranges, `* + ?`,
  `|`, `()`, and `\d \w \s \D \W \S \t \n \r` + metachar escapes. Includes
  sound
  required-literal extraction (a conservative slice of Cox's regexp→trigram
  analysis) so a regex reuses the T0 prefilter, falling back to a full scan
  only
  when no literal is mandatory. Unit-tested incl. the `(a+)+` pathological
  case.
- **`-g`/`--glob` supports `{a,b,c}` brace alternation** (`bench/rgargs.zig`).
  ripgrep's glob dialect expands `{…}` groups; gist treated the braces
  literally, so
  `--glob '*.{js,py,go}'` matched nothing.

  - **`braceExpand`** lowers a glob into the cartesian product of every brace
  group
    (nesting-aware, unbalanced `{` left literal) at registration time, so
    `*.{js,py}` becomes the include set `*.js`, `*.py` and
    `!{.git,node_modules}/**` becomes the excludes `!.git/**`,
  `!node_modules/**`.
    `addGlob` expands, then routes each variant through `addGlobOne` (the prior
    include/exclude/iglob logic) — one glob dialect across `-g`, `--iglob`, and
    `--type-add`.

  Proven against real ripgrep as the oracle: `r391` (a real editor's
  `!{.git,node_modules,plugged}/**` + `*.{js,json,…,py,…}` glob combo) now
  diffs to
  **0 bytes** vs `rg`.
- **`grep` accepts the reflexive ripgrep surface an agent's muscle memory
  types**
  (`bench/grepargs.zig`, extracted from `bench/lines.zig`;
  `bench/pathfilter.zig`).
  Found by dogfooding gist _as the agent_ against `rg` on real repo questions:
  the
  goal is to _never reach for ripgrep_, but three reflexive invocations still
  broke
  — one of them silently, the worst failure mode. All three are closed,
  byte-exact
  vs `rg` (9/9 head-to-head, `.local/gist-dogfood/prove.sh`):

  - **Positional PATH args now scope the search** — `grep WalletService
  services/`
    used to search the _whole repo_ while the agent believed it scoped (a
    wrong-but-confident result). Every non-flag token after the pattern is now
  a
    path root AND-ed into the `PathFilter` and **pruned before any read** —
  gist's
    structural edge, not just parity: `grep WalletService services/backend/api`
    reads **28 candidates** (vs 86 unscoped, vs rg's whole-subtree walk) and
  runs
    **1.14× faster than rg at ~⅕ the syscall time** (112 ms vs 590 ms system,
    hyperfine 15-run), output byte-identical.
  - **Bundled short flags** — `-ln`, `-in`, `-nw`, `-nC3` used to fail loud as
    "unknown flag". A `-xyz` cluster is now decomposed left-to-right; the first
    _value_ flag consumes the cluster remainder (`-nC3` ⇒ `-n -C 3`, `-tgo` ⇒
    `-t go`) or the next token.
  - **Harmless rg flags** — `-n` (line numbers, always on), `-H`, `-r`/`-R`,
    `--no-heading`, `--color[=X]`, `--with-filename` are accepted as **no-ops**
    under gist's fixed `path:line:text` model (they used to fail loud); `-N` /
    `--no-line-number` drops the line column for real, and `-S` /
  `--smart-case`
    folds iff the pattern carries no uppercase (rg's rule). Every existing flag
    also gained its rg **long spelling** (`--ignore-case`, `--context=N`,
    `--type=<lang>`, `--glob=<glob>`, `--max-count=N`, …).

  Fail-loud is preserved for genuinely unknown flags (a silent empty result is
  the
  worst agent failure) — the diagnostic now prints the full supported surface.
  The
  parser moved to its own module so `lines.zig` (line emit/verify) drops from
  479 →
  344 lines and the larger compatibility table lives on its own (both under the
  500-line shape cap). New adversarial tests (`bench/grepargs_test.zig`, 12
  cases)
  pin bundling, no-ops, long-flag `=`/next-token values, smart-case, `-e`/`--`
  leading-dash safety, and the fail-loud contract; `bench/pathfilter_test.zig`
  gains positional-root coverage (dir-prefix `/`-boundary, exact file, `.`
  whole-corpus, `normalizeRoot`). The `gist ≡ rg` set oracle is unchanged.
- **`grep` closes three reflexive-invocation gaps found by dogfooding gist _as
  the
  agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`,
  `bench/pathfilter.zig`). Racing the two tools on real repo questions surfaced
  one
  silent-wrong landmine, one fail-loud on a legal pattern, and a robustness win
  rg
  lacks — each of which broke a call an agent's muscle memory actually types:

  - **`-r` / `--replace` was a silent-wrong landmine — now a real value flag.**
  rg's
    `-r` _consumes_ the replacement, but gist had it mis-listed among the
  boolean
    no-ops, so `grep -r X pat` parsed `X` as the pattern and `pat` as a path
  root — a
    wrong-but-confident empty result (the worst agent failure). It now stores
    `opts.replace` and rewrites each match before emit: `$0`/`${0}`/`$&` expand
  to
    the whole match, `$$` is a literal `$`. A capture-group ref (`$1`, `${2}`)
  is
    rejected **at parse time** — gist's span engine tracks the whole-match
  extent,
    not per-group captures, so failing loud beats a silently-dropped
  substitution.
    Proven byte-identical to `rg -o -r`/`rg -r` over the shared `-t go` corpus.
  - **Leading inline flag groups `(?i)` / `(?-u)` / `(?m)` are now honored.**
  An agent
    pastes rg patterns carrying a global flag group reflexively; gist used to
  reject
    the whole (legal-to-rg) pattern. Now `i`→ASCII caseless
  (`(?i)sessionstore` is
    byte-identical to `-i`), `m`/`u`/`U`/any `-…` form → no-op (gist is
  per-line,
    byte-oriented — exactly rg `(?-u)`), while `s` (dotall across newlines) and
  `x`
    (extended) still fail **loud** rather than silently mismatch. `-F` keeps
  `(?i)`
    a literal; a non-capturing `(?:…)`/lookahead `(?=…)` is left for the
  compiler.
  - **`-t tsx/jsx/vue/svelte/rego/mdc/cedar` resolve.** Convenience rows for
  types an
    agent types that even `rg` lacks (`tsx`/`jsx`) or that are repo-native
  (`rego`,
    Cursor `.mdc`, Cedar policy), so a reflexive `-t tsx useState` scopes
  instead of
    erroring.

  Also documented but _not_ a gist change — the decisive reason to prefer gist
  in an
  agent loop: in a harness where stdin is a non-tty pipe (how Cursor/Claude
  Code/
  Codex spawn shells), a bare `rg PATTERN` with no path arg **blocks forever
  reading
  stdin**; gist always searches its indexed roots and never has this failure
  mode
  (`rg PATTERN </dev/null` returns instantly with the same result).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves 0 FN / 0 FP
  (80
  literals + 94 regexes), the parser carries 4 new adversarial tests (value
  consumption, inline-flag map, `-F` literal, group-ref reject), and all five
  new
  behaviors diff to **0 lines** vs `rg` on the shared scope.
- **`grep` gains `--files` (file discovery) and `-o`/`--only-matching` (span
  extraction)** — the two reflexive ripgrep invocations dogfooding surfaced as
  the
  next holes in the "never reach for `rg`" goal. Both fail-loud gaps before
  this
  (`unknown flag`), so an agent's `rg --files -g …` / `rg -o …` muscle memory
  hit a
  wall mid-loop.

  - **`--files [PATH…]`** lists every corpus file the `-t`/`-g`/PATH filter
  admits
    — and does it with **zero file reads and zero tree walk**. gist already
  holds
    the whole path list in the mmap'd index, so discovery is a pure in-memory
    filter + sort where `rg --files` must walk the entire tree. On this repo
  that's
    the difference between an instant answer and a walk that, from the
  _uncurated_
    root, stalls on the 106 GB of build/vendor mass gist's corpus policy
  already
    excludes (measured: `rg` content-search from repo root **hangs >20 s**, `rg
  --files` 93 ms; gist projects the index in a few ms). Read-your-own-writes is
    preserved — the freshness overlay folds in files created since the build (a
    stat-only walk, no reads) so a coworker's just-written file still appears;
  a
    file _deleted_ since the last `index` may still list (no read to verify it
  away)
    and self-heals on rebuild, the same tolerated false-positive the trigram
  filter
    carries. The projection is intentionally the curated code set: no build
  caches
    (`.zig-cache/`, `dist-types/`, `.local/`), no binaries, no >4 MiB blobs —
  arguably
    a _better_ discovery list for an agent than rg's raw walk.

  - **`-o`/`--only-matching`** emits each non-overlapping match's TEXT alone
  (not
    the whole line), one `path:line:text` row per match — extraction of idents,
    symbols, URLs, hex, etc. The DFA is match/no-match only, so spans run the
  Pike
    VM with a per-state start-offset side-channel added to the ε-closure
  (`starts`
    in `Closure`, null on the hot boolean path — no cost to
  `lineMatch`/`docMatch`).
    Semantics are rg's `(?-u)` exactly: **leftmost start, then the
  highest-priority
    thread wins the end** — earlier alternation branches and greedy quantifiers
    extend maximally (empirically fixed against `rg -o`: `a|ab`→`a`,
  `a+`→greedy,
    `[0-9]{2,}`→longest run). After a match at `[s,e)` the next search resumes
  at
    `e` (non-overlapping); a zero-width match steps one byte so a nullable
  pattern
    can't loop.

  **Proof (byte-exact vs `rg -o` on the shared corpus):** an 11-pattern
  differential battery (`func \w+`, `[A-Z]\w+Error`, `return|continue|break`,
  `\bfunc\b`, `[a-z]+[A-Z]\w+`, `a|ab`, `[0-9]{2,}`, …) over
  `services/backend/gateway`
  diffs to **0 lines** against `rg -o -n --no-heading --no-ignore --hidden
  --no-unicode` (`.local/gist-dogfood/o_battery.sh`); every residual divergence
  across the wider tree is a `.gitignore`/hidden/`isSkipDir` file — gist's
  documented corpus policy, not a match bug. Permanent regression coverage:
  `matchSpan` leftmost-first/greedy/anchor/boundary cases in `core_test.zig`,
  and
  `-o`/`--files` argv parsing (bundling, pattern-optional, roots) in
  `grepargs_test.zig`.
- **`grep` gains the agent's full ripgrep flag surface** (`bench/lines.zig`,
  `bench/pathfilter.zig`). Found by dogfooding gist _as the agent_, racing
  every
  query against `rg`: the three flags an agent reaches for after `-n` were
  missing,
  and an unknown flag was silently swallowed as the pattern — the worst failure
  mode (a wrong-but-confident empty result). Now:

  - **`-A/-B/-C N` context lines** — read the code _around_ a hit without a
  second
    file round-trip (the #1 affordance after `-n`). Byte-exact `:`/`-`/`--`
  framing:
    a 17-line `-C2` block and an asymmetric `-A1 -B1` block both diff to **0
  lines**
    against `rg -n --no-heading -C`, group separators and all.
  - **`-t <lang>` / `-g <glob>` path scoping** (`pathfilter.zig`) — confine to
  one
    language or subtree. The type table is **codebase-agnostic** (~75 languages
  with
    rg-compatible names — `java kotlin ruby php c cpp cs haskell elixir
  terraform
  dockerfile …`, not just the monorepo's seven), so `-t <name>` accepts the
  same
    name an agent already types at rg, and a row may carry a bare filename
    (`Makefile`, `Dockerfile`, `go.mod`) as well as an extension. This is also
  the
    one place gist _beats_ rg structurally instead of merely matching it: rg
  applies
    the filter while walking the whole tree, but gist already holds the path
  list,
    so it **prunes candidate ids before touching disk**. `-t go pgxpool.Pool`
  reads 234 of 18 608 files and runs **1.44× faster
    than `rg -t go`** (55 ms vs 79 ms, hyperfine 20-run, byte-identical
  output); the
    pre-fix `-t go` swallowed the flag and degenerated to reading all 18 608
  (459 ms).
    Globs are gitignore/rg-shaped (`*` per-segment, `**` across `/`, `?`,
  `[a-z]`
    classes, `!`-exclude), basename-matched when slash-free.
  - **`-w` word-boundary** (wraps `\b(…)\b`), **`-F` fixed-string** (escapes
  regex
    metachars), **`-l` files-with-matches**, **`-c` per-file count**, **`-v`
  invert**
    (seeds all docs — an inverted match can occur in a file lacking the
  literal).
  - **Fail-loud parsing** — an unrecognized `-x` now errors with the
  supported-flag
    list (use `-e <pat>` or `-- <pat>` for a leading-dash literal) instead of
    searching for it.

  Correctness is unchanged and re-proven: the new `pathfilter` glob matcher
  carries
  its own adversarial tests (segment vs `/` boundaries, `**` zero-dir, class
  negation, pathological star backtracking, exclude veto); a 7-feature
  line-output
  battery (`-w`, `-F`, `^`-anchor, `$`-eol, alternation, class, counted) diffs
  to
  **0 lines** vs `rg` on the shared scope; and the `gist ≡ rg` set oracle still
  proves 0 false negatives / 0 false positives. The grep line loop also adopts
  rg's
  `\n`-terminates semantics (a trailing newline yields no phantom empty final
  line),
  so `$`/`^$` match exactly as rg does. Path scoping respects the same
  documented
  corpus policy as the rest of gist (skips `vendor`/`dist-types`/build output)
  — the
  only residual deltas vs a raw `rg` path-arg run, all in skipped subtrees.
- **`rg --json` emits ripgrep's JSON Lines record stream — was a fail-loud
  gap**
  (`bench/rgjson.zig` (new), `bench/rgcompat.zig`, `bench/rgemit.zig`,
  `bench/rgsuite/run.py`). `--json` is how tools consume ripgrep structurally,
  so
  the drop-in has to speak it, not decline it.

  - **Exact message sequence** (`rgjson.zig`): one JSON object per line — a
  `begin`
    per matched file, a `match`/`context` per emitted line with byte-accurate
    `submatches` (and, under `-r`, per-match `replacement`), an `end` carrying
  that
    file's stats, then a trailing `summary`. It rides the _one_ regex engine
    (`matchSpan` for spans, the capture VM for `-r`) and reuses
  `rgemit.expandInto`
    for template expansion, so there's no second matcher or replacer to drift.
  - **`-A/-B/-C` context, `-v` invert, `-m` cap, `--crlf`** are all reflected
  in the
    record stream and the aggregated `stats` (`matches`, `matched_lines`,
    `searches`, `bytes_searched`); `--quiet` still tallies stats while
  suppressing
    the record body.
  - **Deterministic-only fields are real; wall-clock/printer-internal ones are
    normalized.** `elapsed`/`elapsed_total`/`bytes_printed` are inherently
    non-reproducible, so both sides emit placeholders that `rgsuite/run.py`
    normalizes (mirroring what it already does for `--stats` seconds); every
    correctness field is emitted for real.
  - **Strings use rg's escaping** — `\"` `\\`, `\n`/`\r`/`\t` short forms,
  other C0
    as `\u00XX` (all harness fixtures are UTF-8).

  Proven against real ripgrep as the oracle: the `--json` cases diff to **0
  bytes**
  after the shared timing/`bytes_printed` normalization, and `--json` is
  removed
  from the fail-loud deferral list.
  (see also: gist)
- **`rg --type-add` defines and composes custom file types**
  (`bench/rgargs.zig`).
  The type surface already resolved built-in names (`-t go`); ripgrep also lets
  a
  caller _mint_ a type on the command line, and its tests exercise both forms —
  so
  the parser now accepts them instead of erroring on an unknown type.

  - **`--type-add 'name:glob'`** registers a user type from one or more globs
    (`--type-add web:*.html --type-add web:*.css`, accumulated in order),
  usable
    immediately via `-t name`/`-T name`. Bare extensions are lifted to `*.ext`.
  - **`--type-add 'name:include:t1,t2'`** composes an existing set of types
  into a
    new alias, resolving each member (custom-first, then the built-in table)
    recursively.
  - **Resolution order fixed**: `-t <name>` checks `--type-add` definitions
  before
    the built-in `pathfilter` table, so a redefinition wins. (Along the way
  this
    fixed a Zig control-flow bug where an `else die` bound to a `for`'s `else`
    clause mis-reported valid built-in types like `py` as "unrecognized".)

  Proven against real ripgrep as the oracle: the `--type-add` single-glob and
  `:include:` composition cases (`file_type_add`, `file_type_add_compose`) diff
  to
  **0 bytes** vs `rg`. `--type-list` itself stays a documented NA (gist's type
  table
  is a distinct catalogue, not rg's exact list).
- **`rg` auto-detects a UTF-16 BOM and transcodes to UTF-8**
  (`bench/rgcompat.zig`).
  ripgrep's default (`--encoding auto`) sniffs a byte-order mark and decodes;
  gist
  read raw bytes, so a UTF-16 file's (UTF-8) pattern never matched and its NUL
  bytes tripped binary detection into skipping the file entirely.

  - **`decodeBom`** runs once per file at ingest: a UTF-8 BOM is stripped, a
    UTF-16 LE (`FF FE`) / BE (`FE FF`) BOM transcodes the whole file to UTF-8
  via
    **`utf16ToUtf8`** (surrogate pairs resolved; a lone/invalid surrogate or a
    trailing odd byte becomes U+FFFD, matching rust-encoding's lossy decode).
  It's
    applied at every read site (walk, symlink target, explicit path arg), so
  the
    transcoded UTF-8 flows through matching _and_ binary detection uniformly.
  - **Scope stays honest**: only _BOM-marked_ UTF-16 is auto-detected. BOM-less
    UTF-16 and other charsets still require explicit `-E`/`--encoding`, which
    remains a fail-loud NA (gist is a UTF-8/byte engine).

  Proven against real ripgrep as the oracle: `f1_utf16_auto` (a BOM'd UTF-16
  file
  searched for a Cyrillic literal) now diffs to **0 bytes** vs `rg`.
- **`rg` gains `--color` support and match highlighting — the one CLI feature
  demo'd against real ripgrep that gist visibly lacked** (`color.zig` (new),
  `output.zig`, `run.zig`, `args.zig`, `cli/main.zig`). `--color=always`/`ansi`
  previously failed loud (`unsupported by design — gist emits no ANSI`); the
  default `auto` mode silently emitted nothing. Both are now real, resolved
  once
  per run in the new `color.zig`.

  - **`--color auto|always|never|ansi`**, matching ripgrep's own resolution
    rules: `auto` (the default) colorizes iff stdout is a real terminal *and*
    the environment doesn't opt out (`NO_COLOR` — any value,
  <https://no-color.org>
    — or an absent/`dumb` `TERM`) *and* no flag that implies plain text
    (`--json`, `--vimgrep`) is active; `always`/`ansi` force it on regardless
  of
    destination or environment (rg's own override rule — an explicit request
    beats `NO_COLOR`); `never` forces it off.
  - **Match highlighting tuned to beat ripgrep's own default on legibility, not
    just parity**: rg's `fg:red,style:bold` is the "normal" red (SGR `31`),
    which reads muddy against a lot of terminal palettes. gist paints a match
    bold + underlined *bright* red (`1;4;91`) — still coloring the letters, no
    filled background block — so it reads at a glance without inventing a new
    visual language. Path (bold magenta) and line-number (green) keep rg's own
    hues; separators are dimmed one notch so the match is the only thing
    competing for the eye. Wired through every text-emitting path: the default
    `path:line:text` frame, `-o`/`--only-matching`, `--vimgrep`, `--passthru`,
    and `-w` word-bounded spans (an `-r`/`--replace` line is left unpainted —
    the substituted text isn't "the match" any more).

  **Proof:** piped/non-tty output — the common agent-loop case, and the whole
  point of the earlier stdin-parity work — is untouched: `color.enabled`
  resolves to `false` whenever stdout isn't a real terminal, so `make | gist
  "pat"` stays byte-identical to `make | rg "pat"`. `--color=always` verified
  against real `rg --color=always` on the same fixture (`-n`, `-o`, `-w`): the
  path/line-number/match ANSI runs decode correctly and non-tty parity holds
  with color forced off.
- **`rg` gains a capture-group engine — `-r $1`/named-group replacement and
  JSON
  submatches, no longer a fail-loud gap** (`src/regex/captures.zig` (new),
  `src/regex/syntax.zig`, `src/regex/analysis.zig`, `src/regex/compile.zig`,
  `src/root.zig`, `bench/rgemit.zig`). The prior `-r` handled only whole-match
  `$0`/`$$` and _rejected_ a group ref at parse time; ripgrep's own test suite
  leans on `$1`/`${name}` substitution, so the drop-in couldn't reach those
  cases.

  - **Group parsing** (`syntax.zig`): `(…)` and named `(?P<n>…)`/`(?<n>…)` now
    capture (1-based index in opening-paren order, names recorded only when a
  sink
    is given so the hot main-engine parse allocates nothing); `(?:…)` is
    non-capturing; lookaround (`(?=`,`(?!`,`(?<=`,`(?<!`) fails loud as
    `BadPattern` (gist's linear engine can't backtrack).
  - **A dedicated capture VM** (`captures.zig`) compiles the same `syntax.zig`
  AST
    into a Pike VM that threads per-group slot vectors, so a leftmost-first
  match
    now yields each group's `[start,end)` — without touching the hot
  boolean/span
    matcher (the new `.capture` AST node the analysis/compile/prefilter passes
    recurse through transparently, so trigram prefilters and anchoring are
    unchanged). Slot count is capped to keep the closure stack bounded.
  - **`-r` expands real templates** — `$1`, `${2}`, `$name`, `${name}`, `$0`,
    `$$` — with rust-regex `Replacer` semantics (unknown/out-of-range group →
    empty). The expander is a shared free function (`rgemit.expandInto`) so the
    text printer and the JSON stream replace identically.
  - **Two `-r` × `--max-columns` edge cases now match rg byte-for-byte.** A
    replaced over-long line reports match granularity
    (`[Omitted long line with N matches]`, and `--max-columns-preview`'s
    `[... N more matches]`) instead of the granular-less
    `[Omitted long matching line]`; and an empty match whose
    start coincides with the previous match's end is skipped (rust-regex
    `find_iter` progress rule), so `-r '${0}f'` over `.*` yields `af`, not
  `aff`.

  Proven against real ripgrep as the oracle: the `-r`/replacement and
  max-columns-granularity cases (`f129_replace`,
  `r1739_replacement_lineterm_match`,
  `f1078_max_columns_preview2`) all diff to **0 bytes** vs `rg`, and the regex
  engine's adversarial differential/prefilter tests still pass with the new
  node.
- **`rg` honors a linked git worktree's shared `info/exclude`**
  (`bench/rgignore.zig`,
  `bench/rgcompat.zig`). The ignore engine only read `.git/info/exclude` at CWD
  via
  a shallow `.git`-dir check, so searching a _worktree_ path (whose `.git` is a
  gitfile pointing elsewhere) missed the repo's excludes and surfaced ignored
  files.

  - **`Ignore.init` now takes the search's positional roots** and probes each
  for
    its own `.git`, so `rg <flags> some-repo` honors that repo's VCS ignores
  even
    when CWD isn't a repo (`anyRootRepo`).
  - **`resolveGitDir`** mirrors ripgrep's `resolve_git_commondir`: a `.git`
    directory is the git dir; a `.git` **file** is followed through `gitdir: …`
  →
    its `commondir` (relative commondir joined to the worktree git dir,
  absolute
    used as-is), and `<commondir>/info/exclude` is loaded anchored to the
  worktree
    root. `isGitRepo` was refactored onto the shared `hasDotGit` probe so a CWD
    worktree gitfile is now detected too.

  Proven against real ripgrep as the oracle:
  `r1446_respect_excludes_in_worktree`
  (a worktree whose commondir exclude ignores one file) now diffs to **0
  bytes**
  vs `rg`.
- **`rg` honors ancestor ignore files and finds the git repo by ascent**
  (`bench/rgignore.zig`). ripgrep reads `.gitignore`/`.ignore` from every
  directory
  _above_ the search root and discovers `.git` at any ancestor; gist only read
  CWD-and-below, so searching from a repo subdirectory ignored the wrong set.

  - **`gitRootDepth`** ascends from CWD looking for `.git` (dir or worktree
  file),
    replacing the CWD-only `isGitRepo` — so a search run inside `repo/sub/` now
    enables VCS ignores from `repo/`'s `.gitignore` (`no_parent_ignore_git`).
  - **`loadParents`** walks each ancestor shallow→deep (deeper wins), reading
  its
    `.gitignore` (bounded to the git root) and `.ignore`/`.rgignore` (to `/`),
    skipped under `--no-ignore-parent`. An **anchored ancestor rule is
  re-anchored**
    onto the search subtree: `readFile`/`addLine` take a `strip` prefix (CWD's
  path
    relative to that ancestor) — a rule like `/parent/*.txt` seen from
  `parent/`
    becomes `*.txt`, and a rule targeting a sibling of CWD is dropped.
  Slash-less
    ancestor rules match a basename at any depth unchanged.

  Proven against real ripgrep as the oracle: `no_parent_ignore_git`,
  `r829_2778`,
  `r3173_hidden_whitelist_only_dot`, and `f1757` (a `.ignore` above the search
  root
  excluding `target/`) now diff to **0 bytes** vs `rg`.
- **`rg` now honors the `.gitignore` boundary — the single biggest drop-in gap
  closed** (`bench/rgignore.zig` (new), `bench/rgargs.zig`,
  `bench/rgcompat.zig`).
  gist was deliberately ignore-agnostic, so any ripgrep scenario with a
  `.gitignore`/`.ignore` searched a superset and diverged. The walk now applies
  the
  same "what's tracked" filter rg does, as a proper per-directory rule model
  rather
  than a bolt-on path test.

  - **Full gitignore dialect** (`rgignore.zig`, reusing `pathfilter.globMatch`
  so
    there's one glob dialect): leading/embedded `/` anchors to the ignore
  file's
    dir, a slash-less pattern matches a basename at any depth, a trailing `/`
    restricts to directories, `!pat` re-includes, and **last matching rule
  wins**
    with deeper dirs + `.ignore`/`.rgignore`/`--ignore-file` outranking a
  shallower
    `.gitignore`. Rules accumulate as the walk descends (loaded once per dir),
  and
    an ignored directory is _pruned_ — so `/*` + `!/dir` re-includes `dir`
  while
    keeping its siblings excluded, exactly like git.
  - **Hidden-file interaction**: a `!`-whitelisted dotfile is un-hidden
  (overrides
    the default dotfile skip), and `.git` is never walked.
  - **The `--no-ignore*` / `-u` control surface is now real**, not a no-op:
    `--no-ignore`, `--no-ignore-vcs` (VCS sources only), `--no-ignore-dot`,
    `--no-ignore-exclude`, `--no-ignore-files`, `--no-require-git` (honor
    `.gitignore` outside a repo), `--ignore-file <path>` (ordered, later wins),
    `--ignore-file-case-insensitive`; `-u`→`--no-ignore`, `-uu`→`+--hidden`.
  VCS
    rules (`.gitignore`, `.git/info/exclude`) apply only inside a git repo
  unless
    `--no-require-git`.

  Proven against real ripgrep as the oracle: this converts **~30 previously
  divergent cases to byte-exact PASS** (anchoring, negation/whitelist,
  precedence,
  `--ignore-file`, `--no-ignore-vcs`, per-dir `.ignore`, hidden whitelist),
  lifting
  supported-surface parity to 98.9% with no regression elsewhere.
- Initial scaffold mirroring the conventions of its sibling C-ABI kernel: `build.zig`
  (static + dynamic libs, header install, `test` + `coverage` steps),
  `build.zig.zon`, flat C-ABI in `include/gist.h`, `src/root.zig`.
  (see also: gist)
- `gist_trigram_count` C export — the deterministic cross-language parity
  oracle.

### Changed

- **CLI collapses six competitor-shaped verbs into three real ones, on a native
  flag vocabulary with a separated legacy alias layer**
  (`src/commands/search/`,
  `src/commands/status/`, `src/commands/cli/{main,schema}.zig`). The old
  surface
  (`index` · `query` · `regex` · `rank` · `grep` · `rg`) named _which
  competitor's
  argv it aped_, not what gist does — and `query`/`regex`/`rank`/`grep` were
  four
  verbs answering one question (_what matches, and how do you want it shaped_)
  over
  one engine. The new surface says what gist actually does:

  - **`gist search <pattern> [PATH…]`** — the one search verb. Pattern is
    auto-detected literal-or-regex (a literal is its own required literal, so
  it
    rides the same trigram prefilter — no second code path). Output shape is a
    **flag, not a verb**: `--show lines` (default, the byte-exact `rg -n`
    drop-in) / `--show files` (was `query`/`regex`) / `--show count` /
    `--rank [=N]` (was `rank`, top-K default 20). The dispatcher
    (`search/run.zig`) still routes each request to its fastest backend — the
    `drivers` fast paths for `--show files`/`--rank`, the full line engine
    (`emit.zig`) for the feature flags.
  - **`gist status`** — new, read-only introspection: whether an index exists,
    file / distinct-trigram / posting counts, on-disk size, build age vs the
    freshness anchor, and corpus roots. Answers "am I ready to search fast"
    before an agent commits to a query, with zero search work.
  - **`gist index`** — unchanged, the mutating build/refresh lifecycle action.

  **Two flag sets, one behavior each.** Set B (native) is the primary,
  documented
  vocabulary — `--show`, `--rank`, `--lang`, `--glob`, `--word`, `--fixed`,
  `--ignore-case`, `--smart-case`, `--invert`, `--before/--after/--context`,
  `--limit`, `--spans`, `--replace`, `--only-matching`, `--pattern`, plus two
  genuinely new capabilities: **`--live`** (skip the index, scan the live tree
  —
  the capability `gist rg` carried, without keeping a competitor-shaped verb)
  and
  **`--json`** (structured records, the one thing rgsuite marked NA against
  `rg --json`). Set A (legacy) is every `rg`/`grep` spelling an agent's muscle
  memory types — `-A/-B/-C -i -w -F -l -c -v -o -n -N -S -m -e -t -g -r`, the
  long
  forms, short-flag bundling, the no-op set, the fail-loud set — each an
  **alias
  onto exactly one native option**, split into its own module
  (`search/compat.zig`) so the ergonomic surface reads clean.

  **Agent discovery.** `gist --schema` emits a JSON capability manifest (verbs
  →
  flags → `{native_name, type, default, legacy_aliases, description}` + exit
  codes)
  so the two-set model is machine-checkable, not just prose — the seed for
  wiring
  gist into `services/ai/tools`.

  Dead-code shake per the refactoring rule: `src/commands/grep/` and
  `src/commands/cli/drivers.zig` are **deleted**, not deprecated-and-kept;
  their
  logic lives in `search/`. The `ripgrep/` differential-parity engine stays
  wired
  but **undocumented** (dropped from `--help`/`--schema`) — it's the `rgsuite`
  441-test harness plumbing, not a public verb. Every bench script
  (`_compete.sh`, `streams.sh`, `scan_regress.sh`) and the README are rewritten
  around `search`; `bench/rgsuite/run.py` still targets the internal `rg` path,
  so
  the parity certificate is unaffected. Native + legacy parsing is guarded by
  the
  superset test suite `search/args_test.zig`.
  (see also: gist)
- **Cold / first-query win** (`bench/cli.zig`, `bench/coldquery.sh`): a
  one-shot
  CLI — `cli -- index` builds + persists the index (postings + a doc→path
  table) once; `cli -- query <needle>` is a **fresh process** that cold-loads
  the
  index (~30 ms) and reads & verifies **only the candidate files**. rg has no
  index, so every invocation re-walks the tree and reads every byte. Measured
  fresh-process via hyperfine (spawn included, warm cache): `queryLiteral`
  39ms→290ms (**7.4×**, 7 files read), `pgxpool` 47ms→274ms (**5.9×**, 399),
  `rate_limit` 46ms→293ms (**6.4×**), `func` 140ms→252ms (**1.8×**), `import`
  212ms→376ms (**1.8×**). rg now wins only the one-time build (~1.3 s) and a
  bare
  <3-byte needle (full read ⇒ tie). gist wins **every query after the first
  build — warm and cold.**
  (see also: gist)
- **Cold regex query** (`bench/cli.zig`): `cli -- regex <pattern>` runs the T2
  Thompson NFA on the cold path — prefiltered on the regex's required literal
  (sound, so no true match is dropped), `docMatch`-verified per candidate with
  a
  per-thread `Sim` over the existing parallel read fan-out (the `Regex` is
  shared
  immutably; only the `Sim` scratch is per-thread). The literal `query` path is
  unchanged (its benchmark contract is preserved). Proven e2e: 11 regex shapes
  (incl. `[a-z]+_[a-z]+` at 12,803 files and `//\s*TODO` at 16)
  **byte-identical
  to `rg (?-u) -l`** over gist's exact indexed file list, 0 FN / 0 FP.
  Refactored
  the shared cold-load / candidate-resolve / emit into `loadPersisted` /
  `candidateIds` / `emitMatches` so literal + regex share one path.
- **Parallel build + counting sort** (`src/trigram.zig`): `Index.build` now
  fans
  trigram extraction across all cores (byte-balanced contiguous doc shards,
  each
  thread filling a private region — no contention) and replaces the O(n log n)
  comparison sort over ~22.8M postings with an O(n) **counting sort** on the
  24-bit trigram key. The count is stable and the concatenated postings are
  doc-major, so each bucket lands doc-ascending — **byte-identical** to the old
  index. Small corpora keep the single-threaded comparison sort (the 64 MiB
  histogram isn't worth it below 4 MiB). **6.5 s → 1.0 s (6.4×), 124 MiB/s**;
  re-proven sound by the equality oracle on the new path. Degrades gracefully
  to
  the serial path on any spawn/alloc failure.
- **Parallel cold read** (`bench/cli.zig`): the cold path is IO-bound (read
  every
  candidate's bytes), and it was the one place a heavy cold query could lose —
  rg reads multi-threaded, gist read single-threaded. Fanned the candidate
  read+verify across one `std.Thread` per core, each shard doing **blocking
  `std.posix` reads** into a reused `per_file_cap` scratch buffer (no per-file
  alloc; same cap as the indexer ⇒ byte-identical corpus). Cold head-to-head
  now:
  `import` 212→**155 ms** (1.9×), `func` 140→**109 ms** (2.4×),
  `context.Context`
  **58 ms** (4.9×), selective queries 40–44 ms (6.6–7.5×). gist wins **every**
  cold query 1.9×–7.5×. Posix read path proven faithful: `queryLiteral` (7) and
  `pgxpool` (401) match the index-based counts exactly.
  - **Negative result (recorded, not hidden):** the first cut fanned this out
  via
    `std.Io.Group.concurrent`. Measured on the macOS io backend it was **~6×
    slower** (`pgxpool` 43→252 ms, `import` 212→1305 ms) — fiber/scheduling
    overhead dwarfed the reads and the concurrent file IO didn't parallelize.
    Raw `std.Thread` + blocking syscalls (what `search.zig` already uses) is
  the
    proven-fast path; the io event loop is bypassed for the worker reads.
- **Ranking signals are now language-agnostic** (`bench/signals.zig`, extracted
  from
  `bench/cli.zig`). The two byte-level heuristics the T4 ranker consumes — the
  **definition boost** (`definesNeedle`) and **codegen demotion**
  (`isGenerated`) —
  hardcoded only the monorepo's seven languages, so on any other codebase the
  def-boost stayed flat (a search for a Ruby/Kotlin/C# symbol never recognized
  its
  declaration) and generated files weren't demoted. Now:

  - `definesNeedle` knows the declaration keywords of the **mainstream
  ecosystem**
    (Kotlin `fun`, Elixir `defmodule`/`defp`, Perl `sub`, Scala `object`, Swift
    `protocol`/`actor`/`extension`, `record`/`namespace`/`trait`/`impl`/…
  alongside
    the original `fn`/`func`/`def`/`class`/`struct`/…), so the def-first
  ordering
    fires on any repo.
  - `isGenerated` leans first on the **universal** first-line markers
  (`@generated`,
    `Code generated`, `DO NOT EDIT`, `AUTO-GENERATED`, … — language-independent
  and
    far more reliable than any suffix list) and broadens the suffix fast-path
  across
    ecosystems (`.pb.cc`, `.pb.h`, `_pb2_grpc.py`, `.g.dart`, `.designer.cs`,
    `.min.js`, …).

  Dogfooding the extraction caught a **real latent bug**: `definesNeedle` only
  checked the identifier boundary _before_ the needle, so searching `Session`
  treated
  `type SessionStore struct` as its _definition_ (a prefix hit). It now
  requires a
  whole-word match on **both** sides. The signal still only ever reorders
  (never
  drops) a match, so it stays sound; the fix only sharpens the def-first order.
  New
  adversarial tests (`bench/signals_test.zig`) pin definition detection across
  ten
  languages, the use-vs-decl discriminators, and generated detection by suffix
  and
  by marker. Extracting the module also returns `bench/cli.zig` under the
  500-line
  shape cap (it had drifted to 554 with no `MONOLITHIC` marker).
- **SIMD substring scan** (`bench/simd.zig`): reading `std/mem.zig::findPos`
  shows `std.mem.indexOf` is SIMD only for a 1-byte needle — lengths **2–4**
  fall
  to `findPosLinear` (a naive byte loop) and 5+ to scalar Boyer-Moore-Horspool.
  Code search is dominated by 2–4 byte needles (`})`, `ctx`, `func`, `=>`,
  `::`,
  `fn`), so that naive path was the hot loss. `simd.contains` runs the memchr
  "generic SIMD": splat the needle's first + last byte, vector-compare both
  lanes
  across a V-wide window, AND the masks, and `eql`-verify only survivors.
  **Isolated single-thread full-corpus scan (125 MiB), std → SIMD MiB/s:** `})`
  2233→41051 (**18.4×**), `ctx` 2093→37735 (**18.0×**), `func` 2274→40713
  (**17.9×**), `=>` 1866→32019 (**17.2×**), `import` 6085→40757 (**6.7×**),
  `context.Context` 3560→19525 (**5.5×**) — std's ~2.2 GB/s naive path vs
  SIMD's
  ~40 GB/s. Wired into the parallel verify (`search.zig`) and the cold CLI
  (`cli.zig`). Byte-exact with `std.mem.indexOf`, proven by a 5000-case
  differential fuzz (`zig build test`, now wired) **and** the rg equality
  oracle
  (135 literals + 44 regexes, 0 FN / 0 FP, re-proven on the SIMD verify path).
- **Shape refactor**: extracted corpus loading into `bench/corpus.zig` and the
  parallel verify into `bench/search.zig`; the cold CLI lives in
  `bench/cli.zig`.
  Every file stays under the 500-line cap.
- **T3 freshness overlay** (`bench/fresh.zig`): keeps a persisted index correct
  against a working tree many agents rewrite many times a minute, without
  rebuilding and without consulting git history (the fragile part under heavy,
  overlapping, rebased commit churn). Insight: the cold query already reads &
  *verifies* every candidate against live bytes, so a stale/edited/deleted
  match
  is never a false **positive** — the only gap is a false **negative** (a file
  that now matches but wasn't a trigram candidate). So freshness only *widens*
  the candidate set with files touched since build; the existing verify does
  the
  rest. Anchor = the build's wall-clock instant (a `real` Io.Clock timestamp,
  same UTC-ns domain as file mtime); a file is fresh iff `mtime ≥ anchor`.
  Immune
  to commit chaos — rebases/overlaps/races never undo the fact that writing a
  file's bytes (incl. a `git checkout`/merge/pull landing a coworker's commit)
  advances its mtime — so it has no false negatives and cannot break, where
  `git diff HEAD` is *unsound* (a coworker commit already in HEAD shows no diff
  yet differs from our pre-commit index). The discovery stat-walk fans across
  the
  roots in parallel (private page-backed arenas, no shared-allocator
  contention).
  Proven end-to-end on a single probe file: a **new** file, a **modified** file
  whose new trigrams the index never saw, and a **deleted** file (stale posting
  reads-fails gracefully → no match, no crash) are each handled. Cold process
  wall **~42 ms vs ripgrep's ~555 ms (13×)**; worst-case cold-cache walk ~95 ms
  still ~6×. Backward compatible: no anchor file ⇒ freshness is skipped,
  behavior
  byte-identical to the pre-T3 cold path. `widen` dedup carries a unit test.
- **T4 fusion + rank** (`src/rank.zig`, `cli -- rank`): the lexical tiers
  return
  an unordered match *set*; an agent wants the one line that answers first — a
  symbol's **definition**, not its 200 call sites — and pays tokens for every
  line below. Ranking via **weighted Reciprocal Rank Fusion** (Cormack 2009):
  score(d) = Σ wᵢ/(k+rankᵢ) over three rank-based signals — lexical density,
  symbol/definition boost (weight 2), shallow-path — plus an optional external
  ranking (a graph-centrality hook; null until wired). RRF needs no
  per-signal normalization and admits new signals for free; embeddings stay out
  (CoREB: short keyword queries collapse them). The harness extracts per-file
  features in a parallel posix read pass (matching-line count, a cross-language
  definition-line detector, the representative best line) and prints ranked,
  token-compressed `path:line [def|use] ×n  <line>`. Proven on real symbols:
  the
  `pub fn` definition of `queryLiteral` / `parallelVerify` /
  `extractSortedUnique`
  ranks **#1** above every call site, ~25–42 ms cold. rrf + signals carry 4
  unit
  tests (definition beats a 25×-hotter usage; external graph drives + is
  weight-controlled). Kernel suite 28/28.
- **T4 ranking now demotes codegen output** (`src/rank.zig`). A fourth RRF
  signal,
  `authored`, sinks generated files (`*_grpc.pb.go`, `*_pb2.py`,
  `*.connect.go`, …)
  below hand-written code. Found by dogfooding: `rank context.Context` returned
  a
  head of `*_grpc.pb.go` stubs because a generated file wins _both_ the lexical
  signal (most occurrences) and the definition boost (its boilerplate `func (c
  *…)`
  parses as a decl) — yet it is never an agent's edit target. The class split
  is
  fused tie-aware (authored docs share rank 0, generated docs share rank
  `n_authored`), so it is neutral _within_ a class and never re-votes the
  density/def order among real files; when a symbol lives only in generated
  files
  the demotion is uniform and the def-first order is untouched. Detection
  mirrors
  the repo shape gates (generated filename suffixes + first-line `// Code
  generated` / `@generated` markers). Match sets are unchanged — the gist ≡ rg
  oracle still proves 0 false negatives / 0 false positives. `rank` output
  gains a
  `[gen]` tag.
- **The engine now lives entirely under `src/`, split into concern-scoped
  tiers;
  `bench/` is the benchmark/verify harness only** — a clean separation of the
  product from the tooling that measures it. Engine logic had accreted inside
  `bench/` next to the latency harness; it moved out into six tiers, each a
  subfolder with its own `README.md`:

  - `src/index/` (**T0** trigram candidate index —
  `ngram`/`trigram`/`persist`),
    `src/regex/` (Thompson NFA + byte-class DFA + Pike VM), `src/rank/` (**T4**
  RRF
    fusion + language-agnostic signals), `src/scan/` (no-prefilter parallel
  verify
    — `simd`/`sweep`/`verify`), `src/corpus/` (loading + mtime freshness
  overlay),
    `src/commands/` (the CLI driver surfaces that compose the tiers).
  - The `rg` drop-in was **renamed off ripgrep's source layout onto its
  features**:
    the one `rgcompat` monolith became
  `src/commands/ripgrep/{args,ignore,output,
  json,run}.zig`, `rgemit` became `output.zig`, and `pathfilter` split into
    `src/commands/scope/{glob,types}.zig`. Each module is now named for what it
  _is_.
  - `build.zig` builds two artifacts on the shared kernel — the production
  `gist`
    CLI (`src/surface/face/gist/main.zig`) and a separate `gist-bench` harness
    (`bench/bench.zig`); they no longer share a binary.

  Pure structural move — every `*_test.zig` rides `src/root.zig` and the full
  suite
  (177 tests, incl. the differential Pike-VM fuzz oracle) stays green.
  Rule-of-Five
  registry entries record the `src/` tier fan-out and the harness-only
  `bench/`.
  (see also: gist)

### Fixed

- **A `./root` positional no longer breaks anchored ignore matching**
  (`bench/rgignore.zig`). When the search root was given as `./some_dir`, gist
  prefixed every walked path with `./`, so an anchored rule (or a whitelist
  like
  `!/some_dir/build/`) failed to match and the path was mis-ignored.

  - **`match` normalizes a leading `./`** (new `stripDot`) on both the
  candidate
    path and the rule's `base` before comparing, so `./some_dir/build/foo` is
    matched identically to `some_dir/build/foo` — the anchored/negated rules
  now
    fire regardless of how the root was spelled. Output still keeps the `./`
  prefix
    ripgrep prints.

  Proven against real ripgrep as the oracle: `r829_2731` (`-l string
  ./some_dir`
  with a `build/` ignore + `!/some_dir/build/` whitelist) and `f1757`'s
  `./rust1`
  invocation now diff to **0 bytes** vs `rg`.
- **DFA compilation no longer churns the allocator on every subset-map probe,
  so
  compiling a pathological pattern is ~9× faster** (`src/regex/powerset.zig`).
  The
  determinizer interns each transition target into the subset map
  ~`states×ncls×2`
  times; a genuine blow-up probes it ≈86k times before bailing at `max_states`.

  - **`intern` now probes with a reusable scratch key** and heap-allocates a
    permanent key **only when the state proves genuinely new** — one alloc per
    interned state, not one alloc+free per probe. On a real fuzzer-surfaced
    cap-busting pattern this drops allocations from ≈86k to **4184** (≈
  `nstates`),
    and per-compile time from **~175ms → ~19ms** ReleaseFast (~5s → ~0.37s
  Debug).
  - Because interning duplicates is the common case in _any_ determinization,
  the
    win applies to every DFA compile, not just the pathological bail path.

  Proven with a before/after timing harness and pinned by a new deterministic
  regression guard (`powerset_test.zig`): a counting allocator asserts a
  cap-busting compile allocates `< 2×max_states` — it would jump ~20× if
  alloc-per-probe ever returns. Full regex suite (177 tests, incl. the
  differential
  Pike-VM fuzz oracle) stays green — no correctness change.
- **Query results now go to stdout, diagnostics to stderr** (`bench/cli.zig`,
  `bench/scan.zig`, `bench/corpus.zig`). The `query` / `regex` / `rank` paths
  printed _everything_ — match paths, ranked rows, and the timing summary —
  through `std.debug.print`, which writes to **stderr**. Found by dogfooding
  gist
  as an agent: `gist query Foo > files.txt` captured an **empty file** and
  `gist query Foo | head` mixed the `—` summary line into the paths — the
  opposite
  of the `rg` convention every agent and shell pipeline assumes. The match list
  (literal `query`), the ranked rows (`rank`), and the live-tree scan match set
  (`regex` / sub-trigram `query`) now emit on **stdout** via a raw
  `posix.write`
  loop (`corpus.emitStdout`, EPIPE-safe so `| head` exiting early can't crash
  the
  query); the human-facing `—` summary, the `[pipeline]` straggler canary, and
  the
  `no index` / `bad pattern` guidance stay on **stderr**. Match sets are
  byte-for-
  byte unchanged — the `gist ≡ rg` equality oracle (50 literals + 68 regexes)
  and
  the no-prefilter `scan_regress.sh` gate both still prove 0 false negatives /
  0 false positives, and every bench harness (which captures `2>&1` and splits
  by
  content shape) is unaffected. New permanent guard: `bench/streams.sh` asserts
  the results→stdout / diagnostics→stderr split across the literal, rank, and
  scan
  paths and reproduces the original empty-file bug as a falsifiable regression.
  (see also: gist)
- **README benchmark prose + `regex/adversarial_test.zig`** — escaped the bare
  `_loaders_` / trailing-underscore emphasis in the cold-loader notes (markdown
  lint), and switched the rg second-oracle differential's temp-path `bufPrint`
  from `catch unreachable` to `try` so a formatting error propagates instead of
  panicking (zig-safety ratchet). No behavior change to the search path.
- **`--ignore-file` precedence + `-u`/`--require-git` semantics match ripgrep**
  (`bench/rgignore.zig`, `bench/rgargs.zig`). Three ignore-source ordering
  bugs:

  - **`--ignore-file` is now lowest precedence** — added _before_ the in-tree
    `.ignore`/`.gitignore` (not after), so a repo `.ignore` `!imp.log`
  correctly
    overrides an `--ignore-file` `*.log` (`f45_precedence_with_others`).
  - **`-u`/`--no-ignore` no longer disables `--ignore-file`** — the explicit
    `--ignore-file` sources are loaded before the `no_ignore` early-return,
  matching
    rg (an explicit ignore file is honored even unrestricted); only
    `--no-ignore-files` drops them, and **`--ignore-files`** re-enables them
    (`f1466_no_ignore_files`).
  - **`--require-git` now undoes `--no-require-git`** (last flag wins) instead
  of
    being a no-op, so `--no-require-git --require-git` again requires a real
  `.git`
    before honoring `.gitignore` (`f1414_no_require_git`).

  Proven against real ripgrep as the oracle: all three regressions diff to **0
  bytes** vs `rg`.
- **`.skip` search no longer drops a zero-width match at a bare boundary /
  EOL**
  (`src/regex/analysis.zig`, `src/regex/core.zig`). The first-byte `.skip`
  search
  seeds a start only at line position 0 and immediately _before_ a byte in the
  first-set — never at a bare word-boundary gap or at end-of-line. That is
  sound
  for a match that must consume a first byte, but a **conditionally-nullable**
  branch can match with no consumed byte at a position the skip never visits.
  So a
  pattern like `zzz|\b{4,6}$` or `q|\B{2}` — where one branch supplies a
  first-set
  (forcing `.skip`) while another matches zero-width via a word boundary —
  silently
  missed the zero-width branch. `reachesMatchEol` couldn't rescue it: it
  deliberately won't cross a `\b`/`\B`, so its `eol_empty` shortcut stays false
  for
  these _content-dependent_ EOL matches.

  Surfaced by the regex engine's own adversarial differential fuzzer against
  the
  `rg` oracle: `MATCH-DIVERGENCE pat=/^\S\w{2}|\b{4,6}$/` and
  `DOC-DIVERGENCE pat=/…|\B+\B{4,6}$/` (gist returned `false` where `rg`
  matched).

  Fix: a new conservative analysis predicate `reachesMatchZeroWidth` — does the
  start ε-reach `match` through a zero-width path that may cross _any_
  assertion
  (`^ $ \b \B`)? — sets a `Regex.nullable` flag, and `lineMatchPike` routes
  nullable
  patterns to the `.plain` search (which re-seeds every position, EOL included)
  instead of `.skip`. Sound by construction: a false "nullable" only forgoes
  the
  skip optimization, never a match, and genuinely consuming patterns
  (`func\s+\w+`, `pgxpool`, …) stay non-nullable on the fast `.skip` path. The
  full
  differential fuzz suite is green again; permanent regression coverage lands
  in
  `src/regex/core_test.zig` (the `z|\b{4,6}$` / `z|\B{2}` / `z|\b{2,}$`
  skip-mode
  cases, expectations cross-checked against `rg`).
- **`grep` closes four more reflexive-invocation gaps found by dogfooding gist
  _as
  the agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`). Racing
  the
  two on real repo questions surfaced one silent-wrong landmine and three
  fail-loud-on-a-legal-call breaks — each of which an agent's muscle memory
  hits:

  - **`--count-matches` was a silent-wrong landmine — now a true match count.**
  It
    aliased to `-c`/`--count`, so it counted matching _lines_ where rg counts
    individual match _spans_ — on `e` in one file gist said `165` (lines) while
  rg
    said `988` (matches), a wrong-but-confident number (the worst agent
  failure).
    It now counts non-overlapping leftmost-first spans via the same span engine
    `-o` rides (a per-shard `SpanSim`, allocated only when the flag is set),
  while
    `-c`/`--count` stays line-count. `-m N` caps the total; `--count-matches
  -v`
    falls back to counting non-matching lines (rg's behavior — invert has no
  span
    to count). **Proven byte-identical to `rg --count-matches`** across 11
    literal + regex patterns over the shared `-g '*.go' services/backend` scope
    (up to 2 591 files each, 0 mismatches).
  - **Corpus-policy no-ops gist already satisfies are accepted, not
  fail-loud.**
    `--hidden`, `--no-ignore[-vcs/-parent/-dot/-global]`, `-u`/`-uu`/
    `--unrestricted`, `--one-file-system` all ask rg to widen its corpus toward
    what gist's index **already** searches (it ignores `.gitignore` and
  includes
    hidden dotfiles — README "Scope vs ripgrep"), so they're no-ops here, not
    errors. Proven to leave output byte-identical to the bare query.
  - **`--sort`/`--sortr` swallow their value (gist emits path-ascending
  already).**
    gist's `grep` output is sorted by path (a stable, deterministic order),
  which
    _is_ `--sort path` — the overwhelmingly common agent request — so the flag
  is
    a no-op that consumes its value instead of erroring.
  - **Recognized-but-unsupportable flags fail LOUD with the reason + `rg`
    fallback, not the generic "unknown flag" dump.** `-P`/`--pcre2` (PCRE
    backreferences/lookaround — gist runs a linear-time RE2-style engine),
    `-U`/`--multiline[-dotall]` (gist matches per line), and
    `--json`/`--vimgrep`/`--column` (gist emits fixed `path:line:text`) now
  print
    a one-line "why + use `rg …`" instead of leaving the agent to guess whether
  it
    typo'd or hit a real limit. Crucially still fail loud — never silently
  ignored
    (which would give a wrong result on a genuinely PCRE/multiline pattern).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves **0 FN / 0
  FP**
  (140 literals + 70 regexes over the byte-identical snapshot), and the parser
  carries 4 new adversarial tests (count-matches ≠ count, the corpus no-op
  family,
  `--sort` value-swallow, the fail-loud contract for `-P`/`-U`/`--json`/…).
- **`rg -o` emits zero-width matches for a nullable pattern, matching rg's
  `find_iter`** (`bench/rgemit.zig`). gist's only-matching span loop
  unconditionally
  skipped empty spans, so `-o ''` (and other nullable patterns) produced
  nothing
  where ripgrep prints an empty `-o` line per zero-width match.

  - **`emitMatches`** now emits a zero-width match when the regex is
  **nullable**
    (`re.nullable`), following rg's progress rule — an empty match adjacent to
  the
    previous match's end is skipped, empties advance one byte — and honoring
  `-w`
    (word-boundary check on the empty span). A **non-nullable** pattern never
    produces an empty span, so its output is byte-identical to before: **zero
    regression risk** for every previously-passing `-o`/`-w` case (verified: no
    passing test regressed).

  Proven against real ripgrep as the oracle: `r1891` (`-won ''` over `"\n##\n"`
  →
  one empty match on the blank line, three on `##`) now diffs to **0 bytes** vs
  `rg`, taking the drop-in to **100% supported-surface parity (265/265)**.
- **`rg` drop-in matches ripgrep's stdin heuristic exactly — the socket fd type
  is
  no longer a silent divergence** (`bench/rgcompat.zig`). ripgrep decides to
  search
  stdin (vs. walking `./`) with `!is_terminal(fd0) && (is_file || is_fifo ||
  is_socket)` (grep/cli `is_readable_stdin`). gist's `readableStdin`
  whitelisted
  only regular files and FIFOs, so `sock_producer | gist rg pat` — and, more
  commonly, any exec API that wires fd0 to a `socketpair` — fell through to a
  directory walk while real `rg` searched the stream. Added `S.IFSOCK` to the
  whitelist; the three-type set still excludes a tty and `/dev/null` (a char
  device), so bare `rg pat` and `rg pat </dev/null` keep walking `./`.

  **Proven byte-identical to `rg` across all four fd types** (socket, pipe,
  regular-file, `/dev/null`) via a `socketpair`-backed differential probe:
  socket
  and pipe search the stream (`match here`, rc 0), `/dev/null` and a bare tty
  walk
  the CWD, a redirected regular file searches that one source.
  Supported-surface
  parity over the 330 mined ripgrep tests stays **61/61 = 100%**.

  Note: the "`rg foo` appears to hang" failure mode in exec-spawned shells (a
  pipe/socket wired to fd0 that never sends data or EOF) is ripgrep's own
  documented, unmitigable heuristic — its source calls it "a terrible failure
  mode, but there really is no good way to mitigate it" (core/flags/hiargs.rs).
  gist now reproduces it faithfully; non-interactive callers should redirect
  `</dev/null` exactly as they would for `rg`.
