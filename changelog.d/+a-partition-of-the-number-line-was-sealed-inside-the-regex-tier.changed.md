`math.minterm` - the coarsest partition of a scalar line that a family of
interval sets cannot tell apart. Two scalars belong together when every set in the
family agrees about both, so a consumer that asked the family `n` questions per
input asks the partition one. The blocks are the atoms of the Boolean algebra the
family generates: its minterms.

This is not new code so much as code that was in the wrong place. The linear
engine's symbolic tier had been carrying it as `alphabet.zig`, specialized to
`u21` and to 512 predicates, sealed behind the regex facade where nothing else
could reach it - even though the algorithm knows nothing about regular
expressions, characters, or Unicode. It is interval arithmetic. So it moved to the
floor as `Space(Scalar, top, capacity)`, and `alphabet.zig` is now the three-line
adapter that picks Unicode's numbers and keeps the one genuinely regex-shaped
piece, interning a `ByteSet`. The regex seal is untouched and no zone variance was
needed, which is the test of whether a thing was actually general: a lexer
generator's character classes want the same partition, and now they can have it.

The construction refuses the textbook O(2ⁿ) of intersecting every subset of the
family. Every set's endpoints become open and close events on one line, sorted
once; between two consecutive endpoints the covering set is constant, so each gap
is an atom whose label is the live set of sets, and atoms sharing a label are the
same block. The label *is* the block's identity, so the partition arrives minimal
rather than minimized afterwards, at O(B log B) in endpoints.

Both ceilings now refuse instead of wrapping. Too many sets for the signature word
and too many minterms for a `Mint` to name are both `error.Oversized` - one member,
because that is one fact and the two bounds checks are only where it got noticed -
mapped by the symbolic tier onto the `too_large` decline it already had, where the
previous code reached a `@intCast` and would have panicked on a pattern wide enough
to overflow the predicate index. A partition too large to name is an error, not a
truncated one.

Tested against the definition rather than against a second implementation. Over
small spaces the oracle computes each scalar's membership signature by brute
force, then asserts the two things being a minterm partition means: two scalars
share a block if and only if their signatures are equal - stability in one
direction, minimality in the other. Over-splitting and under-splitting therefore
fail as separate assertions, which was confirmed by removing the interning step
and watching only the minimality half break. Randomized families, the top of the
space, empty and full sets, and the set-capacity boundary are checked besides.
