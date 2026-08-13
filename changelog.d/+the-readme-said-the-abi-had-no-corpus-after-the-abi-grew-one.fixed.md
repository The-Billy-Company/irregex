The README's C ABI section said there is no corpus, no walk, no index and no
session, and by then three of those four were in the header. It has been rewritten
whole rather than patched, because a note appended to a false paragraph leaves a
reader deciding which half to believe.

The section now says what the ABI is — the engine minus the products built on it —
and names the planes: the floor over bytes a host already holds, then `walk`, `tree`,
`sieve`, `codex`, and the multi-pattern, lexer, literal-sweep, promise and line-grid
verbs. Two other places carried the same stale claim and were rewritten with it: the
"should I be using this" bullet, which described the header as having no corpus
behind it, and the paragraph drawing the line between this repository and a binding,
which described a binding as hiding decisions the bindings now expose.

The header's own exclusion list was the more consequential half. It named the session
and stopped, which reads as a complete list, so `rank`, `signals`, `emit`, `argv`,
`preference` and `math` were absent from the C ABI with nothing anywhere saying they
had been left out on purpose. That paragraph now names them and points at the table
that decides: `contract/exports.toml`, one row per plane, a door or a reason.

`src/surface/ffi/` and `quality/parity/` also had no README, in a package where every
other leaf folder does. Both have one now, and the export gate's README gained the
section for the lane it grew.
