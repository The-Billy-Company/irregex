`PatternSet.ends` is gone, and with it the union automaton a slate used to
determinize at compile time. Compiling eight mixed patterns went from ~175 ms to
17 ms; the worst combination I could find in that set went from 194 ms to 34 ms.

The verb had no callers. Not in the kernel, not in the three faces, not in any of
the four consumer repos - and it cost every slate a powerset construction over
the alternation of all N patterns. A Unicode `\d+` in the set is what makes that
visible: the class expands to hundreds of ranges before the subset construction
starts, so two patterns cost 7 ms and eight cost most of a fifth of a second, all
of it for a `?Ends` nobody ever read. It surfaced through the new C ABI slate
plane, where compiling a set is something a host does out loud rather than a
step buried in a corpus walk.

Nothing was lost. The automaton itself lives where it always did, in
`regex/linear/program/chorus.zig`, tested there, and `Munch` compiles one
directly for the lexer face. What went away is a slate holding one for free.
Anyone who wants every end position - including the ends a leftmost scan
swallows, which is the one question the confirm path genuinely cannot answer -
compiles a `Chorus` and pays for it deliberately.

Its absence from the hot path was already measured, which is why the removal is
cheap to believe: `bench/rungs/patternid` puts one union walk against the N
engine confirms it would replace and the union runs at 0.06x-0.41x their speed,
because a literal pattern's confirm is a SIMD memmem that never reaches a DFA at
all. So the slate was paying at compile time for something it correctly refused
to use at match time.
