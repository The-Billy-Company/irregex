# irregex

The irregular-expression engine. One Zig library that holds everything a
grep-class tool needs below the product line: the regex engines, the
trigram index, the corpus walk, the freshness model, the ranking math,
and the rg-shaped output frames. No binary ships from here; this is the
library the binaries are built on.

The shape is deliberate. ripgrep is a thin `rg` over a stack of
library crates (`regex`, `grep-searcher`, `grep-printer`, `ignore`);
irregex is the same cut applied to our stack. The library owns the
engine-grade code, and three sibling packages own everything with an
opinion about products:

| Package | What it is |
|---|---|
| **irregex** (this repo) | the library: engines, index, corpus, rank, emit, warm core |
| [`relate`](../relate) | the similarity engine: compression-as-search, kinship, the codex |
| [`gist`](../gist) | the product chassis: ships the `gist` + `relate` binaries, the daemon, the C ABI, editor + shell integration |
| [`blast`](../blast) | the composed face: ships the `irregex` binary (`blast` / `provenance`) |

## What's inside

- `src/kernel/regex/` - the engine family: the linear ladder (literal ·
  memmem · Teddy · lazy DFA · Pike VM), full determinization, dwell,
  reduction, pricing, and the vendored PCRE2 10.47 behind `-P`. Unicode
  is default-on at rg parity (simple case fold, codepoint classes).
- `src/kernel/{scan,math,rank,query}/` - SIMD byte scanning, the crest
  sieve and its math floor, the shared ward/parallel primitives, rank
  signals, and the transport-neutral compiled query every face runs.
- `src/corpus/` - the tree walk (`.gitignore`/hidden precedence exactly
  as rg orders it), bulk stat, the trigram index and its persisted
  slivers, the crest sidecar, the signet identity, and the wall-clock
  freshness anchor that folds mid-session edits into a days-old index
  with no false negatives.
- `src/exec/cold/` - the one-shot pipeline: argv flag grammar,
  preferences, the walk, and emit (rg-shaped output, `-n/-v/-o/-c`
  frames, JSON).
- `src/exec/session/` - the warm resident core: the in-memory engine the
  daemon in `gist` keeps hot, the answer keep, the filesystem watch, and
  reconcile. The sockets and daemon lifecycle live in `gist`; the engine
  they hold lives here.
- `src/surface/` - `api.zig` (the embedding surface) and the CLI
  vocabulary the faces share.
- `research/` - the hand-authored algorithms (crest, pincer, ceiling,
  the automata work) with their own proofs and prior-art dossiers.
- `python/` - the `irregex` PyPI face: a dependency-free subprocess API
  over an installed binary.
- `tools/` - the generated-table builders (Unicode, encodings, rarity,
  schema) and their pinned UCD/WHATWG inputs.

## Build and test

Zig 0.16, no network. PCRE2 builds from the mirror physically vendored
under `vendor/pcre2/`; the `build.zig.zon` entry is `.lazy` and exists
only to pin the upstream release by URL + hash.

```bash
zig build check          # compile everything, run nothing
zig build test           # the full brigade-sharded suite (ReleaseSafe)
zig build test-quick     # same suite minus the declared long poles
zig build coverage       # per-function coverage
```

`check-linux` / `check-windows` are folded into `test`, so a push is
judged against every target the library claims.

The unit-test binary is pinned to ReleaseSafe on purpose: the suite that
tries to break the checks keeps them; the shipped CLIs (built in `gist`
and `blast`) compile them out with ReleaseFast.

## Using it

```zig
// build.zig.zon
.irregex = .{ .path = "../irregex" },  // dev: sibling checkout
// releases pin url + hash

// build.zig
const irregex = b.dependency("irregex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("irregex", irregex.module("irregex"));
```

The module surface is `src/root.zig`: the engine tiers (`regex_*`,
`matcher`, `engine`), the corpus (`corpus`, `haystack`, `fresh`, the
trigram family), presentation (`emit`, `argv`), and the `irregex`
primitives tier itself (match ∪ relate ∪ weave). The `inner` namespace
is the product seam - internal-but-stable modules the sibling packages
consume; everything under it is fair game for `relate`/`gist`/`blast`
and subject to change for anyone else.

## Provenance

Extracted from `irregex` (cut at the extraction commit).
Architecture is machine-checked: `contract/irregex.ward` declares the
tier ordering, seals, and reach ceiling, and the ward gate judges it
over the real `@import` graph. Changelog is towncrier
(`changelog.d/` fragments → `CHANGELOG.md`). MIT licensed; `NOTICE`
attributes the vendored and borrowed work (PCRE2, the ripgrep lineage,
UCD data).
