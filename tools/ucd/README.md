---
doc_radar:
  sentinels:
    - file: tools/build_unicode_tables.py
      contains: [ "UNICODE_VERSION = \"17.0.0\"" ]
    - file: tools/build_unicode_names.py
      contains: [ "UNICODE_VERSION = \"17.0.0\"" ]
---

# Vendored Unicode Character Database - Pinned 17.0.0

These are the exact upstream UCD text files the engine's Unicode tables are
lowered from. They are pinned and vendored so table generation is hermetic (no
network at build/CI time) and the drift gate is reproducible. The lowering
lives in [`../build_unicode_tables.py`](../build_unicode_tables.py) → emits
`src/kernel/regex/unicode/tables.gen.zig`.

## Provenance

- **Version:** Unicode 17.0.0.
- **Source:** `https://www.unicode.org/Public/17.0.0/ucd/<file>.txt`
  (`DerivedGeneralCategory.txt` is under `.../ucd/extracted/`, `emoji-data.txt`
  under `.../ucd/emoji/`).
- **License:** Unicode License v3 - [`LICENSE.txt`](LICENSE.txt) carries the
  copyright and permission notice these Data Files must be distributed with,
  and the package [`NOTICE`](../../NOTICE) lists them alongside the other
  bundled third-party components. Keep both in step when upgrading the pin.

## What's Used

- **`CaseFolding.txt`** provides the simple case-fold orbits, its `C` and `S`
  lines - sha256 `ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.
- **`DerivedCoreProperties.txt`** provides `Alphabetic`, which backs `\w` -
  sha256 `24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08`.
- **`DerivedGeneralCategory.txt`** provides the general categories - `Nd`
  behind `\d`, the mark categories, `Pc`, and every `\p{…}` general-category
  query - sha256 `d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e`.
- **`PropList.txt`** provides `White_Space` (behind `\s`) and `Join_Control`
  (behind `\w`) - sha256 `130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd`.
- **`Scripts.txt`** provides `\p{Script=…}` -
  sha256 `9f5e50d3abaee7d6ce09480f325c706f485ae3240912527e651954d2d6b035bf`.
- **`emoji-data.txt`** provides `Emoji`, `Emoji_Modifier`,
  `Emoji_Modifier_Base`, `Emoji_Component`, and `Extended_Pictographic`. Same
  two-field shape as `PropList.txt`, which is why it joins the same loop -
  sha256 `2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b`.
- **`PropertyAliases.txt`** provides the short spellings every binary property
  also answers to - `Alpha`, `WSpace`, `XIDS`, `EMod`, `ExtPict` and the rest.
  Read from the standard's own alias table rather than hand-listed, because a
  hand-listed set is a set that silently stops matching the competitor the day
  Unicode adds one - sha256
  `4441f573caf952ffece1d7c892e7715bd7136dfc26f96eb6f268bf1e474715fb`.
- **`UnicodeData.txt`** provides the character *names* behind `\N{NAME}`, from
  its second field - plus, from its `<…, First>`/`<…, Last>` range markers, which
  codepoints get their names from a derivation rule instead of a table (the CJK
  and Tangut ideographs, the Hangul syllables) and which have no name at all
  (surrogates, private use). Read from the markers rather than a hand-listed set
  of block bounds, for the same reason as `PropertyAliases.txt` above: Unicode
  moves those bounds every release - sha256
  `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c`.
- **`NameAliases.txt`** provides the additional spellings `\N{}` must also
  answer to. It is not optional garnish: a control character has *no* name in
  `UnicodeData.txt` (its field is the marker `<control>`), so `\N{NULL}` and
  `\N{LF}` resolve only through this file, and `re` resolves all five alias
  types - sha256
  `793f6f1e4d15fd90f05ae66460191dc4d75d1fea90136a25f30dd6a4cb950eac`.

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
