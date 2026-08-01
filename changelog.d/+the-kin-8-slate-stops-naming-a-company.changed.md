The `kin-8` slate in `bench/rungs/patternid` spelled its eight patterns
`billy_{wallet,ledger,audit}_{grant,debit,hold}`, which named the monorepo this
package came out of for no measurement reason. The prefix is now `store_`.

The swap is measurement-neutral, and that was checked rather than assumed. What
this slate exercises is subset collision between patterns that share a prefix and
share a suffix, so what has to survive is the shape: eight patterns, one common
6-character prefix, three distinct suffixes, and three 12-character prefix groups.
`store_` is the same length as `billy_`, so every pattern keeps its exact byte
length and all four of those properties are unchanged.

It also could not have been corpus-tuned. The old patterns matched exactly one
file anywhere in the corpus, and that file was the corpus's own copy of this
bench source - so the real match density was zero before the rename and is zero
after it. That is the difference between this slate and `lit-18` next to it,
whose literals are genuine symbols with real density behind them (`WalletService`
alone lands in 112 files); renaming those would change what is being measured, so
they stay until the corpus question is settled.
