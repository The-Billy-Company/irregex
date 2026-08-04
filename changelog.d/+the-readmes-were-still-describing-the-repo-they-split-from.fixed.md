Every README in the repository, all 118 of them, was audited against the
source it documents and rewritten wherever it disagreed. Most of the drift
traced to one cause: this package split out of Billy's monorepo, and the prose
kept describing the shape it had before the move. The root `README.md` still
named `regex_dfa` and `matcher` as sibling top-level exports, which retired
when the engine consolidated behind one `regex` door; `vendor/README.md`
pointed at a `libsais` path and a `zig build codex-scale` command that never
existed; `tools/whatwg/README.md` and `tools/ucd/README.md` credited a sibling
project's decoders for tables this engine's own kernel and corpus build.

Real fixes beyond the split: `contract/README.md` now documents `exports.toml`
and `contract/irregex.zone`, both born after the last time anyone touched that
file. `quality/surface/README.md` described a deprecation-schedule table shape
that isn't how `check.py` actually diffs `[removed]` entries against the last
release tag. `src/kernel/regex/oracle/README.md` and the root `README.md` each
cited a fixed differential case count for the composition, symbolic, and
one-pass rungs - numbers that appear nowhere in the tree as constants, because
the generators are randomized against an asserted floor rather than a fixed
total. Both now cite the floor the test actually holds the build to. The
`ladder/`, `shuffle/`, and `oracle/` accelerator docs had each drifted from
`price.zig`'s live calibration independently, in three different directions,
and no two of them agreed on the composition rung's own measured speedup until
this pass traced all three back to the same reference run.

Every table became a bulleted list, every bold-lead paragraph became a real
heading, and every number left standing was checked against a committed source
rather than an earlier draft's memory of one.
