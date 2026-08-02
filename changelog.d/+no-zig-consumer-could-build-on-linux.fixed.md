No Zig package could depend on this one on Linux. `dep.artifact("irgx")`
panicked the build runner before it compiled anything:

```text
thread 2452 panic: artifact name 'irgx' is ambiguous
```

Both libraries were installed as artifacts under the same name - the dynamic one
the Python binding dlopens, and the static one Go cgo and a Rust `build.rs`
link - and `installArtifact` is what publishes a name into the table a
dependent's lookup searches. Two rows, one name, no way to answer.

It failed only in the DEPENDENT and never here, so `zig build` in this
repository was green throughout. And only on the branch macOS does not take: the
macOS arm installs `libirgx.a` as a file already, for an unrelated ld64
alignment reason, so a laptop never saw it. Both arms now install the archive
the same way, leaving exactly one artifact answering to the name.
