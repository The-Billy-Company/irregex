`libirgx` is now a real artifact, and it is a regex library rather than a
search one: `irgx_compile` / `is_match` / `find_all` / `captures` /
`group_count` / `group_index` over a buffer the host already holds, with
`include/irgx.h` as the normative header. No corpus, no session, no index —
those are `libgist`'s, and a host that only wants a regex no longer links them.

Two things make it more than a wrapper. Every verb is a shim over the machinery
the CLI already runs — the compiled-query kernel and the `Caps` capture arms —
so an in-process answer is the same answer `gist --json` prints for the same
pattern, down to the empty-match and `-w` rules. And the arm choice itself moved
onto `Caps.compile`, so the C ABI and `exec/cold/writ/arm.zig` cannot drift on
which engine a pattern belongs to; the CLI now supplies only its own half of the
seam, which is that a bad pattern is a diagnosed exit rather than a status.

The header also carries the substrate the whole ecosystem speaks: the six status
codes and their dispositions, `irgx_last_fault`, `irgx_status_message`, and
the pattern flag bits (now including `IRGX_PCRE` at bit 8, beside the bits
`libgist` claims for its behavioral half). The `export fn` shims live in
`surface/ffi/exports.zig`, the artifact's own root rather than the library
module's, so linking two of the ecosystem's libraries cannot produce a duplicate
definition of a symbol you asked for once.
