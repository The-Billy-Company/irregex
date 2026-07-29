The eager DFA's `is_match[s]` lookup is gone. States are renumbered at build
time so every accepting one precedes every non-accepting one, and the scan loops
ask `s < match_hi` — one unsigned compare on a value already in a register,
where before there was a second dependent load on the byte immediately after the
transition load that produced `s`, into an array that was `ncls`-sparse by
construction and therefore mostly padding in cache. **1.10–1.16× geomean** on the
scalar per-line walk over 13 match-free patterns and **1.20–1.27×** on the rows
whose walk actually wanders, against parity (0.98–1.19×) on the rows that sit in a
self-loop, where the removed load was a perfectly-predicted L1 hit with nothing to
win (`zig build automata-rung`); byte-identical over the Pike VM differential. rust-`regex`-`automata` reaches the same compare by shuffling its
special states into a prefix, but needs a power-of-two stride to recover an index
from a premultiplied id and pays that padding in every row; premultiplication is
monotone in the id, so a contiguous id range is a contiguous offset range at any
stride, and one bound suffices because the low end is zero. New `freeze.zig` owns
the three ordered layout passes — renumber, accelerate, premultiply — that both
determinizers previously transcribed separately.
