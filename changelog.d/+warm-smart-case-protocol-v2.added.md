Warm resident session protocol v2 with smart-case eligibility: `-S`/`--smart-case`
(and its precedence siblings `-s`/`--case-sensitive`) now route warm, byte-identical
to cold. The v2 query flags byte carries the frozen flag-family table (`smart_case`
bit live; `word`/`invert`/`quiet`/`max_count` reserved) and `decodeQuery` fails
closed on any bit outside `known_flags` (BadFrame → decline → cold), so an
unimplemented flag is never silently dropped server-side. Smart-case resolves at
exactly one Zig site — `request.Request.effectiveIgnoreCase` (cold's `hasUpper`
fold) — feeding the engine fold, the trigram-prefilter caseless decline, and the
no-match hints; Python/Rust clients ship the raw bit and never re-implement the
fold. The Python eligibility predicate forked: `warm_eligible` (UDS) admits
smart-case while the new stricter `ffi_eligible` keeps the in-process transport
declining flags its C flag word cannot express.
