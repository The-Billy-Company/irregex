# irregex

A regex engine for Python that matches in linear time, shipped as a single
wheel with the engine inside it.

```bash
pip install irregex
```

You install `irregex` and you `import irgx` - the distribution keeps the
project's name, the module is the short one you type all day.

That is the whole install. There is no compiler step, no Zig toolchain, and no
separate binary to put on your PATH. The engine is written in Zig and ships as
a shared library inside the package; Python talks to it through `ctypes`, which
is in the standard library.

## Why you might want it

The `re` module backtracks. On most patterns that is fine, and on a few it is
not: `(a+)+b` against a string of forty `a`s will hang your process. That is
not a bug in `re`; it is what a backtracking engine does. If your patterns come
from a config file, an API request, or a user, you are one unlucky pattern away
from a stalled worker.

irregex runs a finite automaton instead. Match time is linear in the length of
the text and independent of how the pattern is shaped. In exchange, the default
grammar has no lookaround and no backreferences, because those are the features
that force backtracking. When you need them, ask for them explicitly with
`pcre=True` and you get a PCRE2 backend, with PCRE2's performance profile.

## A short tour

```python
import irgx

for m in irgx.finditer(r"(\w+)@(\w+\.\w+)", "write me@example.com or you@other.org"):
    print(m.span(), m.group(1), m.group(2))
```

```
(6, 20) me example.com
(24, 37) you other.org
```

The module-level verbs are `compile`, `search`, `finditer`, `findall`, `split`,
`sub`, `subn`, `is_match`, and `escape`. `compile` returns a `Pattern` with the
same verbs as methods. A `Match` has `group`, `groups`, `groupdict`, `start`,
`end`, `span`, `expand`, `__getitem__`, and the `.re` and `.string` attributes.

```python
pattern = irgx.compile(r"(?P<key>\w+)=(?P<value>\d+)")

pattern.is_match("a=1")                       # True, and the cheapest question
pattern.findall("a=1 bb=22")                  # [('a', '1'), ('bb', '22')]
pattern.sub(r"\g<value>:\g<key>", "a=1")      # '1:a'
pattern.split("a=1, bb=22")                   # keeps the groups, like re.split
irgx.escape("1+1=2")                       # '1\\+1=2'
```

`sub` and `subn` take a template string or a callable. In a template, `\1` and
`\g<name>` refer to groups and `\g<0>` is the whole match. A callable receives
the `Match`.

```python
irgx.sub(r"\d+", lambda m: str(int(m.group()) * 2), "a1 b20")   # 'a2 b40'
```

## Flags are keyword arguments

There is no bitmask. Every option is a keyword on `compile`, and on the
module-level verbs.

| Keyword | What it does |
|---|---|
| `fixed` | Treat the pattern as a literal string. No metacharacters. |
| `ignore_case` | Fold case, including outside ASCII. |
| `word` | Only report a match that stands alone as a word. |
| `smart_case` | Fold case only if the pattern has no uppercase in it. |
| `unicode` | Unicode classes, folding and boundaries. On by default. |
| `pcre` | Use the PCRE2 grammar. Lookaround and backreferences; not linear time. |

```python
irgx.findall("a.c", "abc a.c", fixed=True)             # ['a.c']
irgx.findall("cat", "cat cats concat", word=True)      # ['cat']
irgx.findall("café", "CAFÉ", ignore_case=True)         # ['CAFÉ']
irgx.findall(r"(?<=@)\w+", "me@example", pcre=True)    # ['example']
```

`fixed`, `word` and `smart_case` have no spelling in `re` at all. They are the
options a command-line searcher has had for decades, and they are frequently
what you actually meant.

## str in, str out

A pattern compiled from `str` searches `str` and reports codepoint indices. A
pattern compiled from `bytes` searches `bytes` and reports byte offsets. Mixing
the two raises `TypeError`, the same way `re` refuses it.

This matters more than it sounds like it does. The engine works in UTF-8 bytes,
so a naive binding hands you byte offsets for a `str` you cannot slice with
them. Here the translation is done for you, and this holds for every match:

```python
text = "naïve café"
for m in irgx.finditer(r"\w+", text):
    assert text[m.start():m.end()] == m.group()
```

ASCII text takes a fast path where the two are identical, so you pay nothing
for the guarantee when it costs nothing.

## A Pattern is safe to share across threads

Put a compiled pattern at module scope and use it from a thread pool. That is
what people do, and it works here.

```python
PATTERN = irgx.compile(r"(\w+)=(\d+)")

with ThreadPoolExecutor() as pool:
    results = list(pool.map(PATTERN.findall, many_texts))
```

Underneath, the engine's handle is not thread-safe; it owns the scratch space
its searches run in. The `Pattern` keeps the pattern text and the flags, which
are immutable, and hands each thread its own handle the first time that thread
uses it. Compiling is pure, so this costs one compile per thread and nothing
after that. When a thread ends, its handle is released with it.

## Errors are exceptions

`irgx.error` is the base, named to match `re.error` so `except` clauses
port unchanged. It carries the same three attributes `re.error` does - `msg`,
`pattern`, `pos` - so a caller compiling patterns out of a config file can say
which one broke and where.

```python
>>> irgx.compile("[abc")
Traceback (most recent call last):
  ...
irgx.error: could not compile pattern '[abc': BadPattern; invalid: bad argument, or a pattern this arm cannot compile
```

A pattern can also be refused for a reason that has a remedy. Lookaround, a
backreference and an atomic group are outside the linear grammar but perfectly
well-formed, and the engine does not call those a failure at all - it *declines*
them, which is a different status code saying "not me, try the fallback". That
arrives as `irgx.UnsupportedPattern`, a subclass, with `pos` of `None`,
because a tier that stepped aside has nothing to point at.

```python
try:
    pattern = irgx.compile(r"(?<=\$)\d+")
except irgx.UnsupportedPattern:
    pattern = irgx.compile(r"(?<=\$)\d+", pcre=True)   # this always works
```

Which of the two you get is the engine's ruling, not a guess made here: it asks
PCRE2 whether PCRE2 can express the pattern, and answers on the return value.
Because `UnsupportedPattern` is a subclass, `except irgx.error` still catches
both.

Running out of memory raises `MemoryError`, because that is the exception a
Python caller already handles for it.

## How this differs from `re`

Most patterns behave identically, and the test suite checks a set of them
against `re` on every run. These are the places they part ways, all of them on
purpose.

**No `match` or `fullmatch`.** Both would have to be faked on top of an
unanchored search, which is where they end up subtly wrong. Write the anchor:
`\A` and `\z` are in the grammar. Note the spelling of the end anchor; it is
`\z`, as in Rust and RE2, not `\Z`.

**Zero-width matches follow the engine's rules, not `re`'s.** `re` reports an
empty match after the last character of the text; this engine does not.

```python
[m.span() for m in irgx.finditer("a*", "abc")]   # [(0, 1), (2, 2)]
[m.span() for m in re.finditer("a*", "abc")]        # [(0, 1), (1, 1), (2, 2), (3, 3)]
```

The engine also suppresses an empty match sitting exactly where the previous
match ended, which is why `a*` over `"abc"` gives two spans and not four.
Iteration here comes from a single call into the engine's own match-sequence
routine rather than from a Python loop advancing a cursor, so these rules are
the engine's and not a re-derivation of them.

**A newline is a line terminator, not ordinary whitespace.** A single-character
class will not match it. A longer match may still span one.

```python
irgx.findall(r"\s", "a\nb")     # []
irgx.findall(r"\s", "a\tb")     # ['\t']
irgx.findall(r"a\sb", "a\nb")   # ['a\nb']
```

**`findall` reports `None` for a group that did not participate**, where
`re.findall` reports `""`. A group that did not match and a group that matched
the empty string are different facts, and `.groups()` already tells them apart
in both libraries.

```python
irgx.findall(r"(a)|(b)", "ab")   # [('a', None), (None, 'b')]
re.findall(r"(a)|(b)", "ab")        # [('a', ''), ('', 'b')]
```

**There is an `is_match`.** It asks whether the text holds a match at all and
lets the engine stop at the first one without building a span. `re` has no
equivalent, so it is named after what it does.

## Introspection

```python
irgx.__version__      # this package
irgx.ENGINE_VERSION   # the Zig engine bundled in this wheel
irgx.PCRE2_VERSION    # the PCRE2 the pcre=True arm runs on
irgx.LIBRARY          # the resolved path of the loaded shared library
```

Set `IRGX_LIB` to the path of a shared library to load that one instead of
the bundled copy. It names a file, not a directory, and a path that is not
there fails loudly at import rather than silently falling back.

## Supported platforms

Wheels are built for macOS on arm64 and x86_64, Linux on x86_64 and aarch64
(manylinux, glibc 2.17 and newer), and Windows on x86_64. Python 3.10 and
newer. The wheels are platform-tagged, because they contain a native library;
a wheel for the wrong platform will not install rather than failing at import.

## License

Apache-2.0. The bundled library includes PCRE2 and other third-party
components; see NOTICE.
