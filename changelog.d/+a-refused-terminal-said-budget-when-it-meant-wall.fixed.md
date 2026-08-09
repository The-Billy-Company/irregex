A terminal carrying `\A` or `\z` was declined with the *size* reason, which told a
caller to raise a bound that would never admit it. It now has its own:
`IRGX_MUNCH_BUFFER_ANCHOR`.

The two are the opposite advice. `IRGX_MUNCH_STATES` is a budget - this build's
`max_states` stopped here, and a bigger one takes the terminal. A buffer anchor is
a wall: the position it asserts is not something an automaton determinized over the
pattern alone can see, so no budget admits it at any size. Reported as the former,
the honest response was to go raise a ceiling and try again, forever.

It also mattered more than it looks, because a slate is refused per terminal: a
lexer that logs its declines was being told to buy memory for a terminal it should
have been told to rewrite. And the rewrite is usually nothing - a munch scan is
already anchored at the offset the caller passed, which leaves `\A` redundant and
`\z` unsatisfiable, so the fix is to drop it.

Surfaced as `Why::BufferAnchor` (Rust), `Why.BUFFER_ANCHOR` (Python), and
`WhyBufferAnchor` (Go).
