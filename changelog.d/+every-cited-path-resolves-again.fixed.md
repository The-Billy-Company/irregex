The split moved directories that the prose kept naming by their old addresses,
so a reader following a citation landed nowhere. Every current-location path
cite I could verify now resolves.

`bench/harness/` became `bench/apparatus/harness/` for the three instruments that
stayed here, and `gist/bench/apparatus/harness/` for `bench.zig` / `flagbench`
which left with the product. `bench/crest/`, `bench/sieve/`, `bench/sliver/`,
`bench/multipattern/`, `bench/parabix/`, `bench/roofline/`, and
`bench/lowerbound/` all gained their bucket prefix (`rungs/` or `bounds/`), and
the lowerbound Zig file is `audit.zig` now, not `lowerbound.zig`. The certificate
scripts renamed when they crossed into the sibling `gist` package, so
`bench/certify/certify_stats.py` is `gist/bench/certificate/report/stats.py`,
`certify_layers.sh` is `mint/splice.sh`, `ratio_regress.py` is `guard/ratio.py`,
and the same for the rest of that table. The gates and the rgsuite moved with
conformance, so those cites say `gist/bench/conformance/…` now too.

One exception inside this tree: `bench/rungs/sliver/scale_race.py` already imports
its quantile / bootstrap / Mann-Whitney math from `bench/apparatus/stats.py`, so
those cites point here, not at gist's copy.

Scrubbing the monorepo's name out of paths had left **empty backticks** where the
path used to be - seven `(from ``)` holes across the bench rung READMEs and the
crest proof, each of which had once said where to run the command from. They say
"from the repository root" now. Three code blocks still ran `cd ../../..`, which
used to climb from the package's nest up to the monorepo root and after
extraction just walks out of the tree before running tree-relative paths.

Four phantom filenames went too. `census.zig` → `emit.py` were offered as the way
to regenerate the PMI table and neither is anywhere, so the recipe they stood for
is written out instead; the recipe was always the contract rather than the digits.
`probe18` and `probe19` were spike files named as if you could open them, so the
measurements they produced are described by method. `bench/multipattern/sweep.py`
turned out to be a second name for the crossing race seven lines above it in the
same doc comment, which is real and now the only one cited.

**Nothing here was reachable by `make`.** This package has no Makefile - it never
did, the targets belonged to the monorepo - so every `make install-gist`,
`make gen`, `make gen-gist-schema`, and `make bench-gist-certify` was an
instruction that could only fail. Three of them were shipped user-facing error
text: the Python and Go binding both tell you to run `make install-gist` when they
cannot find a binary, and the schema-drift failure told you to reconcile with
`make gen`. They name `zig build -Doptimize=ReleaseFast` and
`python3 tools/build_schema_tables.py` now, which is what the generator's own
staleness message and the Rust binding already said.

One test moved with them. `test_a_drifted_digest_is_a_named_failure` asserted the
literal string `make gen` appeared in the drift message; it was pinning the
monorepo contract, so it now asserts on the instruction that can actually run. The
assertion's job is unchanged - the failure still has to say how to reconcile the
two sides.

The Python contract docstrings also still said `schema.gen.py` is lowered from
`contract/surface.toml`. That was true before the contract split by ownership;
the analytic tables are `contract/analytic.toml` here, and `surface.toml` is
gist's.

Not fixed, because fixing it is a decision rather than an edit:
`bench/rungs/sieve/indexcost.sh` still sources `../../dominance/races/field.sh`,
which is not in this package, so that script cannot run here; and a few
`doc_radar` / contract keys still name sibling-repo paths as if they lived under
this root.
