- A buffer-anchored miss is decided at byte 0 now, not after sweeping the whole
  document.

  `^…` and `\A…` outside `(?m)` can only ever match at the first byte, and the
  span walk was refusing to know that: it ran the literal gate over the entire
  buffer looking for a needle the engine could not use past position 0, then
  re-seeded a fresh thread at every byte — each seed dying at its own `^`
  without matching anything — so an anchored pattern that failed fast under
  `re` cost the full document here. Four cuts, all keyed off one
  `anchored and !line_anchors` bit the analysis already computes: a window
  starting past byte 0 answers null before it starts, the whole-buffer gate and
  caliper sweeps are skipped (the single attempt is cheaper than either), the
  per-byte re-seed never runs, and the walk returns the moment its thread list
  dies rather than idling to the end of the buffer.

  `\A` also reads as anchored in the analysis now — it is strictly stronger
  than `^` (a buffer start is always a line start), so everything the flag
  licenses holds a fortiori, and it was sitting in the not-an-anchor bucket in
  both the AST facts and `startsAnchored`. Frontmatter probes
  (`\A---\r?\n…`) went from tens of milliseconds per file to microseconds.
