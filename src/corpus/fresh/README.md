---
doc_radar:
  counts:
    - description: "fresh keeps anchor · journal · sweep (+ tests)"
      glob: pkg/kernels/irregex/src/corpus/fresh/*.zig
      unit: files
      min: 3
  sentinels:
    - description: "the dual-clock anchor is the crate's central truth mechanism"
      file: pkg/kernels/irregex/src/corpus/fresh/fresh.zig
      contains: ["pub fn readAnchor", "pub fn writeAnchor"]
---

# `src/corpus/fresh/` — when may an artifact speak for live bytes?

The freshness law. Promoted out of `corpus/index/trigrams/` because every
persisted accelerator — atlas, frag, shelf, phantom, content, crest, the
trigram pair — folds through the same T3 rule: _index accelerates, never
overrules_. A days-old artifact is still correct under a tree ~10 agents are
editing because this package says so, not because any one format invented a
private clock.

| File | Job |
| ---- | --- |
| `fresh.zig` | Dual-clock build anchor + conservative freshness probe |
| `journal.zig` | macOS FSEvents change-journal replay (the sweep's OS accelerator; never a correctness dependency) |
| `sweep.zig` | Work-stealing "what changed since anchor" metadata walk |

Sits **above** the trigram pair on the ward page (it reads the pair's layout
to prove currency) and **below** the rest of `index/` that trusts the fold.
The build stamps the anchor _before_ reading the corpus; a file whose
mtime/ctime reaches the anchor is re-verified live.

`journal.zig` moved here from `corpus/tree/` — its only consumer is
`fresh.zig`. The walk substrate does not need a change journal; the freshness
law does.
