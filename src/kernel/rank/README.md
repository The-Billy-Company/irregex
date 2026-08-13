# `src/kernel/rank/` — T4 definition-first ranking

Turns the verified match set into the ranked, token-compressed list an agent
actually wants: the one line that answers the question first, not 200
identical call sites. This is the shape `rg` cannot express — the ranked view.

- **`rank.zig`** fuses the signals below with weighted Reciprocal Rank
  Fusion (Cormack et al. 2009) and emits `path:line [def|use|gen|mirror] ×n
  <line>`.
- **`signals.zig`** derives language-agnostic byte features: structural
  declaration confidence, codegen detection for demotion, and a normalized
  match-line shape fingerprint for rarity.
- **`replica.zig`** classifies cache/VCS snapshot paths, fingerprints their
  bytes, and resolves an exact canonical duplicate for display.

## Signals

- **Lexical density** — more occurrences ⇒ more relevant.
- **Definition boost** — structural confidence that the match is a
  declaration, not a use site (three-level: body/value > signature > use).
- **Shape rarity** — normalized match-line geometry devalues repeated
  call/import shapes below rare explanatory shapes.
- **Shallow path** — fewer segments ⇒ closer to a package root.
- **Authored boost** — sinks codegen (`*_pb2.py`, `*.sql.go`, …) and
  cache/VCS mirrors below hand-written code, weighted to outrank their
  inflated lexical and definition scores.
- **Class-split, tie-aware** — ranking stays neutral *within* each class so
  you never invent a total order the signals don't support.
- **Exact duplicates** — a mirror names its canonical result instead of
  flooding the list.

## When to Edit

New intrinsic signals, class labels, or RRF weights. Do not put walk or
emit logic here — rank consumes an already-verified hit set from
`kernel/regex/` + `exec/cold/view/ranked.zig`.
