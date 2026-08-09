`irgx_walk_limits()` now reports `brace_cap` and `brace_group_cap`, so a host
sizing a user's glob reads the numbers this build enforces instead of copying
1,024 and 64 out of a changelog and holding them wrongly forever.

The ceilings were already real and already the right call - a braced term
multiplies, so sixty-five bytes of spec can name 8,192 globs, and a host that
accepted one from a stranger accepted an OOM. But they were only discoverable by
refusal. A service validating a user-supplied glob before sending it had no way
to ask, so its options were to guess the limit, hardcode it against a future
build that moves it, or send the term and treat `IRGX_OOM` as a user error -
which means reading `irgx_last_fault()->name` to tell `BudgetExceeded` apart from
the machine genuinely running out. The struct that should have answered this was
already there, already `struct_size`-guarded, and already says in its own comment
that it exists "so a host sizes its request against the truth instead of a
constant it copied". It just didn't carry these two.

Both are published, not one, because they bound different things and the second
is invisible from the first. `brace_cap` bounds the PRODUCT; `{a}{a}{a}…` has a
product of one and slips past it however long it grows, while still recursing
once per group. A host that validated only against `brace_cap` would still build
a term the open refuses.

Appending is how this struct was always meant to grow, so an older host reading
through its own smaller `struct_size` is unaffected. Go, Python, and Rust each
carry the pair.

The tests do not compare the field to a constant, which would only prove the
constant equals itself. Each ceiling is driven to its own boundary in all three
bindings - exactly at the cap opens, one past it refuses - so the published
number is checked against the enforced one, in the arithmetic a host does.
