_2026-07-19_ — Build: **`engineModules` + `twin` for post-hoc decorations.**
The root/test-twin framework + PCRE2 wiring collapses to one loop; the CLI
engine is a `kernelkit.twin` at `-Dcli-optimize` instead of a hand-rolled
`createModule`.
