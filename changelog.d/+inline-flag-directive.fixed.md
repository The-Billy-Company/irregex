**A leading `(?flags)` inline directive died with a bare `bad pattern`.** The
README promised rust-regex/rg's leading flag-group syntax was "honored where
gist can, loud where it can't", but the parser rejected every `(?…)` group
outright — `gist '(?i)todo'` exited 2 with no reason and no fallback, a
pattern ripgrep accepts.

`combinePatterns` now resolves a leading `(?flags)` directive per pattern
(`stripLeadingFlags`): `(?i)`/`(?-i)` set ASCII caseless run-wide (riding the
same plumbing as `-i`, overriding a resolved `-S`, exactly rg's
inline-beats-CLI precedence); `(?m)`/`(?s)` and negations are inert in the
per-line model (`^$` already anchor every line, no line carries a `\n`);
`(?-u)` is inert (byte semantics are gist's native behavior). Directives the
engine genuinely can't reproduce — `(?u)` `(?x)` `(?U)` `(?R)` — and mixed
per-pattern case demands across `-e`/`-f` patterns (gist compiles one global
engine; rg scopes flags per branch) fail loud with the reason and the rg
fallback. Under `-F` the bytes `(?i)` stay a literal, as in rg. The generic
bad-pattern death (lookaround, backreferences, mid-pattern flags) now names
the pattern, the reason, and the `rg` fallback instead of a bare
`bad pattern`. Guarded by unit tests plus a case-twisted black-box exit-code
guard in `build.zig` (`zig build test`).
