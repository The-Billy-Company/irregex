# Vendored Unicode Character Database — Pinned 16.0.0

These are the exact upstream UCD text files the engine's Unicode tables are
lowered from. They are pinned and vendored so table generation is hermetic (no
network at build/CI time) and the drift gate is reproducible. The lowering
lives in [`../build_unicode_tables.py`](../build_unicode_tables.py) → emits
`src/kernel/regex/unicode/tables.gen.zig`.

## Provenance

- **Version:** Unicode 16.0.0 (matches the toolchain `unicodedata.unidata_version`).
- **Source:** `https://www.unicode.org/Public/16.0.0/ucd/<file>.txt`
  (`DerivedGeneralCategory.txt` is under `.../ucd/extracted/`, `emoji-data.txt`
  under `.../ucd/emoji/`).
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
- **`emoji-data.txt`** provides `Emoji`, `Emoji_Modifier`,
  `Emoji_Modifier_Base`, `Emoji_Component`, and `Extended_Pictographic`. Same
  two-field shape as `PropList.txt`, which is why it joins the same loop —
  sha256 `f1365a5173eee18e1f98b240cdc492e84a25f1ce7e0c9d1094eb29c41a22696a`.
- **`PropertyAliases.txt`** provides the short spellings every binary property
  also answers to — `Alpha`, `WSpace`, `XIDS`, `EMod`, `ExtPict` and the rest.
  Read from the standard's own alias table rather than hand-listed, because a
  hand-listed set is a set that silently stops matching the competitor the day
  Unicode adds one — sha256
  `33a9f2266ad6b8e8de05c0ea3dfac411ac62cf8839ff1c94057471e4c5f6a2b3`.
- **`UnicodeData.txt`** provides the character *names* behind `\N{NAME}`, from
  its second field — plus, from its `<…, First>`/`<…, Last>` range markers, which
  codepoints get their names from a derivation rule instead of a table (the CJK
  and Tangut ideographs, the Hangul syllables) and which have no name at all
  (surrogates, private use). Read from the markers rather than a hand-listed set
  of block bounds, for the same reason as `PropertyAliases.txt` above: Unicode
  moves those bounds every release — sha256
  `ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f`.
- **`NameAliases.txt`** provides the additional spellings `\N{}` must also
  answer to. It is not optional garnish: a control character has *no* name in
  `UnicodeData.txt` (its field is the marker `<control>`), so `\N{NULL}` and
  `\N{LF}` resolve only through this file, and `re` resolves all five alias
  types — sha256
  `9953f0fcebf5ea8091c5c581e4df0e43f20d2533c84ccca7987a9bb819a896a8`.

The last two feed a second generator,
[`../build_unicode_names.py`](../build_unicode_names.py) →
`src/kernel/regex/unicode/names.gen.zig`, kept separate because the name
database is an order of magnitude larger than every property table combined and
has its own encoding.

Verify every pin at once by hashing the vendored files and comparing the
output to the digests above:

```bash
shasum -a 256 *.txt
```

To upgrade the Unicode version, re-fetch the whole set at the new version,
update `UNICODE_VERSION` in **both** generators, run
`python3 tools/build_unicode_tables.py` and
`python3 tools/build_unicode_names.py`, and re-baseline the parity fixtures.
