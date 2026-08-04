# The `irgx` Package

Two surfaces share this distribution: the **regex API** (buffer match, no
corpus) and the **substrate** every product binding imports (contract mirrors,
row decode, transports). The user-facing regex docs are the package
[README](../README.md); this file is about how the code is arranged. The shape
is the same one the Rust and Go bindings use, and
[`bindings/README.md`](../../README.md) is where that agreement is written down.

The regex face **is** the package. There is no `irgx.regex` to import: the whole
of it is reached as `irgx.compile`, `irgx.finditer`, `irgx.error`, so the modules
below it are private and flat, one per concern, in dependency order.

- **`__init__.py`** is the stable module-level regex surface, the pattern
  cache behind it, and `escape`.
- **`_abi.py`** finds and loads the shared library, declares every C
  signature, and turns a status code into an exception of the right class.
  Nothing above it sees a status code.
- **`_pool.py`** carries `Compiled`, one owned `irgx_regex *`, and the
  per-thread pool that makes a shareable `Pattern` out of a handle that is not.
- **`_pattern.py`** carries `Pattern`: flag assembly and every search verb.
- **`_match.py`** carries `TextView`, which keeps the caller's domain and the
  engine's domain apart, and `Match`, which reports positions only in the
  caller's.
- **`_replace.py`** parses a `sub` replacement into literal chunks and group
  numbers, resolved against the pattern at parse time.

The substrate is public, because product bindings import it by name:

- **`contract/`** carries the mirrored contracts and the `schema.gen.py`
  indexes; see its own [README](contract/README.md).
- **`request.py`** is the shared `SearchRequest` / `Match` seam consumed by the
  search products (`contract/engine.toml`).
- **`runtime/`** carries the analytic ladder and the shell/native/daemon
  transports; see its own [README](runtime/README.md).

## The Three Rules the Layering Exists to Enforce

- **Iteration comes from `irgx_find_all`.** The engine owns what a match
  sequence is: whether an empty match adjacent to the previous one counts,
  what happens at the end of the text, how `word=True` interacts with
  resuming. None of that is re-derivable from a `find(from)` cursor, so
  `_pattern.py` asks `find_all` once for the authoritative spans and only
  then, per match and only when the pattern declares groups, asks `captures`
  for the detail. When the two disagree it raises rather than reporting
  either.
- **The caller's domain and the engine's domain never mix.** The engine
  searches UTF-8 bytes. A caller who passed a `str` gets codepoint indices,
  translated by `TextView`, which caches checkpoints so a forward scan pays
  one linear pass in total rather than one per match. ASCII text skips the
  translation entirely, because there the two are the same numbers.
- **A C handle belongs to one thread.** It owns the scratch its finds run in.
  `Pattern` holds only the pattern source and the flags, which are immutable,
  and asks `_pool.py` for a handle; that module keeps one per thread in a
  `threading.local`. The compile is pure, so a thread pool costs one compile
  per thread and nothing after that, and a thread's handle is freed when the
  thread ends.

## Loading

`_abi.py` resolves the library at import: the `IRGX_LIB` environment
override if set, otherwise `irgx/lib/libirgx.{dylib,so,dll}` inside the
installed package. It then declares `argtypes` and `restype` on every bound
function - a missing `argtypes` lets ctypes truncate a pointer to 32 bits on
some platforms, which is the classic way an FFI binding crashes far from the
mistake - and refuses to run against any ABI version but 2.

## Which Exception a Failure Becomes

The classification is the status code, and nothing else. A pattern only the
PCRE2 grammar can express comes back as `IRGX_STALE` - a declinature, the one
negative status that is not an error - so `Compiled` raises
`UnsupportedPattern` from the return value alone, with no second call and no
string to compare. `IRGX_INVALID` is a real failure and becomes `error`,
carrying the byte offset the engine located it at.

This used to key on the fault name being the literal `"Unsupported"`, which was
a spelling agreement rather than a contract: rename it upstream and every
binding quietly stops suggesting `pcre=True` instead of failing loudly. A status
code cannot rot that way.

Two consequences worth knowing. A declinature installs no fault at all and
clears whatever was in the slot, so there is nothing to read even if you wanted
to - which is exactly why the status has to carry the answer. And `check` does
not translate `IRGX_STALE`: what to do about a declinature depends on the
verb's own fallback, compile takes its fallback before calling `check`, so a
stale reaching `check` means a verb grew one this binding does not know about.
It says so rather than guessing.
