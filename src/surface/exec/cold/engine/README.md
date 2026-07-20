---
doc_radar:
  sentinels:
    - description: "three orchestration modes remain the public engine surface"
      file: pkg/kernels/irregex/src/surface/exec/cold/engine/serial.zig
      contains: ["pub fn run", "defaultFileSet", "IndexSkip"]
    - description: "parallel fused pipeline still falls through to serial when ineligible"
      file: pkg/kernels/irregex/src/surface/exec/cold/engine/parallel.zig
      contains: ["pub fn run"]
    - description: "ranked view remains the --rank native shape"
      file: pkg/kernels/irregex/src/surface/exec/cold/engine/ranked.zig
      contains: ["pub fn run", "rank"]
---

# runtime/cold/engine — walk + match orchestration

The control planes that wire [`argv`](../argv) → [`walk`](../walk) →
[`read`](../read) → [`emit`](../emit) into a finished search. Matching itself
lives in `search/match/query.zig`; these modules own _when_ to walk, _which_
files to open, and _how_ to stream results.

| File            | Role                                                                                                                                                                                                                                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `serial.zig`    | the certified rg-compat control plane — argv dispatch, walk/read fallbacks, index admission (`IndexSkip`), stdin / JSON / stats branches, exit semantics. Re-exported as `gist.commands.search`.                                                                                                                         |
| `parallel.zig`  | fused work-stealing walk+read+match when the flag set allows; ineligible combinations fall through to serial unchanged.                                                                                                                                                                                                  |
| `ranked.zig`    | `--rank[=N]` — definition-first ranked view over the same candidate set (gist's one native shape ripgrep can't express).                                                                                                                                                                                                 |
| `retrieval.zig` | relate's cold recall engine (`relate search` / `pack`): nominate a bounded pool from the mmap trigram postings, fold the freshness overlay, price it with the `zipper` cross-parse. Reads the persisted index (never a walk+match), so it shares this tier with the gist engines rather than the pure `search/` kernels. |

**Index is an accelerator, not an authority.** When a covering, fresh index is
present, `IndexSkip` elides reads of files whose trigrams cannot match; the
walk still decides the file set. `--no-index` forces the pure walk; a missing
or stale index is invisible to the user (just slower).

`defaultFileSet` here is also what the warm session uses to select its corpus,
so resident reconcile and cold walk agree on "what's in the tree."
