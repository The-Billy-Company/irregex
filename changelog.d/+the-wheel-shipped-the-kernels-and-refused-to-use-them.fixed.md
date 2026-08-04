A calibration row is now claimed by the byte-permute it was measured over
instead of by the CPU it was measured on, and the published manylinux wheel
gets its vector rungs back.

`Calibration.hosts` - a list of `builtin.cpu.model.name` prefixes - is replaced
by `Calibration.isa`, one member of the new `lanes.Isa` (`portable`, `ssse3`,
`avx`, `neon`). `price.active` selects the row whose class equals this build's
`lanes.isa`. Both sides are comptime reads of the same feature bits that chose
the SIMD arms in the first place, so a row is selected by the property its
coefficients are a function of.

The wheel is the reason. Its declared floor is x86-64-v2, so its model name is
`x86_64_v2`, so it matched neither `apple_` nor `raptorlake`, so it fell to
`unmeasured` - and `measured = false` is what the vector rungs consult before
bidding. The thing most people install had the SSSE3 composition and the
Parabix transposition compiled into it and never let either one bid, and
nothing anywhere said so. Being precise about who a row spoke for had turned
into almost nobody having one.

Selecting on the permute is the middle of two spellings that were both wrong.
`builtin.cpu.arch` claimed too much: every AArch64 target read the Apple row,
so a Graviton, an Ampere part and a Raspberry Pi bid an M4 Max's ratios. The
model name then claimed too little, in the way above. The permute is what the
numbers actually vary on, and they vary a lot - `compose_eol` is 40% dearer
under legacy `pshufb` than under VEX `vpshufb` on the identical core, and the
two Parabix halves come out nearly inverted between them.

A third row, `ssse3`, is minted for that floor. It is the same i5-13500 built
`-Dcpu=x86_64_v2`, so the core is held fixed and the only difference from `avx`
is the encoding. A real v2-only part is older than that core, which makes these
numbers a modern CPU executing a conservative build - the case that actually
ships rather than a hypothetical Nehalem.

Giving the v2 floor a row of its own also changes what the auction does there,
which is the point of having one. `compose_eol` at 1.418 against a 1.924 walk
means the end-of-line composition LOSES on that floor where it wins on AVX at
1.008 against 2.001, so `^[a-z]{6}[0-9]$` now goes to the fallback - and the
bench measures that composition at 2.27 cyc/B, exactly what the row predicts,
with worst regret across the slate at 1.00x. Two tests had been reading the
agreement of the two rows that existed as a law and had to be told it was a
measurement instead: one asserted the widest composition beats its walk with the
end-of-line index on, which is now asked of the plain form (true everywhere) and
pinned per class for the `+eol` form; the other floored a differential's case
count at what the richest build arms, which failed the leaner build for arming
correctly.

The claim is now wider than the measurement behind it: a row speaks for every
core in its class. That is the trade, taken deliberately, and `verify` is the
instrument that reports when a given machine disagrees with its class. There is
no AVX-512 member, because `shuffle` has no `vpermi2b` arm and a class for it
would name a kernel this engine cannot build.

`lanes.Isa` lives beside `shuffle` and `widest` rather than in the price plane,
with a test holding the class and the lane cap in step, so adding an arm without
a class fails at the arm rather than silently pricing the new one as the old.
