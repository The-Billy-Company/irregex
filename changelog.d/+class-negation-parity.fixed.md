Three ways a character class could disagree with ripgrep, all of them found while
re-reading the class parser rather than by a bug report, and all three the same
mistake wearing different hats: taking a complement in the wrong place.

`-i` over a negated class was matching the character it excludes. The fold ran as
a pass over the finished tree, so `[^k]` had already become "everything but `k`" -
which still holds `K` - and folding that set handed `k` straight back.
`gist -i '[^k]'` matched both `k` and `K` where rg matches neither. The fold now
happens before the complement, on the members as written, which is what rust-regex
does; the later whole-tree pass is left in place because a fold-closed set is
closed under folding again, so it can only be a no-op. That covers `[^k]`,
`[^a-z]`, `\P{Lu}`, and both POSIX spellings.

A shorthand class was allowed to bound a range. `[a-\d]` quietly meant `a`, a
literal `-`, and `\d`, and `[A-\d]` meant the range `A`-`\` plus `d`; rg rejects
both with "invalid range boundary, must be a literal". Now so do we, on either
side of the dash and in both engine modes. The byte path got the same
literal-vs-class split the Unicode path already had, which fixed a third thing on
the way: `(?-u)[\t-\r]` was three literal bytes instead of the range 0x09-0x0D, so
it never matched a vertical tab.

And `[[:^lower:]]` complemented the 256 bytes rather than the whole scalar space,
so in Unicode mode it admitted `é` but not `日`. The POSIX reader no longer applies
the complement itself - it reports what the bracket said and each mode takes the
complement in its own universe, bytes under `(?-u)` and scalars otherwise. The
outer spelling `[^[:lower:]]` was always right, which is how the split surfaced.

648 pattern/flag/corpus comparisons against rg now agree, where the same sweep
caught all three of these before, and each fix carries a parser-level test that
fails if you back the fix out.
