The parabix and shuffle suites now run on every architecture, not just the one
the rungs ship on.

Both rungs are AArch64-only on purpose. `plane.on_neon` and `lanes.native` are
compile-time predicates about where the throughput was measured, and off AArch64
the field stays null and the ladder falls through unchanged. That part was fine.
What was not fine is that thirteen tests in those two directories read the
production entrance and assumed it had armed, so the first time CI ran the suite
on Linux it came back with seven differential failures, four `RungDeclined`s, two
`.target`-instead-of-`.star_height` mismatches, and two `SIGABRT`s from
unwrapping a null build.

None of that was an engine defect. `.target` is decided before any other refusal
reason and short-circuits all of them, so every shape gate off AArch64 was
asserting nothing but a column of `.target`s, and every differential floor
(`admitted > 100`, `armed > 1000`, `slice_yes > 100`) was unmeetable because
nothing armed. The vacuity guards were doing exactly their job; they were the
only reason this was visible at all.

The fix is not to skip. `admit.planFor(comptime neon, …)` already existed for
this exact reason - so the gate test could drive the verdict the *other* build
produces - and everything under the arch predicate is portable Zig that means
the same thing everywhere: the lowering, the marker chain, the lane assignment,
the end-of-line axis, the `slice_safe` proof. `lanes.run` already carries a
portable fold to drive it through. So the seam grew two siblings,
`Parabix.buildFor` and `Compose.lowerFor`, the suites pass `true`, and all three
parabix oracles plus all four shuffle layers now run wherever CI runs. Nothing in
production passes anything but the real predicate, and the gate that decides it
keeps its own test on both sides.

Two tests skip off AArch64 instead, because the ladder's arming decision *is*
their subject: the auction against an armed literal skip, and the `sliceSafe`
proof driven through `re.rungs.compose`. There is no tier there to hold to a
slice question.

Measured after the change, on a real x86_64 Linux ELF built for `x86_64_v3` and
run in an amd64 container: 377,640 compose line-and-doc cases, 23,220 parabix
verdicts, 0 divergences, all eight shards green. Which is the answer to the
question the red CI was actually asking - the machinery agrees with the Pike VM
on both architectures, and now we find out from a test rather than from a user.
