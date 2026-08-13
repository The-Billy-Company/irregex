# `research/transplant/` — the index that outlives being copied

A corpus can arrive without being written. An OCI image layer extraction, `tar
-x`, `rsync -t`, `cp -p`, a restore from backup: all of them reproduce content
byte-for-byte onto brand-new inodes, and all of them restore mtime because that
is part of copying a tree faithfully. None of them can restore ctime, because the
kernel owns it.

The engine's freshness law reads both clocks and disqualifies a file if *either*
has reached the build anchor. So a transplanted corpus reads as entirely changed,
its persisted index elides nothing, and the accelerator is inert — while an index
status readout reports it healthy. Containers make this the normal case rather
than a corner: an image layer is a reproduction by construction.

- **[`PROOF.md`](PROOF.md)** — the measured defect (a warm query and an
  explicitly unindexed control landing on the same 0.77 CPU-seconds, with the
  trigram cover set unchanged at 403/15,013 to show the prefilter is not what
  failed), why the model's own assumption list could not have caught it, and the
  repair it calibrates: an inode discriminator for the one band where a
  transplant and an mtime rewind are indistinguishable by clocks.
- **[`PRIOR_ART.md`](PRIOR_ART.md)** — who has stood at this exact tension
  before, and it is a crowd. borgbackup derives the ctime leg independently and in
  nearly our words; git records per-file ctime *and* inode already, and shipped its
  ctime escape hatch because of **content indexers** — the class of tool this
  engine belongs to; Bazel added ctime for the precise inverse reason (a `tar`
  that flattened mtime plus an `mv` that *kept* the inode), a case §4.3 still
  refuses. Two findings that changed the repair: git's own answer was not only a
  knob but stat-only revalidation plus a capability probe, and because this engine
  compares clocks against one corpus-wide scalar instead of per-file recorded
  values, recording an mtime *tightens* a guarantee at the same time as it loosens
  another.
- **[`TESTING.md`](TESTING.md)** — how the claim dies. The reproduction is
  simulated by the same `utimensat(2)` an extractor makes, so the adverse cases
  are the ones that must keep reading live: an in-place write with a rewound
  mtime, a same-size replacement, a corpus whose clocks a filesystem fabricates.

## Status

The defect and its measurement are done and reproducible. The repair in
`PROOF.md` §4 is a design: nothing in the engine implements it yet, and the one
part of it that is a performance claim rather than a correctness argument — that
Darwin can pack the inode and size into the bulk drain it already makes — is
explicitly marked as needing measurement rather than assertion.

§4.5 scopes what building it means, and it is bigger than the predicate: the
decision has to move from `fresh/sweep.zig` (which promises to know nothing about
the index) up into `fresh.zig` (which holds the index), the sweep's output widens
from a path to a small live-facts record, and eight call sites across six
packages share the scalar-anchor contract being changed. Worth doing once,
properly; not worth half-landing.

The mitigation that needs no engine change (re-anchor once, inside the container,
after extraction) is described in §5 and is what unblocks a deployment today. It
is live for the Billy AI service: `reanchor_shipped_index()` in
`tools/code/source.py`, spawned off the boot path, gated on the deployment's
explicit source pin so a developer's shared checkout is never rebuilt under them.

## Where the code and evidence live

The law is [`../../src/corpus/fresh/`](../../src/corpus/fresh/README.md); the
predicate is `needsLiveRead` in
[`../../src/corpus/tree/bulkstat.zig`](../../src/corpus/tree/bulkstat.zig); the
metadata the walk currently reports is `Entry` in
[`../../src/corpus/tree/sheaf.zig`](../../src/corpus/tree/sheaf.zig). The
existing adverse tests for the law are `fresh_test.zig` and
`../tree/bulkstat_test.zig`, which is where the cases in `TESTING.md` belong.
