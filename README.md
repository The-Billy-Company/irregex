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
| `relate` | the similarity engine: compression-as-search, kinship, the cento quoter |
| `gist` | the product chassis: ships the `gist` + `relate` binaries, the daemon, the C ABI, editor + shell integration |
| `blast` | the composed face: ships the `irregex` binary (`blast` / `provenance`) |

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
- `bindings/` - the Python, Go, and Rust faces of the C ABI. Each one
  ships the native library with it, so installing needs no Zig and no
  compiler.
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

### Running one test, and the cache trap underneath it

`-Dtest-filter=<substring>` narrows the suite and `-Dtest-shards=1` puts
it back into one process for a debugger:

```bash
zig build test -Dtest-filter='word-boundary' -Dtest-shards=1
```

Worth knowing before you trust a filtered run twice: **`zig build test`
caches the test run, and the environment is part of the cache key.** The
filter reaches the harness as `BRIGADE_FILTER`, an environment variable
set on the run step (`addShards` at the bottom of `build.zig`), and Zig
hashes a run step's environment along with its argv. So the first run
under a given environment executes, and every later run under an
environment you have already used is served from cache: the step is
skipped, nothing executes, and the build exits 0 in about the time a
no-op build takes (~1.7 s here).

What makes that bite is that a cache hit still reports a test count.
`--summary all` prints `19/19 tests passed` whether the shard ran or was
replayed. The only token that tells them apart is `cached` where an
executed step says `success <n>ms`:

```
+- test shard 0/1 success 3ms     # ran
+- test shard 0/1 cached          # did NOT run, still "19/19 tests passed"
```

That makes `zig build test` the wrong instrument for asking whether the
tree is sensitive to an environment variable. The obvious probe - run the
suite with the variable set, then again without it to confirm - revisits
an environment it has already visited on the confirming leg, so that leg
is a replay and is green by construction. I nearly certified a tree as
environment-immune on exactly that, and the tell was not in the exit code
or the test count; it was one word in the summary.

To probe an environment variable, drive the compiled test binary
yourself. It sits under no build-cache layer, so it executes every time:

```bash
# find the binary - force a real run, or a cached one prints no argv at all
env FORCE=$RANDOM zig build test -Dtest-filter='<name>' -Dtest-shards=1 --verbose
#   ... BRIGADE_SHARD=0/1 BRIGADE_FILTER=<name> ./.zig-cache/o/<hash>/test

BRIGADE_SHARD=0/1 BRIGADE_FILTER='<name>' BRIGADE_TIMES=1 \
  ./.zig-cache/o/<hash>/test
```

`BRIGADE_TIMES=1` emits one `<ms>` + tab + `<name>` line per test, which
is the evidence that the run happened at all rather than a claim that it
did. A filter matching nothing is loud rather than quietly empty -
`BRIGADE_FILTER='...' matched none of the N tests`, naming the count it
searched - so a stale filter cannot pass as a clean run either.

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

Extracted from a private monorepo (cut at `ce430bbaab`).
Architecture is machine-checked: `contract/irregex.ward` declares the
tier ordering, seals, and reach ceiling over the real `@import` graph
(the `ward` judge currently lives in the private monorepo that consumes this package). Changelog is towncrier
(`changelog.d/` fragments → `CHANGELOG.md`). Apache-2.0; `NOTICE`
attributes the vendored and borrowed work (PCRE2, the ripgrep lineage,
UCD and WHATWG data).
