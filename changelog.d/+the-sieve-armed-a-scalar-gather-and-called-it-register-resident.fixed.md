On a generic x86_64 build the quotient sieve armed a pre-pass that was slower
than the DFA the pre-pass exists to skip.

`sheng.resident` decides whether the sieve is worth running, and its own
docstring says what it means: "False on targets where `lanes.shuffle` degrades
to a scalar gather." It did not ask that. It read `switch (builtin.cpu.arch) {
.aarch64, .aarch64_be, .x86_64 => true, else => false }`. But `lanes.shuffle`
lowers to `pshufb` only under SSSE3, and the x86_64 baseline is SSE2 - so on any
build that did not raise its floor, `resident` was true while the kernel
underneath it was a sixteen-element scalar gather, per byte, in front of a DFA
that would have been cheaper alone.

The published wheels were not affected: they build `x86_64_v2`, which carries
SSSE3, and that is the same floor-raising that fixed the `pshufb`-under-SSE2 bug
earlier. What was affected is every from-source build at the default floor -
`zig build`, a distro rebuild, anyone who took the declared baseline at its
word.

The predicate now names its dependency instead of guessing at it. `lanes` has
always known which of its three arms it compiled; it just never said so out
loud. It publishes that as `lanes.arm`, and `resident` is `tbl.arm != .portable`
- one question, asked once, by the module that has the answer. There is no
second derivation left to drift.
