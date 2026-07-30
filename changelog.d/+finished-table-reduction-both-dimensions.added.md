A determinizer stops when it runs out of **reachable** states, and reachable is not
distinguishable. New `linear/automata/reduce.zig` collapses a finished dense table
down to the automaton it means, and it owns **both** dimensions such a table is
over-refined in: rows, where no suffix separates two states (Moore's refinement, i.e.
the Myhill-Nerode congruence), and columns, where no state routes two byte classes
differently. The order only runs one way and that is why they are one file rather than
two passes a caller sequences — merging rows is what makes whole columns coincide,
while merging columns can never create a row merge, because it does not change which
suffixes distinguish a state.

`symbolic/minimize.zig` is gone into it: the symbolic product carries a decoder phase
the pattern cannot observe, so its rows are redundant by construction and
`transcribe.zig` now asks for both dimensions in one call instead of running a
minimizer and then a class merge of its own. Its floor got **tighter** rather than
moved — the suite's `dfa.ncls <= byte.minimal_ncls` check now compares against the
*reduced* byte class count, so the symbolic lane can no longer pass on the byte road's
over-refinement instead of on what the language requires.

**The byte road declines both passes, on measurement, and that is the interesting
half.** `automata-rung -- reduce` prices each pass against the determinization that
produced the table and then times the same walker on the raw and reduced tables, over
three populations kept apart. Rows find 1 automaton in 32 for a geomean 19.4% of a
build, because interning on the NFA-state *set* has already landed that construction
near the Myhill-Nerode quotient. Forcing Unicode down the byte road is the shape that
should have paid, and on the byte counts it looks like it does: columns collapse on 4
trie rows in 5 for 0.6%, and `\w{3,8}` sheds a quarter of its states, a 1.0 MB table
to 729 KB. **The walk does not notice** — every row whose table shrank scans inside a
±8% noise floor, which is claim C2's "area is free at constant touched breadth" holding
one order of magnitude up from where it was measured.

Two things the section had to fix about itself to get an honest answer. Five `\p{…}`
rows had been compiled without `unicode`, built nothing, and been dropped by a bare
`catch return` — so the one shape whose states are indistinguishable *by construction*
had never been measured, and a row that will not compile now says so out loud. And the
one row whose *states* collapse materially cannot be timed at all: `\w{3,8}` accepts
any three word bytes, so no alphabet holding a word byte can spell a document it
misses. It reports `matched` rather than a ratio earned on a prefix.

The last residual is upstream of all of it. The single ASCII column merge is
`(a|b|…|h){10}`, 9 columns to 2, and it exists because the lowering walks the parser's
tree where that alternation is eight `consume` states — while `ast/algebra.zig` already
knows an alternation of byte classes *is* a byte class. Folding it there gives one
consuming set instead of eight and a determinization that is not the slate's third
slowest at 59 µs for 11 states, none of which a post-hoc column merge recovers. Filed
as its own claim rather than smuggled in here.

The instrument stays, which is what makes the decline revisitable: the `reduce` section
re-prices both passes and re-times both tables every run, so if a future lowering hands
that determinizer a shape which does pay, the `scan` column says so.
