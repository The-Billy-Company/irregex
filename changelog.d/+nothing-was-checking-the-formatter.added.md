CI never ran the formatter. It compiled the engine, ran the tests, ran the three
binding suites and ran the four ratchets, and in none of that did anything ask
`zig fmt` what it thought - so `zig fmt --check` was failing on committed code
and there was no way to find that out short of typing it yourself.

The drift that exposed it is worth describing, because it is not the kind you
catch by reading a diff. A rename shortened a string inside a column-aligned
multiline array literal. `zig fmt` pads those into a grid, so shrinking the
widest cell leaves every row beneath it one space too wide, and the rows that
move are in files nobody edited. Two test files were sitting wrong. The
embarrassing part is that Rust here already runs `cargo fmt --check` and
`cargo clippy -D warnings` on every push; Zig is the language this repository is
written in and was the one with no formatting gate at all.

So there is a sixth job, `fmt`, rather than a step bolted onto an existing one.
Formatter drift is its own kind of news and has earned its own red X - folding
it into `engine` would run it once per host for a verdict that cannot vary by
host, and folding it into `ratchets` would put a Zig toolchain into the one job
that deliberately has none. It pins the same `ZIG_VERSION` the engine builds
with, because the formatter's output is a property of the compiler release and a
gate on a different Zig checks a different grid.

The file set is enumerated from git rather than written down, since a
written-down path list drifts the same silent way the formatting did: the
invocation I caught this with by hand named `tools`, which holds no Zig at all,
and would have sailed straight past a new top-level directory that did. Tracked
plus untracked-not-ignored is every Zig file this repository owns. What it
leaves out is the ignored trees - `bindings/rust/target`, where cargo parks a
whole semver-checks copy of this repo, and `zig-pkg/` - and those are named in
`.gitignore`, where someone can review them, rather than being whatever happened
to fall outside an argument list.

I watched it go red before believing it: a deliberately mis-padded grid literal
in a throwaway file fails the job and names the file, and deleting the file
passes it again.
