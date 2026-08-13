`irgx.literals()` reads the promise off a compiled pattern's AST, and its parameter
was annotated `Any`. So the one thing a caller is most likely to pass — the pattern
text — type-checked clean and then failed inside the call with
`AttributeError: 'str' object has no attribute '_pool'`, naming a private field.

The annotation is now `Pattern`, imported under the type-checking guard so a
docstring's benefit does not become a load-order edge. Anything without a pool
raises `TypeError` saying what the function reads and what to do about it.

`Literals` also grew a `__repr__`. It is the handle a caller opens to learn what a
pattern promises, and it printed as an object address. It now reports the promise —
minimum and maximum length, whether the pattern is anchored, how many literal sets
it carries — read live, so a closed handle says it is closed rather than lying.
