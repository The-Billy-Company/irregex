`libirgx` grew a slate plane: `irgx_slate_compile` takes N patterns, and
`irgx_slate_is_match` / `irgx_slate_which` answer about all of them in one pass
over the text, with attribution. Everything else in this ABI is about one
pattern, and the two ways a C host had to fake this were both bad. N calls to
`irgx_is_match` read the bytes N times. One fused `a|b|c` reads them once and
throws away which pattern hit, which is usually the answer you wanted.

The kernel has had this for a while - it is what `gist`'s `patterns` verb runs
on, but it had it in the wrong unit. `PatternSet.docMask` answers per LINE, which
is right for a grep walking a corpus and wrong for a plane whose neighbor treats
the whole text as one unit: `^b` over `"a\nb"` is a match to a grep and not a
match to a regex library, and shipping the line face would have meant one
library telling a host two different things about the same string. So the kernel
grew the buffer face first - `bufMask` / `bufAnyMatch`, confirming through the
same `holds` the single-pattern plane goes through - and the parity suite holds
it to `irgx_is_match` pattern by pattern, with the SIMD prefilter on and off,
because a prefilter that changes an answer is a prefilter with a bug.

The fused gate the line face uses is deliberately not on this path. It is an
alternation of every pattern, which over-approximates per line and is unsound
per buffer: `a\sb` over `"a\nb"` matches the buffer and no line, so a gate that
says no would have withheld a real match.

`*refused` is the part a single pattern never needed. With two hundred patterns,
"one of them is unsupported" is not something you can act on, so a refusal names
the index, and it names it in the vocabulary `irgx_compile` already uses -
`IRGX_STALE` when `IRGX_PCRE` would take the pattern, a located `BadPattern`
when nothing will. It costs one recompile per pattern on a path that already
failed, and it is the only way to answer the question a host actually has.

There is no per-pattern span verb, and that is the edge rather than an omission.
A slate is a classifier: once you know pattern 7 is in this text,
`irgx_find_all` on pattern 7 is the walk you were going to run anyway, against a
text that is now known to be worth walking. `Munch` stayed out too - it has a
Zig consumer and no C one, and a verb minted for nobody is a verb that gets
maintained for nobody.
