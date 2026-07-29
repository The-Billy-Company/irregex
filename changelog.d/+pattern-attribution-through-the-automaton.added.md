The determinizer can now name **which** patterns matched, not just that
something did — and with it come overlapping ends and end-only (HalfMatch)
search, neither of which the engine could express before.

Each DFA state's key already ended in a spare `u64` holding a bare match flag.
Widening that word into a 64-pattern mask is free in every dimension that costs
(same key length, same allocation, same hash, same compare), and it is what
turns "did something match here?" into "which patterns matched here?". `freeze`
then sorts match states by accepted-pattern set so the whole attribution table
collapses to a handful of `(bound, mask)` runs — 3 to 18 across the measured
slates — instead of a `u64` per state.

A one-pattern program is bit-for-bit unperturbed: its mask is exactly `{0, 1}`,
the same values the flag held, so keys, hashes, discovery order, and the
resulting automaton are unchanged, and the hot loop keeps its lone
`s < match_hi` compare.

The new `Chorus` (`kernel/regex/linear/program/chorus.zig`) lowers N patterns
into one program whose N terminals sit at indices `0..N-1`, and walks it once to
yield `(end, patterns)` pairs. Overlapping search falls out for free: on
`foofoofoo` against `foo|foofoo|foofoofoo` it reports ends 3, 6 and 9, each
naming the patterns that ended there. rust-`regex` needs `MatchKind::All` for
that same answer, because its determinizer breaks out of the NFA walk on the
first `Match` state and has already discarded the longer alternatives — and it
pays for the flag with a larger automaton and a search loop that forgoes its
4-byte unroll. Our recognizer never had a priority to preserve (leftmost-first
lives downstream in the caliper), so All-mode is not a mode we enter.

Measured and reported rather than assumed: one union walk does **not** beat N
per-pattern confirms for presence questions (0.06x-0.41x on six slates, with
identical answers), because a literal confirm never reaches a DFA at all and a
regex confirm still carries a required-literal prefilter and the fused
multi-lane document walk. So `PatternSet` keeps the muster and the confirm path
exactly as they were, and exposes the chorus only through `ends` — the question
presence cannot express at any price.

`caliper/reverse.matchIndex` now declines a multi-terminal program instead of
reversing from the last one it finds. Its contract always said "the lone
`match`"; with a union program in the tree that assumption would have produced
confidently wrong spans for every pattern but one.
