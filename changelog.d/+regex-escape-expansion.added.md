**Regex parser expands the control + hex escape set (`\f \v \a \0 \xNN
\x{H..H}`)** (`src/regex/syntax.zig`). ripgrep patterns reach for these
byte escapes routinely; gist previously only decoded `\t \n \r`, so a legal
pattern like `\x7F` or `\0` was mis-parsed as a literal `x`/`0`.

- **Control escapes**: `\f`→`0x0C`, `\v`→`0x0B`, `\a`→`0x07`, `\0`→NUL (rg's
  `\0`), alongside the existing `\t \n \r`.
- **Hex escapes**: `\xNN` (two hex digits) and the braced codepoint form
  `\x{H..H}` (`hexByte`/`hexVal`). gist is a byte engine, so a value `> 0xFF`
  is a hard `BadPattern` (rg's `(?-u)` byte-mode behavior) rather than a silent
  truncation — fail-loud beats a wrong match.

Proven against real ripgrep as the oracle: the escape cases (`\x` byte, braced
codepoint, `\0`/control) diff to **0 bytes** vs `rg`; over-`0xFF` `\x{…}` errors
loud as designed. The regex engine's differential tests stay green.
