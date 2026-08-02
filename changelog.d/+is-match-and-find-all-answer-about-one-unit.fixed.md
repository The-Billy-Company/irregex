`irgx_is_match` and `irgx_find_all` disagreed about every anchored
pattern. `c$` over `"abc\n"` was a match to one and no match to the other; so
were `^a` over `"\nabc"`, `\Aabc\z` over `"x\nabc\ny"`, and 19 of 54 probed
pairs. Two independent bindings hit it while being written, and both had to
route their predicate through `find_all` to get one answer out of the library.

`is_match` was riding the boolean *document* kernel, which is the faster
routine but answers a different question: it splits a buffer into lines and
asks whether any line matches, so `^` and `$` become per-line anchors. In this
plane the buffer IS the unit - there is no corpus behind it - so those are its
ends, which is what `find_all` and `captures` already said. It now runs the
same walk `find_all` runs, stopped at the first span.

Which meant giving the kernel one walk instead of two. `collectSpans` and the
new line-scoped `holds` predicate share `walk`, whose only difference is
whether there is a sink to append to; a null sink returns at the first span.
The empty-match, adjacency and `-w` rules are subtle enough that a
hand-written second version is precisely how a predicate starts disagreeing
with the list it summarizes, which is the bug above. An iterator would have
been the obvious shape and is the wrong one here: splitting the walk into an
inner and an outer loop cost a measured 2.5% on short matches, and 3.8% on a
nullable pattern once inlined to win the first back. `walk` is `inline` with
a comptime-known sink instead, so each caller still compiles to the single
tight loop, measured at parity on both shapes.

Also: `irgx_compile` rejected a NULL pattern of length zero, though the
empty pattern compiles fine and every search verb already reads NULL with
length zero as the empty text. A language whose empty string carries no data
pointer, like Go, hands that in without meaning anything by it.
