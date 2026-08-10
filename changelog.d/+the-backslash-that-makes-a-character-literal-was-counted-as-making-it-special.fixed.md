The `-F` hint no longer fires on a pattern whose metacharacters are all escaped.

The trigger was `indexOfAny` over a metacharacter set, which is a substring test
and not a parse: `globals\(\)` contains `(` and `)`, so it was reported as having
regex metacharacters and the caller was told to retry with `-F` to search those
bytes literally. They already were literal. The backslash the test walked past is
the whole reason.

`activeMeta` scans with escape state instead, so a metacharacter only counts when
it is actually operating - and the field it feeds is named `active_meta` rather
than `has_meta`, because "has" is the question that was being answered wrong. The
same walk skips a bracket expression's interior, where a bare `(` is also just a
byte.

Pinned by cases the substring test passed and a parse must fail: fully escaped
metacharacters, one escaped and one live, an escaped backslash followed by a real
metacharacter (`\\.` does have an active `.`), and a class holding punctuation.
