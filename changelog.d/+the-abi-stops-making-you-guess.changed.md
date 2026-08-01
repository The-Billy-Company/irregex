`irregex_abi_version` is 2. Three things a caller had to work around are now
just answered, and two of them change what a v1 host would read.

**A fault's offset says which string it indexes.** `at` is a byte in a file for
a corpus fault and a byte in the pattern for a refused compile - two rulers, one
field, and which one was in force had to be inferred from `path` coming back
NULL. So every binding wrote the same three-clause conjunction, and any binding
that missed a clause pointed a caret at the wrong string. `has_at` is now
`at_space`, holding `IRREGEX_AT_NONE` / `AT_FILE` / `AT_PATTERN` - the boolean
widened in place, same offset and width, so `struct_size` cannot catch the
difference and the version gate is what has to. `AT_NONE` is 0 so a reader that
only wanted "is there a position at all" still gets it from a zero test.

**`find_all` counts what the text holds, not what fit.** Its sibling
`captures` already reported the needed group count on a short buffer, which is
what lets a caller size one retry. `find_all` reported the written count, where
`written == cap` is equally a full window and an exact fit - undecidable, so all
three bindings independently grew a buffer and searched again until a call came
back short. It now reports the total either way, `cap = 0` with a NULL `out` is
a cheap "how many are there", and the status is about the text rather than the
window: a count query writes nothing and still returns `IRREGEX_MATCH`.

**`irregex_group_name` tells you what group 3 is called.** There was a
name→index lookup and no inverse, so each binding built its `groupindex` /
`SubexpNames` / `name_table` by scanning the pattern text for `(?<...>` - three
separate reimplementations of a parse the engine had already done, each with its
own opinion about escapes and character classes. The engine answers now, from
its own capture table and from PCRE2's name table when PCRE2 compiled it.
Purely additive; it would not have bumped anything on its own.
