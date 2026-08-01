`bindings/python/` is a real Python binding now: `ctypes` over the bundled
`libirregex`, so `pip install irregex` gives a working regex library with no Zig
toolchain, no compiler, and nothing to install alongside it. The published 0.1.0
shelled out to a CLI that no longer exists; 0.2.0 links the library the header
describes and loads it out of the installed package, with an `IRREGEX_LIB`
override for people pointing at their own build. `irregex_abi_version()` is
checked at load, so a wheel and a library that disagree say so instead of
mis-reading a struct.

The surface is stdlib `re`'s, because that is the API a Python user already has
in their fingers: module-level `compile` / `search` / `finditer` / `findall` /
`split` / `sub` / `subn`, `Pattern` and `Match` with `group` / `groups` /
`groupdict` / `span`. Flags are keyword arguments (`fixed`, `ignore_case`,
`word`, `smart_case`, `unicode`, `pcre`) rather than an or-ed bitmask, since the
C bits are already named and a keyword is what a reader can see at the call
site. There is no `match` or `fullmatch`: the engine has no anchored verb, and
inventing one out of a scan would be a semantic the library does not actually
hold.

Three properties are the whole reason this is a binding rather than a wrapper.
Iteration is `irregex_find_all`, never a Python advance loop over `captures`, so
the empty-match, adjacency, and `-w` rules a nullable pattern depends on are the
engine's and not a re-invention of them; the group detail is filled in
afterwards by `captures(from=span.start)` per span the engine already blessed.
`str` in gives `str` out with **codepoint** indices, translated off the engine's
byte offsets lazily and skipped entirely when the subject is ASCII, so
`text[m.start():m.end()] == m.group()` holds for the caller's own string; a
pattern compiled from `str` refuses `bytes` and the reverse, as `re` does. And a
`Pattern` is safe at module scope under a thread pool, because the C handle owns
the scratch its finds run in and cannot be shared — each thread gets its own
lazily through `threading.local`, which costs one pure compile per thread and is
released when the thread dies.

Wheels are platform-tagged and carry the library, built by a hatch hook that
cross-compiles with Zig: macOS arm64 and x86_64, manylinux x86_64 and aarch64,
and Windows x86_64 all come off one machine.
