Tighten the `--json` record encoder's per-record hot path — three
output-identical shaves that compound across a match-dense stream:

- **Path object cached once per file.** A file's `begin`, every `match`/
  `context`, and its `end` all repeat the identical path; each record was
  re-running full UTF-8 validation + the SIMD string escape on it. `pathData`
  now encodes the `{"text":…}`/`{"bytes":…}` object once and every record
  appends the cached bytes — O(1) path work per file instead of O(records).
- **Hand-rolled unsigned integer writer** (`writeUint`) for the four
  per-submatch integers (`line_number`, `absolute_offset`, `start`, `end`),
  shedding `std.fmt.format`'s writer-vtable indirection on the hottest fields.
- **ASCII fast-path for the string encoder** (`asciiOnly`): a SIMD high-bit
  scan proves valid UTF-8 without the full validator (ASCII ⊂ UTF-8) for the
  overwhelmingly common all-ASCII line/path/match span.

Byte-identical to ripgrep by construction — `bench/rgsuite` `run.py` stays
409/409 on both engines, and a `sort -u` set-compare of the normalized record
stream matches `rg --json` across sparse/dense/`-n`/multi-word patterns.

Measured on a 48 MB single-file corpus, gist vs `rg --json` (fresh process,
resident daemon off): dense `id` **7.74× → 8.19×**, `NOT NULL` 6.60× → **6.84×**,
`CREATE` 5.26× → **5.56×**, sparse `pgvector` 1.95× → **2.06×**. Repo-wide
`--json` stays **3.2–4.2×** (walk-bound: it still rides the cold parallel walk,
not the warm resident index — the remaining structural lever).
