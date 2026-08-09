`math.succinct.parens` — an ordinal tree stored as a balanced-parenthesis bit
string with a range min-max tree over it, so a tree of n nodes costs 2n bits
plus a small index and still answers parent, children, siblings, depth, subtree
size, preorder, ancestor, and LCA.

The three succinct structures already here (`sais`, `rrr`, `wavelet`) all
answer questions about a *sequence*; there was nothing that answered questions
about a *tree*, so anyone needing one paid for pointers - 8 or 16 bytes a node
against 2 bits, three orders of magnitude, plus a pointer chase per hop.

The whole file rests on one observation: a parenthesis string is a ±1 walk, and
the excess after k parens is `2·rank1(k) - k`, which `rrr.Plain` already
answers in O(1). Every tree question is then the same question about that
walk - "the nearest position, forward or back, holding this target excess". The
matching close is the next position at the same excess; the parent is the
previous position one below; the LCA of a and b is the previous position one
below the minimum excess over `[a, b]`. So there is one primitive in two
directions, and `findClose` / `findOpen` / `enclose` / `lca` / `firstChild` /
`lastChild` / `nextSibling` / `prevSibling` / `subtreeSize` / `isAncestor` are
all spellings of it rather than separate machinery.

Making that walk sublinear is the range min-max tree (Sadakane & Navarro, SODA
2010): a segment tree over 512-bit blocks storing the min and max excess each
block reaches. A block whose `[min, max]` excludes the target cannot contain it
and is skipped whole; a block that might contain it is scanned a byte at a time
through a 256-entry table of per-byte (sum, min, max). That is
O(b/8 + log(n/b)) - about 64 table lookups worst case plus a shallow descent -
against the O(n) a naive rescan of the bit string costs. `rank`/`excess`/`depth`/`preorder` stay
O(1) on the rank sample; `select` is O(log n) by binary search over it.

Measured on random shapes from 1e3 to 1e7 nodes (M-series, ReleaseFast, 1e6
cold random probes): 2.65-2.96 total bits per node, `depth` 6.6 ns,
`findClose` and `enclose` 23-31 ns, `lca` 104-254 ns, build 87.9 ms at 1e7
nodes. Four orders of magnitude of n buys 1.35x on `findClose`, which is what a
log-depth descent over a tree that does not fit in cache should look like. The
space figure is stated as measured rather than as "2n + o(n)": with `b` fixed
at 512 the index is Θ(n/b), a small constant fraction of n, and only o(n) in
the textbook setting where `b` grows.

**This is the static structure**, and that is a deliberate stopping point. A
tree that survives edits needs the bit string itself to become a balanced tree
of blocks so an insert is O(log n) rather than a memmove, which means it cannot
ride `rrr.Plain` at all. That is a different substrate, not a flag on this one.

Every operation is tested against a naive stack walk over randomized balanced
sequences up to 2,000 pairs - the oracle builds the parent, depth, and match
tables by pushing and popping, and knows nothing about excess, blocks, or
min-max trees - plus the shapes random generation will not produce on its own:
empty, one node, a left chain 900 deep, a flat comb whose excess never leaves
{0, 1}, a maximum-fan-out star, and a match placed to land at `blk-2`,
`blk-1`, `blk`, `blk+1`, `2·blk` and `2·blk+1`, which is exactly the case an
in-block scan alone cannot answer and so is the climb-and-descend path or
nothing.
