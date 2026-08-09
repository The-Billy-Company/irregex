An anchored search no longer pays for a leftmost hunt it throws away.

`findAt`, `isMatchAt`, and the anchored walk all meant the same thing: search
leftmost, then discard the answer unless it began exactly where the search did.
Exact, and it paid for every position it was never allowed to report from - the
whole distance to a match that could not be the answer. On a megabyte whose only
match sits at the far end, deciding that nothing begins at offset 0 cost 146 us.

The anchored determinization has existed since the determinizer was written - it is
the `anchored` argument to `Subset.init`. It just had no route up: seeded once and
never renewed, so an acceptance proves a match begins where the walk began, and a
drained thread set proves none does. Wired through the match seam as
`Matcher.Probe`, an anchored ask now stops at `min(first accept, death)` instead of
scanning on.

Measured per function rather than by re-running a suite, inherited algorithm against
new one in one binary over one haystack, best of five alternating rounds:

| case | bytes | before | after |
|---|---|---|---|
| `findAt`, nothing begins at `from` | 1 Ki | 116 ns | 12.1 ns |
| `findAt`, nothing begins at `from` | 1 Mi | 145,750 ns | 11.9 ns |
| `isMatchAt`, nothing begins at `from` | 1 Mi | 151,313 ns | 8.0 ns |
| anchored walk, 8 matches then a gap | 64 Ki | 9,066 ns | 161 ns |
| `findAt`, a match DOES begin at `from` | 64 Ki | 8,977 ns | 8,969 ns |
| anchored walk, dense run, no gap | 16 Ki | 281,625 ns | 286,625 ns |
| `findIn`, unanchored (control) | 64 Ki | 9,367 ns | 9,172 ns |

Flat where it used to be linear in the distance to a match it would reject. The last
three rows are the honest other side: where a match really does begin at `from` the
halting walk cannot save the leftmost pass, so its cost is added rather than traded -
about 8 ns fixed, and 2-3% on a walk whose every step matches. The unanchored path
opens no machine at all and measures unchanged.

Output is identical, and not by inspection: the inherited algorithm is written out
inside `glean_test.zig` as the oracle and a generated slate of 1,500 patterns over
six haystacks requires the anchored walk to agree with it span for span, on both
the patterns that get a machine and the patterns that decline one.
