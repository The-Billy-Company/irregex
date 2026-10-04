---
doc_radar:
  sentinels:
    - file: bindings/go/testdata/ucd/Scripts.txt
      contains: ['# Scripts-17.0.0.txt']
    - file: tools/build_unicode_tables.py
      contains: ['GO_UCD =', '"LICENSE.txt"']
---

# Unicode oracle

We test property ranges against the [official Unicode 17 data](https://www.unicode.org/Public/17.0.0/ucd/), independently of the Go compiler's Unicode edition. These inputs and their license are exact copies of our pinned upstream files; the published Go module carries them too.

`python3 tools/build_unicode_tables.py` copies them and its `--check` verifies their bytes alongside the generated engine tables. We parse the source range records directly and check their edition against the loaded engine.
