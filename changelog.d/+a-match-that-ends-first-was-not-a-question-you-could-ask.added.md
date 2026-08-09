`Pattern.earliest` / `earliestIn` / `walk`, and `Pattern.halts` to ask first - the
match that ENDS first, which is not the leftmost one and cannot be filtered out of
it.

Every span entry in this engine was leftmost-first, because that is what a match IS
to a consumer of a span. But leftmost-first picks a match by where it STARTS and
then extends it by priority, so it is frequently neither the earliest-ending match
nor reducible to one: `a+` over `aaa` is one leftmost span `(0,3)` and three
earliest ones `(0,1) (1,2) (2,3)`, and no predicate over the first yields the
second, since the second sequence holds spans the first never reported. So the
request bit existed and the span verb refused it - correctly, rather than shipping
a leftmost answer under an earliest label.

It needed a machine, and the machine was already built. `subset.zig` determinizes
both an unanchored automaton, whose re-seed makes its first acceptance the earliest
end of any match in the region, and an anchored one; nothing above it could ask a
determinized walk to stop AT an acceptance. `lazy.Cache.onset` is that halt, and
`dfa/onset.zig` is the policy over it - which automaton a mode needs, built on the
first ask that needs it, per-thread scratch shelved beside the Pike VM's.

A forward recognizer knows where a match ended and never which one, so an earliest
SPAN is the halt plus one leftmost pass under the position it found. That is exact
rather than an approximation: every match in the region ends exactly there by
minimality, so the leftmost-first answer inside it is the earliest end and the
leftmost start reaching it. It is also the reason there is no O(log n)
binary-search-over-the-bound version of this - one bounded pass, not a ladder of
them.

Two compiles have no such machine and say so instead of guessing: the PCRE2 arm,
whose program is not inspectable, and a pattern carrying a positional assertion,
where a determinized state's meaning depends on the gap it was entered at. Those
raise `Unsupported`. `halts` answers it once after compiling, so a host is never
surprised mid-walk.
