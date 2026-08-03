The Rust install instructions named a package nobody can install. Both the
binding README and the root README's Install section still said `irregex =
"0.1"` and "a path or git dependency" - the former is an unrelated 2023 crate
and the latter had not been true since the crate went to crates.io as
[`irgx`](https://crates.io/crates/irgx) 1.0.0. Copying either got you a
resolution error at best and a stranger's code at worst.

Both now say `cargo add irgx`, and the Install section explains once why the
name differs per registry rather than leaving three spellings unaccounted for:
PyPI keeps `irregex` because it was free, crates.io takes `irgx` because it was
not, and the import is `irgx` either way.
