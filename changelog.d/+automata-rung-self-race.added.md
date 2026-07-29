`zig build automata-rung` races the DFA against itself, because a whole-engine
benchmark cannot attribute a layout change: a prefilter that skips the automaton
entirely hides whatever the automaton did, and a document with matches in it
spends its time reporting rather than walking. So the rung searches **match-free**
documents with the automaton forced live, and reports a `seen` column — distinct
states actually visited — so a row that never left the start state is visibly not
evidence about the scan loop. Five arms: `shape` (alphabet, states, accepting,
table bytes, build ns), `build` (ns/state, ns/step, visits/step, tier), `search`
(the match test, head-to-head), `area` (throughput against table size at two line
lengths, which separates *how big the table is* from *how much of it you touch*),
and `width` (NFA words, so a claim about closure sparsity has to name the patterns
where the premise holds). `bar.py` puts the same patterns through
`regex-cli debug dense dfa` in byte mode for the cross-engine column. Two claims
died on this rung's numbers and one landed — which is the point of building it
before the optimization rather than after.
