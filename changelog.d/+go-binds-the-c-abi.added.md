`bindings/go/` is a Go binding now: cgo over a static archive vendored in the
module, so `go get github.com/The-Billy-Company/irregex/bindings/go` followed by
`go build` gives a working regex library on a machine with no Zig toolchain and
nothing to install alongside it. Go has no `build.rs`, so there is no install-time
hook to compile into; the module carries one archive per platform - darwin arm64
and amd64, linux amd64 and arm64, about 6 MB in total - and the build constraint
on a `link_*.go` file is what picks the matching one. The archives sit beside
the Go source rather than a directory down, because `go mod vendor` copies a
package's own files and skips a subdirectory holding no Go package; kept one
level down, every vendored consumer would fail at the linker. All four come off
one machine, cross-compiled by Zig against a glibc 2.17 and macOS 11 floor, and
each one is proved to link before it is committed. `irgx_abi_version()` is checked
at package init, so a library supplied through the `irgx_syslib` escape hatch
that disagrees says so instead of mis-reading a struct.

The surface is stdlib `regexp`'s, because that is the API a Go programmer
already has in their fingers: `Compile` / `MustCompile`, the `Find` family with
its `All`, `String`, `Index` and `Submatch` variants on both the `string` and
`[]byte` side, `Split`, the `ReplaceAll` family, `Expand`, `SubexpNames` /
`SubexpIndex`. The engine's flags have no `regexp` spelling, so they live in a
`CompileOpts` struct with its own `Compile` and `MustCompile`; a struct rather
than functional options because the C ABI closes the flag set, leaving nothing
for an option function to extend. There is no `MatchReader` family and no
`Longest`: the engine searches a buffer you already hold, and inventing either
would be a semantic the library does not hold.

Three properties are the whole reason this is a binding rather than a wrapper.
Iteration is `irgx_find_all`, never a Go advance loop over `captures`, so the
empty-match, adjacency and `-w` rules a nullable pattern depends on are the
engine's; group detail is filled in afterwards by `captures(from: span.start)`
per span the engine already blessed, and the two are checked against each other.
Offsets need no translation at all, unlike the Python binding's: Go strings are
UTF-8 and indexed by byte exactly as the engine's spans are, so an index this
package returns slices the caller's own string, `café` and all. And a `*Regexp`
is safe for concurrent use, as `regexp.Regexp` is and as every package-level
`var re = MustCompile(...)` assumes, even though the C handle owns the scratch
its finds run in and cannot be shared - goroutines are not threads, so there is
no thread-local to hide one in, and a `sync.Pool` lends a handle out per call
instead, with a finalizer to free what the pool drops.

Writing it turned up two faults in the ABI, both fixed in the engine before this
shipped. `irgx_compile` used to refuse a NULL pattern of length zero even
though the empty pattern compiles fine, which a language whose empty string
carries no data pointer trips over without meaning anything by it. And
`irgx_is_match` used to answer a different question from `irgx_find_all`,
splitting the buffer into lines, so `c$` over `"abc\n"` was a match to one and
not the other. The nine-pattern by six-text anchor grid that found it is now a
test here, checking that `MatchString` and `FindStringIndex` agree on all 54
pairs and that neither reads the buffer as lines, because those two verbs
drifting apart would split this package's answers down the middle.
