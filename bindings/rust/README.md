# irregex

A regex engine for Rust that matches in linear time, with the engine shipped
inside the crate.

```toml
[dependencies]
irregex = "0.1"
```

You depend on `irregex` and you `use irgx::` - the package keeps the project's
name, the lib is the short one you type all day.

That is the whole install on the four common desktop and server targets. There
is no Zig toolchain to fetch, no C compiler step, and no separate binary to put
on your PATH. The engine is written in Zig; the crate carries a prebuilt static
archive per target and `build.rs` picks the right one and links it in.

## Why you might want it

The `regex` crate is excellent and it is also linear time, so this is not a
pitch against it. The reason to reach for irregex is the other half of the
grammar. When a pattern needs lookaround or a backreference, `regex` cannot
express it at all and you end up adding `fancy-regex` or `pcre2` beside it, with
a second API and a second set of semantics. Here it is one flag on the same
builder, and the two arms report matches in the same coordinate system:

```rust
use irgx::RegexBuilder;

let re = RegexBuilder::new(r"(?<=\$)\d+").pcre(true).build()?;
assert_eq!(re.find("cost $42").unwrap().as_str(), "42");
```

You do not have to know in advance which patterns need that flag, either. A
pattern the fast engine cannot express comes back as `Error::NeedsPcre` rather
than as a syntax error, so you can retry it on the other arm in two lines - see
"Compiling" below.

The other reason is `fixed`, `word` and `smart_case`, which have no spelling in
`regex` and are frequently what you actually meant. See "Flags" below.

## A short tour

```rust
use irgx::Regex;

let re = Regex::new(r"(\w+)@(\w+\.\w+)")?;
for caps in re.captures_iter("write me@example.com or you@other.org") {
    println!("{:?} {} {}", caps.get(0).unwrap().range(), &caps[1], &caps[2]);
}
```

```
6..20 me example.com
24..37 you other.org
```

The surface is the `regex` crate's, so code written against that crate mostly
compiles unchanged:

```rust
re.is_match(text);              // the cheapest question; may stop at the first hit
re.find(text);                  // Option<Match>
re.find_iter(text);             // every match
re.captures(text);              // Option<Captures>
re.captures_iter(text);         // groups for every match
re.split(text);                 // the pieces between matches
re.splitn(text, 3);
re.replace(text, "$1");         // the leftmost match
re.replace_all(text, "$1");
re.replacen(text, 2, "$1");
```

A `Match` has `start()`, `end()`, `range()`, `as_str()`, `as_bytes()`, `len()`
and `is_empty()`. A `Captures` has `get(n)`, `name("n")`, `iter()`, `len()`,
`expand()`, and `Index` by number and by name. A replacement can be a `&str`
template with `$1` and `${name}` references, a `NoExpand` for text you did not
write, or a `FnMut(&Captures) -> impl AsRef<str>`.

Every verb that can panic has a `try_` sibling that returns
`Result<_, irgx::Error>` instead: `try_is_match`, `try_find`, `try_find_iter`,
`try_captures`, `try_captures_iter`, `try_replacen`. The panicking forms exist so
`re.find(text)` returns an `Option` and reads like the crate you already know;
the checked forms exist so a caller who cannot take a panic never has to.

## Flags

`RegexBuilder` carries six, and each one changes an answer:

| Method | What it does |
|---|---|
| `fixed` | Treat the pattern as a literal string. No metacharacters, and no pattern can be a syntax error. |
| `ignore_case` | Fold case, including outside ASCII. |
| `word` | Only report a match that stands alone as a word. |
| `smart_case` | Fold case only if the pattern itself has no uppercase in it. |
| `unicode` | Unicode classes, folding and boundaries. On by default. |
| `pcre` | Use the PCRE2 grammar: lookaround and backreferences. Not linear time. |

```rust
use irgx::RegexBuilder;

RegexBuilder::new("a.c").fixed(true).build()?;         // matches "a.c", not "abc"
RegexBuilder::new("cat").word(true).build()?;          // "cat", not "concatenate"
RegexBuilder::new("café").ignore_case(true).build()?;  // matches "CAFÉ"
RegexBuilder::new("abc").smart_case(true).build()?;    // folds; "Abc" would not
```

`fixed` wins over `pcre`, as it does in the engine: a literal string needs no
grammar at all.

## A Regex is Send + Sync

Put one in a `static` and search from as many threads as you like. That is what
people do, and it works here.

```rust
use std::sync::LazyLock;
use irgx::Regex;

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\w+").unwrap());

// from any number of threads, concurrently
let count = WORD.find_iter(text).count();
```

Underneath, the engine's handle is not thread-safe; it owns the scratch space
its searches run in, and the C ABI says to compile one per thread. A `Regex`
keeps the pattern and the flags, which are immutable, plus a pool of handles.
A search leases a handle for as long as it needs one and returns it. So the cost
is one compile per thread that is *concurrently* inside the engine, not one per
thread that ever touches the pattern, and a handle a finished thread used gets
reused rather than leaked. There is no `unsafe impl Sync` over a shared handle
anywhere in the crate.

`Regex` is also `Clone`, which recompiles, because a compiled handle cannot be
duplicated through the C ABI. The compile is pure, so the clone behaves
identically.

## Offsets are byte offsets, and they are yours

Rust `str` is UTF-8 and sliced by byte index. The engine reports byte offsets
into the same UTF-8. So there is no translation layer here at all, and this
holds for every match:

```rust
let text = "naïve café";
for m in Regex::new(r"\w+")?.find_iter(text) {
    assert_eq!(&text[m.range()], m.as_str());
}
```

One exception, and it is one you have to ask for. With `unicode(false)` the
engine matches bytes, so `.` can stop in the middle of a codepoint. Slicing a
`str` there panics, which would surface as an unexplained panic from inside this
crate, so instead it is `Error::NotCharBoundary` with the offset in it:

```rust
let re = RegexBuilder::new(".").unicode(false).build()?;
assert!(re.try_find("é").is_err());   // the boundary is at byte 1
```

The panicking verbs panic with that message rather than a slice-index panic.

## Compiling: there are two ways a pattern can be refused

This is the one place the API is shaped differently from `regex`, and it is
worth two minutes because it is the difference between a pattern you can fix
and a pattern you can just retry.

`regex` has a single `Error::Syntax(String)`, which is right for `regex`: there
is exactly one grammar, so a pattern it will not take is a pattern that is
wrong. Here there are two grammars, so "I cannot read this" and "I can read this
but the fast engine cannot run it" are different facts with different repairs.
They come back as different variants, and the engine decides which by asking
PCRE2 rather than by matching the pattern against a list of constructs:

**`Error::NeedsPcre`** - the pattern is fine, the linear grammar just cannot
express it. Lookaround, backreferences, atomic groups, inline flag groups.
The same pattern under `pcre(true)` compiles. So the retry is two lines:

```rust
use irgx::{Error, Regex, RegexBuilder};

fn compile(pattern: &str) -> Result<Regex, Error> {
    match Regex::new(pattern) {
        Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
        other => other,
    }
}

assert_eq!(compile(r"(?<=\$)\d+")?.find("cost $42").unwrap().as_str(), "42");
```

Retrying is a real decision rather than a formality, which is why this is not
done for you. The linear engine is linear in the length of the text and the
PCRE2 arm is not, so a program compiling patterns somebody else typed may
prefer to report this and stop. Both are one match arm.

**`Error::Syntax`** - the pattern is malformed, and it carries the byte offset
the engine stopped at, so you can point at it. `pcre(true)` will not rescue
this one; retrying just fails twice.

```rust
let Err(Error::Syntax { at, .. }) = Regex::new("(unclosed") else { unreachable!() };
assert_eq!(at, 9);
```

```
cannot compile pattern `(unclosed`: at byte 9, BadPattern; invalid: bad
argument, or a pattern this arm cannot compile (status -4)
```

The offset is always a real index into the pattern you handed over - never past
the end, never mid-codepoint - so `&pattern[..at]` is the part the engine got
through, and printing a caret under it needs no bounds check.

## Errors

`irgx::Error` implements `std::error::Error` and carries the engine's own
fault name and its sentence for the status, never a bare number. The variants
are `NeedsPcre`, `Syntax`, `Pattern`, `Search`, `Groups`, `OutOfMemory`, `Abi`,
`NotCharBoundary` and `Inconsistent`.

`Pattern` is the third compile refusal and the rarest: the engine's own
ceilings, where no single byte is the problem and so there is no offset to
report. `OutOfMemory` is separate because "the machine is out of memory" and
"your pattern is wrong" call for different handling; ask
`err.is_out_of_memory()`. `Inconsistent` means the engine's own arms disagreed
about a match, which is reported rather than papered over. A negative status
never becomes a wrong answer.

## How this differs from the `regex` crate

Most patterns behave identically. These are the places they part ways.

**`pcre` is a flag, not a different crate.** Lookaround and backreferences are
available; they are also not linear time, which is why they are opt-in rather
than the default.

**`fixed`, `word` and `smart_case` exist.** They are the options a command-line
searcher has had for decades and they have no `regex` equivalent.

**No `Regex::shortest_match`, `find_at`, or byte-slice `Regex`.** The C ABI has
no anchored or resumable verb, and faking one on top of an unanchored scan is
exactly where a binding goes subtly wrong. Anchors are in the grammar: use `\A`
and `\z`. Note the spelling of the end anchor; it is `\z`, as in `regex` and
RE2, not `\Z`.

**`find_iter` is eager.** The engine reports the whole match sequence in one
call, and that call is the authority on what a sequence *is*, so the crate asks
once instead of advancing a cursor. In exchange the iterator knows its own
length and runs backwards:

```rust
let found = re.find_iter(text);
println!("{}", found.len());
for m in re.find_iter(text).rev() { /* ... */ }
```

**Zero-width matches follow the engine's rules.** It suppresses an empty match
at the end of the buffer, and one sitting exactly where the previous match
ended:

```rust
// irregex
[(0, 1), (2, 2)]
// the regex crate
[(0, 1), (1, 1), (2, 2), (3, 3)]
```

for `a*` over `"abc"`. This is not a translation choice; iteration comes from a
single call into the engine's own match-sequence routine, so these are its rules
rather than a re-derivation of them.

**A newline is a line terminator, not ordinary whitespace.** A
single-character class will not match one. A longer match may still span one.

```rust
Regex::new(r"\s")?.find("a\nb");      // None
Regex::new(r"\s")?.find("a\tb");      // the tab, at byte 1
Regex::new(r"a\sb")?.find("a\nb");    // the whole thing, newline included
```

**The text you search is one unit, and there is no multi-line mode.** `^` and
`\A` match at offset 0, `$` and `\z` at the end, and an interior newline is an
ordinary byte rather than a boundary. That is the `regex` crate's default too;
the difference is that you cannot turn it off. The linear grammar refuses `(?m)`
rather than accepting it and ignoring it, so a pattern written for another engine
fails loudly instead of quietly matching the wrong thing. If you want per-line
anchors, either split the text yourself and search each line, or use the `pcre`
arm, which does honour `(?m)`:

```rust
Regex::new("(?m)^b");                                   // Err(Error::NeedsPcre)
RegexBuilder::new("(?m)^b").pcre(true).build()?
    .find("a\nb");                                      // matches at byte 2
```

An inline flag group is a grammar the linear engine declines rather than a
pattern it cannot read, so this is the retryable variant and the two-line retry
above handles it.

`is_match` is the cheap way to ask, and it agrees with `find` on every input: it
runs the same walk and stops at the first span rather than materialising the
rest.

**`Captures::get` reports `None` for a group that did not participate**, which
is a different fact from a group that matched the empty string. So does the
`regex` crate; the difference is that indexing distinguishes the two reasons in
its panic message here.

## Install and linking

`build.rs` resolves the native library in this order, and the first rung that
answers wins:

1. **`IRGX_LIB_DIR`** - a directory holding your own `libirgx.a` or
   `libirgx.{dylib,so}`. This is the override, and it is absolute: if it is
   set and does not hold a library, the build fails rather than falling through
   to something you did not ask for.
2. **A vendored static archive** for the target triple, from `vendor/` in this
   crate. This is the path almost everyone takes, and it needs nothing installed.
3. **An existing `zig-out/lib/`** in an engine checkout beside the crate, when
   you are building for the host.
4. **`zig build`** in that checkout, when `zig` is on PATH.

Vendored targets:

| Target | Archive |
|---|---|
| `aarch64-apple-darwin` | 1.32 MiB |
| `x86_64-apple-darwin` | 1.42 MiB |
| `x86_64-unknown-linux-gnu` | 1.76 MiB |
| `aarch64-unknown-linux-gnu` | 1.45 MiB |

The Linux archives are built against glibc 2.17, so they work on anything from
CentOS 7 forward. Each one is stripped of debug info; the whole crate is
6.15 MiB on disk and 2.28 MiB gzipped.

A target with no vendored archive and no `zig` fails at build time with a
message saying which target it was, what it looked for, and the two ways to fix
it. It does not fail at link time with an undefined symbol, and it does not
silently produce a crate that panics on first use.

The ABI version is checked the first time you compile a pattern. A library
speaking a different ABI is `Error::Abi` with both numbers in it, rather than a
struct read against the wrong layout.

To regenerate the vendored set from an engine checkout:

```bash
python3 scripts/vendor_libraries.py
```

## Supported platforms

macOS on arm64 and x86_64, Linux on x86_64 and aarch64. Other targets build if
`zig` is on PATH or you point `IRGX_LIB_DIR` at your own library. Rust 1.85
or newer, edition 2024.

## License

Apache-2.0. The linked library includes PCRE2 and other third-party components;
see NOTICE at the root of the engine repository.
