# irregex - a linear-time regex engine for Rust

A regex engine for Rust that matches in linear time, with the engine shipped
inside the crate. No catastrophic backtracking, so no ReDoS.

```bash
cargo add irgx
```

The crate is [`irgx`](https://crates.io/crates/irgx) and you `use irgx::`. The
project is called irregex, but `irregex` on crates.io is an unrelated 2023 crate
and names there are permanent, so it was never available to us. That turned out
well: `irgx` is already the C symbol prefix, the header, and the Python import,
so the Rust name now agrees with every other surface.

That is the whole install on the common desktop and server targets - macOS,
Linux, and Windows, on both x86_64 and arm64. There is no Zig toolchain to
fetch, no C compiler step, and no separate binary to put on your PATH. The
engine is written in Zig; the crate carries a prebuilt static archive per target
and `build.rs` picks the right one and links it in.

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

```text
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
re.find_at(text, 4);            // start late without slicing (see below)
re.is_match_at(text, 4);
```

`find_at` and `is_match_at` start the search at a byte offset **without moving
the haystack's edges**, which is the whole reason they exist: `^`, `\b` and every
lookaround still read the text from the beginning. Slicing to the same offset is
a different question, and a wrong one — `^b` does not match `"abc"` from 1, but
it does match the slice `"bc"`. The offset must be a character boundary; the
`try_` siblings return `Error::NotCharBoundary` instead of panicking.

A `Match` has `start()`, `end()`, `range()`, `as_str()`, `as_bytes()`, `len()`
and `is_empty()`. A `Captures` has `get(n)`, `name("n")`, `iter()`, `len()`,
`expand()`, and `Index` by number and by name. A replacement can be a `&str`
template with `$1` and `${name}` references, a `NoExpand` for text you did not
write, or a `FnMut(&Captures) -> impl AsRef<str>`.

Every verb that can panic has a `try_` sibling that returns
`Result<_, irgx::Error>` instead: `try_is_match`, `try_find`, `try_find_iter`,
`try_captures`, `try_captures_iter`, `try_replacen`, `try_find_at`,
`try_is_match_at`. The panicking forms exist so
`re.find(text)` returns an `Option` and reads like the crate you already know;
the checked forms exist so a caller who cannot take a panic never has to.

## Many patterns at once: `RegexSet`

```rust
use irgx::RegexSet;

let set = RegexSet::new([r"^\w+@\w+$", r"^\d{3}-\d{4}$", r"^https?://"])?;

set.is_match("bob@host");                              // true
set.matches("555-1234").iter().collect::<Vec<_>>();    // [1]
```

Same shape as `regex`'s `RegexSet`, and same reason for it: N compiled patterns
asked separately read the text N times, and one fused `a|b|c` reads it once and
throws away which pattern hit. `SetMatches` carries `matched_any()`,
`matched(i)`, `len()` (the size of the set, as in `regex`, not the number of
hits), and `iter()`. `RegexSetBuilder` takes the same flags `RegexBuilder` does,
minus the two the engine's slate cannot carry (`multi_line` and
`dot_matches_new_line`); `smart_case` is resolved per pattern, so one set can
hold a case-folding pattern and a case-sensitive one.

What is underneath is not an alternation. The engine pools every pattern's
required literals into a SIMD sieve, so a text nothing in the set can match is
usually rejected before any automaton runs, and a pattern whose literals
*decide* it is answered by the sieve alone. Past ~18 pooled literals it hands off
to one Aho-Corasick automaton so the per-byte cost stops growing with N.

A set reports presence, not position — there is no per-pattern span verb, exactly
as there is none in `regex`. Once you know pattern 7 matched, `Regex::find` on
pattern 7 is the search you were going to run anyway, against a text now known to
be worth searching.

Admission is all or nothing: the first pattern the engine will not take refuses
the whole set, and the error names *that pattern* rather than saying one of them
failed.

## Flags

`RegexBuilder` carries six, and each one changes an answer:

- **`fixed`** treats the pattern as a literal string, so there are no metacharacters and no pattern can be a syntax error.
- **`ignore_case`** folds case, including outside ASCII.
- **`word`** only reports a match that stands alone as a word.
- **`smart_case`** folds case only if the pattern itself has no uppercase in it.
- **`unicode`** turns on Unicode classes, folding and boundaries, and is on by default.
- **`pcre`** switches to the PCRE2 grammar for lookaround and backreferences, which is not linear time.

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

```text
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

**No `Regex::shortest_match` or byte-slice `Regex`.** The C ABI has no anchored
verb, and faking one on top of an unanchored scan is exactly where a binding
goes subtly wrong. Anchors are in the grammar: use `\A` and `\z`. Note the
spelling of the end anchor; it is `\z`, as in `regex` and RE2, not `\Z`.
`RegexSet::matches_at` is absent for the same reason - the bounded search the
single-pattern `find_at` rides on has no slate counterpart yet.

**`find_iter` is eager.** The engine reports the whole match sequence in one
call, and that call is the authority on what a sequence *is*, so the crate asks
once instead of advancing a cursor. In exchange the iterator knows its own
length and runs backwards:

```rust
let found = re.find_iter(text);
println!("{}", found.len());
for m in re.find_iter(text).rev() { /* ... */ }
```

**Zero-width matches are the `regex` crate's sequence.** `a*` over `"abc"` is
`[(0, 1), (2, 2), (3, 3)]` in both: the empty match at 1 is skipped because it
abuts the `a` that ended there, the one at the end of the text is reported, and
after an empty match the scan resumes at the next character, so no empty match
is ever reported inside a multi-byte one.

Which matches a nullable pattern yields is a convention rather than a fact, and
every ecosystem picked a different one - Python's `re` shows the empty match at
1, grep tools show fewer than either. The C ABI reports the widest sequence and
each binding thins it to its own language's convention, so this crate shows
Rust's. `tests/sequence.rs` runs both crates over the same inputs and asserts
they agree, rather than freezing a table that could quietly stop being true.

**A newline is ordinary whitespace.** The text is one buffer, not a sequence of
lines, so `\s` matches a newline and a match may span one:

```rust
Regex::new(r"\s")?.find("a\nb");      // the newline, at byte 1
Regex::new(r"a\sb")?.find("a\nb");    // the whole thing, newline included
Regex::new(".")?.find_iter("a\nb");   // (0,1) and (2,3) - `.` still stops
```

**`^` and `$` are text anchors, and `multi_line` makes them line anchors.** Off
by default, exactly as `regex`'s `multi_line` is. That is a separate question
from the buffer above: the text is one buffer under either setting, and this
only moves the two anchors.

```rust
RegexBuilder::new("^..").multi_line(true).build()?
    .find_iter("ab\ncd");                               // (0,2) and (3,5)
RegexBuilder::new(".").dot_matches_new_line(true).build()?;
```

The builder is the portable way to ask. Inline `(?m)` and `(?s)` are PCRE2
grammar here - the linear engine returns `Error::NeedsPcre` rather than
accepting them and ignoring them, so a pattern written for another engine fails
loudly instead of quietly matching the wrong thing. That is the retryable
variant, and the two-line retry above handles it; reaching for it also opts into
a backtracking engine, which the builder flags do not.

`is_match` is the cheap way to ask, and it agrees with `find` on every input: it
runs the same walk and stops at the first span rather than materializing the
rest.

**`Captures::get` reports `None` for a group that did not participate**, which
is a different fact from a group that matched the empty string. So does the
`regex` crate; the difference is that indexing distinguishes the two reasons in
its panic message here.

## Install and linking

`build.rs` resolves the native library in this order, and the first rung that
answers wins:

1. **`IRGX_LIB_DIR`** - a directory holding your own `libirgx.a`,
   `libirgx.{dylib,so}`, or, on Windows, `irgx.lib` beside the DLL. This is the
   override, and it is absolute: if it is set and does not hold a library, the
   build fails rather than falling through to something you did not ask for.
2. **A vendored static archive** for the target triple, from `vendor/` in this
   crate. This is the path almost everyone takes, and it needs nothing installed.
3. **An existing `zig-out/lib/`** in an engine checkout beside the crate, when
   you are building for the host.
4. **`zig build`** in that checkout, when `zig` is on PATH.

Vendored targets, and the size of the archive each one links:

- **`aarch64-apple-darwin`** — 2.06 MiB.
- **`x86_64-apple-darwin`** — 2.22 MiB.
- **`x86_64-unknown-linux-gnu`** — 2.80 MiB.
- **`aarch64-unknown-linux-gnu`** — 2.30 MiB.
- **`x86_64-pc-windows-gnu`** — 2.83 MiB, and it also serves
  `x86_64-pc-windows-gnullvm`, which is the same ABI under a second name.
- **`aarch64-pc-windows-gnullvm`** — 2.47 MiB. Rust has no
  `aarch64-pc-windows-gnu`; mingw-w64's gcc was never ported to arm64, so
  llvm-mingw is the GNU-ABI arm64 Windows toolchain and `-gnullvm` is its
  triple.

The Linux archives are built against glibc 2.17, so they work on anything from
CentOS 7 forward, and the Windows ones against Windows 10 RS4. Each is stripped
of debug info; the whole crate is 15.3 MiB unpacked and 5.3 MiB as the gzipped
package `cargo package` produces, against crates.io's 10 MiB ceiling.

**MSVC is the one Windows ABI with no vendored archive.** Zig cross-compiles
every target above from a single host, but the MSVC C runtime headers are not
redistributable, so an MSVC archive can only be produced on a machine that has
Visual Studio - which is exactly the machine that can build it from source
anyway. `build.rs` knows the MSVC triples, so on Windows with `zig` on PATH a
`cargo build` for the default toolchain builds the engine and links it; without
Zig it fails with a message saying so and naming `-pc-windows-gnu` as the
vendored alternative.

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

macOS on arm64 and x86_64, Linux on x86_64 and aarch64, and Windows on x86_64
and arm64 under the GNU ABI. Every one of them links a vendored archive and is
tested on its own hardware in CI. Other targets - MSVC among them - build if
`zig` is on PATH or you point `IRGX_LIB_DIR` at your own library. Rust 1.85
or newer, edition 2024.

## License

Apache-2.0. The linked library includes PCRE2 and other third-party components;
see NOTICE at the root of the engine repository.
