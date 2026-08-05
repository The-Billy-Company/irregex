`Munch.adopt` assembles a slate from automata the caller already holds, and
`Dfa.borrowed` says the tables under one are somebody else's to free.

Determinizing a slate is the expensive half of `Munch.compile`, and its result
is a pure function of the slate. A caller whose slate is fixed - shipped inside
an artifact rather than written at the prompt - can now pay that cost once,
store the automata, and arrive with the answer instead of the question. The
tables can live in a mapping or in one inflate buffer, because a borrowed `Dfa`
releases its handle and leaves the memory to whoever owns it.

Both are additions. `Munch.compile` builds exactly the slate it always did,
and a `Dfa` nobody marks `borrowed` frees exactly what it always freed.
