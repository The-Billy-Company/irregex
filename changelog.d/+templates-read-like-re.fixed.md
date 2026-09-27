- **Replacement templates read octal and unknown escapes the way `re` does.**
  Three spellings quietly meant something else here, so a template ported from
  `re` produced different text with no error:

  - `\0` takes up to two more octal digits (`\07` is BEL, not NUL then `7`), and
    three octal digits after a backslash are a character rather than a group
    (`\101` is `A`, not group 10 then `1`). Past `\377` is refused.
  - An escaped character that is not a letter keeps its backslash (`\é` stays
    `\é`, and a backslash before a space stays both), where it used to be
    dropped.
  - `\g<...>` takes ASCII decimals only as a group number. `str.isdigit` also
    accepts `١` and `²`, which `re` refuses.

  Checked against `re` over every template of up to four tokens from the escape
  alphabet, `str` and `bytes` - 108,480 templates. The one remaining difference
  is deliberate: an unknown group name raises `irgx.error` (which is `re.error`)
  where `re` raises a bare `IndexError`.
