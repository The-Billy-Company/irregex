The Go vendoring matrix declares `-lm` on both Linux targets, so its link probe
links the way a consumer's cgo build links.

The two sides had drifted: `link_linux_amd64.go` and its arm64 twin carry
`-lm`, while the matrix declared no library there, and the parity check added with
the Windows targets refused to vendor a Linux archive until the two agreed. The
archive really does need it - `exp` and `log` come out of the cost model
undefined, and libm only merges into libc in glibc 2.34, well past the 2.17 these
targets pin. What hid it is the same thing that hid `-lntdll`: `zig cc` links
libm silently, so a probe that leaves it out closes anyway and proves nothing
about the gcc that will actually perform the link.

Reconciled toward the link file rather than away from it, because the link file is
the one a consumer runs.
