# bindings

Three bindings over one C ABI: [Python](python/), [Rust](rust/), and
[Go](go/). Each one is a full port rather than a wrapper - it presents the API
its own language already has for regex, so adopting it is an import change -
and each one is arranged the same way underneath. This file is where that
agreement is written down, because it is the kind of thing that is convention
until somebody states it.

## The regex face is the binding's root

A binding has two audiences. Somebody who wants a regex over a buffer, and a
sibling product binding (`gist`, `relate`, `blast`) that wants the shared
analytic substrate. The first audience is the larger one by far, so it gets the
root and pays for nothing:

```python
import irgx; irgx.finditer(r"\w+", text)          # Python
```

```rust
irgx::Regex::new(r"\w+")?.find_iter(text)         // Rust
```

```go
irgx.MustCompile(`\w+`).FindAllString(s, -1)      // Go
```

No binding has a `regex` namespace inside it. Rust declares its regex modules
as bare private `mod`s and reserves `pub mod` for the substrate; Go keeps the
regex face at the package root and the substrate in `analytic/` and `runtime/`;
Python's regex modules are underscore-private and flat, with `contract/`,
`request.py`, and `runtime/` public beside them. `irgx.regex.pattern` would be
an import path with no counterpart in the other two, bought with a level of
nesting the code does not have.

## One concern map

Down the page is the dependency order, and it is one-way in all three. Across
the page is the same concern in each language, so a fix that lands in one
binding can be found in the others.

| Concern | Zig `src/surface/ffi/` | Rust `src/` | Go `go/` | Python `irgx/` |
|---|---|---|---|---|
| The C seam: types, signatures, ABI gate | `contract.zig`, `exports.zig` | `sys.rs` | `bridge.go` | `_abi.py` |
| Refusal vocabulary: a status becomes a typed error | `contract.zig` | `error.rs` | `errors.go` | `_abi.py` |
| Handle lifetime, and sharing one that cannot be shared | (the host's) | `pool.rs` | `pattern.go` | `_pool.py` |
| The compiled pattern, its flags, and the search verbs | `pattern.zig` | `pattern.rs` | `pattern.go` | `_pattern.py` |
| Match projection into the caller's coordinates | (the host's) | `matches.rs` | `find.go` | `_match.py` |
| Replacement parsing and rendering | (the host's) | `replace.rs` | `replace.go` | `_replace.py` |
| The public face | `include/irgx.h` | `lib.rs` | `pattern.go` doc | `__init__.py` |
| Substrate: mirrored contracts + generated schema | `schema.gen.zig` | `contract/` | `analytic/` | `contract/` |
| Substrate: the shared `SearchRequest` | - | `request.rs` | `analytic/request.go` | `request.py` |
| Substrate: rows, answers, transports | `rows.zig`, `answer.zig`, `corpus.zig` | `runtime/` | `runtime/` | `runtime/` |

## Where the map is deliberately not identical

**A name follows the language's own incumbent, not the other bindings.** The
concern that projects a span into something a caller can slice is `matches.rs`
in Rust because the `regex` crate calls the iterator `Matches`, `find.go` in Go
because the stdlib calls the family `Find*`, and `_match.py` in Python because
`re` calls the object a `Match`. Forcing one spelling on all three would buy an
internal symmetry nobody imports at the cost of the thing every caller reads.

**A binding decomposes as far as its language forces, and no further.** The map
is a claim about seams, not about file counts:

- Rust splits `sys` from `error` because it *links* the engine, so its seam has
  no failure path to report. Python *loads* the engine, and a wrong `IRGX_LIB`
  is a refusal the seam itself has to raise, so splitting the two would be a
  cycle rather than a ladder; `_abi.py` is both.
- Rust's `pool.rs` is its own module and 100-odd lines, because leasing a
  `!Sync` handle out of a mutex and justifying the `unsafe impl Send` is that
  much code. Go's pooling is a `sync.Pool` field and two methods, so it sits in
  `pattern.go` rather than becoming a file that would say nothing the stdlib
  does not already say.
- Go's `bridge.go` holds every cgo call site as well as the type declarations,
  because a cgo call cannot be made from a file that does not carry the
  preamble and the build tag. Rust reaches `sys` from `pattern.rs` freely.

Each of those is a language forcing a fusion. None of them is a concern going
missing - a fused file names both seams in its own header comment, and the tests
reach for them by name. The per-binding layout notes are
[`python/irgx/README.md`](python/irgx/README.md) and
[`rust/src/README.md`](rust/src/README.md); the Go package documents its layers
in the file comments and this table, since its own README is written for a
caller rather than a contributor.

## The one rule that outranks all of the above

**The match sequence comes from `irgx_find_all`, never from a loop over
`irgx_captures`.** The engine decides what a sequence of matches *is* - whether
an empty match adjacent to the previous one counts, what happens at the end of
the buffer, how word-boundary filtering interacts with resuming - and none of
that is derivable from a `find(from)` cursor. Every binding asks `find_all`
once for the authoritative spans and only then, per match and only when the
pattern declares groups, asks `captures` for the detail. The visible
consequence, in all three, is that iteration is eager; the sequence is one
answer.
