A slate now builds the accelerators for the face it will be asked:
`PatternSet.compileFor(gpa, specs, .buffer)` skips the fused gate, and the C ABI's
slate plane compiles that way. `PatternSet.compile` is the line face's
constructor and is unchanged, so every corpus walk in the ecosystem compiles
exactly what it did before.

The gate is one `CompiledQuery` over `(?:p0)|(?:p1)|…`, so unlike everything else
in a slate its price grows with the whole slate rather than with any one pattern.
The buffer face cannot use it at any price - an alternation over-approximates per
line and is outright unsound per buffer, which is why `bufMask` never consulted
it - so a C host was paying, at compile time, for the one accelerator that could
never answer its question.

That is the difference between an ABI you can hand two hundred patterns and one
you can't. `irgx_slate_compile` over 200 patterns of the shape `a<i>x+\d?` cost
about 5.5 s with the gate; without it the slate compiles at parity with
compiling the same patterns one at a time (0.5x-0.8x of that, since the muster
pools their literals in one pass). The realistic case moved even further: the
eight mixed patterns the binding suites use went from ~175 ms to 3.2 ms, and the
Python suite's 497 tests from 35 s to 6.6 s.

The muster stays on both faces, because both faces use it. A prefilter you run
is worth its compile; a gate you refuse to run is not.
