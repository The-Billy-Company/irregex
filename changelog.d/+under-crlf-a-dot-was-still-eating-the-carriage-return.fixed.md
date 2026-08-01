`--crlf` no longer reports matches ripgrep does not have. `.` and every
character class now decline `\r`, so nothing consuming can cross a CRLF
terminator.

`rg --crlf -o -e '(.{2,}|\S)fn'` over a small mixed CRLF/LF tree printed one
match; gist printed three. Same flag, same corpus, and gist's extra rows spanned
two lines each - because with `\n` as the terminator and `--crlf` on, the CR is
still sitting at the end of the line's bytes, and gist's `.` was happy to eat
it. Once a thread consumes the CR it is inside the next line, and one match
covers two.

`--crlf` in ripgrep is not an engine mode; it is a pattern rewrite.
`grep-regex` runs `strip_from_match` over the parsed HIR and takes `\r` out of
every class it finds - `.`, a spelled-out `[…]`, a negated class, `\S`, all of
them - before the regex is ever compiled. Line furniture stops being content.

gist now does the same, as an AST pass (`syntax/scalars.zig::stripCpAst`) run
after the `-i` fold so a class promoted to `uclass` by folding is stripped too,
and applied by the same `parse` both the match engine and the capture VM go
through, so `-r`/`--json` cannot disagree with the match. Measured against real
rg over `alpha\r\nbeta\r\ngamma\n`, `a.*`, `[^x]+`, `a[^q]*`, `.$` and
`alpha.beta` are now byte-identical, and the count under `--count-matches` that
the fuzzer caught at 5-vs-4 now agrees.

Two related divergences remain, and are not touched here:

- ripgrep REFUSES a literal `\r` (or `\n`) in the pattern under `--crlf`, exiting
  2 with "the literal \r is not allowed in a regex". gist keeps its own posture -
  the class of one empties, the pattern is unmatchable, and the hint channel says
  which flag would have matched - the same answer it already gives for a literal
  `\n` under the per-line model. Divergent in exit code, deliberately.
- ripgrep treats a LONE `\r` as a line boundary for `^`/`$` under `--crlf`, where
  gist only recognizes a `\r\n` pair. That is a line-anchor question rather than a
  class question, it crosses both engines, and it is still open.
