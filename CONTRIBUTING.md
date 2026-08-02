# Contributing

Thanks for looking. This page is the practical half - what to install, what to
run, and what a reviewable change looks like here. The design half is
[`README.md`](README.md) for what the engine is, [`src/README.md`](src/README.md)
for how the tiers fit together, and [`research/`](research/README.md) for why the
load-bearing algorithms are the ones they are.

Two other files bound this one. Report a vulnerability privately, never in an
issue: [`SECURITY.md`](SECURITY.md). How we treat each other:
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## What this repository is

`irregex` is the library and the C ABI floor - the regex engines, the corpus
walk, the candidate indexes, the freshness law, the compiled query, and the
runtimes. It ships no CLI. The products built on it live in their own
repositories: [`gist`][gist] (indexed pattern search), [`relate`][relate]
(compression-as-search), and [`blast`][blast] (the composed face).

That split matters when you file something. A wrong match, a slow engine, a
crash in the index loader, or a C ABI question belongs here. "`gist --rank` put
the wrong thing first" belongs in `gist`, even though the ranking math lives
here - the maintainers move it if it turns out to be ours.

The development model is **sibling checkouts**. The faces path-depend on
`../irregex`; releases pin url and hash instead. If you are changing something
that crosses the boundary, clone the sibling next to this one rather than
inside it:

```
Billy-Company/
├── irregex/     ← you are here
├── gist/
├── relate/
└── blast/
```

## Setup

One toolchain is mandatory. The rest you need only for the binding you touch.

| For | Install | Pinned by |
| --- | --- | --- |
| the engine | Zig **0.16.0** | `minimum_zig_version` in [`build.zig.zon`](build.zig.zon), `ZIG_VERSION` in CI |
| the Python binding | [uv](https://docs.astral.sh/uv/) | `requires-python` floor 3.12 |
| the Rust binding | rustup | `bindings/rust/rust-toolchain.toml` |
| the Go binding | Go | `bindings/go/go.mod` |

Nothing is fetched at build time. PCRE2 and libsais are physically vendored, so
`zig build` is hermetic and works offline; the `.lazy` entries in
`build.zig.zon` exist to pin provenance, not to download anything.

```bash
zig build              # the library and the shared objects the bindings load
zig build check        # compile only, no run - the fastest "did I break it"
zig build check --watch  # ... and again on every save
zig build test         # the suite
```

## The test loop

The suite is sharded and filterable, and using that is the difference between a
0.1-second loop and a coffee break:

```bash
zig build test -Dtest-filter='<substring>'   # just the tests you touched
zig build test -Dtest-shards=1               # one process, for a debugger
BRIGADE_TIMES=1 zig build test               # per-test milliseconds
```

A filter matching nothing **fails** rather than passing empty, so a stale
filter can never read as a clean run. Before you push, run the unfiltered
suite once.

To probe something that reads the environment, drive the compiled test binary
directly - `zig build` caches on the environment, so a second run with a
different variable can be a replay that is green by construction:

```bash
env FORCE=$RANDOM zig build test -Dtest-filter='<name>' -Dtest-shards=1 --verbose
BRIGADE_SHARD=0/1 BRIGADE_FILTER='<name>' BRIGADE_TIMES=1 ./.zig-cache/o/<hash>/test
```

The bindings each have their own suite, and each is a separate CI job:

```bash
cd bindings/python && uv run pytest -q
cd bindings/rust   && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cd bindings/go     && go vet ./... && go test ./...
```

## What CI will check

Eight jobs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), split on
purpose - an engine regression and a clippy nit are different news and deserve
different red Xs.

| Job | What it holds |
| --- | --- |
| `engine` | `zig build check` + `zig build test`, on Linux **and** macOS |
| `hermetic` | the same suite under a deliberately hostile `GIST_SKIP` and `skips.list`, because a test that reads ambient configuration passes here and fails on someone's real machine |
| `python` / `go` / `rust` | each binding's own suite; Python across 3.12, 3.13, and 3.14 |
| `fmt` | `zig fmt --check` over every tracked and untracked-not-ignored `.zig` file |
| `ratchets` | the baselines under [`quality/ratchets/`](quality/ratchets/README.md) |
| `changelog` | every fragment in `changelog.d/` is one towncrier recognizes |

Run the formatter before you push - `zig fmt` reflows column-aligned literals,
so a rename that shrinks the widest cell leaves rows you never touched one space
too wide:

```bash
zig fmt .
```

### Ratchets only shrink

[`quality/ratchets/`](quality/ratchets/README.md) freezes behaviour a unit test
cannot: one canonical out-of-memory exit, a fault taxonomy every error path is
drawn from, a gate against bypassing the assay. Each keeps a `.baseline`, and
the contract is that **new code is born clean and existing counts only go
down**.

If a ratchet fails, you added an instance of the thing it forbids. Fix the code.
Raising a baseline to go green is the lint equivalent of deleting an assertion,
and it will be the first thing review asks about.

## Architecture is machine-checked

Zig has no visibility rules between files in a package, so every boundary the
READMEs describe would be convention. [`contract/irregex.ward`](contract/irregex.ward)
is the machine-checkable half: tiers, what may import what, and the exceptions
that have to state a reason. It is judged by the `ward` gate riding in each
consumer's CI.

If your change needs a new import edge, edit the contract in the same commit and
say why in the exception. Do not route around it.

## New algorithms want a dossier

A performance or correctness idea substantial enough to have a name gets a
folder under [`research/`](research/README.md) with, at minimum:

- **`CLAIM.md`** - what it does better, stated so it could be wrong;
- **`PRIOR_ART.md`** - who did it first, with annotated links. "Inspired by" is
  not a citation;
- **`TESTING.md`** - what would falsify the claim, and what runs to try;
- **`PROOF.md`** where the claim is a proof rather than a measurement.

This is not ceremony. It is the reason an unfamiliar reader can tell what we
built from what the world already knew, and it is enforced socially rather than
by a gate - which means review will ask.

## Benchmarks are evidence, not vibes

Any performance claim needs a number from a harness in
[`bench/`](bench/README.md), taken on a quiet machine, against the rung it
claims to beat. Two rules the harnesses enforce rather than merely state: no
fabricated hardware model (an absent number beats an invented one), and no
unoptimized measurement (a Debug build refuses to publish a curve).

Profile the function you changed rather than re-running a whole suite and
squinting. If output is supposed to be byte-identical, prove that it is.

## Every change carries its own news

Write a towncrier fragment in the **same PR**:

```bash
towncrier create '+<slug>.<type>.md'    # types: added changed deprecated removed fixed security
```

Fragment names read like the sentence they are: `+the-abi-stops-making-you-guess.changed.md`.
The leading `+` tells towncrier there is no issue number attached. The body is
prose for a person reading release notes - what changed and what it means for
them, not a restatement of the diff.

Skip it only for comment-only, format-only, or genuinely invisible internal
work. When unsure, write it. A malformed filename is a CI failure by design
(`ignore` in [`towncrier.toml`](towncrier.toml) turns towncrier's silent skip
into an error), so a typo cannot quietly drop your entry from a release.

## The version is written once

You will not edit a version by hand, and you should not try. `build.zig.zon`'s
`.version` is the only place this package's number is written:

- **Zig** reads it through a build option, so `src/root.zig`'s `version_string`
  and `irgx_version()` are the manifest, not a copy of it;
- **Rust** reads `CARGO_PKG_VERSION`;
- **Python** reads its installed distribution metadata.

Four copies survive, and only in files that cannot import anything: the
contract, `Cargo.toml`, `pyproject.toml`, and the Go mirror. Each carries an
`x-release-please-version` marker, `release-please-config.json` lists all four,
and one merged release PR moves the whole set in a single commit.
`python3 tools/version_parity.py` proves they agree, and fails just as loudly on
a marked line the release config was never told about. It runs in CI.

Adding a fifth copy? Only if the language truly cannot ask. Mark the line, add
it to `extra-files`, and the gate will hold it.

**Cutting a release.** Merge the release PR that release-please opens; that tags
`vX.Y.Z` and `release.yml` publishes the wheels. Two things ride along:

1. towncrier owns `CHANGELOG.md`, so run
   `towncrier build --version <the version the PR bumps to>` and push it onto
   the release branch - the tag and the notes should land together.
2. Regenerate the Rust oracle: `python3 bindings/rust/scripts/python_oracle.py`.
   Its fixture records the engine build that produced it, and
   `corpus_matches_the_linked_engine` compares that stamp against the linked
   library - by design, so a hundred span mismatches read as "the corpus is
   stale" instead of "the engine is wrong". A version bump moves the engine, so
   the stamp needs re-minting from the same script that wrote it. Do not hand-edit
   the JSON; the whole point of the stamp is that a generator put it there.

## Commits and pull requests

Commit subjects here are a conventional prefix plus a lowercase sentence that
says what changed, in the voice of the change rather than the ticket:

```
fix: the batched walk cannot leak its own step-aside
perf: the automata ladder stops dispatching twelve lanes for a walk that ends at two
docs: every cited path resolves again after the split
```

Prefixes in use: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci`
`chore`. Keep the subject under about 72 characters and put the reasoning in the
body, where reviewers and `git log` both find it.

For the pull request: one concern per PR, describe what would have caught the
bug if it had existed, and fill in the template. Reviews here ask three
questions more than any others - *what proves this?*, *what does it cost?*, and
*what did it replace?* Answering them in the description saves a round trip.

If you removed something that a newer path superseded, remove it completely.
Leaving the old implementation beside the new one to be safe is how a codebase
grows two spellings of the same bug.

## Licensing

This project is Apache-2.0. There is no CLA: contributions are accepted under
the same license the project already carries, per the inbound=outbound norm in
section 5 of the license itself.

If you bring in third-party code, data, or an algorithm implemented from a
published description, it goes in [`NOTICE`](NOTICE) with its license, and the
credit goes in the module that uses it. Attribution is a correctness property
here, not a courtesy.

## A small thing that makes diffs readable

Git ships hunk-header patterns for C, Go, Python, Rust, and Markdown, and
[`.gitattributes`](.gitattributes) already binds them. Zig has none, so teach
your own git what a Zig declaration looks like once:

```bash
git config diff.zig.xfuncname '^((pub |export |inline |noinline )*fn .*|(pub )?(const|var) [A-Za-z_].* = (struct|union|enum|opaque)\b.*)$'
```

The attribute is already in place; until you run this, it simply falls back to
git's default.

[gist]: https://github.com/The-Billy-Company/gist
[relate]: https://github.com/The-Billy-Company/relate
[blast]: https://github.com/The-Billy-Company/blast
