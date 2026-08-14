# `changelog.d/` — towncrier news fragments

Per-change fragments for the OSS-shaped `irregex` package. They fold into
[`../CHANGELOG.md`](../CHANGELOG.md) on release build — not something you
hand-edit into the changelog mid-PR.

```bash
towncrier create +<slug>.<type>.md
# write the fragment body, then on release:
towncrier build --version x.y.z
```

Fragment shape: `+<slug>.<type>.md`. Write one in the *same PR* as any
user-visible / API / behavior / perf / security change. Skip only for
comment-only, format-only, or pure-internal refactors with zero observable
delta — when unsure, write the fragment.

A fragment's `<type>` is one of `note`, `added`, `changed`, `deprecated`,
`removed`, `fixed`, `security`. `note` is the odd one: it is the release's
lede rather than an entry in it — prose that frames the section, rendered
above every category because towncrier emits types in declaration order. Use
it at most once per release, for the paragraph someone should read before the
bullets. Everything under `changelog.d/` becomes the GitHub Release body
verbatim on tag, so write for the person landing on the release page.

Scaffolding is [`../towncrier.toml`](../towncrier.toml) — hand-maintained in
this repo (standalone after extraction).
