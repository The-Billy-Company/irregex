Every SIMD kernel here had a scalar oracle and a differential against it, and
three of them were proving less than they looked like they were proving. The
pattern is the same each time: a build compiles one arm and comptime-prunes the
rest, so a test that goes through the front door only ever exercises whichever
arm the host happened to have.

**The shuffle primitive.** `lanes.shuffle` has three arms - NEON `tbl`, SSSE3
`pshufb`, and a portable gather - and the portable one was reachable from no
test on no machine. CI runs macOS/aarch64 and Linux/x86_64-native, and the
shipped artifacts declare floors (`aarch64` baseline, `x86_64_v2`) that carry
one of the two instructions; the arm that a `-Dcpu=baseline` build, a distro
rebuild, or any third architecture actually executes had never run. It is now
`pub fn shufflePortable`, compiled on every target, and `lanes_test.zig` holds
the host's real instruction to it - so two CI hosts pin all three arms to one
statement, because each asm arm is proved against the same shared reference.
Three layers: hardware against portable over the in-range domain; an
independently written restatement against both, which is what keeps the test
honest on a build where those two are one function; and a characterization of
where the arms disagree above index 15, so "these all do the same thing, drop
the check" cannot pass review by being plausible. The 32-lane `shufflePair` gets
the same treatment where NEON exists, and skips loudly where it does not.

The in-range precondition is now asserted rather than documented, in
`lanes.shuffle` and in `classrun.pshufb` (whose contract is the opposite one -
truffle *relies* on the zeroing). Out of range the arms do not agree, so a
caller that drifts does not get a wrong answer, it gets a different wrong answer
per architecture, which no single-host test can see. The assert is live in every
safe build and free in ReleaseFast, so the whole existing differential corpus
now doubles as a probe for it. Nothing tripped, which is the answer I wanted.

**The compose rung's own kernel differential.** "The vector fold equals the
scalar definition" compared `lanes.run` against `lanes.reference`. Off AArch64,
`run` dispatches to `runPortable`, and `reference` *is* `runPortable` - so on
every Linux CI run it compared a function to itself and reported two thousand
agreeing cases having proved none of them. It drives `runNative` now, which runs
anywhere for the 16-lane width and, on SSSE3, exercises a `pshufb` composition
production never reaches. The case count is asserted per target so a silently
halved corpus shows up as a moved number.

**The whole-buffer sieve.** `sheng.survivesDoc` cuts a buffer at newlines,
advances four shuffle chains in lockstep, folds per-lane accumulators and
finishes each remainder from the state its lane reached. No test called it. The
one doc-grain test drove the per-line entry over 64-byte buffers, and the lane
split needs 256 bytes to engage at all. There are now three: a randomized
differential against the scalar oracle over multi-line buffers, a sweep that
plants a derived positive at every offset so tails and cut-straddling matches
are covered by construction rather than by hand-computed offsets, and a geometry
pass over the split's three ways to decline. Each asserts a floor on
`sheng.lanesEngaged`, a new predicate that asks the kernel whether it took the
lane path, because a corpus of too-short buffers passes while executing nothing.

**The JSON escaper.** `jsonstr.nextEscape` scans for the next byte needing an
escape with a vector block loop and a scalar tail. Its two tests ran on 11-byte
and 4-byte strings, and `vlen` is at least 16 everywhere, so the block loop had
never executed. Three differentials now sweep length by plant-offset by start
across the block/tail seam - the width is target-chosen, so the seam moves per
build and cannot be probed with a fixed fixture - plus a random pass over every
byte value and an end-to-end check of `write` against a byte-at-a-time escaper.

All of it is mutation-verified rather than assumed. A one-lane rotation in
`shufflePortable`, a one-byte-short tail in `docLanes`, and a narrowed control
test in `nextEscape`'s vector arm: each is caught, and for the escaper the two
pre-existing fixture tests pass through the bug the three new ones catch, which
is the blind spot stated as a measurement.
