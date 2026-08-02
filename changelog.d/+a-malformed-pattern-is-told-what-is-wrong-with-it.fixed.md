The CLI used to answer every pattern the linear engine declined with the same
paragraph: *outside gist's linear-time syntax*, a list of constructs it does not
own, and two flags to try. For `[abc` that was wrong three times over — the
pattern contains no lookaround to blame, `-P` and `--engine auto` both fail on
it too, and nothing said where the defect was. ripgrep names the error and
points a caret at it.

So the refusal now asks PCRE2 before it speaks, which is the same probe the C ABI
already used to separate `IRGX_STALE` from a `BadPattern` fault. If PCRE2
takes the pattern, the escalation really was the answer and the message is
unchanged. If PCRE2 refuses it too, gist names the defect, points at the byte,
and says that no engine here compiles it rather than sending you to a flag that
cannot help:

```
gist: error: bad pattern — missing terminating ] for character class
gist: note: [abc
gist: note:     ^ here (byte 4)
gist: note: no engine here compiles it, so -P / --engine auto cannot answer it either
```

`-r/--replace` asked the same question and assumed the same answer, so it is
fixed with it.

One of these is a case where the advice was worse than missing: for `a\1`,
ripgrep tells you to try `--pcre2`, and following that advice fails, because
there is no group 1 to refer to. gist now says so up front.
