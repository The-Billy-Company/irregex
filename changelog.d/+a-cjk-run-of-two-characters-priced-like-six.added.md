Crest's Unicode-default lanes (`digit+u`, `hex+u`, `word+u`, `space+u`) counted
UTF-8 *bytes*, and `[0x80,0xFF]` — the escape valve every one of them shares —
cannot tell a continuation byte from a lead byte. So two CJK ideographs priced
the same as a six-byte forced run: any 6+ consecutive non-ASCII bytes anywhere
in a document, whether or not they resembled the target class, satisfied every
`+u` lane at once and made the whole document unprunable. `\d{6}` — the
ordinary way anyone spells "six digits" under the engine's own Unicode default
— pruned 62.5% of the corpus where its ASCII twin `[0-9]{6}` pruned 92.7%, and
most of that gap was this tax, not genuine ambiguity about what the document
contained.

The repair adds a third alphabet that counts codepoints without decoding one.
A UTF-8 lead byte (`0xC0-0xFF`) always advances a codepoint-run lane; a
continuation byte (`0x80-0xBF`) is transparent — neither advancing the run nor
resetting it, because self-synchronization guarantees it can only ever belong
to the codepoint the lead byte already opened. That "hold" rule is exact, not
approximate: `n` consecutive scalars of the target class advance the counter
exactly `n` times regardless of how many bytes each one costs, so a genuine
two-character CJK run now measures as 2, not 6, and correctly fails to satisfy
`ĝ=6`. A byte class holding a continuation byte in its own right
(`[\x80-\xFF]{6}`, read as raw bytes) refuses the lane outright rather than
resolve the ambiguity — `ĝ=0`, sound by degradation, the same rule the rest of
the calculus already lives by. Measured on the 21,854-file corpus, stacking
`+cp` on the already-shipped `+u` lane: `\d{6}` 62.5% → 72.7% (1.94x → 3.05x),
`\d{4}` 40.9% → 48.3%, `\s{4}` 4.8% → 14.6%; `\w{8}`, the adverse case where the
word class is nearly the whole alphabet, honestly stays at 0.0%.

The lane count `K` this needed (16 → 24, one codepoint twin per family member)
uncovered a real bug in the block scan rather than just costing more cycles:
`@Vector(24, u16)` occupies the same 64 bytes / 4 NEON registers the target
already rounds `@Vector(32, u16)` up to, but a microbenchmark of this exact
recurrence measured the *odd* width at 0.089 GiB/s against the *clean* one's
0.713 — 8x slower for identical storage, the signature of a lane count LLVM
cannot autovectorize cleanly rather than genuinely more work. Padding the
scan's internal vector to the width the backend already pays for (truncating
back to the real `K` only at the persisted `Vector` boundary) recovered it:
shipped throughput dropped from 2.07 to ~1.0 GiB/s on this machine — a third
alphabet is real extra state, and that part of the cost is honest — but the
speedup over the naive per-byte reference *improved*, 1.87x → 7.9x, because the
odd-width penalty is gone. `ways` (how many pieces the scan interleaves) had
to be re-picked by measurement rather than carried over: its register
footprint doubled alongside `K`, so the `ways=4` tuned for 16 lanes now
overflows NEON's register file where `ways=2` does not.

`Vector`/`Mask` grew accordingly (`Mask` is `u24` now, `u32`-serialized), and
the sidecar format bumped to v4 — a stale v3 (`K=16`) sidecar decodes to
`null` rather than being silently misread.
