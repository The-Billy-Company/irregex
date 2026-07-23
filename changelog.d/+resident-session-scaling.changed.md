The resident `gist serve` daemon now scales across the coworker fleet and the
largest corpora without regressing warm latency or the parity contract
(`resident == gist --no-index == rg`):

- **Concurrent warm queries.** The poll thread stays the sole connection owner
  but now dispatches `query`/`query_ext` frames to a persistent worker pool
  (`min(cpu/2, 8)`, `GIST_SERVE_WORKERS` override, `serve.zig`): an in-flight
  query leaves the poll set, its worker owns the fd and writes the response
  (incl. `chunk_fd`) directly, and a self-pipe wakeup re-registers the fd on
  completion — so one slow scan no longer stalls every other client's
  clean-window probe. `hello`/`status`/`ping`/`changed`/`shutdown` stay inline;
  the reconcile/abort counters the poll thread samples are now atomic. The
  session rides the `ward` reader/writer discipline, so readers answer in
  parallel and only a reconcile takes the writer lease.

- **Shard-backed resident mirror.** `corpus.load` is now a two-tier byte store
  (`session/corpus.zig`): an unchanged member binds its bytes to the persisted
  `content.shard` mmap (zero heap, page-cache-evictable) and only a
  changed/new/binary/oversize/BOM-carrying doc — or the whole corpus when no
  shard is on disk — heap-reads. Resident heap drops from O(corpus) to
  O(churn + exceptions) with byte-identical ingest (full body, BOM/UTF-16
  decode, whole-body first-NUL offsets, empty docs dropped); no shard ⇒
  fail-open to the old full-heap mirror.

- **Linux exact scoped reconcile.** The inotify backend realpaths its roots and
  `note`s each changed path into the dirty log (unmapped wd / malformed record /
  `Q_OVERFLOW` ⇒ doubt), arming exactness on case-sensitive roots
  (`FS_IOC_GETFLAGS`/`FS_CASEFOLD_FL` gates a casefolded root back to coarse).
  Linux now reconciles O(changed) like macOS FSEvents instead of always walking
  the tree.

- **Non-ASCII paths scope too.** The `delta` resolver drops its "any byte ≥ 0x80
  ⇒ needs_full" gate: `realpath` canonicalizes macOS case + NFC/NFD aliasing to
  the on-disk spelling, so non-ASCII events resolve to normal
  `file`/`subtree`/`gone` verdicts. The one residual hazard — a stale
  normalization/case TWIN of a path the batch never named — is retired by a
  session-side sweep of the (almost always empty) set of non-ASCII corpus keys
  through `keyIsCurrent`, O(changed + |non-ASCII keys|). Adversarial
  `scoped_test.zig` cases (case-rename, NFC↔NFD twin, delete-then-recreate under
  another normalization) assert scoped answers stay oracle-exact.
