The Python binding has an import contract: `bindings/python/binding.zone`,
governing `irgx` the way `charter.zone` governs the Zig side.

It is the floor all three product faces import, so its layering is the
one that propagates - the generated contract surface at the bottom, the runtime
and request model above it, tests on top. The one cycle in it is declared rather
than tolerated: `request` is decoded by `runtime/decode`, and `decode` reaches
back for the calibrated enum types through a cached deferred import, so a
decoded grade is comparable instead of a bare string and the load-time graph
still has no loop.

Needs `zoning` 1.3.1, which is where the `python` dialect and root-anchored
contracts both arrive.
