# irregex - a linear-time regex engine for Python

A regex engine for Python that matches in linear time, shipped as a single
wheel with the engine inside it. No catastrophic backtracking, so no ReDoS.

```bash
pip install irregex
```

You install `irregex` and you `import irgx` - the distribution keeps the
project's name, the module is the short one you type all day.

That is the whole install. There is no compiler step, no Zig toolchain, and no
separate binary to put on your PATH. The engine is written in Zig and ships as
a shared library inside the package; Python talks to it through `ctypes`, which
is in the standard library.

## Why You Might Want It

The `re` module backtracks. On most patterns that is fine, and on a few it is
not: `(a+)+b` against a string of forty `a`s will hang your process. That is
not a bug in `re`; it is what a backtracking engine does. It has a name when an
attacker reaches it - regular expression denial of service, ReDoS - and if your
patterns come from a config file, an API request, or a user, you are one
unlucky pattern away from a stalled worker.

irregex runs a finite automaton instead. Match time is linear in the length of
the text and independent of how the pattern is shaped. In exchange, the default
grammar has no lookaround and no backreferences, because those are the features
that force backtracking. When you need them, ask for them explicitly with
`pcre=True` and you get a PCRE2 backend, with PCRE2's performance profile.

## A Short Tour

Here is the module-level surface, doing the thing it is for:

```python
import irgx

for m in irgx.finditer(r"(\w+)@(\w+\.\w+)", "write me@example.com or you@other.org"):
    print(m.span(), m.group(1), m.group(2))
```

```text
(6, 20) me example.com
(24, 37) you other.org
```

The module-level verbs are `compile`, `search`, `finditer`, `findall`, `split`,
`sub`, `subn`, `is_match`, and `escape`. `compile` returns a `Pattern` with the
same verbs as methods. A `Match` has `group`, `groups`, `groupdict`, `start`,
`end`, `span`, `expand`, `__getitem__`, and the `.re` and `.string` attributes.

```python
pattern = irgx.compile(r"(?P<key>\w+)=(?P<value>\d+)")

pattern.is_match("a=1")  # True, and the cheapest question
pattern.findall("a=1 bb=22")  # [('a', '1'), ('bb', '22')]
pattern.sub(r"\g<value>:\g<key>", "a=1")  # '1:a'
pattern.split("a=1, bb=22")  # keeps the groups, like re.split
irgx.escape("1+1=2")  # '1\\+1=2'
```

`sub` and `subn` take a template string or a callable. In a template, `\1` and
`\g<name>` refer to groups and `\g<0>` is the whole match. A callable receives
the `Match`.

A compiled `Pattern`'s `search`, `finditer`, `findall` and `is_match` take
`re`'s `pos` and `endpos`, which bound the search without slicing the subject:

```python
pattern = irgx.compile("^b")
pattern.search("abc", 1)  # None - `^` is still offset 0, not offset 1
irgx.compile("b$").search("abc", 0, 2)  # matches (1, 2) - `endpos` IS the end
```

The asymmetry is `re`'s and this follows it: `pos` moves where the search
starts, `endpos` moves where the text *ends*, so `$` and `\b` see it. Both clamp
into the subject rather than raising, and both count in the subject's own units —
characters for `str`, bytes for `bytes`. They live on the compiled pattern only,
as in `re`, where the module-level functions take `flags` in that position.

```python
irgx.sub(r"\d+", lambda m: str(int(m.group()) * 2), "a1 b20")  # 'a2 b40'
```

## Flags Are Keyword Arguments

There is no bitmask. Every option is a keyword on `compile`, and on the
module-level verbs.

- **`fixed`** treats the pattern as a literal string, with no metacharacters.
- **`ignore_case`** folds case, including outside ASCII.
- **`word`** only reports a match that stands alone as a word.
- **`smart_case`** folds case only if the pattern has no uppercase in it.
- **`unicode`** turns on Unicode classes, folding, and boundaries; it is on by
  default.
- **`pcre`** switches to the PCRE2 grammar - lookaround and backreferences,
  and no linear-time guarantee.

Each flag composes with the others, and none of them touches the pattern text:

```python
irgx.findall("a.c", "abc a.c", fixed=True)  # ['a.c']
irgx.findall("cat", "cat cats concat", word=True)  # ['cat']
irgx.findall("café", "CAFÉ", ignore_case=True)  # ['CAFÉ']
irgx.findall(r"(?<=@)\w+", "me@example", pcre=True)  # ['example']
```

`fixed`, `word` and `smart_case` have no spelling in `re` at all. They are the
options a command-line searcher has had for decades, and they are frequently
what you actually meant.

## `str` In, `str` Out

A pattern compiled from `str` searches `str` and reports codepoint indices. A
pattern compiled from `bytes` searches `bytes` and reports byte offsets. Mixing
the two raises `TypeError`, the same way `re` refuses it.

This matters more than it sounds like it does. The engine works in UTF-8 bytes,
so a naive binding hands you byte offsets for a `str` you cannot slice with
them. Here the translation is done for you, and this holds for every match:

```python
text = "naïve café"
for m in irgx.finditer(r"\w+", text):
    assert text[m.start() : m.end()] == m.group()
```

ASCII text takes a fast path where the two are identical, so you pay nothing
for the guarantee when it costs nothing.

## A `Pattern` Is Safe to Share Across Threads

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

## Errors Are Exceptions

`irgx.error` is the base, named to match `re.error` so `except` clauses
port unchanged. It carries the same three attributes `re.error` does - `msg`,
`pattern`, `pos` - so a caller compiling patterns out of a config file can say
which one broke and where.

An unbalanced class is refused at compile time, with `pos` naming the byte:

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
    pattern = irgx.compile(r"(?<=\$)\d+", pcre=True)  # this always works
```

Which of the two you get is the engine's ruling, not a guess made here: it asks
PCRE2 whether PCRE2 can express the pattern, and answers on the return value.
Because `UnsupportedPattern` is a subclass, `except irgx.error` still catches
both.

Running out of memory raises `MemoryError`, because that is the exception a
Python caller already handles for it.

## How This Differs from `re`

Most patterns behave identically, and the test suite checks a set of them
against `re` on every run. These are the places they part ways, all of them on
purpose.

- **No `match` or `fullmatch`.** Both would have to be faked on top of an
  unanchored search, which is where they end up subtly wrong. Write the
  anchor instead: `\A` and `\z` are in the grammar. Note the spelling of the
  end anchor; it is `\z`, as in Rust and RE2, not `\Z`.
- **`finditer` is eager.** The engine reports the whole match sequence in one
  call rather than handing back a cursor a Python loop advances, so the
  iterator knows its own `len()` before you walk it. The sequence itself is
  `re`'s — every empty match at every position, including the one at the end of
  the text and the one abutting a previous match — because deriving it in Python
  is exactly where a binding gets nullable patterns wrong:

  ```python
  [m.span() for m in irgx.finditer("a*", "abc")]  # [(0, 1), (1, 1), (2, 2), (3, 3)]
  ```

- **`findall` reports `None` for a group that did not participate**, where
  `re.findall` reports `""`. A group that did not match and a group that
  matched the empty string are different facts, and `.groups()` already
  tells them apart in both libraries.

  ```python
  irgx.findall(r"(a)|(b)", "ab")  # [('a', None), (None, 'b')]
  re.findall(r"(a)|(b)", "ab")  # [('a', ''), ('', 'b')]
  ```

- **There is an `is_match`.** It asks whether the text holds a match at all
  and lets the engine stop at the first one without building a span. `re`
  has no equivalent, so it is named after what it does.

## Introspection

A few module attributes describe what is actually loaded, which matters the
moment `IRGX_LIB` enters the picture:

```python
irgx.__version__  # this package
irgx.ENGINE_VERSION  # the Zig engine bundled in this wheel
irgx.PCRE2_VERSION  # the PCRE2 the pcre=True arm runs on
irgx.LIBRARY  # the resolved path of the loaded shared library
```

Set `IRGX_LIB` to the path of a shared library to load that one instead of
the bundled copy. It names a file, not a directory, and a path that is not
there fails loudly at import rather than silently falling back.

## Supported Platforms

Wheels are built for macOS on arm64 and x86_64, Linux on x86_64 and aarch64
(manylinux, glibc 2.17 and newer), and Windows on x86_64 and arm64 (Windows 10
RS4 and newer). Python 3.12 and newer. Every platform gets the same engine and
the same answers, and the suite runs on each of them rather than on one and by
assumption on the rest. The wheels are platform-tagged, because they contain a
native library; a wheel for the wrong platform will not install rather than
failing at import.

## Searching a Codebase with It

This is the engine. If what you actually want is a tool, three are built on it
and each ships its own package.

- **[`gist-search`](https://pypi.org/project/gist-search/)** answers where an
  exact pattern is.
- **[`relate-search`](https://pypi.org/project/relate-search/)** answers what
  resembles this, and what repeats.
- **[`blast-search`](https://pypi.org/project/blast-search/)** answers what
  breaks if this symbol changes.

## License

Apache-2.0. The bundled library includes PCRE2 and other third-party
components; see NOTICE.
