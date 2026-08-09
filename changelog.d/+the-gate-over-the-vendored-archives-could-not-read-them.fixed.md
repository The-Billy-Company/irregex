The parity gate reads all twelve committed engine archives now, and reads them on
the platform everyone here develops on. It was doing neither, and it reported
confidently either way.

Three faults stacked. `SHIPPED` matched `\birgx_\w+`, but Mach-O spells every
global symbol `_irgx_foo`, and `_` is a word character - so `\b` cannot match
between it and the `i`, and the pattern read NOTHING out of a darwin symbol table.
It still returned 98 of 100 by finding those names elsewhere in the file's bytes,
which is worse than finding none: a plausible number that named two present,
global, exported symbols as absent. The two it missed were the two the linker had
ICF-folded onto a shared address, so they carried no second spelling to be found
by accident.

Second, archives were keyed by filename. Go names its six for their platforms, so
that worked by luck. Rust puts six identically-named `libirgx.a` under
`vendor/<target>/`, and the key collapsed all six into one entry - five archives
unread and reported current. They are keyed by path now, which also says which
target is stale, the thing you need next.

Third, `contract/bindings.toml` asserted that only Go ships archives and that Rust
"genuinely cannot go stale this way". Rust vendors six and its `build.rs` PREFERS
them over a source build, so it went stale in exactly the way the comment denied,
on the default `cargo test` path, for as long as the gate was told not to look.
Rust declares its glob now, and the refresh command moved out of the reporter and
into each binding's own row - a gate that reports a stale archive while naming
another binding's script has told you half of it, and `rebuild` is required
wherever `archives` appears.

Each fix carries a test that was proven to fail without it.
