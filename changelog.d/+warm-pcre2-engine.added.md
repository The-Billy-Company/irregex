The resident (warm) session now serves `-P`/`--pcre2`/`--engine=pcre2` queries
warm instead of punting them to a cold process. `CompiledQuery.body` migrated
from a linear-only regex arm to an engine-neutral `Matcher` union, so the shared
query core compiles, prefilters, and matches through the same PCRE2 JIT backend
the cold path uses — including lookahead, lookbehind, backreferences, and
negative lookahead. A single `pcre` trailer byte rides the additive `query_ext`
opcode (protocol v4→v5); `request.classify` sets `Request.pcre` and still
declines `-P`+`--rank` (ranked view stays linear-only). Caseless PCRE prefilters
decline soundly rather than risk a false narrow. Proven byte-exact against the
cold `--no-index` walk across lines/`-n`/`-c`/`-l`/`-c -w` on the live corpus —
the warm hit is identical, just without the per-query trigram-index + corpus
load.
