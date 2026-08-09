`irgx_munch_*` - the maximal-munch plane, so a host can ask *what is the longest
thing that starts right here, and which terminal was it*. Bound in all three
bindings: `Munch`/`MunchBuilder` in Rust, `compile_munch` in Python, `CompileMunch`
in Go.

`Munch` has existed in the Zig kernel for a while. The ABI did not carry it, and
the shape of that gap is worth naming because it was not a missing convenience:
nothing else on the surface answers this question. `irgx_slate_*` says *which of
these patterns match somewhere in this text*, which is set membership - a lexer
needs the reading at one cursor, the longest of them, and the identity of every
terminal that tied for it. Built out of the pieces that were exported, that is one
anchored `is_match_at` per terminal per cursor, comparing lengths in the host, and
a token-per-byte tokenizer paying N crossings for a question the automaton answers
in one walk.

What a munch returns is deliberately not a winner. `if` is both the keyword and an
identifier and both reach length 2; which one a lexer wants is its own business,
usually declaration order, so the engine names **both** and resolves nothing.
Picking one here would make keyword recognition impossible to build on top.

Three things fall out of it determinizing every terminal together:

- **Flags are the slate's, not a terminal's** - there is nowhere to put "terminal
  3 folds case", so `ignore_case` and `dotall` are properties of the munch.
  `IRGX_MULTILINE` is *refused* rather than accepted-and-ignored: it asks for the
  line-anchor reading, and an anchored scan cannot observe the difference either
  way, so taking it would be answering a question that was not asked.
- **A refusal is partial.** A slate of a hundred and fifty terminals where one is
  outside the linear grammar is a working lexer. So the terminals that determinize
  are seated, the rest are readable as `(index, why)` from `irgx_munch_declined`,
  and only a slate where *nothing* seated is an error - there being no handle to
  read the reasons from in that case.
- **A restriction is per call.** The allow list is an argument to the scan, not a
  second compile, which is how context-sensitive lexing works without a munch per
  context.

Each binding answers in its own host's text domain, on purpose: byte offsets in Go
and Rust, character offsets in Python, where the existing `TextView` does the
translation. Tested in every binding against the same oracle - one anchored
`^(?:terminal)` per terminal via that language's stdlib regex engine, maximum taken
in the test - over every cursor of every text, including the end of the input.
