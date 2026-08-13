# The Header Parse Gate

`include/irgx.h` is written by hand, and until this existed the only compiler
that ever read it here was Zig's own clang, through cgo, at whatever default the
toolchain picked.

So the standards the header claims to speak were never asked of it. A `_Static_assert`,
an anonymous union, a trailing comma in an enum, a `bool` without `stdbool.h` —
each compiles under that default, and each is a host's build breaking on a file we
published.

Two probes ask. `parse.c` compiles the header as C99 with `-pedantic-errors`,
because a warning is a thing nobody reads. `parse.cpp` compiles it as C++17,
because a C++ host is the ordinary case for this ABI and it is the case a C-only
probe cannot speak for.

The C++ probe also proves the `extern "C"` guard holds. It takes the address of
one entry per plane into a typed function pointer, and a mangled declaration is a
different symbol with a different type.

Both are compiled to objects and thrown away. Nothing links, because the question
is whether the text parses and whether every struct is a complete type — which is
what a host needs and what reading declarations as text can never see.

Run it the way CI does, on both operating systems.

```bash
zig build header
```

The probes have to *use* the types rather than name them. An incomplete struct is
only a fault at the point somebody needs its size, and that point is the host.

When it fails, the fix is the header. Loosening a flag here would mean publishing
a header that parses on this machine and nowhere else.
