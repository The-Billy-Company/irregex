# The `irgx.runtime` Package

This package owns how an answer reaches a binding. Every product verb is
answered by the same certified engines, and the doors and the order they are
tried in live here:

```text
in-process C-ABI  →  resident session (UDS)  →  subprocess CLI
```

The first two rungs are *product-shaped* — a warm session and a resident
daemon belong to the library whose corpus they hold — so they live in that
product's own package (its native and daemon modules). What stays here is
what every face shares: finding a library or a binary, composing one cffi
type universe, dispatching a verb, and decoding a row.

- **`loader.py`** owns the face registry, library location, and the one
  `cdef` composition.
- **`shell.py`** owns binary location (the exact, kinship, and composed faces
  via owning checkout or env), subprocess search, and `run_verb`.
- **`analytic.py`** owns the verb ladder over the three `<face>_run`
  producers.
- **`cold.py`** rebuilds the CLI's NDJSON through the same `Row` decoder.
- **`decode.py`** owns the schema-driven row-to-record conversion.
- **`params.py`** owns the five analytic parameter families.
- **`errors.py`** owns the typed failures.

Product packages import this substrate; it imports none of them. The
substrate declares all three producers, because `irgx.h` does — analytic op
numbers stayed ecosystem-wide when the libraries split — but it `dlopen`s
only faces a product package registered, so nothing here mirrors or maps a
foreign header.
