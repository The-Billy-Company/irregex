Multi-tier **literal-set engine** fronting the ladder (`scan/literal_set.zig`):
a single dispatcher that decides a whole line or buffer in one pass with no
automaton. Zero/one-needle patterns take a rare-byte / `memchr` / `memmem` scan;
up to 64 literals go through grouped Teddy (the SIMD prefilter, widened from 8 to
64 buckets); above 64, a sparse Aho–Corasick automaton. It answers a `Presence`
or `Position` with `exact` or `candidate` authority — an `.exact` set (the
pattern _is_ this alternation of literals) decides the match outright, while a
`.candidate` (a cover union or a required literal) is a necessary condition, so a
miss rejects the haystack before any rung runs and a hit falls through unchanged.

Lowering builds it from the pattern's extracted literals and declines gracefully
past its capacity (`../regex/linear/program/lower.zig`); `verdict.zig` consults
it at the top of every boolean entry point, ahead of the class-run kernel and the
accelerator tier. Byte-identical to the Pike VM on the sets it accepts.
