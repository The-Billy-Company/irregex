The Python binding stops re-deriving three things the C ABI now states, and one
of them was quietly giving wrong answers.

`Pattern.groupindex` used to be built by scanning the pattern text for
`(?P<...>)` spellings and confirming each candidate through
`irgx_group_index`. Confirmation caught everything the scan *invented*, and
nothing it *missed* - so a name declared after a `[` the scan misread as a
character class simply was not there:

```python
>>> irgx.compile(r"(?#[)(?P<n>\w+)", pcre=True).groupindex
{}                       # before - and m.group("n") raised IndexError
{'n': 1}                 # now
```

`\Q[\E(?P<n>\w+)` had the same hole. There is no scan left: the binding walks
`1..groups` asking `irgx_group_name` what each one was declared as, which is
the parser's own answer and cannot disagree with the numbering it came from. The
names are decoded into Python strings where they are read, since the bytes
borrow a handle that a thread can outlive.

`finditer` over a text with more matches than the first span window now costs
two searches instead of five. `irgx_find_all` reports how many matches the
text HAS rather than how many fit, so a short window sizes its own retry exactly;
the doubling schedule that grew 4096 spans to 32768 to 262144, rescanning the
whole text at every rung, is gone. Same spans, same order.

And `error.pos` reads the fault's declared coordinate space instead of inferring
one from "there is an offset and no path came back with it". That conjunction
was right, which is the problem with it - the day a compile fault arrives
carrying a path, an inferring binding starts pointing a caret into the wrong
string, and it does it silently.

This needs ABI 2. The wheel refuses to load anything else, so an old library and
a new wheel say so at import rather than mis-reading a struct.
