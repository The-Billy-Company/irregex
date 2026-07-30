The boolean ladder gained an **accelerator tier**: the optional machines that
beat the byte-class DFA on the patterns they accept, behind one interface
(`linear/ladder/rungs.zig`).

Three rungs arrived from separate build lanes with three different shapes — one
takes a DFA and returns a heap handle answering `bool`, one takes an AST and
returns a value, one takes a DFA and answers `miss`/`unproven`. Wiring them
directly would have put three fields on `Regex`, three constructors in the
lowering, two verdict protocols and nine blocks in the dispatch. The tier absorbs
all of it: the handle carries **one** field, the lowering makes **one** call, and
each boolean entry point gains **one** line. Adding the next rung is an entry in
one ordered table.

A three-valued verdict (`hit` / `miss` / `unproven`) unifies the two rung kinds
exactly rather than papering over them — a decider declines at compile time by
being absent and never says "not sure" mid-scan, a sieve can only narrow — and
both meanings of `miss` coincide, so one switch serves both.

A second axis says **which question** a rung answers, because the two boolean
entry points are genuinely different — a slice, versus the lines inside a buffer
— and they coincide only where the haystack holds no newline. A rung that reads
`\n` as a line boundary is consulted at the document grain only, unless the
particular machine can prove its reset row is what the automaton would do on a
newline anyway, in which case it answers both. The proof is published as a
method the tier looks up at compile time, so a rung that never grows one is
simply held to its kind's conservative reading.

Measured on a 64 MiB corpus: transformation composition arms on 11 of 18 scan
patterns including every realistic field pattern, holding ~8.3 GB/s where the DFA
runs 0.9–1.25 GB/s, and halving to ~4.0 GB/s once the automaton passes 15 states.
On the per-line entry point the proof above is worth 2.13–2.52× against controls
at 0.94–1.05, and on `-U` — where the whole-buffer search already hands an
assertion-free program to the DFA, so the slice question and the multiline one
are the same question — 4.84–11.42×. An unarmed tier is free: the control
patterns time identically with it present and absent.
