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
a shared library inside the package, and Python reaches it two ways depending on
what pip found for your interpreter - see [How it talks to the
engine](#how-it-talks-to-the-engine). Either way there is nothing to configure
and nothing to install alongside it.

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

The module-level verbs are `compile`, `search`, `match`, `fullmatch`, `finditer`,
`findall`, `split`, `sub`, `subn`, `is_match`, and `escape`. `compile` returns a `Pattern` with the
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

## Lexing: `compile_munch`

`compile_set` answers *which of these patterns match somewhere in this text*. A
tokenizer needs the other question — *starting exactly here, what is the longest
thing, and which terminal was it* — and `re` has no verb for it either:

```python
lex = irgx.compile_munch(["if", r"[a-z]+", r"[0-9]+", r"\s+"])

scan = lex.over("if x")
token = scan.token(0)
token.length  # 2
token.patterns  # (0, 1) - the keyword AND the identifier
```

The pair is the design, not a shortcoming. `if` is both terminals and both reach
length 2; which one wins is your lexer's business — declaration order, usually — so
the engine names every terminal that tied and resolves nothing. Choosing one here
would make keyword recognition impossible to build on top.

`over(text)` is the loop's friend: it encodes the subject **once** and answers every
cursor against that, so a whole-file tokenization pays one encode rather than one
per token. Offsets are in the subject's own units throughout, as everywhere else
here — characters for `str`, bytes for `bytes` — so `token.length` is a number you
can slice with. `lex.token(text, at)` is the one-shot form.

It is one walk, not one per terminal, because every pattern is determinized
together. That is also why the flags belong to the slate rather than a terminal:
there is nowhere to put "terminal 3 folds case". `ignore_case` and `dotall` are
carried; `multiline` is refused, since it asks for the line-anchor reading and an
anchored scan cannot observe the difference either way.

**A refusal is partial.** A slate of a hundred and fifty terminals where one is
outside the linear grammar is a working lexer, so the rest are seated and
`lex.declined` reports a `Refusal` per terminal that was not, each with a `Why`.
`Why` separates a budget from a wall: `STATES` means a bigger build would take the
terminal, `BUFFER_ANCHOR` that none ever will — a scan already starts where you
pointed, which leaves `\A` redundant and `\z` unsatisfiable, so the fix is deleting
it rather than raising a bound. Only a slate that seated *nothing* raises.

`shortest=True` is the other reading of the same cursor, skipping the empty one so
a nullable terminal cannot answer zero everywhere, and `allow=` restricts a single
call to a subset without a second compile — which is how context-sensitive lexing
works.

## Beyond One Buffer

`re` searches a string you already have. Most of the work in a real search tool
is deciding which strings to have at all, and the engine exposes that as six more
planes. Every one of them is imported lazily, so a program that only calls
`search` never pays to declare them.

```python
import irgx

# Which files may a search read? A materialized set, narrowed by term, not a
# generator you filter afterwards.
with irgx.walk(".", globs=["*.py"], not_globs=["*_test.py"]) as files:
    print(len(files), "eligible")

# Search a corpus rather than a buffer. `None` means no tier answered and you
# should fall back; an EMPTY cursor means the corpus really holds nothing.
with irgx.corpus(".") as corpus:
    cursor = corpus.search("WalletService", before=1, after=1)
    if cursor is not None:
        with cursor:
            for record in cursor.pull():
                print(f"{record.path}:{record.line_number}: {record.line}")

# An FM-index over a text it does not keep: counting needs no enumeration,
# because the count IS the width of the row interval the pattern admits.
with irgx.build_codex(open("big.log").read()) as codex:
    print(codex.count("ERROR"), codex.locate("ERROR"))

# The line grid, so the byte-offset-to-row conversion happens once, in one place.
text = "one\ntwo\nthree\n"
band = irgx.line_context(text, at=irgx.search("two", text).start(), before=2, after=2)
print(band.center, [row.number for row in band.rows])

# What a pattern promises before it runs, plus the Unicode tables behind it.
facts = irgx.literals(irgx.compile("hello world"))
if facts is not None:  # None for a pcre=True pattern: nothing to promise
    with facts:
        print(facts.set(irgx.Place.PREFIX))
print(irgx.unicode_version(), irgx.fold_orbit(ord("k")))

# N literal strings in one pass, keeping which one hit - what an alternation
# throws away.
with irgx.compile_needles(["cat", "the", "zebra"]) as needles:
    print(needles.which("the cat sat"))  # (0, 1) - zebra is absent
```

The sixth plane is `sieve`, which narrows a corpus against a persisted artifact
so most files are never opened. It is the one plane that declines routinely: with
no artifact on disk there is nothing to narrow *with*, so `irgx.sieve(path)`
returns `None` and your next move is to walk the tree yourself.

Two rules hold across all of them, and both are the kind of thing a ctypes
binding gets wrong invisibly:

- **Every value is copied at the boundary.** A tree record's path, a walk
  entry's path and a sieve's candidate list all point into an arena the handle
  owns. In Python a `str` built from borrowed memory looks exactly like any
  other, so nothing here hands one back: close the handle, drop it, let the GC
  run, and the values you already read still work.
- **A declinature is `None`, never an exception.** `IRGX_STALE` is the engine
  stepping aside with no fault set. The caller's next move is a fallback, not a
  traceback.

Handles are context managers, close idempotently, and refuse use afterward
instead of following a dangling pointer.

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

- **`fullmatch` refuses instead of guessing when groups would be wrong.** Both
  `match` and `fullmatch` are here, and they are not faked on top of an
  unanchored search - `match` is a leftmost search plus a start comparison, which
  is exact because this engine is leftmost-first exactly as `re` is, and
  `fullmatch` asks the anchored-longest automaton, so `a|ab` full-matches `"ab"`
  here the same way it does under `re`'s backtracking. What that automaton cannot
  do is report capture groups, and for the handful of patterns whose full match
  takes a path their leftmost match does not - `(a)|(ab)` over `"ab"` - the
  groups would belong to the wrong match, so it raises and says so rather than
  answering. Anchoring in the pattern still works and needs none of this: `\A`
  and `\z` are in the grammar. The canonical end anchor is `\z`, as in Rust and
  RE2; `\Z` is accepted as that same absolute end, so a `re` pattern carrying it
  ports unchanged. PCRE reads `\Z` as the end *or* just before a trailing
  newline, and that is deliberately not the reading you get here.
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

- **`$` is the end of the text, and not the byte before a trailing newline.**
  This one is not an improvement, it is a gap, and it is the only place the two
  libraries disagree about whether a pattern matches at all. `re` inherits
  Perl's rule where `$` also matches just before a final `\n`; Rust's `regex`
  and Go's `regexp` do not, and neither does this engine. So a pattern ending in
  `$` against text that ends in `\n` finds nothing here:

  ```python
  [m.span() for m in irgx.finditer(r"[a-z]+$", "cat\ndog\n")]  # []
  [m.span() for m in re.finditer(r"[a-z]+$", "cat\ndog\n")]  # [(4, 7)]
  ```

  Three spellings do agree, and one of them is probably what you meant:
  `(?m)[a-z]+$` (every line's end, which is where a trailing newline stops
  being special), `[a-z]+\z` (the text's end, said exactly), or stripping the
  newline first. `pcre=True` also has Perl's rule, since it *is* Perl's.

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

## How It Talks to the Engine

Nothing in this section changes an answer. It is here because on a short string
the interesting number is not how fast the engine matches but how much it costs
to ask it, and that is worth being honest about.

The floor is small: `irgx_is_match_in` runs in about 13 ns and `find_all` in
about 66 ns on a short text. Calling either through `ctypes` costs 300-600 ns on
top, because ctypes converts every argument, allocates a buffer object per call,
and builds the result out of Python objects one at a time. On a megabyte that is
invisible. On a 17-byte string it is most of the wall clock.

So the twelve verbs that get asked *once per text* - `search`, `finditer`,
`is_match`, the group spans behind `Match`, the set / needle / munch scans, and
the two whole-answer verbs behind `findall`, which walk the matches, run the
capture pass and build the finished list of texts in a single crossing - run
through a small C extension when one is installed:

```python
from irgx import _engine

_engine.native()  # the verbs answering natively; () means all ctypes
```

It takes your `str` directly, reads the UTF-8 CPython already keeps for it
rather than encoding a copy, keeps small span buffers on the C stack, and builds
the tuples itself. Same engine, same answers, 5-8x less overhead on a short
text: reading three groups out of a match goes from ~1.4 us to ~180 ns, a
one-match `finditer` from ~1.1 us to ~190 ns. The margin narrows as the text
grows, which is the point - the fix is to overhead, and overhead is most of what
a short string costs. The ninety-odd other symbols - opening a handle, compiling
a slate, describing the build - stay on ctypes, because a verb you call once per
program is not worth C.

**You do not need it, and you cannot end up without a working package.** Every
one of those verbs has its ctypes implementation sitting beside it, the routing
is per verb, and the fallback is what this package shipped before. Set
`IRGX_NO_ACCEL=1` to decline it for a process. If you are developing against a
checkout and want the fast path, `python3 scripts/build_accel.py` builds it in
place; `--clean` removes it.

## Supported Platforms

Wheels are built for macOS on arm64 and x86_64, Linux on x86_64 and aarch64
(manylinux, glibc 2.17 and newer), and Windows on x86_64 and arm64 (Windows 10
RS4 and newer). Python 3.12 and newer. Every platform gets the same engine and
the same answers, and the suite runs on each of them rather than on one and by
assumption on the rest. The wheels are platform-tagged, because they contain a
native library; a wheel for the wrong platform will not install rather than
failing at import.

Most platforms get two wheels, and pip picks between them for you. The
`py3-none-<platform>` one is the ctypes build and runs on any interpreter that
can load the library at all. The `cp312-abi3-<platform>` one additionally
carries the accelerator above; it is built only where the release machine *is*
the target, since a C extension needs its target's own Python headers. pip
prefers it wherever it fits and falls back to the portable wheel everywhere
else - a free-threaded build, PyPy, a platform no release box runs. One abi3
binary covers 3.12 and every version after it.

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
