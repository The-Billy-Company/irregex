The Go binding gets its group names from the engine now, instead of reading the
pattern you wrote.

`SubexpNames()` is indexed by group number, and the only way to fill that slice
used to be to scan the pattern source for `(?P<...>)` and `(?<...>)` and confirm
each candidate through `irregex_group_index`. That is a second parser, and a
worse one. It had never been taught PCRE2's `(?'name'x)`, so a name spelled that
way just vanished; two groups sharing a name under `(?J)` came back as one name
and one blank slot; and every shape that merely looks like a group - an escaped
`\(`, a paren inside a character class, a `(?:` that takes no number - was a
rule it had to re-derive correctly on its own, forever.

ABI 2 adds `irregex_group_name`, the inverse of `irregex_group_index`, so the
table is walked straight out of the compiled pattern: group 1 through group N,
whatever the engine calls each one, identically on both grammars. The scanner is
deleted. Nothing about the public contract moved - it is still stdlib `regexp`'s
- `SubexpNames()` indexed by group number with `""` for an unnamed group and for
element 0, `SubexpIndex` answering -1 for a name the pattern does not declare,
and the first of two groups that share one. The engine lends those bytes rather
than copying them, so they are copied into Go strings while the handle is still
alive.

Two more things came with ABI 2, and you notice both of them by nothing going
wrong. `irregex_fault` states which string its offset is measured in instead of
leaving you to infer it from a NULL path, so `SyntaxError.At` is filled only
from an offset the engine measured in the pattern - which is the string you
print a caret under. And `irregex_find_all` reports how many matches the text
HAS rather than how many fit in the window it was given, so the grow-and-rescan
loop is gone: one pass, then at most one more at exactly the count the engine
just reported. The window can no longer be the reason you go around again twice,
and the retry is a measurement rather than eight times the last guess.

`abiVersion` is pinned to 2 and checked at package init, so a library handed in
through the `irregex_syslib` tag that still speaks ABI 1 says so in a sentence
naming both numbers. The vendored archives are rebuilt on it, and the link probe
that gates them calls `irregex_group_name` too - an archive that cannot resolve
it now fails when it is vendored rather than in somebody's `go build`.
