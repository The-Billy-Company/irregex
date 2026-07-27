A one-pass capture engine. Most patterns never have two live alternatives, so
their ε-closures determinize: `-r`/`--json` submatches for those now come from a
small DFA that writes group offsets straight into the caller's slot vector,
instead of the Pike VM's priority-ordered thread list with its slot copy on
every `save`. It is a third arm of `Caps`, taken only when the pattern is
provably unambiguous and falling back to the Pike VM otherwise — so which arm
runs is a speed decision and never a semantic one, and the two are held to
slot-exact parity by a randomized differential.
