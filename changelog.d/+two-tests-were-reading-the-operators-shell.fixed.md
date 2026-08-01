The two output-budget tests in `corpus.zig` now assert against the budget they
name, instead of against whatever `GIST_*` the shell that ran them happened to
export.

Both tests are claims about the DEFAULT ceiling - one that the budget charges
content rather than the escapes around it, one that a sharded merge cuts on
content so a decorated run keeps every file. Both opened by calling
`initOutputBudget(false)`, which reads `GIST_UNCAP`, `GIST_MAX_OUTPUT_TOKENS`
and `GIST_MAX_OUTPUT_BYTES` on its way to installing a ceiling. So a shell that
had run the bench harness - which exports `GIST_UNCAP=1`, and the comment three
lines above the read says so - lifted the soft guard, the merge stopped cutting,
and `a sharded merge cuts on content` failed with `expected 2, found null`. CI
was green the whole time, because CI has a clean environment. That is the worst
shape a test can have: it is not wrong often enough to get fixed, and it is
wrong exactly when the person running it has been doing the measurement work.

The tempting fix is to have the tests set the variables they want and put them
back. I did not do that, for two reasons. It leaves the design defect in place -
a function that silently consults global state stays harder to reason about than
one handed its inputs, and the test difficulty was the symptom, not the disease.
And it makes every test in the process share one mutable environment, which
trades a flake that at least reproduces for one that depends on test order.

So the budget got the split it already wanted. `resolveOutputBudget` reads the
flag and the three knobs and returns a `Budget`, and that is all it does;
`installOutputBudget` binds a `Budget` and resets the run counters, and that is
all IT does. `initOutputBudget` is now those two composed, so production is
unchanged - the CLI still calls the same function, and `GIST_UNCAP` still lifts
the soft guard for the harness that depends on it. The two ceilings moved out of
the counter struct into `Budget` so there is one definition of them rather than
two, and `Budget.default` is what a run with no flag and no environment is bound
by. The tests install `.default` and say so.

This is the shape `assay.install` already uses for the trace mask, whose
`lenses: ?u32` exists, in its own words, "for the callers that have no
environment to read: an embedder of the C ABI ..., and a test that must light a
lens deterministically." A budget is the same kind of fact, and now has the same
kind of seam. It also means the C-ABI embedder can state a ceiling outright,
which it previously could only do by editing the host process's environment.

Verified both ways round. The two tests pass with the three variables unset,
with `GIST_UNCAP=1`, with `GIST_MAX_OUTPUT_BYTES=99991`, with
`GIST_MAX_OUTPUT_TOKENS=1000`, and with all three at once - where before they
failed under every one of those. Production was A/B'd by building the same probe
against the old and new code and driving `initOutputBudget` through twelve
environments (each knob alone, the falsy `GIST_UNCAP=0`, the `--uncap` flag with
no env, `GIST_MAX_OUTPUT_BYTES=0`, and the overlapping pairs): the resolved
ceilings are identical, line for line.

One sibling has the same disease and a different cure, so it is reported rather
than papered over here: `resident_test.zig`'s `a covered root stays warm` writes
a `src/` subdirectory into its fixture and queries with that as an explicit root,
so an inherited `<GIST_DIR>/skips.list` naming `src` prunes the fixture's own
directory, the session correctly declines, and the test panics reaching for
`.got`. That is the same class as the `GIST_DIR` inheritance that already bit
`haystack_test`, but the fix is a corpus-scope question rather than a
policy-install one, and guessing at it inside a budget change would be worse
than naming it.
