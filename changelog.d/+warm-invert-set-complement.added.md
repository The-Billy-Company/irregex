Warm resident session eligibility for `-v`/`--invert-match`, byte-identical to
cold and now FASTER on the faces the math proves winnable — overturning the
earlier "keep invert cold" result. The daemon answers `-v` by the set-complement
`non_matching(f) = lines(f) − matching(f)`: the trigram prefilter stays SOUND for
the positive MATCH set (a ruled-out file matches nothing by construction, a
candidate false positive is corrected by the scan), so `matching(f)` is exact and
the complement is exact. Per-file line counts and the corpus total are counted
once at Mirror load and maintained on reconcile, so `-c -v` = `TOTAL − Σ match`
and `-l -v` (file qualifies iff `match(f) < lines(f)`) subtract cached invariants
with ZERO scan on the ruled-out majority — strictly less work than cold's
full-corpus `-v` scan. On a 1833-file / 238k-line corpus warm `-c -v` runs
0.05–5.3 ms vs cold 39–48 ms (9–760×, versus the prior warm 106–286 ms), and
`-l -v` wins 2.7–10.8×. The bare-`-v` emit selects nearly every line of every
doc, so it shards its render over cores through `src/math/parallel.zig`
(`greedyBounds` + `fanOut`, concatenated in original doc order) and stays
byte-identical to the serial core; end-to-end it holds parity with cold's 16-core
scan (output-transfer-bound, winning for common patterns). The v2 query flags
byte is now fully assigned — `invert` (bit 4) joins `known_flags` alongside
fixed/ignore_case/line_num/word/smart_case/quiet/max_count — and, with every bit
carrying a semantic, fail-closed now rests on the version handshake plus the
length/opcode gates. Non-invert hot paths stay byte-for-byte unchanged; the
session gate is unregressed (geomean 474×). Eligible across the UDS daemon
(`-l`/`-c`/emit), the in-process FFI, and the Python + Rust bindings
(`_FLAG_INVERT`, `invert` out of the warm-ineligible set), all proven against
cold on controlled fixtures.
