`\p{Emoji}`, `\p{EMod}` and `\p{ExtPict}` were rejected, and so was every short
property alias - `\p{Alpha}`, `\p{XIDS}`, `\p{WSpace}`. rg resolves all six.

Both gaps were the generator lifting the names somebody happened to need rather
than reading the file that defines them. The emoji properties live in UTS #51's
`emoji-data.txt`, whose rows are the same two-field shape
`DerivedCoreProperties.txt` already parses, so it joins the binary-property
source list and nothing else changes. The aliases live in `PropertyAliases.txt`,
so the alias table is generated from it instead of hand-kept: an alias whose
long name this build does not carry is dropped rather than emitted, because an
alias resolving to nothing reads at the call site exactly like a property we
support and got wrong.

Both files are vendored under `tools/ucd/` beside the rest of the UCD, at the
same Unicode version, each with its own sha256 pin in that folder's README and
its own line in `NOTICE` under the Unicode License v3 entry.

Why it mattered enough to chase: the three emoji names are how Swift and Julia
spell an identifier. A grammar whose identifier terminal will not build does not
fail loudly - the terminal simply never wins, and every byte it should have
owned surfaces downstream as a stray, hundreds of bytes away and wearing a
different defect's name. Swift's parse went from 49.5% to 77.0% of the file
under a root on the back of this and the class-set operators; Julia's from 21.2%
to 67.2%. Measured by rebuilding the same parser against an engine with only
these two changes reverted: the other twenty-eight grammars are byte-identical,
and the two that move are exactly the two whose patterns contain this syntax.

Not all of it is tree. Julia's 12,579 recovered bytes are 8,847 under a
construct and 3,732 under a bare token - identifiers that now lex correctly
inside a docstring whose external scanner still walls, so they are named rubble.
Swift's landed under constructs. Same headline, different meanings, which is why
the caller now reports both.
