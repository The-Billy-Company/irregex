The cross-binding gate read every committed archive for the ABI names it carries,
and nothing anywhere read one for which BUILD it came out of. Those are different
questions, and cutting a release is precisely when they diverge: the release bot
moves the declared version, the twelve vendored archives keep the engine from
before it, and every symbol is still present - so the symbol lane, which exists to
catch a stale archive, has nothing to say about the stalest one there is.

The half that nearly shipped is Go's. Rust asserts the linked engine's version
equals its crate's in its own contract test, so its six archives failed at test
time and got re-minted. Go asserts nothing about the version, and its oracle corpus
embeds the same stale number the archive does, so the two agreed with each other and
the suite went green - `go get` would have installed a module claiming a release it
did not contain, with no test anywhere that could say otherwise.
`tools/version_parity.py` cannot reach either one: it holds marked lines in
manifests to the declared number, and an archive has no line to mark.

So the archives are held to the same authority a different way. `build.zig.zon`
declares the number, and every committed archive has to spell it in its own string
table - the engine bakes its version in there beside PCRE2's `10.47`, which keeps
this a stdlib byte scan like the symbol lane beside it rather than an `nm` that
would have to understand three object formats. Against the tree as released the new
lane reports twelve faults and names each archive's rebuild script; against the
tree it was written on, zero.

Reading a version out of a string table has one trap, and the first implementation
fell in it: adjacent entries SHARE a delimiter. The Linux archives spell
`\0 16.0.0 \0 2.0.0 \0`, so a pattern that consumes the trailing NUL reads every
other entry and finds LLVM's version where the engine's should be - which reported
four clean archives stale while the engine's number sat one byte past the match.
The trailing delimiter is a lookahead, and the case is a test. Six new proofs:
the release state itself, a whole-but-old archive passing the symbol lane and
failing this one, version-shaped substrings (`clang version 21.1.0`, PCRE2's
two-part `10.47`) refused, an archive carrying no version at all failing closed,
and the real twelve read off disk.
