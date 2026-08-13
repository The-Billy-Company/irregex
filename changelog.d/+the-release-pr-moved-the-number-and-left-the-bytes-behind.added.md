`tools/mint_artifacts.py`, and a `mint artifacts` job that runs it on the release
PR: the committed files carrying this package's version in their **bytes** are
regenerated when the bot bumps it, rather than by hand afterwards.

The bot rewrites every line carrying an `x-release-please-version` marker. Three
kinds of committed file state the version without carrying that marker, because
no line in them was typed by anybody:

- the **vendored engine archives** - twelve of them, build output, with the
  version compiled into their string tables;
- the **oracle corpora** under each binding's `testdata/` - generated against a
  linked engine, which records the version it linked;
- the **lockfiles** - resolver output, pinning this package's own name at
  whatever its manifest declared the last time the resolver ran.

So the v2.1.0 PR bumped to 2.1.0 while twelve archives, two corpora, and two
lockfiles still described 2.0.0 - and nothing failed early. The archives carry
every symbol, so the parity gate's symbol lane passed; the first complaint came
from a Rust test asserting the engine it linked agrees with the crate it is part
of. Each artifact was then minted by hand, one red CI run at a time, and the
lockfile would have failed last of all, inside `cargo publish --locked`, after
the wheels had already gone out.

The tool discovers rather than lists, like the gate it sits beside: archives and
the command that rebuilds each come from `contract/bindings.toml`, a corpus names
its generator by lying beside it, and a lockfile names its package through the
manifest beside it. So a fourth binding is covered the day it commits an
artifact. `--check` reports staleness and touches nothing, which is what lets the
job skip installing a toolchain at all on a PR that is already current; after
minting it re-reads every artifact, because a rebuild that succeeds and emits the
same stale bytes is the one failure a mint cannot self-report.

Both of the jobs that maintain the release PR - this one and the changelog fold -
now run for as long as the PR is open, rather than only on the push where
release-please rewrote it. A `ci:` commit or a late fragment leaves the PR
untouched, and that used to skip them silently: the PR sat there unfolded and
unminted with nothing saying so, until the preflight refused to publish it.

A corpus is generated against the library **this tree** built, pinned rather than
left to the binding's own search order. That order honors an `IRGX_LIB` already
in the environment, so a maintainer pointed at a second checkout would otherwise
record that engine's version here - the same silently-wrong artifact, arrived at
from the other direction.
