A Python caller can now catch the refusal that has a fix, and fix it.

`irregex.compile(r"(?<=\$)\d+")` used to raise the same `irregex.error` as
`irregex.compile("[abc")`, so the only way to tell "this needs the other engine"
from "this is broken" was to try `pcre=True` on everything and see what stuck.
The first one is not a failure at all - the linear tier declines it and PCRE2
takes it as it stands - and the engine says so on the return value now, so the
binding does too.

A declined pattern raises `irregex.UnsupportedPattern`, and the message says
outright that `pcre=True` accepts it. So this is a real handler:

```python
try:
    pattern = irregex.compile(user_pattern)
except irregex.UnsupportedPattern:
    pattern = irregex.compile(user_pattern, pcre=True)
```

It is a subclass of `irregex.error`, so nothing that already catches
`irregex.error` changes.

`irregex.error` also grew `re.error`'s three attributes - `msg`, `pattern`,
`pos` - which is how a Python user already expects to find a bad pattern. `pos`
is the byte offset the engine located the refusal at, so a program compiling
patterns out of a config file can point at the character instead of reprinting
the line. It is `None` on `UnsupportedPattern`, and not because we withheld it:
a tier that stepped aside files no report at all.

Which class you get is decided by the status code and nothing else. I had this
keyed on the fault name matching the literal `"Unsupported"` for about an hour,
which is a spelling agreement rather than a contract - rename it upstream and
every binding quietly stops suggesting `pcre=True` instead of failing loudly. A
declinature is a status, so there is no string compare left in the binding at
all, and no keyword list of lookaround-ish constructs either; that would have
been a second opinion on a question the engine already answers by asking PCRE2.
