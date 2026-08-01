The rename that scrubbed the monorepo's vocabulary out of the test fixtures left
two files crooked, because nobody re-ran `zig fmt` after it.
`anchor_test.zig` swapped `"WalletService"` for `"SessionStore"` and
`haystack_test.zig` grew a `.gist` row, both inside multiline array literals -
which the formatter lays out as a grid, every column padded to its widest cell.
Shorten the widest cell by one character and every row under it is one space too
wide, so the file stops round-tripping. The tokens never moved, which is exactly
why nothing noticed: CI runs `zig build check` and `zig build test`, and neither
of those formats anything. The tree passes `zig fmt --check` again, and the two
diffs are whitespace only - same bytes with the spaces removed, before and after.

The other leftover was two `doc_radar` pins in
`bench/rungs/multipattern/README.md`, which claimed
`bench/dominance/races/multipattern.sh` and
`bench/certificate/report/multipattern.py` sit under this root. Both left with
the product, and the prose in that same file already cites them as `../gist/…`.
A `paths_exist:` block is a claim about this package's disk, so a file in a
sibling checkout cannot be pinned there at all - the entries are gone rather than
reworded. Every `paths_exist:` entry in the tree resolves now.
