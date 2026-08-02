`-w`/`--word-regexp` no longer misses a match ripgrep finds. The word boundary
is now part of the language the engine searches for, not a verdict passed over
the span it already settled on.

`rg -w -o -e 'abc|abcd'` over `x abcd` prints `abcd`; gist printed nothing. The
cause is where the rule lived. gist compiled the bare pattern, let the engine
settle leftmost-first on `abc` at offset 2, then asked `wordOk` whether that
span was word-bounded. It is not - a `d` sits right after it - so the offset was
abandoned and the scan resumed past it. But the offset was fine; only that ARM
was wrong, and `abcd` at the same offset is a match. A vet that sees one span
per offset cannot express "try the next arm here", so every pattern whose greedy
arm ends inside a word lost the shorter admissible one behind it.

ripgrep does not vet. `grep-regex` sets the `word` config, which rewrites the
pattern into `\b{start-half}(?:pat)\b{end-half}` before compiling, so the
assertions are inside the program and the engine's own backtracking finds the
admissible arm. gist now does the same rewrite, on the parsed root rather than
the pattern text (`syntax/scalars.zig::wordBoundedAst`), which makes the
precedence free: `-w 'a|bc'` binds the alternation, never just its first arm.
The linear arm gets the two `.word` assertion nodes it already had for `\b`; the
PCRE2 arm gets a `(?<!\w)(?:pat)(?!\w)` wrap, with the error caret discounted by
the lead so a bad pattern still points at the byte the user typed. Both arms and
both capture VMs read one option, so `-r`/`--json` cannot drift from the match.

It is the HALF boundaries, not `\b(pat)\b`. `rg -w -o -e -` finds the dash in
`foo - bar` where `\b-\b` finds nothing, and finds no dash in `foo-bar`: a half
boundary judges the neighboring byte, not the span's own first byte. gist
agrees on both.

The vet stays for the `.literal` body, where there is no program to rewrite and
a single literal has exactly one span per offset - the case the vet was always
right about.

The rewrite is also faster than the vet it replaces, which is the answer to the
obvious worry about putting work inside a hot flag. Measured against a pre-fix
binary built from the same tree, `-w -c` over one 211 MB body where every line
matches (hyperfine, 5 runs, `--no-index` so the trigram gate cannot mask the
engine): a literal word 484.3 ms -> 171.4 ms (2.83x), `fn \w+` 226.0 ms ->
191.9 ms (1.18x), `abc|abcd` 333.3 ms -> 242.6 ms (1.37x); the counts are
identical (2,400,000 lines each) and match rg's, so it is the same work. The vet
paid a second span search per candidate offset; an assertion the DFA already
knows how to fail costs nothing.

That said, `-w` is still the flag where ripgrep is ahead of us on that corpus -
100-113 ms against our 170-243 ms - and it is `-w` specific: without the flag the
same literal is 21.4 ms against rg's 54.8 ms. `-w` puts a literal body on the
regex path and off the single-file sharded literal scan. That gap is older than
this fix and this fix halved it; closing it is a separate change with its own
measurement.

The pinned regression covers the alternation cases in both arm
orders, the punctuation half-boundary pair, and the control that separates a fix
from an overcorrection: a pattern whose every span is word-internal must still
find nothing.
