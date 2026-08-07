`powerset.Budget` now carries its two caps separately, so a lexer slate is no
longer refused by a size ceiling calibrated for a one-shot query.

The cost cap (`max_visits`) and the size cap (`max_states`) answer different
questions - how long an automaton takes to *find* versus how much memory it takes
to *hold* - and one enum member spelled both. A caller waiving the first silently
inherited the second, which is how `Munch` came to refuse an automaton needing
5,991 states against a 4,096 bound chosen for the differential oracles.

`Budget` is a struct with `visits` and `states`, and the seats are named
(`budgeted`, `unbudgeted`, `slate`); decl literals leave every existing call site
unchanged. `slate_states` is 8,192, the smallest round value admitting every
automaton measured to need it - a state-maxed slate at 179 byte classes is
11.7 MiB. Raised, not waived: the powerset is still bounded and a genuine
blow-up still declines.

Measured on the thirty-grammar tree-sitter corpus this admits exactly one
terminal that was refused before, markdown's HTML `entity_reference`, and makes
that grammar's slate build **2.85x faster** (1,060 ms to 372 ms) - because
`admit` bisects to name a refusing pattern, so one refusal cost six levels of
re-determinization that were built and thrown away. Grammars that never declined
are unchanged within noise.
