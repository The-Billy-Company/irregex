- `(?m)` and `(?s)` reach the capture arm now. The linear capture VM predates
  the buffer-oriented FFI: its `^`/`$` instructions hard-coded the buffer ends
  (the CLI only ever ran it per line, where the two coincide), and its parser
  never saw `dotall` at all. So `find_all` — which resolves line anchors against
  `\n` adjacency — reported a match the capture pass could not reproduce, and any
  group query on a multiline match past byte 0, or a dotall match whose `.`
  crossed a newline, raised the "internal disagreement" error instead of
  answering. `irgx.finditer(r"^(\w+):", text, multiline=True)` failed on its
  second line, which is the first shape any log parser writes.

  The fix mirrors what `Selection.lowerOptions` already documents for the
  boolean arm: the capture parser runs in buffer mode with `dotall` threaded
  through, the VM resolves `^`/`$` through the same `lineStart`/`lineEnd`
  predicates the Pike closure reads — one definition, so the arms cannot drift —
  and `\A`/`\z` lower to new true-buffer-anchor instructions. The one-pass
  determinizer carries the same four assertions, so the fast arm answers
  identically to the fallback it fronts.
