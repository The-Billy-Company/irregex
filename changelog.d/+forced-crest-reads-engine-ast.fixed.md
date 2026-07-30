Crest sieve: derive the forced crest `ĝ` from the engine's own AST instead of a
private mini-parser inside the kernel. The two grammars disagreed on zero-width
assertions — `\<` and `\>` were read as escaped literal `<`/`>` — so `\<foo\>`
demanded a punct run and silently elided files that matched (700 of 2 200 files
returned on the reproduction corpus). The calculus now lives in
`kernel/regex/analysis/swell.zig` and consumes the `syntax.Node` tree the matcher
compiles, through one shared `parse()`, so there is no second grammar to diverge
from; PCRE2 patterns disable the sieve rather than being approximated. Constructs
the old parser declined (`\x41`, malformed bounds) now certify correctly.
`swell_test.zig` asserts the Sieve Theorem against the real matcher over 1 500
generated patterns spanning every node kind × both engine modes × caseless.
