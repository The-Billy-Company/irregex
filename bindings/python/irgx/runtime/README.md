# `irgx.runtime` — shared transports

How an answer reaches a binding. Every product verb is answered by the same
certified engines; this package owns the doors and the order they are tried:

```text
in-process C-ABI  →  resident session (UDS)  →  subprocess CLI
```

The first two rungs are *product-shaped* — a warm session and a resident daemon
belong to the library whose corpus they hold — so they live in that product's
package (`gist._native`, `gist._daemon`). What stays here is what every face
shares: finding a library or a binary, composing one cffi type universe,
dispatching a verb, and decoding a row.

| Module | Owns |
|---|---|
| `loader.py` | the face registry, library location, and the one `cdef` composition |
| `shell.py` | binary location (`gist` / `relate` / `blast` via owning checkout or env), subprocess search, `run_verb` |
| `analytic.py` | verb ladder over `gist_run` / `relate_run` / `blast_run` |
| `cold.py` | CLI NDJSON → same `Row` decoder |
| `decode.py` | schema-driven row → record |
| `params.py` | five analytic params families |
| `errors.py` | typed failures |

Product packages import this substrate; it imports none of them. The substrate
*declares* all three producers, because `irgx.h` does — analytic op numbers
stayed ecosystem-wide when the libraries split — but it `dlopen`s only faces a
product package registered, so nothing here mirrors or maps a foreign header.
