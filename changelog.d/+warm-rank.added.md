`--rank` now answers from the resident session instead of falling back to
cold. The daemon ranks over its in-memory `LiveFile` set
(`renderRanked`/`renderLive`) — a symbol's definition ahead of its call sites,
generated files demoted — reusing the same chunk transport as plain warm line
output. `request.classify` mirrors cold's last-explicit-wins `--rank[=k]`
semantics and declines the combination of `--rank` with context
(`-A`/`-B`/`-C`), which has no meaning in a ranked view. Output matches cold's
ranked cap; measured ~2× over the cold no-index baseline.
