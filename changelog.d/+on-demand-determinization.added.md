On-demand determinization (RE2 / rust-`regex`'s hybrid DFA) beneath the eager
one. The subset construction moved into `match/regex/linear/dfa/subset.zig`, and
`powerset.zig` and `lazy.zig` are now two policies over that one core, so they
cannot disagree about what a pattern means; the Pike VM stands behind both as the
oracle. The eager driver runs first and freezes an immutable shared automaton,
and what it declines is determinized one visited state at a time into a
per-thread cache that quits to the Pike VM rather than thrash.

The bill this removes was paid before a byte was ever read: `\w+X` determinizes
to only 332 states, but every closure runs over the ~10³-state UTF-8 trie that
Unicode `\w` (137,936 codepoints in 748 ranges) lowers to, so the eager walk
spent ~18 ms discovering a small automaton — on every invocation, since compiled
patterns are not cached across runs. Unicode-class patterns now compile 4.4-11.9x
faster (`\w+\s+\w+\s+Holmes`: 45 ms → 3.8 ms).

Determinization is metered in NFA-state visits rather than states or closures,
which is the unit that actually costs time (measured linear at ~2-3 ns/visit
across a 100,000x range) and the only one that separates the two families:
ordinary ASCII patterns cost ~40-100 visits per state, Unicode-class ones ~26,000.
`max_visits` is a calibrated cost policy, waived by `force_dfa` so the
differential oracles reach the DFA on every pattern they generate; `max_states`
remains a hard safety ceiling no caller may lift.

The on-demand driver derives its own start-state acceleration from the start row
alone, which costs `2 x ncls` closures no matter how large the automaton behind
it is. Without it a 1000-branch alternation walked all 332 MB of a corpus that
the Pike VM's first-byte skip flew over, losing to it by 2.2x; with it the same
pattern beats the Pike VM, and a 3000-branch one by 1.5x.
