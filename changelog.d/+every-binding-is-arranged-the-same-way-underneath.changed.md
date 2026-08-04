Three bindings, one C ABI, and until now three arrangements that happened to
agree without anything saying they should. `bindings/README.md` is that
something: a concern map across Zig's FFI plane, Rust, Go and Python, plus the
reasons the three decompositions are deliberately not identical.

The rule the map is built on is that the regex face **is** the binding's root.
Somebody who wants a regex over a buffer is the larger audience by a wide margin,
so they get `irgx.finditer`, `irgx::Regex::new`, `irgx.MustCompile` and pay for
nothing; the analytic substrate a sibling product binding wants lives in named
packages beside it (`contract/`, `request`, `runtime/`). Rust already said this
in the language - private `mod`s for the regex face, `pub mod` reserved for the
substrate - and Go said it by keeping the face at the package root. A Python
`irgx.regex.pattern` was briefly a real import path here, and it was a level of
nesting with no counterpart in the other two, so it is gone.

Two things moved to finish the map. Python grew `_pool.py`, which is where a
`Compiled` handle and the per-thread pool over it now live together; the handle
had been sitting in the ABI module and the pool inline in `Pattern`, which meant
the one genuinely hard invariant in the binding - *a C handle belongs to one
thread, and it owns the scratch its finds run in* - was the only concern with no
file to its name, in the one binding where that is true. Rust's `pool.rs` has
carried it since the crate existed. Python's `_template.py` is `_replace.py` for
the same reason: `replace.rs` and `replace.go` are named for what a caller asks
for, and it was the last file named for the artifact instead. In Go,
`irregex.go` is `pattern.go` - the package is `irgx`, the file was named after
the repository, and the concern is the one every other surface spells
`pattern`.

What the map does *not* do is force one spelling everywhere. The file that
projects a span into something a caller can slice is `matches.rs` in Rust,
`find.go` in Go and `_match.py` in Python, because that is what the `regex`
crate, the `regexp` package and `re` each call it, and a binding is worth having
because it reads like the library its caller already knows. Nor does it force one
file count: Rust splits its seam from its refusal vocabulary because it *links*
the engine and its seam has no failure to report, where Python *loads* one and a
wrong `IRGX_LIB` is a refusal the seam itself raises. Splitting those two in
Python would be a cycle rather than a ladder. Each fusion in the table is a
language forcing it, and each one now says so out loud instead of reading like
somebody's oversight.

No behavior changed, and no public name in any of the three bindings moved.
