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

| Module        | Lifetime            | Owns                                                                                                                                                                                                                                                                                                    |
| ------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `swarm.zig`   | once per run        | eligibility, pool sizing, the oracle race, spawn/join, the trailing summary                                                                                                                                                                                                                             |
| `queue.zig`   | shared, all workers | the work-stealing spine: the directory task deque, donation, the discovered/finished counters that decide termination, `abort` — the one signal that stops every worker mid-walk when a soft output budget is met — and `walked`, the cumulative count a slow walk reports about itself (`hints.Vigil`) |
| `sink.zig`    | shared, all workers | the only place bytes reach the fd, so interleaving is impossible by construction: one mutex, whole fragments, and the byte tally the budget reads                                                                                                                                                       |
| `crew.zig`    | one per worker      | `Cfg` (everything decided before the walk) and `Worker` (arena, scratch, coalesced path buffer, held fragments, stats), the `Crew` pool that musters them and may hire mid-walk, plus the ordered `--sort` replay                                                                                       |
| `descent.zig` | per directory       | one bulk listing → ignore verdicts → child tasks, with the walk's own work donated back to the queue when the deque runs deep                                                                                                                                                                           |
| `sift.zig`    | per file            | the elision decision, the read, the match, and the render — the innermost loop                                                                                                                                                                                                                          |
| `roster.zig`  | once per run        | the callable file-set walk (`collectFileSet`) and its freshness-metadata variant                                                                                                                                                                                                                        |

## Invariants worth knowing before you edit

- **Ordering is a contract, not a preference.** Streaming order is "as found";
  `--sort`/`--sortr` holds fragments per worker and replays them in
  `crew.emitSorted`; `-l`/`--files` is explicitly order-free, which is what
  licenses the per-worker path-list coalescing. Changing when a fragment reaches
  `sink` changes observable output.
- **A worker's arena outlives its fragments.** Held records reference arena
  bytes rather than copying them, so the arena is freed after the ordered emit,
  never per file.
- **So a path charged to it is immortal, and most paths must not be.** A walked
  path is dead the moment its directory is done, which is why `descent` builds
  entry paths in the per-directory scratch `workerMain` recycles
  (`dir_scratch_retain`) and duplicates into the arena only on the three
  branches that genuinely outlive the directory: a queued child `DirTask`, a
  file deferred while the oracle loads, and a `--sort` record. Adding a fourth
  retaining branch without its own `dupe` reads recycled bytes; charging
  everything to the arena instead is correct but pays a per-entry copy for the
  whole tree, which is what this used to do.
- **The pool's width is a starting bet, not a fact.** Flags and roots cannot tell
  the 40 ms indexed scan the small macOS pool was tuned for from a `-uu` sweep of
  gigabytes of ignored artifacts, where the same pool leaves the machine idle on
  reads. So a worker that finishes a directory may hire (`Crew.consider`) once the
  walk has run past `patience_ns` **and** left a front worth widening for — the
  time gate is what keeps every interactive walk at exactly the width it measured
  best at. Widening never changes an answer: new hands take work through the same
  donation protocol a starving peer uses.
- **The elision oracle may arrive late.** Files walked before it loads are
  deferred, never blocked on, then re-judged once `Lazy.ready` flips — see
  [`../../quarry/elide.zig`](../../quarry).
- **rg parity is the acceptance test.**
  `bench/conformance/gates/parity/line_parity.sh` runs the
  whole supported flag surface through **both** engines and diffs against real
  ripgrep. No change here lands on inspection.
