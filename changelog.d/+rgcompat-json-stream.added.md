**`rg --json` emits ripgrep's JSON Lines record stream — was a fail-loud gap**
(`bench/rgjson.zig` (new), `bench/rgcompat.zig`, `bench/rgemit.zig`,
`bench/rgsuite/run.py`). `--json` is how tools consume ripgrep structurally, so
the drop-in has to speak it, not decline it.

- **Exact message sequence** (`rgjson.zig`): one JSON object per line — a `begin`
  per matched file, a `match`/`context` per emitted line with byte-accurate
  `submatches` (and, under `-r`, per-match `replacement`), an `end` carrying that
  file's stats, then a trailing `summary`. It rides the *one* regex engine
  (`matchSpan` for spans, the capture VM for `-r`) and reuses `rgemit.expandInto`
  for template expansion, so there's no second matcher or replacer to drift.
- **`-A/-B/-C` context, `-v` invert, `-m` cap, `--crlf`** are all reflected in the
  record stream and the aggregated `stats` (`matches`, `matched_lines`,
  `searches`, `bytes_searched`); `--quiet` still tallies stats while suppressing
  the record body.
- **Deterministic-only fields are real; wall-clock/printer-internal ones are
  normalized.** `elapsed`/`elapsed_total`/`bytes_printed` are inherently
  non-reproducible, so both sides emit placeholders that `rgsuite/run.py`
  normalizes (mirroring what it already does for `--stats` seconds); every
  correctness field is emitted for real.
- **Strings use rg's escaping** — `\"` `\\`, `\n`/`\r`/`\t` short forms, other C0
  as `\u00XX` (all harness fixtures are UTF-8).

Proven against real ripgrep as the oracle: the `--json` cases diff to **0 bytes**
after the shared timing/`bytes_printed` normalization, and `--json` is removed
from the fail-loud deferral list.
