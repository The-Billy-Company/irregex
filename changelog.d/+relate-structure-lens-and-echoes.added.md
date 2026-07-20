`relate` grows a structure channel beside LZJD: every corpus file gets a
silhouette — identifiers/numbers/strings normalized to `I`/`N`/`S`, comments
and whitespace dropped, 5-token grams winnowed (w=4) into a k=256 KMV sketch —
so a renamed Type-2 twin lands at exactly distance 0. Surfaced two ways:
`relate similar --lens bytes|structure|fused` (bytes stays the default), and
the new `relate echoes` verb, which ranks pairs by `bytes − structure` distance
(`--min-echo`, default 0.15) to report DRY/abstraction candidates that `dups`
can't see — same skeleton, different vocabulary. The kinship atlas is now v3
(silhouette rows persisted beside sketch rows, both folded on freshness); older
atlases read as corrupt and degrade to a live build with a `relate index` hint.
