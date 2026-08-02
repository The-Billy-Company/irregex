A fifth Zig ratchet, `isa-floor`, over the class of bug that put SSSE3 into a
baseline wheel: an inline `asm` block selected by `builtin.cpu.arch` instead of
`builtin.cpu.has`. It is the one codegen mistake nothing else in the stack can
catch, because the compiler that would catch it is looking at a string.

The rule is one finding per asm block whose mnemonic is not in a small exempt
set and which no `cpu.has(` predicate covers between the enclosing `fn` and the
block. A negated guard counts - a leaf that `@compileError`s off-feature has
stated its precondition as clearly as one that branches.

The exempt set is the interesting part. It holds mnemonics in their
architecture's *mandatory* base ISA, where there is no optional feature to ask
about, and it currently holds one entry (`add`). Everything else fails closed:
an instruction nobody has classified needs a guard, so adding to the set is a
one-line change that puts the claim "this needs no optional feature" in front of
a reviewer instead of leaving it to silence.

The baseline is empty, which makes this a floor rather than a burn-down, and an
empty baseline is exactly the state where a gate can be quietly broken and look
identical to a gate that is working. So the detector proofs run it against the
verbatim pre-fix text of `lanes.shuffle` and require both findings back. Thirteen
of them, beside the driver, in CI next to the scan.
