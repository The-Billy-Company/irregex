`bindings/rust/build.rs` now watches the library file it links, so `cargo test`
after a `zig build` tests the engine you just built.

Every rung emitted `rerun-if-changed` for its *directory*, or for nothing at all in
the `IRGX_LIB_DIR` case. A directory's mtime does not move when a library inside it
is overwritten in place, which is exactly what rebuilding the engine does - so cargo
saw no reason to re-link, ran the tests against the previous archive, and reported
the result as the new one's.

It cost real time before it was found. A negated class and a dotall `.` were both
failing to match a newline in Rust while the Zig kernel demonstrably handled them,
which reads as an FFI bug and was investigated as one. There was no FFI bug; there
were two engines.

Worth stating plainly because of which rung it was missing from: `IRGX_LIB_DIR`'s
whole purpose is linking an engine you just rebuilt. The watch lives in the shared
`link` helper now rather than at each rung, so no rung can be the one that forgets,
and it names the library as a **file** - `libirgx.a`, `libirgx.dylib`, `libirgx.so`,
`irgx.lib`, `irgx.dll` - since that is the mtime that actually moves.
