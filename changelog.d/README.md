---
doc_radar:
  sentinels:
    - description: "irregex remains on the chronicle package roster"
      file: pkg/tools/support/chronicle/packages.py
      contains: 'Package("pkg/kernels/irregex"'
---

# `changelog.d/` — towncrier news fragments

Per-change fragments for the OSS-shaped `irregex` package. They fold into
[`../CHANGELOG.md`](../CHANGELOG.md) on release build — not something you
hand-edit into the changelog mid-PR.

```bash
make changelog-create PKG=irregex TYPE=added|changed|deprecated|removed|fixed|security \
  SLUG=<short-slug> CONTENT="What changed and why it matters."
make changelog-check PKG=irregex COMPARE=origin/main
```

Fragment shape: `+<slug>.<type>.md`. Write one in the **same PR** as any
user-visible / API / behavior / perf / security change. Skip only for
comment-only, format-only, or pure-internal refactors with zero observable
delta — when unsure, write the fragment.

Scaffolding (`towncrier.toml`) is generated from chronicle — never hand-edit
it. See [`pkg/tools/support/`](../../../../tools/changelog/) and the
`libs-oss-standards` rule.
