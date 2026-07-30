# irregex

Python integration for the native
[irregex](https://github.com/The-Billy-Company/irregex)
search and similarity engine.

The package provides a dependency-free subprocess API for invoking an installed
`irregex` binary and decoding its NDJSON output:

```python
import irregex

matches = irregex.records(
    "context",
    "resident similarity cache",
    "-e",
    "Resident",
    "--all",
)
```

Set `IRREGEX_BIN` to an explicit executable path or place the native binary on
`PATH`. If neither is available, the API raises `ExecutableNotFound` with
installation guidance.

## Install

```console
python3 -m pip install irregex
```

This initial package is the Python bridge; native binary wheels will follow.

## License

Apache-2.0
