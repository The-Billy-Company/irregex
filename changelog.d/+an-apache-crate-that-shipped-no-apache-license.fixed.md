The `irgx` crate declared Apache-2.0 and carried none of it. The license text and
the NOTICE live at the repository root, and a `.crate` tarball cannot reach above
its own directory, so the crate shipped an SPDX string and nothing else. Section 4
of that license asks a redistributor for exactly those two files - and this NOTICE
is also where what the vendored archives are built from is credited, so the crate
that ships those archives was the worst place in the repository to be missing it.
The wheel was already correct; only the crate was not.

`LICENSE` and `NOTICE` are now committed beside `bindings/rust/Cargo.toml`,
byte-identical to the root pair.

`rust-toolchain.toml` stops shipping in the crate on the same pass. It pins 1.96.0
so this repository's contributors lint identically - no business of anyone building
the extracted crate, and it would have quietly overridden the 1.85 `rust-version`
the sources actually ask for.
