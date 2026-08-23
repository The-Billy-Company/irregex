- Spans got their reductions back under the buffer model, which is the only model a binding can compile.

  Two optimizations were gated on `!multiline`, and `multiline` down in `lower.zig`
  does not mean what the name suggests. It is not the `(?m)` question; it is the
  statement *the haystack is a buffer rather than one line*. A `glean.Pattern`
  forces it as an invariant - it is handed whole buffers by definition - so every
  consumer of the C ABI compiled with it set, and both gates were therefore always
  closed for Python, Rust, Go and every other binding. Only the CLI, which feeds
  one line at a time, ever saw the fast paths.

  The pure-literal set was the worse of the two. `pureLiterals` already rejects
  every assertion and rejects any literal carrying `\n`, so what survives is a
  claim about the AST - this pattern matches a text iff that text contains one of
  these literals - and a literal with no newline in it sits inside one line
  wherever it lands. The buffer and the line read that claim identically, so the
  gate was not conservative, it was just lossy. It left `pike/span.zig`'s SIMD
  literal path unreachable from every binding and dropped their spans onto the
  Pike VM, a bare literal string included.

  The caliper's gate cited a real hazard and then over-applied it. A buffer anchor
  has no per-line determinization, true; but `reverse.matchIndex` already declines
  any program carrying `\A`/`\z`, so the conjunct only restated it while also
  rejecting every multi-segment pattern that carries no anchor at all - the exact
  family the two-jaw construction exists for. What genuinely does not survive the
  model change is `^`/`$` when line anchors are on, since a jaw reads `at_start`
  off the edge of the slice it was handed while `(?m)` means "after any newline".
  That is now its own precondition instead of a proxy for one, so `(?m)^foo` is
  declined and everything else is measured.

  On a megabyte, a multi-segment pattern with no extractable literal
  (`[A-Z][a-z]+[A-Z]\w*`) went from 9.99 ns/byte to 0.04. Against the safety
  catalogue this repo is benchmarked on, a 300-byte scan of 31 real patterns went
  from 323 us to 79.

  The caliper suite only ever ran the line model, so it could not have caught
  either of these; it now runs both, over haystacks whose newlines are interior,
  leading and trailing. The `isMatch`-versus-walk differential got the same
  treatment - its alphabet could not spell `\s`, `\d` or `\w`, so the
  newline-claiming family its own guard exists for was unreachable by generation.
