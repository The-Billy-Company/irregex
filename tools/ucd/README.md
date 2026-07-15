# Vendored Unicode Character Database (UCD) — pinned 16.0.0

These are the exact upstream UCD text files gist's Unicode tables are lowered
from. They are pinned and vendored so table generation is **hermetic** (no
network at build/CI time) and the drift gate is reproducible. The lowering lives
in [`../build_unicode_tables.py`](../build_unicode_tables.py) → emits
`src/regex/unicode/tables.gen.zig`.

## Provenance

- **Version:** Unicode 16.0.0 (matches the toolchain `unicodedata.unidata_version`)
- **Source:** `https://www.unicode.org/Public/16.0.0/ucd/<file>.txt`
  (`DerivedGeneralCategory.txt` is under `.../ucd/extracted/`)

| File | Used for | sha256 |
|---|---|---|
| `CaseFolding.txt` | simple case-fold orbits (C+S lines) | `6f1f9c588eb4a5c718d9e8f93b782685e5c7fec872cf05e8e6878053599e09bb` |
| `DerivedCoreProperties.txt` | `Alphabetic` (for `\w`) | `39d35161f2954497f69e08bdb9e701493f476a3d30222de20028feda36c1dabd` |
| `DerivedGeneralCategory.txt` | general categories (`\d`=Nd, marks, Pc, `\p{...}`) | `7676ab755a41ef82108460238569e60ad65c191ddafe61b36c6765ec1353f293` |
| `PropList.txt` | `White_Space` (`\s`), `Join_Control` (for `\w`) | `53d614508e2a0b2305a8aa21cd60d993de9326cdf65993660dfcce4503548583` |
| `Scripts.txt` | `\p{Script=...}` | `9e88f0a677df47311106340be8ede2ecdacd9c1c931831218d2be6d5508e0039` |

Verify with `shasum -a 256 *.txt`. To upgrade Unicode: re-fetch the whole set at
the new version, update this table + `UNICODE_VERSION` in the generator, then
`make gen-gist-unicode` and re-baseline the parity fixtures.
