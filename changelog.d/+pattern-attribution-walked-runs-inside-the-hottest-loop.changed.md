`Dfa.patternsAt` answered "which patterns does this match state accept" by
scanning `pat_runs` - the (bound, mask) pairs the freeze emits - linearly per
call. The encoding is right for the wire, where equal pattern sets are
contiguous and the table serializes as a handful of pairs, and wrong for the
ask: a multi-voice `Munch` calls it on every accepting state of every byte,
so the scan sat inside the innermost DFA loop of every anchored match.

The runs are now the wire encoding only. `freeze` keeps the dense per-state
mask row it already had, `Dfa` carries it as `pats`, and `patternsAt` is one
bounds check and one index. A reader inflates the runs back to the dense row
on thaw, refusing non-monotone bounds as the corruption they are; a
single-pattern voice, which has no runs at all, keeps its zero-cost
`match_hi` answer.

Measured from the consumer that found it (the joints parser's lexer, where
the scan was 21% of a cold cpp parse): 92.8 to 82.3 ns/byte on a 129 KB
corpus, with the loop-hoist landed in the same pass.
