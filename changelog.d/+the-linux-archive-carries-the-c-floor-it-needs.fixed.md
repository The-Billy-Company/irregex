`libirgx.a` was only self-contained on macOS, and by accident. The installed
ELF archive held this package's Zig objects and nothing else, so a consumer who
linked it got undefined `pcre2_compile_8` and friends and had to go find two
more archives the build never installs. Darwin escaped it because `ld64`
rejects the member alignment `zig ar` writes, so that arm already repacked
through `libtool -static` - which archives a partially-linked object, which
pulls the C floor in. The workaround happened to be the fix.

That accident is now the design. Both platforms pack the archive from
`addObject`, and only the archiver differs: `libtool -static` on Darwin for the
alignment, `zig ar` everywhere else, which is the compiler already in hand
rather than one more host tool to have installed. The ELF archive now defines
70 PCRE2 and libsais symbols and references none of them undefined; a C program
built with nothing but `zig cc c.c libirgx.a` links and runs on both platforms,
where the Linux side previously did not link at all.

Three consumers stop routing around it. The Rust `build.rs` had its source
rungs link the shared library and burn an rpath, purely because a static link
could not work on ELF; they link the archive now, like the vendored rung
always did. The Go and Rust vendoring scripts each carried a merge step that
read `libpcre2irregex.a` back out of a Zig build cache by glob and folded it in
with `zig ar -M`; both are gone, and the PCRE2 symbol probe they used to branch
on is now a precondition that fails loudly, because an archive arriving there
without its floor is a regression in the build rather than a platform to
compensate for.

One thing the archive fixed exposed another. `-l static=irgx` does not actually
mean static when the search directory holds `libirgx.a` beside
`libirgx.dylib`: `ld64` takes the dylib, so pointing `IRGX_LIB_DIR` at an
install prefix - the exact shape of `zig-out/lib` - produced a dynamically
linked test binary with no rpath to find its library at run time. The archive
is staged alone into `$OUT_DIR` and searched for there, so the linker has no
choice to get wrong.
