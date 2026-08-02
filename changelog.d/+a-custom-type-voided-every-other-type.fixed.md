A `--type-add` type named with `-t` no longer cancels every other `-t` beside
it. `-t` is a union; one custom name was turning it into an intersection.

`--type-add 'tsx:*.tsx' -t go -t tsx` over a mixed tree returned 453 files, all
of them `.tsx`. ripgrep returns 1,082 for the same line: 629 `.go` plus those
453. Nothing errored and no flag was rejected, so the only symptom was a
smaller answer than the one you asked for; that is the failure a search tool is
least allowed to have. A five-type line (`-t go -t py -t rust -t ts -t tsx`)
found 3 files where rg found 168.

The cause is which bucket a custom type landed in. `PathFilter` keeps two
positive dimensions and ANDs them: `exts` is the union of every `-t` type's
globs, `includes` is the `-g` glob set. `Builder.addType` sent a built-in name
to `exts` and a `--type-add` name to `includes`, so the two ANDed and a `.go`
file could satisfy the type half but not the glob half. It only showed up in
the MIX, which is why it lasted: built-ins union with built-ins correctly, and
a custom type on its own matches rg exactly. The genus branch three lines above
already had the rule written down - a widened genus joins `exts`, "so they add
to the selection instead of becoming an override that decides alone" - the
plain custom-type branch just never got it.

It fixes a second, quieter divergence at the same time. `-t` may un-hide a
dotfile but must never un-ignore a gitignored leaf; only `-g` does that
(`filter.surfacesHidden`, and rg's own rule). While custom types lived in the
`-g` set they were un-ignoring too.

The gate is `bench/conformance/gates/parity/type_union_parity.sh` in the gist
repo, with rg as the oracle over a corpus it synthesizes so the cases can't go
vacuous in a checkout that happens to be single-language. Reverting this one
line breaks 5 of its invariants.
