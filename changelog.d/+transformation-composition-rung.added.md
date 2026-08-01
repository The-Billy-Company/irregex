Matching a byte-class DFA as a REDUCTION rather than a pointer chase. A
transformation Q→Q is a |Q|-byte vector and composing two of them is one
AArch64 `TBL`, so a chunk's per-byte transformations fold in a tree and only
one shuffle per chunk stays on the critical path: **2.26 B/cycle against the
shipped eager DFA's 0.335** over 206 MiB of the host corpus, byte-identical
over 350,200 differential cases against the Pike VM. It is a decider — it
declines at compile time above 31 states, under a `\b` word context, off
AArch64, and below any armed literal skip, where retiring every byte loses
6.7× to a `memchr` that touches almost none. `lanes.zig` is the shareable
byte-shuffle primitive, importable without the rung.
