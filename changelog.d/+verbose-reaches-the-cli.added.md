- The cold face honors a leading `(?x)` now, so verbose mode reaches every CLI
  built on it (`gist` first among them) instead of stopping at the library
  boundary. It reconciles like `i`/`u`/`m`/`s` — one run compiles one engine, so
  a pattern that *demands* verbose may not sit beside one that demands it off —
  and rides both arms, `Regex.Options.verbose` on the linear side and
  `PCRE2_EXTENDED` on the other.

  The engine had supported the mode for a while. The face was still answering
  "outside gist's linear-time syntax" to `(?x)`, which is the worst kind of gap:
  the capability exists, the refusal is a leftover, and the person hitting it has
  no way to tell those apart.

  The wrap needed one byte of thought. This face wraps a pattern in `(?:…)` for
  `-e`/`-x`, and under verbose a pattern may END INSIDE a `#` comment — a comment
  runs to the next newline, so the `)` appended after one is swallowed rather
  than closing anything. Ripgrep wraps the same way and dies exactly there:
  `rg '(?x) alpha \s+ \d+  # count'` is "regex parse error: unclosed group", for
  a pattern its own engine accepts, and it wraps even a lone pattern so there is
  no spelling that dodges it. So every wrap closes with a newline, which under
  verbose is both insignificant whitespace and a comment terminator: it cannot
  change a pattern's meaning, and it makes a commented pattern compose with
  `-e`/`-x` the way an uncommented one already did.
