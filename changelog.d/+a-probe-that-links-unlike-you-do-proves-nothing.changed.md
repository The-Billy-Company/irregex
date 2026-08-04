Both vendoring scripts link a probe program against each fresh archive before
committing it, so a missing symbol is their failure rather than somebody's
`go build` a week later. The catch is that nobody ever performs that link. A Go
consumer's link is driven by the `#cgo LDFLAGS` line in
`link_<goos>_<goarch>.go`; a Rust consumer's is driven by what `build.rs`
emits. If either disagrees with what the probe used, the proof is evidence about
a build that does not happen.

That was harmless while every archive closed against libc alone. Windows ends
it: those archives need `-lntdll`, and it is now the kind of thing a matrix can
declare and a link file can quietly not.

So each script checks the other side of the link before compiling anything.
Go's reads every target's `link_*.go` and holds its `#cgo LDFLAGS` to the
libraries the matrix declares - and holds `link_unsupported.go`'s build
constraint to excluding every target the matrix now serves, which is the failure
where you add a platform, forget the constraint, and both files compile at once
and die on an undefined constant in the consumer's build. Rust's checks that
every library a target declares is one `build.rs` actually emits. Both run off a
file read, before the first byte is compiled, because the alternative costs
several minutes per target to learn the same thing.

Two smaller things fell out. Both scripts decided whether to *run* the probe
rather than only link it by asking `os.uname()`, which does not exist on
Windows, so somebody vendoring from a Windows machine got a cross-compile note
for their own platform. That is `platform.machine()` now, and each target names
the machines it is native to. And the Python wheel matrix pins Windows 10 RS4 in
its triple like every other target pins its floor, rather than inheriting
whatever Zig defaults to.
