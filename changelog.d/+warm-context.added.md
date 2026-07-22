`-A`/`-B`/`-C` context windows now render warm. `request.classify` accepts the
short forms (glued `-A2` and separated `-A 2`), the long forms
(`--after-context`/`--before-context`/`--context`, `=`- or space-joined), folds
them with cold's precedence (`after = A ?? C`, `before = B ?? C`), and declines
non-decimal or missing values. The `query_ext` opcode gained a back-compatible
context trailer (protocol v4 — older daemons tolerate its absence via
`takeContext`), and the warm `lines` renderer reuses the cold `output.Emitter`
for in-file windows plus cold's inter-file `--` separator, forcing serial
emission on context queries so the cross-file separator state stays exact.
Byte-identical to `gist --sort path` under an uncapped output
(`GIST_UNCAP=1`); measured 4–6× on narrow context queries over the cold
no-index baseline.
