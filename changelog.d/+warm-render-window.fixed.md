The warm line renderer set only one end of its per-document window, and a text
document following a binary one inherited the binary's end address. `handleBinary`
re-points the pair at the committed pre-NUL prefix, so the next document's
`body_end` pointed into a region that was not its own — and every fused
whole-buffer pass inside `Emitter.file` reconstructs its body from that pair, so
this was not a lost optimization but a scan over another document's address
range. `panic|0x` (pure literals with no single needle, which is what engages the
SIMD candidate sweep) walked off the end of the mirror's shard mapping and killed
the daemon; the unterminated-tail framing was reading the same stale end. Both
ends are now assigned per document, exactly as the cold renderer does it.
