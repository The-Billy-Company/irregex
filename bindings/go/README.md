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
"cgo is required" below.

## Why you might want it

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
- **The same answers as the engine's other bindings.** If you also use the
  Python binding or the command line tools, this package reports the same spans
  for the same pattern over the same bytes.

If none of that is worth a cgo dependency, `regexp` is a fine answer and you
should use it.

## A short tour

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

The six options are `Fixed`, `IgnoreCase`, `Word`, `SmartCase`, `ASCII` and
`PCRE`. The zero value is what plain `Compile` uses, so `CompileOpts{}.Compile`
and `Compile` are the same call.

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

## How it differs from `regexp`

**Zero-width matches.** The engine suppresses an empty match at the end of the
text, and one that starts where the previous match ended. So a nullable pattern
reports fewer spans here:

```go
irgx.MustCompile(`a*`).FindAllStringIndex("abc", -1) // [[0 1] [2 2]]
regexp.MustCompile(`a*`).FindAllStringIndex("abc", -1)  // [[0 1] [2 2] [3 3]]
```

Neither is wrong; they are different conventions. This one is the engine's, and
it is the same one you get from the engine's other bindings and its command line
tools.

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

## cgo is required

There is no pure-Go implementation behind this package, so `CGO_ENABLED=0`
cannot produce a working build. It fails at compile time with a message that
says so, rather than building a package whose every call panics:

```
./nocgo.go:11:11: undefined: irregex_requires_cgo_build_with_CGO_ENABLED_1
```

If you need a regex engine in a cgo-free build, that is what `regexp` is for.

## Platforms

One static archive is vendored per platform, selected by the build constraint on
the `link_*.go` file that names it:

| Platform | Archive | Size |
|---|---|---|
| darwin/arm64 | `libirgx_darwin_arm64.a` | 1.3 MB |
| darwin/amd64 | `libirgx_darwin_amd64.a` | 1.4 MB |
| linux/amd64 | `libirgx_linux_amd64.a` | 1.8 MB |
| linux/arm64 | `libirgx_linux_arm64.a` | 1.5 MB |

That is about 6 MB of module, 2.3 MB of it over the wire, of which your binary
links one archive. The Linux archives are built against glibc 2.17 and the macOS
ones against the macOS 11 SDK, so they work on anything newer.

The archives sit beside the Go source rather than in a subdirectory, because
`go mod vendor` copies a package's own files and skips a subdirectory that holds
no Go package. Kept one level down they would be dropped from a vendored
consumer, and the build would fail at the linker.

Building for a platform not in that table fails at compile time with a named
error rather than a linker error about a missing symbol.

### Linking your own build

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

### Regenerating the vendored set

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
