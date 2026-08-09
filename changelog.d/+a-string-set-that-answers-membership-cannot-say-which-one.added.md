`math.dafsa` - a set of strings stored as the smallest automaton accepting it,
built by inserting sorted keys and hash-consing each state the moment nothing can
be added to it again, so it is minimal at every step rather than built large and
minimized afterwards.

The reason to reach for it over a sorted array is not the size. It is the
**ordinal**. Every state knows how many keys it accepts, so the same walk that
answers `contains` can count the keys sorting before the one it is walking:
`rank` is an order-preserving minimal perfect hash onto `0..count`, obtained from
the bytes that already answer membership. Put the payloads in a flat array, index
it with `rank`, and no key is stored twice. `spell` inverts it, which is what
makes this a bijection rather than a one-way hash you hope is injective.

Which matters because the size claim, measured, does not hold in general.
Compression here is entirely the tails the keys have in common, so it is a
property of the corpus and not of the structure. At a fixed 4,096 keys, moving
from 4,096 distinct tails to 64 tails shared 64 ways moves the resident size from
1.33x a sorted array's to 11.1x. Point it at 34-byte keys with genuinely unshared
25-byte stems - file paths, roughly - and it **loses to a sorted array by 7 to
8x**, at every count from 128 keys to 32,768, with no crossing. `rank` holds
across all of it at 27 to 108 ns per key, pointer-free, and is unavailable from
the array at any size. Come here for the ordinal.

Sorted input is required and checked, because ascending order is what lets a
state be sealed the moment the next key diverges from it. Daciuk et al. give a
second algorithm for unsorted input that clones states on the way; it is a much
larger piece of code and a caller who sorts first does not need it. So unsorted
input is `error.NonCanonical` rather than a wrong automaton - equal neighbours
included, since a set has no duplicates and silently dropping one would make
`rank` disagree with the caller's own array.

It deliberately does not sit on `dag.zig`, which looks like the right floor and
is not: a `Dag` node is a payload plus exactly `arity` children fixed at comptime,
where a DAFSA state's fan-out is whatever the keys gave it. That would mean a
wasted `[256]Id` per state or an edge list smuggled into the payload, at which
point `Dag` contributes a hash table and nothing else. What is shared is the
discipline, not the type: structural identity, and children interned before
parents, so every id points strictly downward and one ascending sweep counts what
each state accepts.

Tested against a third route rather than against itself. The oracle builds the
plain trie over the same keys and quotients it with `math.refine` - Revuz's road
instead of Daciuk's - and the state counts must agree exactly, which also gives
`refine` its first in-package consumer. Language exactness, the rank/spell
bijection over the whole set, and near-misses (every key with one byte changed,
truncated, and extended) are checked besides.
