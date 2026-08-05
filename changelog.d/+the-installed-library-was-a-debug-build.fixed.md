`zig build` now installs `libirgx.dylib` / `libirgx.a` at `ReleaseFast`
regardless of the mode the rest of the build runs in, and `-Dlib-optimize`
overrides that on its own.

The default `optimize` mode is `Debug`, which is right for the test binary and
for `zig build check`, and wrong for the artifact a host links. The Python
binding loads the dynamic library, so a plain `zig build` handed it a Debug
engine and nothing said so. Compiling `\w` cost 108 ms there against 2.6 ms in
Go, which links the vendored archive and had therefore been optimized all along -
a 40x gap that looked exactly like an engine problem in the Unicode class
lowering, and was the build mode.

A cache footgun is not a tuning knob. So the ABI artifacts get their own module
tree at the shipped mode, while the module the tests and `check` compile keeps
the caller's - the fast iteration loop stays fast, and what leaves the build is
what a consumer should have.
