`libirgx` would not compile for any `-msvc` Windows target in zig 0.16.0,
static or dynamic, whether or not a caller ever panicked. `std.Io.Threaded`'s
vtable makes every method reachable the moment one instance exists, and its
`netWriteFile` is `@panic("TODO implement netWriteFile")`-stubbed on every
backend - so the mere presence of that vtable pulled the default panic
handler's stack walk into the build. On the MSVC ABI that walk runs through
`SelfInfo.Windows.zig`'s `loadNtdllProc`, which casts a `*anyopaque` to a
function pointer without the `@alignCast` Zig itself now demands: a bug in the
standard library, not in this engine, and one that blocks every `-msvc`
target's static or object artifact regardless of whether the panic path is
ever exercised at runtime.

The artifact's root now declares its own panic namespace, `std.debug.
simple_panic`, for `.msvc` only - message to stderr, then trap, no stack walk,
no `SelfInfo`. Every other ABI keeps the default, fully symbolicated panic
handler unchanged.
