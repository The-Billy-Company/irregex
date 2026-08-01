# `irregex.runtime` — shared transports

How an answer reaches a binding. Every product verb is answered by the same
certified engines; this package owns the doors and the order they are tried:

```
native (in-process C-ABI)  →  resident session (UDS)  →  subprocess CLI
```

| Module | Owns |
|---|---|
| `shell.py` | binary location (`gist` / `relate` / `blast` via owning checkout or env), subprocess search, `run_verb` |
| `native.py` | `libirregex` + `libgist` loader, push-session search handle |
| `daemon.py` | warm `gist serve` UDS client |
| `analytic.py` | verb ladder over `gist_run` / `relate_run` / `blast_run` |
| `cold.py` | CLI NDJSON → same `Row` decoder |
| `decode.py` | schema-driven row → record |
| `params.py` | five analytic params families |
| `errors.py` | typed failures |

Product packages import this substrate; they do not re-export each other's faces.
