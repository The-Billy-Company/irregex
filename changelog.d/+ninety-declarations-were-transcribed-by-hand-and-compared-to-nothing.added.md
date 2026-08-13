The parity gate grew two lanes and the build grew a step, all three about the same
thing: a binding can reach every symbol and still call it wrong.

Rust's ninety `extern "C"` declarations are now held to the shapes `include/irgx.h`
publishes — parameter count, levels of indirection on each, and the width of every
scalar. Not names, which are documentation, and not an opaque handle's pointee,
which each host is entitled to spell in its own types.

Rust was the only binding that needed it, and it is also the binding where the
mistake is worst. Go hands the header to a C compiler through cgo, so a compiler
judges its signatures on every build, and Python's suite parses the same header and
audits all hundred `ctypes` prototypes against it. Rust transcribes by hand and
links a vendored archive statically, which turns a wrong parameter into a call
through a signature the engine never agreed to rather than a link error.

The lane found no drift, and the lesson it is built on came from Python: an unset
`restype` truncates a `size_t` to an `int` on every 64-bit host, and no test over a
corpus smaller than two gigabytes can see it.

The second lane holds `bindings/go/irgx.h` to the header this package installs. cgo
compiles that copy, not the published one — build output under version control,
exactly like the archives beside it, with none of the checks they got. A copy
missing a declaration fails loud at the compiler. A copy whose struct grew a field
in the engine and not here links fine and reads the wrong bytes, which is the exact
hazard the header's own "gate on the ABI integer, never on a struct size" note is
about. Declarations are compared and comments are not: the copy is deliberately
scrubbed of the sibling libraries' names, and nobody links against a paragraph.

`zig build header` is the third. The header claims to be C99 and to be safe for a
C++ host, and the only compiler that had ever read it here was Zig's own clang at
whatever default the toolchain picked. Two probes now ask: C99 with
`-pedantic-errors`, because a warning is a thing nobody reads, and C++17, which also
proves the `extern "C"` guard holds by taking the address of one entry per plane
into a typed function pointer. Both compile to objects that are thrown away, and
both use the types rather than naming them — an incomplete struct is only a fault at
the point somebody needs its size, and that point is the host.

CI runs the step on Linux and macOS, beside the suite.
