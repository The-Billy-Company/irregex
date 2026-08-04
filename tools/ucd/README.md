# Vendored Unicode Character Database — Pinned 16.0.0

These are the exact upstream UCD text files the engine's Unicode tables are
lowered from. They are pinned and vendored so table generation is hermetic (no
network at build/CI time) and the drift gate is reproducible. The lowering
lives in [`../build_unicode_tables.py`](../build_unicode_tables.py) → emits
`src/kernel/regex/unicode/tables.gen.zig`.

## Provenance

- **Version:** Unicode 16.0.0 (matches the toolchain `unicodedata.unidata_version`).
- **Source:** `https://www.unicode.org/Public/16.0.0/ucd/<file>.txt`
  (`DerivedGeneralCategory.txt` is under `.../ucd/extracted/`).
- **License:** Unicode License v3 — [`LICENSE.txt`](LICENSE.txt) carries the
  copyright and permission notice these Data Files must be distributed with,
  and the package [`NOTICE`](../../NOTICE) lists them alongside the other
  bundled third-party components. Keep both in step when upgrading the pin.

## What's Used

- **`CaseFolding.txt`** provides the simple case-fold orbits, its `C` and `S`
  lines — sha256 `6f1f9c588eb4a5c718d9e8f93b782685e5c7fec872cf05e8e6878053599e09bb`.
- **`DerivedCoreProperties.txt`** provides `Alphabetic`, which backs `\w` —
  sha256 `39d35161f2954497f69e08bdb9e701493f476a3d30222de20028feda36c1dabd`.
- **`DerivedGeneralCategory.txt`** provides the general categories — `Nd`
  behind `\d`, the mark categories, `Pc`, and every `\p{…}` general-category
  query — sha256 `7676ab755a41ef82108460238569e60ad65c191ddafe61b36c6765ec1353f293`.
- **`PropList.txt`** provides `White_Space` (behind `\s`) and `Join_Control`
  (behind `\w`) — sha256 `53d614508e2a0b2305a8aa21cd60d993de9326cdf65993660dfcce4503548583`.
- **`Scripts.txt`** provides `\p{Script=…}` —
  sha256 `9e88f0a677df47311106340be8ede2ecdacd9c1c931831218d2be6d5508e0039`.

Verify every pin at once by hashing the vendored files and comparing the
output to the digests above:

```bash
shasum -a 256 *.txt
```

To upgrade the Unicode version, re-fetch the whole set at the new version,
update `UNICODE_VERSION` in the generator, run
`python3 tools/build_unicode_tables.py`, and re-baseline the parity fixtures.
