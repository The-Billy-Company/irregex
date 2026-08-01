A refused pattern now tells you whether a flag fixes it, and if not, where it
went wrong.

`(?=x)` is one flag away from working. `[abc` is just broken. Both used to come
back as `IRREGEX_INVALID` with the fault name `Unsupported` and no position -
one byte-identical answer for two problems, only one of which has a remedy. No
binding could suggest `pcre` because no binding could tell them apart.

`[fault_domains]` had already drawn the line and named both channels:
`Unsupported` is "a declinature while PCRE2 can still answer it, a fault once
PCRE2 has refused", and `BadPattern` is "the grammar itself rejects it, so no
slower engine could answer it either". The seam just wasn't honoring it, because
the kernel can't tell the two apart - its parser returns one `BadPattern` for
both and the query layer folds that to `Unsupported`.

So ask the authority. PCRE2 is definitionally the judge of what PCRE2 can
express; a construct list kept in the seam would drift the first time PCRE2 grew
one. It costs a second compile on a path that already failed. Now:

- PCRE2 takes it, so the answer is `IRREGEX_STALE` - the routing fact, not an
  error. That is exactly `unsupported_syntax`, whose declared fallback *is*
  pcre2; `--engine auto` escalates across the same seam in the CLI, and here you
  escalate by setting `IRREGEX_PCRE`. Per the seam's own law a declinature never
  installs a fault, so this is decidable from the return value alone - no second
  call, and nothing anywhere has to compare a fault name as a string.
- PCRE2 refuses it too, so it is `BadPattern`, carrying PCRE2's own error offset
  as a byte index into the pattern (`path` NULL, `at_space` `AT_PATTERN`).
- There is no PCRE2 to escalate to - a build without it - so it stays the
  `Unsupported` fault. A tier that does not exist has refused, which is the
  moment the declinature above becomes the fault.

No signature moved and no struct grew.
