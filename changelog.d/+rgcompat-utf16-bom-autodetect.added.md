**`rg` auto-detects a UTF-16 BOM and transcodes to UTF-8** (`bench/rgcompat.zig`).
ripgrep's default (`--encoding auto`) sniffs a byte-order mark and decodes; gist
read raw bytes, so a UTF-16 file's (UTF-8) pattern never matched and its NUL
bytes tripped binary detection into skipping the file entirely.

- **`decodeBom`** runs once per file at ingest: a UTF-8 BOM is stripped, a
  UTF-16 LE (`FF FE`) / BE (`FE FF`) BOM transcodes the whole file to UTF-8 via
  **`utf16ToUtf8`** (surrogate pairs resolved; a lone/invalid surrogate or a
  trailing odd byte becomes U+FFFD, matching rust-encoding's lossy decode). It's
  applied at every read site (walk, symlink target, explicit path arg), so the
  transcoded UTF-8 flows through matching *and* binary detection uniformly.
- **Scope stays honest**: only *BOM-marked* UTF-16 is auto-detected. BOM-less
  UTF-16 and other charsets still require explicit `-E`/`--encoding`, which
  remains a fail-loud NA (gist is a UTF-8/byte engine).

Proven against real ripgrep as the oracle: `f1_utf16_auto` (a BOM'd UTF-16 file
searched for a Cyrillic literal) now diffs to **0 bytes** vs `rg`.
