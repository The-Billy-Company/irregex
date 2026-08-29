- Three scan dispatches were calibrated at their endpoints and lost in the band
  between them. Every one is now measured across the band it actually serves, and
  a Unicode class or a multi-way alternation no longer trails ripgrep on either
  clock.

  **The any-of gate hands off to Teddy at two needles, not four.** The old
  threshold was fitted at N=4 and N=8 without measuring N=2–3, and the fused
  gate's first+last fingerprint is *degenerate* exactly there: a 2-byte UTF-8
  needle fingerprints on its own two bytes, so every occurrence of the lead byte
  survives to a full compare. The tell was that adding a FOURTH needle made the
  same scan several times faster, because the fourth needle crossed the
  threshold — a dispatch whose cost falls when the work grows is the threshold
  being wrong, not the kernels. The width sweep is flat now (17.3 / 16.9 / 17.8 ms
  wall at N=2/3/4 against rg's 87.1 / 88.4 / 87.0), so the band is gone rather
  than moved.

  **A codepoint class asking only whether a member OCCURS stays bit-parallel.**
  A block touched by a byte ≥ 0x80 needs codepoint-grained membership, because the
  byte bit-path would misread a member codepoint's own continuation bytes as run
  breakers — so the whole block fell to the scalar resolver. But a bare class or
  `[…]+`, which is what nearly every real query spells, carries no run to count:
  it asks for existence, and existence is expressible in bits. That case now keeps
  the SIMD fold for the block's ASCII bytes and decodes only the maximal runs of
  high bytes, so the scalar work is proportional to the non-ASCII bytes actually
  present rather than to the 64 bytes around them. A higher run floor still needs
  the resolver, which is the one thing bit tricks cannot express.

  **The range prefilter folds four vector windows into one branch.** Its per-byte
  work was already cheap and it still trailed `memchr` on a sparse lead set,
  because it branched once per vector and stalled on its own branch. The compares
  are independent, so four windows now fill the issue slots the single-window loop
  left idle, and a skip across barren text costs one test per 64 bytes. The width
  is the register's claim (`64 / vlen`), not a tuned constant, so it degrades to
  one window under AVX-512 rather than guessing.

  Measured on a 268 MB mixed-script corpus, `-c`, minimum of 25 runs per shape
  with both tools sampled under the same load, counts identical everywhere. gist
  is ahead on **both** clocks on every shape — which is the bar, since a wall-clock
  win bought with 3× the CPU is a loss on any laptop doing something else:

  | shape | cpu | rg cpu | cpu× | wall | rg wall | wall× |
  |---|---|---|---|---|---|---|
  | wide range class `[\u00a0-\u00ff]` | 46.4 | 59.1 | 1.27× | 16.3 | 58.2 | 3.56× |
  | class + quantifier `[\u00e9\u65e5]+` | 69.5 | 94.1 | 1.35× | 17.6 | 93.2 | 5.30× |
  | anchored literal `^\u00e9` | 47.2 | 51.0 | 1.08× | 16.4 | 50.6 | 3.09× |
  | rare 2-byte literal `\u00ab` | 27.9 | 44.6 | 1.60× | 13.1 | 43.9 | 3.34× |
  | rare wide class `[\u00ab-\u00bb]` | 27.1 | 41.7 | 1.54× | 13.3 | 41.2 | 3.09× |
  | dense class `\w` | 98.8 | 142.3 | 1.44× | 21.1 | 141.2 | 6.69× |

  All three are throughput dispatches, not fallbacks: both arms of each are
  byte-exact, so nothing here can change an answer. `anchor.selectivity` is
  exposed for the same reason — a caller ranking two candidate needles now prices
  them under the same fitted model that will scan the winner, instead of a second,
  differently-calibrated guess.
