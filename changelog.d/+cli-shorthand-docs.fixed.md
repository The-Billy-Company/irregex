`gist --schema` and the bare `usage()` banner now document the
`gist <pattern> [PATH...]` shorthand (no verb, no index required) as a
first-class capability instead of leaving it undiscoverable — the schema
manifest gained a `"shorthand"` field and a corrected exit-code description.

Also fixed several stale doc comments left over from the pre-`search`-verb-
collapse design that misdescribed the whole-tree `rg`-compatible engine: a
dead `commands/grep/` reference (the folder itself, empty and unused, is
deleted), and incorrect claims that the engine ignores `.gitignore` and fails
loud on `--json`/`--column`, when it actually supports both.
