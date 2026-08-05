A leading `(?i)`, `(?s)`, `(?m)` or `(?-u)` is read as the flag it asks for and
folded into the compile, in the C ABI and in every binding on top of it.

This is the spelling every host language's own library documents.
`re.compile("(?i)cat")`, `Regex::new("(?i)cat")`,
`regexp.MustCompile("(?i)cat")` - and until now `irgx_compile("(?i)cat", 0)` was
refused, because the recursive-descent parser has no production for a bare flag
group and the seam had nothing that turned one into the option it asks for. That made the *documented*
way to be case-insensitive unavailable to a host whose pattern came out of a
config file it does not own, which is exactly the case where the host has no flag
word to pass: it would have to read the pattern to know which one it needed.

The reading lives in the syntax tier as one pure function, because it was already
living in the CLI and a second grammar that agrees today is a divergence waiting
to happen. Only the head is folded: `(?i)` inside a group and the scoped
`(?i:…)` form are per-subexpression scoping, a real AST feature, and a fold that
pretended otherwise would quietly apply a nested flag to the whole pattern. A
non-leading global flag is also the case `re` itself has refused since 3.11.

What the pattern says beats what the caller passed, since the pattern is the more
specific statement - `IRGX_IGNORE_CASE` with `(?-i)cat` is case-sensitive. Under
`IRGX_FIXED` nothing is folded, because the bytes are data. And `(?x)`, `(?U)`
and `(?R)` are named rather than skipped past: they are flags of the wider grammar
this engine does not implement, so the letter is reported and the pattern stays
whole, which routes a host to the PCRE2 arm that does have them. Honoring the
letters it recognized and dropping the rest is the silent wrong answer.

Slates read the directive per pattern, so one member of a two-hundred-pattern set
can fold case without the rest of it folding. `(?m)` and `(?s)` are refused there
by index, the same refusal the flag word already gets, because that plane has
nowhere to carry them.
