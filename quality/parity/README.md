# The Binding Parity Gate

Every other gate here judges one artifact against one contract. This is the only
one that compares the bindings to each other.

That is the gap it was built for. Go, Python and Rust were each written against
the header, each reviewed on its own, and each correct — and they had drifted to
three different ABIs. Go could search a buffer and not a window. Rust had a
cancellation field with no way to fill it. Python was complete and nobody knew,
because nothing had ever put the three side by side.

The contract is [`contract/bindings.toml`](../../contract/bindings.toml). Each
binding declares where its sources are, what a reachable symbol looks like in its
language, and — where it ships build output — how to refresh it.

## The Five Lanes

1. **The header** must declare every symbol the linker publishes. The authority
   is `src/surface/ffi/exports.zig`, because an `export fn` is the promise; a
   header is a description of one, maintained by hand beside it.
2. **Coverage** asks whether each binding reaches every symbol. A gap is either
   fixed or waived, and a waiver states the reason a host can act on.
3. **Waivers** must still name a real gap. One kept after the gap closed reads
   as a live design decision and is a stale note, which is how a reviewer learns
   to skim the block.
4. **Signatures** hold a hand-transcribed declaration to the shape the header
   publishes: the number of parameters, the levels of indirection on each, and
   the width of every scalar. Names are documentation and an opaque handle's
   pointee is the host's own to spell, so neither is compared.
5. **Vendored build output** — the archives and the header copy under version
   control — must carry the whole ABI and come out of the build this tree
   declares.

## Why Only Rust Declares Signatures

Go hands `include/irgx.h` to a C compiler through cgo, so a C compiler holds its
signatures to the header on every build. Python's own suite parses the same
header and audits all hundred `ctypes` prototypes against it.

That suite is where the lesson came from. An unset `restype` truncates a
`size_t` to an `int` on every 64-bit host, and no test over a corpus smaller than
two gigabytes can see it.

Rust transcribes ninety `extern "C"` declarations by hand and links a vendored
archive statically. A mistranscribed parameter there is not a link error; it is a
call through a signature the engine never agreed to.

## Why The Go Header Copy Is A Lane

cgo compiles `bindings/go/irgx.h`, not the header this package installs. That
copy is build output under version control, exactly like the archives beside it,
and it had none of the checks they got.

A copy that misses a declaration fails loud at the compiler. A copy whose struct
grew a field in the engine and not here links fine and reads the wrong bytes,
which is precisely the hazard the header's own "gate on the ABI integer, never on
a struct size" note is about.

Declarations are compared and comments are not. The copy is deliberately scrubbed
of the sibling libraries' names, and nobody links against a paragraph.

## Running It

Run the gate the way CI does, then the detector's own proofs.

```bash
python3 quality/parity/check.py       # the gate (CI runs this)
python3 quality/parity/test_check.py  # the detector's own proofs
```

Exit `0` is clean, `1` is drift, `2` is a malformed contract. It is stdlib-only
Python: the archives are read as bytes for their symbol table, and everything
else is text.

A malformed contract reports only itself. Every binding looks empty when the
tables are unreadable, and a hundred drift lines caused by one typo would bury
the fault that caused them.

## When It Fails

The fix is the binding, or a waiver that says why not. Deleting a binding's row
to go green is the forbidden move, the same way lifting a ratchet baseline is.

A stale vendored artifact has a named fix, and the gate prints the binding's own
refresh command rather than a generic one.
