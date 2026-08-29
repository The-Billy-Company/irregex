- `(?-u)` no longer truncates a character to one byte. Disabling Unicode changes
  what a class, a fold, and a boundary mean; it cannot change what a scalar value
  IS, and rg draws the line in the same place. Two spellings were on the wrong
  side of it.

  `\x{H..H}` named a character and was read as a raw byte: `(?-u)\x{e9}` looked
  for 0xE9, which a UTF-8 file does not contain, so it found nothing where rg
  found `é` and found a match where rg found none — a silent wrong answer in both
  directions, the worst shape a search bug has. Anything above 0xFF was refused
  outright, so `(?-u)\x{2603}` was a parse error against rg's three bytes. Both
  now match the character's UTF-8 sequence. Bare `\xNN` and octal are byte
  syntax and keep naming the raw byte (`(?-u)\xe9` is 0xE9), which is rg's line
  too; `escape.Width` now carries that promise from the spelling to the two
  byte-mode sites that act on it.

  A quantifier bound a character's last byte rather than the character. `(?-u)é+`
  over `éé` answered `é`, because the atom walk emitted one byte per call and `+`
  repeated only 0xA9, and `(?-u)é{2}` matched nothing at all. A character's bytes
  are now chained into ONE atom, so both answer what rg answers.

  Inside a byte-mode `[…]` a character above ASCII is now refused rather than
  matching one byte of it: a byte class cannot hold a sequence, and matching a
  fragment would be a confident wrong answer. rg refuses the same pattern
  (`(?-u)[\x{e9}]`: "Unicode not allowed here").

  Found by the new `records.py` conformance lane in gist rather than by
  inspection, on its first run, in the one cell that crossed a byte-mode escape
  with an output frame.
