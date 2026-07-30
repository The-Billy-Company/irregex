The corpus byte-density table stopped throwing away the ordering it exists to carry.

`rarity.zig` stored `min(255, P·32768)` in a `[256]u8`. The clamp was the load-bearing
part: 30 printable bytes hit the ceiling, 20 of the 26 lowercase letters among them, so
for a lowercase identifier every byte scored the same and the table had no opinion about
which two the block filter should compare. Anchor selection then fell through to whatever
its tie-break happened to do, and the module doc's "only the coarse ordering matters"
was true in exactly the way that made this fatal - the clamp destroyed the only property
the table promised.

It is now `[256]u16` at `round(P · 65535)`, unclamped, re-measured over 253 MB of the
tree (24,602 text files) by a checked-in generator, `tools/build_rarity_table.py`, so a
regeneration is a reviewable diff rather than a hand-edit. On that census the old
representation left 423 printable pairs and 171 lowercase pairs sharing a cell despite
differing in real frequency; the new one leaves 7 printable pairs and no lowercase pair,
with only the space at the top of the range and zero rank inversions across all 256 cells.
The 7 survivors are bytes whose true frequencies differ by under 0.7% (`{`/`}` by 0.05%),
where a tie is an honest statement rather than a representation failure.

Measured with the anchor policy held fixed and only the table varying, over the 203 MB
code corpus and 128 MB prose corpus of `research/pincer/`, priced against the best pair
that exists for each needle: **2.55x -> 1.50x of oracle survivors on code** and
**2.99x -> 2.21x on prose**. Against the selector as it shipped before any of this
(4.61x code, 6.97x prose) the two repairs together are 3.08x and 3.15x. The prose figure
is honestly cross-distribution: this is a code-corpus prior, and a prose-fitted census
reaches 1.76x there.

`single_probe_max` moved 48 -> 96, which is the same 0.15% probability bar under the new
denominator, not a policy change. `analysis/prefilter.zig` lost the sentinel branch that
expanded a saturated cell to a guessed 2048 - a made-up number that priced the space
identically to `c` - and its `probability_scale` tracks the table's scale so every
`stride` bar calibrated against it is unchanged.

Byte-exactness is unaffected by construction: the table decides which filter runs, never
which positions match, and every survivor is still `memcmp` verified.
