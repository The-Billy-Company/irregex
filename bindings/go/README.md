# irregex

A regex engine for Go that matches in linear time, shipped as an ordinary Go
module with the engine inside it.

```bash
go get github.com/The-Billy-Company/irregex/bindings/go
```

That is the whole install. There is no compiler step, no Zig toolchain, and no
separate binary to put on your PATH. The engine is written in Zig and ships as a
prebuilt static archive inside the module; a cgo build constraint picks the one
for your platform and links it into your program.

You do need cgo, which means a C compiler. `CGO_ENABLED=0` will not build; see
"The cgo Requirement" below.

## Reasons to Use It

`regexp` is already linear time, so that is not the reason. These are:

- **The flags `regexp` has no spelling for.** `Fixed` for a literal pattern,
  `Word` for standalone matches only, `SmartCase` for fold-unless-you-typed-a-
  capital. Each one is applied by the engine during the search rather than
  filtered afterwards, so they compose with everything else.
- **PCRE2 when you actually need it.** Lookaround and backreferences are not in
  the linear grammar; `CompileOpts{PCRE: true}` switches to a vendored PCRE2 and
  you get its features and its performance profile. `regexp` simply does not
  have them. You do not have to know up front which grammar a pattern wants
  either: a declined compile says so with `ErrNeedsPCRE`, and you retry.
- **`Set`, for many patterns over one text.** Which of N patterns match, in one
  pass, keeping which one it was. `regexp` has no type for this, so the
  alternative is a loop that reads the text N times or an alternation that
  throws the attribution away.
- **The same answers as the engine's other bindings.** If you also use the
  Python binding or the command line tools, this package reports the same spans
  for the same pattern over the same bytes.

If none of that is worth a cgo dependency, `regexp` is a fine answer and you
should use it.

## A Short Tour

```go
import irgx "github.com/The-Billy-Company/irregex/bindings/go"

var mailbox = irgx.MustCompile(`(?P<user>\w+)@(\w+)`)

func main() {
	const text = "write to bob@host, cc eve@box"

	mailbox.MatchString(text)                      // true
	mailbox.FindString(text)                       // "bob@host"
	mailbox.FindStringIndex(text)                  // [9 17]
	mailbox.FindAllString(text, -1)                // ["bob@host" "eve@box"]
	mailbox.FindStringSubmatch(text)               // ["bob@host" "bob" "host"]
	mailbox.SubexpIndex("user")                    // 1
	mailbox.ReplaceAllString(text, "${user}")      // "write to bob, cc eve"
	irgx.MustCompile(`,\s*`).Split(text, -1)    // ["write to bob@host" "cc eve@box"]
}
```

The names and shapes are the standard library's on purpose. `Compile`,
`MustCompile`, the `Find`/`FindString` family with its `All`, `Index` and
`Submatch` variants, `Split`, the `ReplaceAll` family, `Expand`, `SubexpNames`,
`SubexpIndex`, `NumSubexp`, `String`, and the package-level `Match` and
`MatchString`. If you know `regexp`, you know this.

Flags live in a `CompileOpts` struct, which has a `Compile` and a `MustCompile`
of its own:

```go
re := irgx.CompileOpts{IgnoreCase: true, Word: true}.MustCompile("cat")
re.FindAllString("Cat concatenate CAT", -1) // ["Cat" "CAT"]
```

The options are `Fixed`, `IgnoreCase`, `Word`, `SmartCase`, `ASCII`, `PCRE`, and
the two `regexp` spells inline instead of as flags - `MultiLine` for `(?m)` and
`DotAll` for `(?s)`. The zero value is what plain `Compile` uses, so
`CompileOpts{}.Compile` and `Compile` are the same call.

You can also spell them the way `regexp` does, at the head of the pattern:
`Compile("(?is)cat.dog")` reads `i` and `s` as the options they ask for, and
`(?-u)` is the ASCII opt-out. A directive the pattern gives wins over the same
field in `CompileOpts`, because the pattern is the more specific statement -
`CompileOpts{IgnoreCase: true}.Compile("(?-i)cat")` is case-sensitive. Only a
*leading* run is a whole-pattern flag, which is also the only place `regexp`
itself allows one; `(?x)`, `(?U)` and `(?R)` are flags this grammar does not
have and route to `PCRE`.

## Concurrency

A `*Regexp` is safe for concurrent use by multiple goroutines, exactly as
`regexp.Regexp` is. Compile once, put it in a package-level `var`, and call it
from anywhere:

```go
var word = irgx.MustCompile(`\w+`)
```

The C handle underneath is not safe to share; it owns the scratch memory its
searches run in. A `*Regexp` keeps a pool of handles and lends one to a
goroutine for the duration of a call, so the rule is kept for you and never
becomes your problem. The cost is that a burst of concurrency compiles a few
extra copies of the pattern, which are freed when the pool releases them.

## Many Patterns at Once: `Set`

`regexp` has no type for "which of these two hundred patterns match this text",
so you write the loop, and the loop reads the text two hundred times. Or you
write `a|b|c`, which reads it once and then cannot tell you which branch hit.

A `Set` is the third thing - one pass, and attribution:

```go
var kinds = irgx.MustCompileSet(`^func `, `^type `, `^var `, `^const `)

func classify(decl string) []int { return kinds.WhichString(decl) }
```

Two questions. `MatchString` asks whether *any* pattern matches, which is the
cheap one and where a batch workload spends its time: a literal scan can throw
out a hopeless text with no pattern running at all. `WhichString` asks *which*,
as ascending indices into the list you compiled - `Patterns()` names them,
`Len()` bounds them, and `Match`/`Which` take `[]byte` for the same questions.

There is no per-pattern span verb, which is an edge rather than an omission. A
`Set` is a **classifier**: once you know pattern 7 is in this text,
`FindAllIndex` on pattern 7 is the walk you were going to run anyway, over a text
now known to be worth walking.

The unit is the whole text, exactly as it is for a `Regexp`, so a `Set` that
names pattern *i* and a `Regexp` compiled from pattern *i* alone always agree.
That is the property the test suite spends most of its time on, including over
all 255 subsets of a corpus, because a prefilter that over-rejects is precisely
the bug you would not notice.

Two things differ from a plain compile. The flags apply to every pattern, which
is the honest shape for a set that came from a config file - and `MultiLine` and
`DotAll` are refused rather than ignored, because this plane has nowhere to carry
them. That holds however they are spelled: a pattern whose own head says `(?m)`
is refused too, while `(?i)` and `(?-u)` are read per pattern, so one member of a
set can be case-insensitive without the rest of them being. And a refusal names
the pattern: a `*SetError` carrying the index, wrapping
the same `*SyntaxError` or `ErrNeedsPCRE` a lone `Compile` would have given, so

```go
var refused *irgx.SetError
if errors.As(err, &refused) {
	log.Printf("pattern %d (%q): %v", refused.Index, refused.Expr, refused.Err)
}
```

A `*Set` is safe for concurrent use by multiple goroutines, by the same pool the
`Regexp` uses.

## Differences from `regexp`

**Nullable patterns iterate exactly like `regexp`'s.** The engine's own match
sequence is byte-granular - an empty match at every offset a nullable pattern
can produce one - and this package thins it to the standard library's rule
before you ever see it: an empty match abutting the previous one is dropped,
and the scan resumes a rune past an empty match rather than a byte past it.
`a*` over `"abc"` reports the same three spans here as it does from
`regexp.MustCompile`.

**Word classes are Unicode by default; `regexp`'s are ASCII.** `\b`, `\B` and
`\w` treat any Unicode letter as a word character here, so `\b` finds two
boundaries in `"héllo"` where `regexp` finds four, because `regexp` does not
count `é` as a letter. `CompileOpts{ASCII: true}` asks for `regexp`'s alphabet
and gets its exact answer back.

**Invalid UTF-8 is not silently repaired.** `regexp` decodes a byte that begins
no valid rune as U+FFFD and lets `.` consume it, so `.` finds two "characters"
in two junk bytes that encode nothing. A Unicode `.` here matches only
well-formed scalar values, so the same junk leaves behind zero-width positions
instead. `CompileOpts{ASCII: true}` drops to the byte alphabet, where every
byte is a match again.

**Lookaround and backreferences are compile errors, not silent non-matches.**
`Compile("foo(?=bar)")` returns an error that matches `errors.Is(err,
irgx.ErrNeedsPCRE)`, so a caller can retry with `PCRE: true` instead of
guessing. See "Errors" below.

**Anchors do not treat the text as lines.** `^` and `$` mean the start and end
of the whole text you passed, not of each line inside it. If you want per-line
matching, hand the engine one line at a time.

**What is missing.** No `MatchReader`, `FindReaderIndex` or
`FindReaderSubmatchIndex`: the engine searches a buffer you already hold, so
there is nothing to hang a `RuneReader` off. No `Longest`, because the engine
does not expose leftmost-longest as a switch. No `LiteralPrefix`. These are
absent rather than faked; everything else in the tour above is present, on both
the `string` and the `[]byte` side.

**Offsets are byte offsets**, which is not a difference, but it is the thing
most likely to worry you when a binding sits on top of a C library. Go strings
are UTF-8 and indexed by byte, and so are the engine's spans, so an index this
package returns slices your string directly:

```go
const text = "le CAFÉ noir"
loc := irgx.CompileOpts{IgnoreCase: true}.MustCompile("café").FindStringIndex(text)
text[loc[0]:loc[1]] // "CAFÉ"
```

## Errors

A refused pattern is one of two things, and the difference is the whole point:
one of them you can retry, the other you cannot.

**`ErrNeedsPCRE` - the linear grammar declined it.** Lookaround, a
backreference, an atomic group: nothing is wrong with the pattern, the
linear-time engine just has no way to express it. The vendored PCRE2 does, so
the same text compiles with one flag set:

```go
re, err := irgx.Compile(pattern)
if errors.Is(err, irgx.ErrNeedsPCRE) {
	re, err = irgx.CompileOpts{PCRE: true}.Compile(pattern)
}
if err != nil {
	return err
}
```

That is the idiom to reach for whenever the pattern came from outside your
program - a config file, a flag, a user - because you cannot know in advance
which grammar it wants. The engine decides by handing the refused pattern to
PCRE2 itself, so what `ErrNeedsPCRE` covers is whatever PCRE2 can express rather
than a list somebody has to keep current.

**`*SyntaxError` - nothing here accepts it.** An unclosed group, a reversed
class range, a quantifier with nothing to quantify. It carries the byte offset
the engine stopped at, so you can point at it, and `PCRE: true` does not rescue
it:

```go
_, err := irgx.Compile(`[abc`)
// irregex: compile "[abc": BadPattern at byte 4

var bad *irgx.SyntaxError
if errors.As(err, &bad) {
	fmt.Printf("%s\n%*s\n", bad.Expr, bad.At+1, "^")
	// [abc
	//     ^
}
```

`At` is `-1` when the engine reported no position, never a stand-in `0` - byte 0
is a real offset.

The two are decided from the ABI's status code, not from a fault name, so they
can never be confused with each other and neither is matched by comparing
strings. Anything else - an allocation failure, a limit, an unknown flag bit -
stays an `*irgx.Error` carrying the status code, the library's sentence for
it, and whatever detail the engine recorded. A `*SyntaxError` unwraps to one of
those, if you want the status underneath it.

`MustCompile` panics instead of returning any of them, like the standard
library's.

The Find family returns no error, again like the standard library. A search that
fails at the C boundary after the pattern already compiled can only be an
allocation failure, and it panics rather than returning a wrong answer.

## The cgo Requirement

There is no pure-Go implementation behind this package, so `CGO_ENABLED=0`
cannot produce a working build. It fails at compile time with a message that
says so, rather than building a package whose every call panics:

```text
./nocgo.go:11:11: undefined: irregex_requires_cgo_build_with_CGO_ENABLED_1
```

If you need a regex engine in a cgo-free build, that is what `regexp` is for.

## Platforms

One static archive is vendored per platform, selected by the build constraint on
the `link_*.go` file that names it:

- **darwin/arm64** ships `libirgx_darwin_arm64.a`, about 2.2 MB.
- **darwin/amd64** ships `libirgx_darwin_amd64.a`, about 2.3 MB.
- **linux/amd64** ships `libirgx_linux_amd64.a`, about 2.9 MB.
- **linux/arm64** ships `libirgx_linux_arm64.a`, about 2.4 MB.
- **windows/amd64** ships `libirgx_windows_amd64.a`, about 3.0 MB.
- **windows/arm64** ships `libirgx_windows_arm64.a`, about 2.6 MB.

That is about 15 MB of module, of which your binary links one archive. The Linux
archives are built against glibc 2.17, the macOS ones against the macOS 11 SDK,
and the Windows ones against Windows 10 RS4, so they work on anything newer.

Every platform is equally supported: same engine, same answers, one suite, and
CI runs it on each of them rather than cross-compiling and assuming. The
Windows arms link `ntdll` alongside the archive, which is declared in their
`link_*.go` files and is the one thing that differs between platforms.

Building for a platform not in that list fails at compile time with a named
error rather than a linker error about a missing symbol.

### Windows needs a C compiler too

Nothing here is Windows-specific except how easy the compiler is to forget.
cgo needs a C toolchain on every platform, and on macOS and Linux you almost
certainly have one; on Windows you may not. Install
[mingw-w64](https://www.mingw-w64.org/) (MSYS2's `mingw-w64-ucrt-x86_64-gcc` is
the usual route) and make sure `gcc` is on `PATH`.

On **windows/arm64** there is no mingw-w64 gcc, because it was never ported
there. Use [llvm-mingw](https://github.com/mstorsjo/llvm-mingw), or Zig, which
is the same toolchain with less to install:

```bash
set CC=zig cc -target aarch64-windows.win10_rs4-gnu
go build ./...
```

Either mingw flavor links them. Beyond the sixty ntdll symbols and a handful
of kernel32 imports, the archives ask the C runtime for nothing but `malloc`,
`free`, `memcpy`, and the ctype table - names msvcrt and UCRT both export - so
they carry no dependency on which one your gcc was built against.

The archives sit beside the Go source rather than in a subdirectory, because
`go mod vendor` copies a package's own files and skips a subdirectory that holds
no Go package. Kept one level down they would be dropped from a vendored
consumer, and the build would fail at the linker.

### Linking Your Own Build

Set the `irgx_syslib` build tag and point the toolchain at your library:

```bash
IRGX_LIB_DIR=/path/to/your/build \
CGO_CFLAGS="-I$IRGX_LIB_DIR/include" \
CGO_LDFLAGS="-L$IRGX_LIB_DIR/lib" \
go build -tags irgx_syslib ./...
```

cgo expands nothing but `${SRCDIR}` inside a `#cgo` line, so the environment
variable is read by the toolchain rather than by this package; `CGO_CFLAGS` and
`CGO_LDFLAGS` are appended to what the tag declares. Your library is checked
against this binding's ABI version when the package initializes, so a mismatched
one gives you a sentence naming both numbers rather than a corrupted search.

### Regenerating the Vendored Set

```bash
python3 scripts/vendor_libraries.py
```

Run it whenever the engine changes. The archives are committed build output; an
engine change that is not followed by a run of this script ships an engine older
than the repository it came from. See `scripts/README.md`.

## Tests

```bash
go test ./...
go test -race ./...
```

The strongest test is the cross-check in `oracle_test.go`. The engine's Python
binding was written against the same C ABI first and its test suite pins the
match semantics; `testdata/python_oracle.json` is its answer for a shared corpus
of patterns, flags and texts, and the Go binding has to agree with it span for
span. Regenerate it with `python3 scripts/python_oracle.py`.

## License

Apache-2.0, the same as the engine.
