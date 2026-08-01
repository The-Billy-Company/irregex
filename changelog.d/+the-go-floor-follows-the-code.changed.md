Lowered the Go module floor from `go 1.26.3` to `go 1.24`. The split had raised it three releases — to a patch level, no less — for one piece of test sugar: `new(0.6)`, the Go 1.26 spelling of "address of a literal", used only to fill optional `*float64` knobs in tests. No production file needed anything past 1.24, so every consumer of a package we publish was locked out of `go get` by a convenience in a `_test.go` file.

A four-line `ptr[T any]` helper replaces the sugar. 1.24 is the real floor: the suites use `t.Context()`.
