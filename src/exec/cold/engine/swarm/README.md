---
doc_radar:
  counts:
    - description: "seven modules — the face plus its six stages"
      glob: pkg/kernels/irregex/src/exec/cold/engine/swarm/*.zig
      equals: 7
  sentinels:
    - description: "the plane's whole published surface is two functions; everything else is reached through them"
      file: pkg/kernels/irregex/src/exec/cold/engine/swarm/swarm.zig
      contains: ["pub fn eligible", "pub fn run"]
    - description: "the callable file-set walk stays a peer entry point, not a search with its output suppressed"
      file: pkg/kernels/irregex/src/exec/cold/engine/swarm/roster.zig
      contains: ["pub fn collectFileSet"]
    - description: "one queue owns discovery, donation, and the abort that makes a soft output budget stop the walk"
      file: pkg/kernels/irregex/src/exec/cold/engine/swarm/queue.zig
      contains: ["pub fn donate", "pub fn abort", "pub fn noteDiscovered"]
---

# exec/cold/engine/swarm — the fused work-stealing pass

One walk that also reads and also matches. The serial engine descends the tree,
then reads, then matches; this plane does all three in a single pass per file,
because macOS's `getattrlistbulk` hands back each entry's metadata beside its
name — so by the time a worker knows a file exists it already knows whether the
elision oracle can skip it, and opening it is the next instruction rather than
the next phase.

That fusion is the whole reason the plane exists, and it is why the modules below
are stages of one pipeline rather than independent services. They are split by
**lifetime**, not by flag: what is decided once per run, what is shared by every
worker, what is private to one worker, what happens per directory, what happens
per file.

## The published surface

Two functions, both in `swarm.zig`:

- **`eligible`** — may this flag set take the fused path at all? A conservative
  yes/no over the parsed argv. Answering no is never an error; serial produces
  the same bytes.
- **`run`** — the lifecycle: size the pool, race the elision oracle's load
  against the walk, spawn, join, then emit whatever the ordering contract held
  back.

`roster.zig` adds a third, `collectFileSet`, for callers that want the file set
this walk _would_ search without searching it (the resident session's corpus
reconcile). It is a peer entry point that shares the walk, not a search run with
its output suppressed — a distinction that matters because suppressed output is
how a walk quietly grows a dependence on the emitter.

## The stages

| Module        | Lifetime            | Owns                                                                                                                                                                                                                  |
| ------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `swarm.zig`   | once per run        | eligibility, pool sizing, the oracle race, spawn/join, the trailing summary                                                                                                                                           |
| `queue.zig`   | shared, all workers | the work-stealing spine: the directory task deque, donation, the discovered/finished counters that decide termination, and `abort` — the one signal that stops every worker mid-walk when a soft output budget is met |
| `sink.zig`    | shared, all workers | the only place bytes reach the fd, so interleaving is impossible by construction: one mutex, whole fragments, and the byte tally the budget reads                                                                     |
| `crew.zig`    | one per worker      | `Cfg` (everything decided before the walk) and `Worker` (arena, scratch, coalesced path buffer, held fragments, stats), plus the ordered `--sort` replay                                                              |
| `descent.zig` | per directory       | one bulk listing → ignore verdicts → child tasks, with the walk's own work donated back to the queue when the deque runs deep                                                                                         |
| `sift.zig`    | per file            | the elision decision, the read, the match, and the render — the innermost loop                                                                                                                                        |
| `roster.zig`  | once per run        | the callable file-set walk (`collectFileSet`) and its freshness-metadata variant                                                                                                                                      |

## Invariants worth knowing before you edit

- **Ordering is a contract, not a preference.** Streaming order is "as found";
  `--sort`/`--sortr` holds fragments per worker and replays them in
  `crew.emitSorted`; `-l`/`--files` is explicitly order-free, which is what
  licenses the per-worker path-list coalescing. Changing when a fragment reaches
  `sink` changes observable output.
- **A worker's arena outlives its fragments.** Held records reference arena
  bytes rather than copying them, so the arena is freed after the ordered emit,
  never per file.
- **The elision oracle may arrive late.** Files walked before it loads are
  deferred, never blocked on, then re-judged once `Lazy.ready` flips — see
  [`../../quarry/elide.zig`](../../quarry).
- **rg parity is the acceptance test.** `bench/gates/line_parity.sh` runs the
  whole supported flag surface through **both** engines and diffs against real
  ripgrep. No change here lands on inspection.
