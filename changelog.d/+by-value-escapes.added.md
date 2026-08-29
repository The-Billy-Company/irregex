- The by-value escape family lands on the linear arm: `\uHHHH`, `\u{H..H}`,
  `\UHHHHHHHH`, `\U{H..H}`, and the octal `\0oo` / `\ooo` — in atom position and
  inside `[…]`, in byte mode and Unicode mode, where they can also bound a range
  (`[\u00ab-\u00bb]`).

  The surface is now a strict superset of both incumbents, which is the property
  worth stating precisely: every pattern **rg** compiles keeps rg's meaning, and
  every pattern **`re`** compiles keeps `re`'s meaning. That is not a
  coincidence of taste — the two disagree here, and each one's gap is the other's
  feature. rg has the braced spellings `re` lacks; `re` has octal, which rg
  reports as "backreferences are not supported" and then points you at PCRE2.
  Since each engine *refuses* what the other accepts, accepting both reinterprets
  nothing. Measured over 30 (pattern, subject) triples against `re` and a real
  `rg` process: zero superset violations, ten behaviours rg refuses, four `re`
  refuses.

  Octal is the one that needed a decision, because `\1` is ambiguous and `re`
  resolves it *by position*: inside `[…]` every numeric escape is octal (`[\1]`
  is U+0001), while at atom position `\1` and `\12` are group references, so only
  a leading `0` or a full three digits commits to octal there. We adopt that rule
  exactly, and a bare `\1` at atom position stays an error — not because it is
  unparseable but because a group reference is the one construct a linear-time
  engine cannot honor, and answering it with a literal would be a confident wrong
  answer. `\8`/`\9` are not octal digits in any position, and `\400` is refused
  rather than silently becoming U+0100, both matching `re`.

  Mechanically this is a *collapse*, not an addition. The four positions the
  grammar can reach a character escape from each carried their own `\x`-shaped
  prong, which is precisely why `\u` was missing from all four at once: there was
  no single place to add it. They now share one `escape.value`, on the principle
  that what a character's value is cannot depend on where it was written. Two
  things genuinely do differ, and they are the decoder's only two parameters: one
  positional (whether a bare `\1` is octal — `re`'s rule, turning on `[…]`), and
  one the spelling's own promise about its width (`Width`). `\xNN` and octal are
  byte syntax, so `(?-u)\xe9` is the raw byte 0xE9; `\x{…}` `\u` `\U` `\N{…}` name
  a character, so `(?-u)\u00e9` is its UTF-8 sequence, exactly as `(?-u)é` is. A
  short counted run stays an error, because `\u00` is a typo and reading it as
  U+0000 would match something nobody wrote; surrogates and values past U+10FFFF
  are refused, since this engine emits well-formed UTF-8 or nothing.

  Verified end to end: `gist -l` output is byte-identical to `rg -l` across the
  whole Billy tree (23k files) for six escape-bearing patterns, including a
  codepoint range.

  There is no slow path to fall back to, because an escape is resolved at parse
  time into the codepoint it names and reaches the same DFA, prefilter, and SIMD
  kernels a literal does — nothing downstream can tell which way `é` was typed.
  So the timings are the literal timings: over 50 MB, `-c`, minimum of 15
  interleaved rounds with counts identical, the eight of these spellings rg can
  run come in 3.5–5.9× faster on wall clock and 1.1–3.9× on CPU
  (`[\u00e9\u00fc]` 9.9 ms against 58.3; `\U{2603}` 7.5 against 31.7). The other
  eleven of the fifteen spellings measured rg cannot run at all.
