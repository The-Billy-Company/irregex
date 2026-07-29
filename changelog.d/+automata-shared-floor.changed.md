There are two roads to a DFA here — the byte powerset construction and the
symbolic predicate-alphabet determinizer — and they now share a floor instead of
each carrying a copy of it. New `linear/automata/` holds the operations on a
finished automaton that cannot say which road produced it, with one membership
rule: shared *by nature*, not shared *by accident*. `freeze.zig` moves there from
`linear/dfa/`, where it had been sitting inside one road's folder while the other
reached across a boundary to borrow it; the three ordered layout passes it owns
(match-first renumbering, start acceleration, premultiplication) are established
once rather than transcribed twice. `dfa/dfa.zig` deliberately stays put — its
path is pinned inside the frozen benchmark manifests under
`bench/certificate/artifact/`, and tidying a folder is not a reason to rewrite
recorded evidence. Claim C5's shared partition-refinement core is the next
occupant.
