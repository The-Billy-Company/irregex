`contract/search_api.toml` is now `contract/engine.toml`, and it only declares
what this kernel actually authors: the request surface, match kinds, exit codes,
and the version axes. It used to carry fifteen tables while the kernel cited
two; the other thirteen described surfaces belonging to `gist` and `relate`, and
have moved to `gist/contract/surface.toml` and `relate/contract/kinship.toml`
respectively. The clearest sign it had gone wrong: the single biggest table was
named `[irregex]` and described relate's compression vocabulary.

The split is textual, so every line of the prose explaining why a value is what
it is moved with the value. All 419 leaf keys are accounted for; none was
dropped, renamed, or invented, apart from `meta.package_dist` and
`meta.package_import`, which name artifacts gist publishes and are now
`[package] dist` / `import` in gist's contract.

`tools/build_schema_tables.py` moved to `gist/tools/` alongside the files it
generates. It had grown a walk into a sibling checkout to reach them, which only
ever encoded living in the wrong repo. (It moved back here shortly after, once
the row schemas were recognized as substrate rather than gist's — see the
`analytic.toml` entry, which is where that reasoning finishes.)
