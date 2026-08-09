`Caps.matchAt` - the anchored twin of `find`, on every arm of the union.

`find` searches forward and reports the first match at or after the offset it was
handed. That is the right question for a search and the wrong one for a caller
deciding what a byte position IS - a lexer probe asking "does a fenced-code
opener start here" got `true` for one starting six bytes along, and the group
slots it read back described text it never reached. There was no way to ask the
other question, so the only spelling available was the one that silently answers
about somewhere else.

It is a specialization rather than a second engine, and each arm already had the
shape for it. The Pike VM's `find` and `matchAt` are one `run` that either does or
does not seed a new thread at each later position, which is precisely what
"anchored" means for a Pike VM; anchored also stops the moment no thread survives,
since nothing will reseed and the rest of the line cannot matter. `OnePass` is its
existing walk with the candidate-start restart loop removed - and needs no visit
budget, because one walk is O(1) per byte by construction and the quadratic shape
`find` guards against cannot arise. PCRE2 needs no second compile at all:
`PCRE2_ANCHORED` is a match-time bit, so one program serves both.

Tested as parity rather than in isolation. The onepass/Pike differential now runs
`matchAt` alongside `find` on every case it already had, requiring identical
verdicts and slot-exact agreement, plus that the reported match begins exactly
where it was asked. A new case table pins the distinction the twin exists for -
patterns whose `find` is true and whose `matchAt` is false at the same offset -
across the linear arm and the PCRE2 one, so a silent substitution of one for the
other fails rather than passes.
