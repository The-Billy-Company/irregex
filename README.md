---
doc_radar:
  counts:
    - description: "irregex src/ tiers: math · corpus · index · search · runtime · cli"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 6
  sentinels:
    - description: "the Zig package identity is irregex"
      file: pkg/kernels/irregex/build.zig.zon
      contains: ".name = .irregex,"
    - description: "the C ABI is the irregex_* session surface (libirregex, include/irregex.h)"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["irregex_abi_version", "irregex_open", "irregex_search", "irregex_close"]
    - description: "registered in the changelog roster (OSS-package membership)"
      file: pkg/tools/support/chronicle/packages.py
      contains: 'Package("pkg/kernels/irregex"'
    - description: "the irregex primitives tier is a first-class root export"
      file: pkg/kernels/irregex/src/root.zig
      contains: "pub const irregex = struct"
    - description: "correctness remains ahead of performance in the proof pipeline"
      file: pkg/kernels/irregex/bench/gates/ci_order.sh
      contains: ["pcre parity -P", "index-elision parity", "macro certificate"]
---

# irregex

## What it is

The **irregular expression engine** is one Zig kernel for three set-shaped
problems: regular-expression **match**, compression-based **relate**, and
engine-side **weave**. Regex asks _"does this text match?"_ irregex also asks
_"which of these N intents hit?"_, _"what in this tree is like this file?"_,
and _"does this string exist anywhere, proven rather than sampled?"_
([ADR-363](../../../docs/architecture/3-decisions/363-irregex-primitives.md)).

I kept coming back to one fact: text is bits. Flip one bit and the patterns
change. Gist started with a question: _can I use those differences to reject
most files before reading them?_ That pulled me from exact matching into
compression, similarity, and information retrieval. irregex is what came out.

> **Scope:** build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## Why it exists

Agents search constantly. The tree keeps changing. Every extra line burns
context. I built irregex for that loop. Speed matters, but truth matters more;
the index can save reads, but it never gets to overrule current bytes.

Then I started thinking about compressors. They turn repeated structure into
shorter descriptions. What if I used that same math, but returned the files
most like a query instead of one compressed blob? That became `relate`. It aims
at the same job as embeddings by a different route: embeddings compare learned
vectors; relate compares shared bytes and coding cost.

## Prior art

Most of the math here I did not invent. I put the pieces together, then made
each claim prove itself. The kernel builds on:

- Google Code Search's trigram index (Russ Cox), with a conservative live-tree
  freshness overlay rather than snapshot authority;
- Thompson/Pike/RE2-family linear matching plus opt-in, resource-capped PCRE2;
- the Ferragina–Manzini FM-index, SA-IS, Huffman wavelet trees, and RRR
  bitvectors for the restorable compressed codex;
- LZJD, winnowing, Ziv–Merhav cross-parsing, and FM-index matching statistics
  for compression kinship and attribution.

One piece is mine: the **crest sieve**, a forced-class-run necessary condition
that prunes the literal-free class repetitions every index in the trigram
family concedes. New math, adversarially refereed for priority; the theorem,
calculus, and its own prior-art survey live in
[`research/crest/`](research/crest/PROOF.md).

I deliberately keep model-free byte kinship rather than dress it up as semantic
retrieval, and per-pattern confirmation rather than Hyperscan-style fused
attribution. [`PRIOR_ART.md`](PRIOR_ART.md) contains the full survey and
explicit non-claims.

## Quick start

From the Billy checkout (the package requires the Zig version declared in
[`build.zig.zon`](build.zig.zon)):

```bash
make install-gist                    # build both CLIs, link them, index the tree

gist 'SearchRequest' --rank          # ranked exact/regex search
gist 'foo(?=bar)' -P                 # indexed PCRE2 when a sound literal exists
relate similar path/to/file --top 5  # compression-nearest files
relate pack "how does CDC recover?"  # non-redundant context set

gist status
relate index --shelf                 # optional warm atlas + quotation shelf
relate status
```

Indexes are optional accelerators. Missing, stale, or uncertain state falls
back to current files rather than changing the answer. See the face-specific
docs for the complete CLI surfaces and standalone `zig build` commands.

## Choose a face

| Face       | What it is                                                                                                                                                                                  | Docs                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| **gist**   | the rg-parity code locator CLI: trigram + crest read-elision, ranked search, and a resident session; the agents' everyday search reflex                                              | [`src/cli/gist/README.md`](src/cli/gist/README.md)       |
| **relate** | compression-as-search: `search` / `quote` / `similar` / `dups` / `patterns` through description length, corpus quotation, LZ kinship, and pattern attribution                         | [`src/cli/relate/README.md`](src/cli/relate/README.md)   |
| **codex**  | the compressed self-index: a corpus stored at entropy-bound size with exact O(m) `count`/`find` and byte-exact restoration; powers `gist codex` + `relate quote`                     | [`src/index/codex/README.md`](src/index/codex/README.md) |
| **ffi**    | the in-process C-ABI warm session (`irregex_open` / `irregex_search` / `irregex_close` over `libirregex`)                                                                                   | [`src/runtime/ffi/README.md`](src/runtime/ffi/README.md) |

The two CLIs are separate faces over one shared floor (`src/math/`,
`src/corpus/`, `src/index/`, `src/search/`, `src/runtime/`); neither owns a
private copy of the corpus walk, scope machinery, indexes, or execution hosts.

## Guarantees and limits

- Indexes may skip reads, never own truth; current bytes verify every result.
- `gist` preserves rg-shaped output and 0/1/2 exit codes, but
  [`gist --schema`](src/cli/gist/README.md#the-search-contract), not folklore
  about ripgrep, defines supported flags.
- PCRE2 is opt-in (`-P` or `--engine auto`) and resource-capped. If required
  literals cannot be proven, gist scans instead of risking a false negative.
- `relate` provides deterministic byte-level kinship, attribution, and packing;
  it serves a retrieval-shaped purpose without pretending compression distance
  is learned semantic meaning.
- The C ABI is versioned and flat; the header and
  [`ffi` documentation](src/runtime/ffi/README.md) are its public contract.

## Evidence: six runnable claims

The idea started the work. It did not prove anything. Every claim below has a
checked-in harness that tries to break it. “Only” means only the competitive
field that harness actually runs.

### 1. PCRE2 semantics can ride a sound code-search index

The established indexed searchers in our field, **csearch** and **zoekt**, use
RE2-family matchers and cannot express lookaround or backreferences. The
PCRE-capable peers - ripgrep, ugrep, ag, GNU grep, and git grep - scan the tree.
Gist is the field's unusual intersection: a vendored, JIT'd, resource-capped
PCRE2 10.47 verifier behind the same persisted trigram index as its linear
engine. A conservative parser extracts only literals that every PCRE2 match
must contain; if it cannot prove one, gist scans rather than guessing.

The hand-authored `-P` matrix proves stdout, exit-code, and indexed
≡ `--no-index` parity against live `rg -P` for lookaround, backreferences,
atomic/possessive forms, Unicode switches, and resource-limit failures
(**30/30**). `bench/races/pcre_headtohead.sh` then times a row only after its
file set equals ripgrep's, and records csearch/zoekt as inexpressive rather than
pretending they lost a race they cannot enter.

### 2. A stale index can accelerate a live tree without owning truth

Most indexes answer from a snapshot. irregex makes the stronger operational
claim needed by a coworking tree: an index may only **elide reads**. The live
walk still chooses the corpus; changed files widen the candidate set; current
bytes verify every survivor; deletion and uncertainty make resident paths
decline to the cold path. Staleness can therefore cost time, never matches.

`bench/gates/index_elision_parity.sh` compares every indexed answer and exit
code byte-for-byte with `--no-index`, including a match written after the
index anchor. The filesystem and resident-session gates separately exercise
new, modified, deleted, overflowed, and reconcile-racing files. This is the
proof behind “freshness-aware,” not a promise delegated to a watcher.

### 3. A code index can replace the corpus and still answer it exactly

I followed the same idea from matching into description length. The **codex**
applies the FM-index family as a restorable code-corpus shelf: `count(P)` is
O(|P|), `find` locates occurrences, and `restore()` regenerates the source bytes
from the index alone. With a clean freshness walk,
`gist codex count == 0` proves corpus-wide absence with no source-file I/O;
categorically stronger than a trigram candidate filter.

`zig build codex-scale` checks every timed answer against a naive scan, then
save/load, locate, and byte-exact restoration at every size. At 128 MiB the
count index occupies **1.95 bits/character**, below the corpus's measured
H₂ of 2.90, while a 16-byte count stays flat at **~11 µs** from 1–128 MiB
(**3,727×** the top-size scan). The same shelf powers `relate quote`: known
corpus text prices near 0.15 bits/byte versus ~15 for foreign bytes, with each
maximal quotation attributed to a source file; a measured ~90× separation.

### 4. Set-shaped search can be exact, attributed, and anti-redundant

`PatternSet` compiles N intents once and walks once without erasing which
pattern hit which file. Its fused prefilter is skip-only: every emitted answer
must equal N independent single-pattern searches. On the relocator-shaped
10-pattern slate that is **~195 ms** versus **~1.2 s** for ten sequential
`gist -l` calls (~6×), while a plain alternation cannot return attribution at
all (`bench/races/multipattern.sh`).

Instead of collapsing shared information into a compressed blob, I use the
same accounting to return a **set**. In `relate pack`, corpus-priced
fingerprints make every pick pay only for bits not already covered by earlier
picks. The greedy max-coverage plan carries the standard (1−1/e) bound and
emits marginal-bit receipts, so near-duplicate files cannot quietly consume an
agent's context budget as independent value.

### 5. A new necessary condition can close the trigram index's blind spot

Every index in the trigram family — csearch, pg_trgm, RE2's prefilter, zoekt,
Blackbird, gist's own — reduces a regex to required substrings, so a
literal-free class repetition like `[0-9a-f]{12}` extracts nothing and forces
a full scan. Gist's certificate records that hole honestly (cand% = 100% on
`regex-classcount`). The **crest sieve** is the formula I wrote to close it:
index each file's longest run per byte-class (16 bytes/doc), derive from the
regex the run every accepted string must contain, and skip any file that never
crests that high. It is not a substring test; the soundness theorem, the
min-of-max calculus over the AST, and an adversarially refereed priority
review live in [`research/crest/`](research/crest/PROOF.md).

`zig build crest` proves it fail-closed against the real matcher on the live
corpus: matched ⇒ never pruned, over every file × query plus 48k randomized
pattern/file pairs in both engine modes. Measured through the shipped CLI —
same binary, same index, only the sidecar toggled — the narrow-class slate
runs **3.2–4.3× faster end-to-end** with diff-identical match sets, and the
wide-class rows cost nothing. The count-population cousin at the same
thresholds prunes ≤1% where the run prunes 91%: the run is the condition.

### 6. Performance claims can be certificates, not benchmark anecdotes

The idea got me moving. It did not prove the system. So I built the checked-in
**Certificate of Optimality**. Correctness gates run first; only then do four
independent layers measure empirical
dominance (A), static and native port pressure (B/B′), the hardware roofline
(C), and the algorithmic read lower bound (D). A Layer-A win requires both a
lower median and Mann–Whitney p < 0.05; missing counters or tools are printed
as missing, never inferred.

On the recorded 22,827-file / 223.8 MiB corpus, the end-to-end linear/literal
path beats ripgrep in all 12 query classes by **1.97×–23.57×**. Layer D then
checks the narrower structural statement: trigram pruning touches no rejected
file bytes, and the DFA verifies each admitted byte exactly once. The artifact,
raw data, machine identity, losses, and rerun commands live in
[`bench/certify/artifact/CERTIFICATE.md`](bench/certify/artifact/CERTIFICATE.md);
`make bench-gist-certify` remints the full A–D bundle.

I carried the same discipline into the agent surface: `--rank` puts definitions
above call sites and demotes codegen; misses coach on stderr while stdout stays
pipe-clean; and output budgets protect the context window. The theory earns its
place only when the tool feels obvious in the hand.

## Package layout

| Dir            | What                                                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `src/runtime/` | the shared floor: `corpus/` walk/loading, `scope/` path scoping, `session/` warm resident transport, `ffi/` C-ABI face |
| `src/math/`    | the shared bit-identity floor (`bits.zig`) + the crest sieve calculus (`crest.zig`)                                     |
| `src/search/`  | match (`match/`), rank, batch (`patterns` · `loom`), similarity (`sketch` · `lexicon` · `zipper`)                       |
| `src/index/`   | trigram postings (`trigrams/` · `postings/`) + the compressed self-index (`codex/`) + the crest sidecar (`crest/`)      |
| `src/cli/`     | the two product binaries: `gist/` (exact locator) and `relate/` (compression-search)                                   |
| `include/`     | `irregex.h`: the flat C ABI (`irregex_*` symbols)                                                                      |
| `bindings/`    | Python (`billy-gist`, subprocess + optional cffi over `libirregex`) and Rust (subprocess) faces                         |
| `contract/`    | `search_api.toml`: the unified SearchRequest/irregex contract (ADR-352)                                                |
| `bench/`       | certification + competitive benchmark harness (rgsuite, races, certify, roofline)                                       |

See [`src/README.md`](src/README.md) for the tier-by-tier map and
[`src/cli/gist/README.md`](src/cli/gist/README.md) for the gist architecture
narrative, competitive benchmarks, and the full rg-parity flag table.

## Build & test

```bash
make install-gist   # build (ReleaseFast) + symlink ~/.local/bin/gist + index
make build-gist     # staticlib + dynlib (libirregex) + irregex.h → zig-out/
make test-gist      # zig build test: unit + differential-fuzz suites
```

One changelog covers the whole package (one version, one release unit):
`CHANGELOG.md` + `changelog.d/` at this root, roster row `irregex` in
`pkg/tools/support/chronicle/packages.py`.

## Project

- **License:** [MIT](LICENSE)
- **Changes:** [`CHANGELOG.md`](CHANGELOG.md)
- **Contributing:** [repository guide](../../../CONTRIBUTING.md)
- **Security:** [reporting policy](../../../SECURITY.md)
