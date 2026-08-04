`\p{Control}` now resolves, and so does every other UAX #44 long name for a
general category - `\p{Uppercase_Letter}`, `\p{Other_Symbol}`,
`\p{Space_Separator}`, and the rest of the forty. The generated property table
carries these categories only by their two-letter abbreviation, so a pattern
spelling the long name got `unknown property after \P or \p` and refused,
where PCRE, ICU and rust-regex all take either spelling.

The aliases are hand-written next to the lookup rather than folded into the
generated table, because they are the property file's own names and do not move
with a Unicode revision; the ranges they resolve to are still the generated
ones, and the test asserts the two spellings return the same slice rather than
merely both returning something. Matching stays loose in the same way the rest
of the lookup is, so `gc=private use` and `Private_Use` are one name.

Nothing that already compiled changes: the alias table is consulted only after
the generated table has already failed to answer, and an undefined name still
fails closed.
