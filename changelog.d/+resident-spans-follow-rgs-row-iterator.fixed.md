The resident record stream was built on the wrong one of the cold engine's two
span iterators, so a nullable pattern could report a line as no match at all.

Cold has `nextSpan` and `Rows`. They look interchangeable and are not: `nextSpan`
drops every zero-width span, because its consumers - `-o`, `--column`,
highlighting - all need bytes to point at. `Rows` keeps them, and `Rows` is what
the `--json` stream is actually built on. The resident twin mirrored `nextSpan`
while claiming parity with the JSON stream, which held for every non-nullable
pattern and quietly failed for the rest: `rg -w 'x*'` paints an empty submatch
at each word boundary and matches eight lines of our own test corpus, and we
reported one.

`collectSpans` now reproduces `Rows`. That means three rules the old code did not
have. An empty span is real only for a nullable pattern; it is dropped when it
sits exactly at the previous match's end, which is why `a*` over "aa" is one row
and not two; and at end-of-content it exists only on a line that carried a
newline in the file, since that is where rg's zero-width match sits. Callers now
pass whether the line was terminated, which the line walker already knew.

The `-w` twin folded back into the one function while this was being fixed. It
existed to filter word-invalid spans, which is a flag on `Rows`, not a separate
walk - and it had drifted on its own account, advancing past a rejected
candidate's whole span where rg retries one byte on. A rejected candidate never
consumed anything, because rg compiles `-w` into the pattern.

Found by the FFI-vs-cold parity suite. The cold path was right throughout; only
the resident face was wrong.
