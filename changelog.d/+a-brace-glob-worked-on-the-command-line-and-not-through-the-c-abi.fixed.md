`*.{js,ts}` now admits the same set through the C walk plane that it admits on a
command line. It used to be `IRGX_INVALID`, and the reason was nothing to do with
globs.

The brace expander was pure, nesting-aware and genuinely reusable, but it lived in
the argv value grammar and called the CLI's `oom()` at both of its allocation
sites. A function that can end its host's process is not one a library path may
call, so `walk.open` could not reach it and refused every alternation instead -
correctly, given it could not honor one, because a spec that quietly matched
nothing would have read exactly like a corpus that narrowed to nothing. Same
engine, same corpus, two different answers, purely because of which file the
expander happened to sit in.

It sits in `kernel/math/glob.zig` now, beside the matcher whose input it produces,
and it returns `error{OutOfMemory, BudgetExceeded}` instead of exiting. The CLI
keeps its loud death - `intent.Builder.addGlob` catches and calls `oom()` or
`die()` - which is the same division `charter.honorNoConfig` already draws for a
malformed charter: the kernel states the fault, the face decides it is fatal.

Expansion happens once, while the spec is materialized, not per candidate path,
which would have made a linear walk quadratic in the group's cartesian size. And
it is bounded, because `{a,b}{c,d}{e,f}…` multiplies: sixty-five bytes of spec
names 8,192 globs, so a host that accepted one from a stranger accepted an OOM.
1,024 patterns is the ceiling, plus a second one at 64 groups for `{a}{a}{a}…`,
whose product is ONE and which blows the stack anyway. Past either is
`BudgetExceeded` and never a shortened list - a truncated expansion answers about
a smaller corpus than the one asked about, and a glob is the least visible place in
a search for that to happen. It crosses as `IRGX_OOM`, with the fault name the
place a host learns the machine did not actually run out.

Nothing else got softer. An unclosed `{`, an unclosed `[`, and an unclosed `[`
hiding inside one alternative of a well-formed group are all still `IRGX_INVALID`.
The proof is a set comparison rather than a spot check: one walk spelled
`-g '*.{js,ts}'` and one spelled `-g '*.js' -g '*.ts'`, over a fixture holding
`app.tsx` as the near miss both have to reject, must list the same files.
