---
doc_radar:
  sentinels:
    - description: "grid owns the per-line frame and the fused-walk eligibility predicate"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output/grid.zig
      contains: ["pub fn file", "pub fn fusedFileEligible"]
    - description: "skim stays the line-free literal loop behind its own eligibility gate"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output/skim.zig
      contains: ["pub fn fileLit", "pub fn litFastEligible"]
    - description: "multibuf owns the -U whole-buffer emit and the harness its parity table drives"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output/multibuf.zig
      contains: ["pub fn buffer", "pub const MlHarness"]
    - description: "display is the one place a chosen line becomes bytes"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output/display.zig
      contains: ["pub fn emitBody", "pub fn exceeded", "pub fn emitMatches"]
    - description: "replace keeps expandInto allocator-explicit so --json shares it verbatim"
      file: pkg/kernels/irregex/src/surface/exec/cold/emit/output/replace.zig
      contains: ["pub fn expandInto", "pub fn buildReplaced"]
---

# emit/output — the rg output models

Every ripgrep flag that changes *what stdout looks like* lands here. The
[`Emitter`](../output.zig) next door holds the state; these modules are the
bodies, written as free functions over `*Emitter` so the struct stays one
declaration and the modes stay separable.

The split is by **model of the file**, not by flag — that is the axis along
which a regression actually travels. Three modules disagree about what a file
*is*, and two serve all three.

| File | The model it holds |
| --- | --- |
| `grid.zig` | A file is a **grid of physical lines**. Walk them, decide per line, frame each hit. Home to the default frame, `-v`, `--passthru`, `-o`, `-c`, and `--vimgrep`, plus `fusedFileEligible` — the predicate the fused walk consults before skipping the line array entirely. |
| `skim.zig` | A file is **raw bytes with a literal needle in them**. For pure-literal patterns, never build the line array: SIMD-skim the body for hits and reconstruct only the lines that matched. `litFastEligible` is the gate; every flag it cannot honor turns it off. |
| `multibuf.zig` | A file is **one buffer** (`-U`/`--multiline`), because a match may cross line boundaries. Spans are collected against the whole body first, then rendered as blocks, vimgrep rows, `-o` fragments, or replacements. Also carries `MlHarness`, the fixture `multibuf_test.zig` drives. |
| `display.zig` | Given a line the mode already chose, what bytes leave the process: `--trim`, `-M/--max-columns` (and its preview), color highlighting, and the terminator model. |
| `replace.zig` | `-r` template expansion. `expandInto` takes its allocator explicitly rather than reading the `Emitter`'s, because the `--json` stream calls the same function on the same templates — one expander, no second dialect. |

## The invariant worth protecting

`grid`, `skim`, and `multibuf` are three routes to the *same bytes*. A file
that qualifies for the skim path must print exactly what the grid path would
have printed; that equivalence is what makes the fast path safe to take. When
you touch one, ask what the other two would have emitted — the parity tables
in `multibuf_test.zig` and the warm-session renderer's cold-parity suite exist
to catch the moment they diverge.

## When to edit

A flag that changes framing, presentation, or replacement. Changing *what*
matched belongs in `kernel/match/`; changing *which files* were searched
belongs in the walk. Adding a mode means picking one of the three file models
above — if it fits none of them, that is the signal you are adding a fourth,
and it deserves its own module rather than a branch inside someone else's.
