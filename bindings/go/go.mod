// A standalone Go module, deliberately outside any parent workspace: importing
// the regex engine must not drag a Zig build into a consumer's module graph.
//
// `go get` followed by `go build` needs no Zig toolchain and no separate
// binary. The module carries one prebuilt static archive per supported
// platform, beside the source so that `go mod vendor` keeps them, and a cgo
// build constraint links the matching one. cgo itself is required - there is no
// pure-Go engine here to fall back to, and the module says so at compile time
// rather than at run time.
module github.com/The-Billy-Company/irregex/bindings/go

go 1.24

toolchain go1.26.5
