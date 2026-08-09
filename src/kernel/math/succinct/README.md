# `src/kernel/math/succinct/` — structure math

Generic succinct structures the codex composes, not FM-private ones. They were
lifted out of the old monolithic `corpus/index/codex/` so SA-IS, RRR, and the
wavelet tree are reusable math on the floor, while the FM composition lives in
`src/kernel/codex/` and the persisted `SHLF` artifact lives in
`src/corpus/index/shelf/`.

- **`sais.zig`** wraps the vendored libsais suffix-array construction, the
  O(n) sort (Nong–Zhang–Chan) the codex's suffix array is built from.
- **`rrr.zig`** implements O(1)-rank bitvectors behind one seam, plain words
  or Raman–Raman–Rao block coding, chosen per vector by measured size.
- **`wavelet.zig`** builds the canonical-Huffman wavelet tree that turns a
  sequence of those bitvectors into one rank/access oracle over a small
  alphabet.
- **`parens.zig`** is the odd one out: it is not part of the FM composition at
  all. It stores an ordinal tree as a balanced-parenthesis bit string with a
  range min-max tree over it, so a tree of n nodes costs 2n bits plus a small
  index and still answers parent, children, siblings, depth, subtree size,
  preorder, ancestor, and LCA. Measured at 2.65-2.96 bits per node.

## Why balanced parentheses is here and not in the codex

The other three exist to answer questions about a *sequence*. `parens.zig`
answers questions about a *tree*, and it does it without pointers; every
navigation op is arithmetic over the same bit string, through `rrr.Plain`'s
rank. Nothing in this package's search path uses it yet - it is the shared
floor a sibling package's parser sits on, which is why it lives on the math
tier rather than inside whoever calls it first.

The trick is that a parenthesis string is a ±1 walk. Write `E(k)` for the
excess after reading the first k parens, i.e. opens minus closes, which is
`2·rank1(k) - k` and so is one rank query. Then every tree question is the same
question about that walk:

| you want | you are asking |
|---|---|
| `findClose(i)` | the next k with `E(k) = E(i)` |
| `findOpen(i)` | the previous k with `E(k) = E(i+1)` |
| `enclose(i)` (the parent) | the previous k with `E(k) = E(i) - 1` |
| `lca(a, b)` | the previous k with `E(k) = min E over [a, b] - 1` |

So there is really one primitive - "walk to the nearest position holding a
target excess" - in a forward and a backward flavour, and the range min-max
tree is what makes that walk sub-linear. It is a segment tree over 512-bit
blocks storing the min and max excess each block reaches. If the target is
outside a block's `[min, max]` the block cannot hold it and the walk skips the
whole thing; if it is inside, we scan the block a byte at a time through a
256-entry table of per-byte (sum, min, max). That is O(b/8 + log(n/b)) with
b = 512, so ~64 table lookups worst case plus a shallow tree descent.

`rank`/`excess`/`depth`/`preorder` are O(1) up to the rank sample; `select` is
a binary search over those samples, O(log n). Everything else is the min-max
walk.

On space, be precise rather than flattering. The parenthesis string itself is
exactly 2n bits, which is the information-theoretic floor. The index on top is
the rank samples (one u32 per 512 bits) plus the min-max tree (an 8-byte
min/max pair per node over `ceilPow2(2n/512)` leaves), so it is Θ(n/b) with b
fixed at 512 - genuinely o(n) only in the textbook setting where b grows with
n, and a small constant fraction of n here. Measured end to end:

| nodes | total bits/node | build |
|---|---|---|
| 1e3 | 2.784 | <0.1 ms |
| 1e5 | 2.781 | 0.6 ms |
| 1e6 | 2.649 | 5.9 ms |
| 1e7 | 2.964 | 87.9 ms |

The ratio is flat rather than growing, and the wobble is the tree rounding its
leaf count up to a power of two - worst at 1e7, where 39,063 blocks round to
65,536. Query cost on the same machine (M-series, ReleaseFast, 1e6 random
probes, so every one is a cache miss): `depth` 6.6 ns, `findClose` and
`enclose` 23-31 ns each, `lca` 104-254 ns. The growth from 1e3 to 1e7 is four
orders of magnitude of n for ~1.35x on `findClose`, which is what a log-depth
descent over a cold tree is supposed to look like.

**This is the static structure.** The spec's downstream consumer wants a tree
that survives edits, and a dynamic BP (Navarro-Sadakane's dynamic variant)
needs a different substrate: the bit string has to become a balanced tree of
blocks so an insert is O(log n) rather than a memmove, which means it cannot
ride `rrr.Plain` at all. That is a separate structure, not a flag on this one.

### Prior art

- [Jacobson, *Space-efficient Static Trees and Graphs* (FOCS
  1989)](https://doi.org/10.1109/SFCS.1989.63533) - where rank/select over a
  bit vector became a tree representation in the first place; the level-order
  encoding, and the observation that o(n) extra bits buy O(1) navigation.
- [Munro & Raman, *Succinct Representation of Balanced Parentheses and Static
  Trees* (SICOMP 2001)](https://doi.org/10.1137/S0097539799364092) - the 2n +
  o(n) bound this file's space claim is measured against, and `findClose` /
  `enclose` as the primitive operations rather than derived ones.
- [Sadakane & Navarro, *Fully-Functional Succinct Trees* (SODA
  2010)](https://arxiv.org/abs/0905.0768) - the range min-max tree, which is
  the actual idea here: one tree over excess replaces the pile of
  special-cased structures Munro-Raman needed, and it is what makes the
  operation table above collapse into a single primitive. The extended journal
  version (Navarro & Sadakane, ACM TALG 10(3), 2014) adds the dynamic variant
  we did not build; §5 of it is the reference if someone picks that up.

Edit here for new succinct structure math: a different suffix-sort seam, a
rank/select variant, anything that is arithmetic over bits rather than an
opinion about a corpus. The FM-index composition that wires SA-IS, RRR, and the
wavelet tree into a restorable self-index lives in `src/kernel/codex/`.
