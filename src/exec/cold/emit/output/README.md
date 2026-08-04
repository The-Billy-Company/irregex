# exec/cold/emit/output — the rg Output Models

Every ripgrep flag that changes *what stdout looks like* lands here. The
[`Emitter`](../output.zig) next door holds the state; these modules are the
bodies, written as free functions over `*Emitter` so the struct stays one
declaration and the modes stay separable.

The split is by model of the file, not by flag — that is the axis along
which a regression actually travels. Three modules disagree about what a
file *is*, and two serve all three.

- **`grid.zig`** treats a file as a grid of physical lines: walk them,
  decide per line, frame each hit. Home to the default frame, `-v`,
  `--passthru`, `-o`, and `-c`, plus `fusedFileEligible` — the predicate
  the fused walk consults before skipping the line array entirely.
- **`skim.zig`** treats a file as raw bytes with a literal needle in them.
  For pure-literal patterns, it never builds the line array: SIMD-skim the
  body for hits and reconstruct only the lines that matched. `litFastEligible`
  is the gate; every flag it cannot honor turns it off.
- **`multibuf.zig`** treats a file as one buffer (`-U`/`--multiline`),
  because a match may cross line boundaries. Spans are collected against
  the whole body first, then rendered as blocks, vimgrep rows, `-o`
  fragments, or replacements. Also carries `MlHarness`, the fixture
  `multibuf_test.zig` drives.
- **`display.zig`** decides, given a line the mode already chose, what
  bytes leave the process: `--trim`, `-M/--max-columns` (and its
  preview), color highlighting, and the terminator model. Also holds the
  two row shapes more than one model emits — `-o` fragments and
  `--vimgrep` rows.
- **`replace.zig`** expands `-r` templates. `expandInto` takes its
  allocator explicitly rather than reading the `Emitter`'s, because the
  `--json` stream calls the same function on the same templates — one
  expander, no second dialect.

## The Invariant Worth Protecting

`grid`, `skim`, and `multibuf` are three routes to the same bytes. A file
that qualifies for the skim path must print exactly what the grid path
would have printed; that equivalence is what makes the fast path safe to
take. When you touch one, ask what the other two would have emitted — the
parity tables in `multibuf_test.zig` and the warm-session renderer's
cold-parity suite exist to catch the moment they diverge.

## When to Edit

A flag that changes framing, presentation, or replacement. Changing *what*
matched belongs in `kernel/regex/`; changing *which files* were searched
belongs in the walk. Adding a mode means picking one of the three file
models above — if it fits none of them, that is the signal you are adding
a fourth, and it deserves its own module rather than a branch inside
someone else's.
