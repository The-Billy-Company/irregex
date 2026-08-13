# exec/cold/view — Our Own Ways of Looking at a Match

A lens answers the same compiled query over the same PATH scope, but
presents it in a shape ripgrep has no flag for. Two ship today.

- **`view.zig`** is the dispatch: it picks the lens the flags selected, or
  answers `unclaimed` and lets the ordinary rg path run.
- **`ranked.zig`** implements `--rank[=N]`, a definition-first RRF over
  the same hits: the definition outranks its call sites, and codegen
  sinks below authored code.
- **`commentscope.zig`** implements `--in-comments` / `--in-code`: the
  exact engine still decides IF a line matches; the span lexer only
  filters WHICH matches survive.

## Why a Lens Branches Early

Each lens finishes the run itself, before the certified rg-parity walk and
emit path. That early return is not a shortcut — it is what keeps the
parity certificate meaningful. A lens cannot thread its own awareness
through the machinery the face package's rgsuite harness measures, because
it never reaches that machinery. The rg path stays a byte-for-byte ripgrep
drop-in no matter how many native views the face grows.

## One Seam, Not a Growing Ladder

These were two `if` blocks written inline in `serial.run`, and a third
lens would have been a third block. Each one re-derived the file set,
re-resolved rg's filename-visibility rule, and re-spelled the exit shape
by hand — so the cost of a new lens was paid in copies of decisions that
already had owners.

`dispatch` writes them once (the cold-engine deep-module split). A lens
receives a `Run` whose `Writ` already carries every prune guard resolved,
asks `r.collect()` for the file set, `r.showNames(c)` for the filename
rule, and returns a `Claim`. Adding a lens is adding a case.

`Claim` distinguishes the two honest endings: a lens that owns an
rg-shaped exit code never returns at all, while `--rank`'s no-match is an
empty view (exit 0), not rg's exit-1 "nothing found" — a difference the
old inline `return` expressed only by being physically inside `run`.

## The File Set a Lens Gets

Lenses read every walked file whole. The whole-file gate and the index
prefilter are both proven against the question "would this file emit an
rg line?", which a lens does not ask, so neither applies. Only the line
needle, a property of the pattern itself, carries over. That reasoning
lives in `collect`, once, rather than in each lens.
