# Transplant — proof and measurements

A corpus that arrives by being *reproduced* — `tar -x`, an OCI image layer
extraction, `rsync -t`, `cp -p`, a restore from backup — carries content
identical to the tree it was copied from and inodes that are all new. The claim
here is that gist's freshness law reads such a corpus as *entirely changed*, so
its persisted index elides nothing and the accelerator is inert while reporting
itself healthy; that this is not a tuning problem but a consequence of one leg of
`needsLiveRead`; and that it is fixable without giving up the property that leg
exists to defend.

This is a defect dossier in the shape of [`pincer/`](../pincer/PROOF.md): the
measured defect first, then the repair it calibrates. §1–§3 are measured. §4 is a
design with its cost and its new exposure stated; nothing in §4 has been built
yet, and the dossier is deliberately readable in that state.

## 1. The setting

[`src/corpus/fresh/`](../../src/corpus/fresh/README.md) is the freshness law:
*index accelerates, never overrules*. A build stamps an **anchor** — a
wall-clock instant — before reading the corpus, and a later query may serve a
file from the index only if that file proves unchanged since the anchor. One
predicate carries it:

```zig
// src/corpus/tree/bulkstat.zig
pub fn needsLiveRead(anchor_ns: i128, mtime_ns: ?i128, ctime_ns: ?i128) bool {
    const mtime = mtime_ns orelse return true;
    const ctime = ctime_ns orelse return true;
    return mtime >= anchor_ns or ctime >= anchor_ns;
}
```

Two clocks, either one disqualifying. The `mtime` leg is the ordinary case. The
`ctime` leg is there for one specific reason, stated in the package's own model:

> A completed ordinary write advances the file's reported ctime to the anchor
> tick or later […] which is what closes the ordinary preserved-mtime hole:
> `touch -r old new` rewinds mtime and *advances* ctime.

So `ctime` is the tamper-resistant leg. No portable call rewinds it, and that is
precisely its value: an mtime is an argument to `utimensat(2)` and therefore a
claim the filesystem will repeat back without checking, while a ctime is a fact
the kernel stamps.

The per-file identity in the index is the **path**; the artifacts record no
per-file metadata at all. The anchor is a single scalar for the whole build, and
`needsLiveRead` is the only thing consulted per file. That is the fact §4 turns
on.

## 2. The defect

### 2.1 A reproduction restores mtime and cannot restore ctime

Every tool that reproduces a tree faithfully restores mtime, because mtime is
part of what "faithfully" means. It does so with `utimensat(2)`, and POSIX
requires that call to mark `st_ctime` for update. There is no flag, no
privilege, and no second call that sets ctime to an older value: the kernel owns
it. So a reproduced file lands with

```text
mtime = the original's mtime   (restored, so < anchor)
ctime = the instant of extraction  (>= anchor, always)
```

The two legs of `needsLiveRead` are an `or`, so the ctime leg alone disqualifies
the file. This holds for **every file in the corpus simultaneously**, because
they were all extracted in the same pass.

### 2.2 The union is then the whole corpus

The trigram prefilter still works exactly as designed — it is not what fails.
The freshness sweep runs beside it and unions in every file that
`needsLiveRead` flags, and after a reproduction that is all of them. The
measured shape below shows both halves at once: a cover set of **403 files out
of 15,013**, and a query that nonetheless costs what reading all 15,013 costs.

### 2.3 It is invisible

`gist status` reports the inert index as current — `built N s ago (freshness
anchor set — new/edited files are folded in per query)`. Nothing in a container
would tell an operator that "folded in per query" had quietly come to mean
*every file, every query*. The artifact is present, bound to the right tree,
structurally valid, and useless.

### 2.4 Why the model's own assumption list did not catch it

[`fresh/README.md`](../../src/corpus/fresh/README.md) enumerates what sits
outside the local-filesystem model, and a reproduction is not on the list. That
is not an oversight in the enumeration — it is a consequence of what the list is
*for*. Every row there is a case where the index might answer from stale bytes,
because that is the failure the law is written to prevent. A wholesale ctime
advance is the opposite direction: it is *conservative*, so by the law's own
terms nothing is wrong. The index over-reads, and over-reading is always
correct.

The gap is that the package prices conservatism as a rounding error. Its
headline is that "a days-old index is still correct, just slightly less
pruning". Under a transplant the same sentence is still true and means something
else entirely: still correct, and pruning *nothing*, permanently, with no event
that would ever heal it — the corpus is immutable after extraction, so the
clocks never move again.

Containers are the case that makes this matter, and they are not a corner: an
image layer is a reproduction by construction, so **gist's persisted index
cannot accelerate anything in any container it ships in**, which is every
deployment target it has.

## 3. Measurement

226.5 MB / 16,373 files, a tracked-source snapshot of the Billy monorepo, copied
with `shutil.copy2` (new inodes, preserved mtime — a reproduction). Corpus as
gist counts it after skips: 15,013 files. Query `pgxpool\.\w+`, five runs,
median CPU and best wall, one isolated `GIST_DIR`, `GIST_NO_AUTOSERVE=1` so no
resident session confounds it. Harness: [`reproduce.py`](reproduce.py) — it
copies the tree you point it at, so it never touches the index of the tree it
measured (see [TESTING.md](TESTING.md)).

The reproduction is simulated by `os.utime(p, ns=(atime, mtime))` — the file's
*own* mtime written back. That is not an approximation of what an extractor
does; it is the identical syscall carrying the identical argument, which is the
whole reason the ctime moves.

| phase | cover set | warm CPU | `--no-index` CPU | wall (warm) |
|---|---|---|---|---|
| B · index built on this filesystem | 403 / 15,013 | **0.081s** | 0.414s | 0.047s |
| C · same index, post-reproduction | 403 / 15,013 | **0.775s** | 0.772s | 0.208s |
| D · re-anchored where it is queried | 403 / 15,013 | **0.110s** | — | 0.026s |

Read the middle row against its own control, not against the row above it: in
phase C the indexed query costs 0.775 CPU-seconds and the explicitly unindexed
control costs 0.772. They are the same number. The index is not degraded, it is
absent.

Phase B is what a developer's machine measures and therefore what gets believed:
a 5.1× CPU win. Phase D shows the win is real and recoverable — re-anchoring on
the filesystem the queries run against restores it — at a one-shot cost of 1.62s
wall / 2.84 CPU-s to rebuild.

Two honest notes on the numbers. Phase A (no index, cold page cache, 2.20 CPU-s)
is reported by the harness but excluded from the table: it measures cache warmth
as much as the index, and the within-phase controls are the comparison that
carries the claim. The cover set is identical in all three phases, which is the
positive evidence that §2.2 is the mechanism — had the prefilter been what
regressed, that column would move.

The claim CPU-seconds carry that wall time does not: the AI container this was
found in shares a vCPU with four others, so the difference between 0.081 and
0.775 is not 0.7 seconds of one request, it is what multiplies under contention
into the 30-second subprocess timeout that surfaced the bug.

### 3.1 Confirmed on a second corpus by the committed harness

The table above came from a hand-driven run. `reproduce.py` was then written to
be re-runnable by anyone and pointed at the *whole* tracked source set — 23,480
files, 21,265 in-corpus after skips, ~40% larger than the first — as an
independent check that the shape is the mechanism and not one corpus's accident:

| phase | cover set | warm CPU | `--no-index` CPU |
|---|---|---|---|
| B · built here | 416 / 21,265 | **0.176s** | 1.854s |
| C · post-reproduction | 416 / 21,265 | **1.550s** | 1.546s |
| D · re-anchored | 416 / 21,265 | **0.143s** | — |

The ratio moved with the corpus (10.5× here against 5.1× before, and phase A's
cold walk spread 1.66–4.82 CPU-s, which is why it stays out of both tables). The
two things that did **not** move are the two the claim is made of: phase C's warm
query and its own unindexed control land on the same number to three decimal
places, and the cover set is identical in every phase of both runs. A larger
corpus makes the defect cost more, never less.

## 4. The repair — design, not yet measurement

### 4.1 Two events present identically under the clocks

The discriminating question is narrow, because it only arises in one band. When
`mtime >= anchor` the file is disqualified for the ordinary reason and nothing
new is needed. When `ctime < anchor` both clocks predate the build and the file
is already elided. The only interesting band is

```text
mtime < anchor <= ctime
```

and exactly two things produce it:

- **A transplant.** New inode, mtime restored to the recorded value, content
  identical.
- **An mtime rewind.** In-place write, then `touch -r` (or any `utimensat`)
  pushing mtime back below the anchor. Same inode, content different. This is
  the case the ctime leg exists to catch, and it must keep being caught.

The clocks cannot separate them, which is why the current predicate — reading
only clocks — must treat the band as dirty.

### 4.2 The inode is the discriminator, and it is free

An in-place write keeps the inode. A transplant replaces every one of them. So
`ino != recorded_ino` is affirmative evidence of a reproduction rather than a
rewrite, and it is evidence the clocks do not contain.

An editor that saves by writing a temp file and renaming over the target also
changes the inode — but that path leaves mtime at the save instant, so it never
enters the band at all and is disqualified by the first leg, as it is today.

This requires the artifacts to record per-file `(size, mtime, ino)`, which they
currently do not (§1). At ~32 B per path that is ~480 KB against a 29 MB index
on this corpus: not a consideration. The walk side is the part that needs
measuring rather than asserting — `Entry` in `src/corpus/tree/sheaf.zig` carries
`name, is_dir, is_file, mtime_ns, ctime_ns`, and Darwin's `getattrlistbulk(2)`
can pack `ATTR_CMN_FILEID` and `ATTR_FILE_DATALENGTH` into the same call, so the
expected cost is wider records rather than extra syscalls. "Expected" is doing
real work in that sentence; the bulk drain is the hot path of the walk, and the
per-entry cost of asking the kernel to resolve two more attributes has to be
measured before this is claimed as free.

### 4.3 The predicate

```text
needsLiveRead(anchor, live, recorded):
    live.mtime >= anchor            -> read      # ordinary write; unchanged today
    live.ctime <  anchor            -> elide     # both clocks predate the build
    recorded == null                -> read      # nothing to re-prove it against
    live.ino != recorded.ino
      and live.size  == recorded.size
      and live.mtime == recorded.mtime -> elide   # a transplant
    otherwise                       -> read
```

Note what the elision rests on: not a clock comparison, but three recorded facts
re-proven against the live inode. The anchor stops being the only evidence the
index carries about a file.

### 4.4 What this newly admits

Stated plainly, because the point of the dossier is that the trade is visible.

Today, a file that is *replaced* (new inode) with content of the same size and
an mtime forged to match the original's, is caught by ctime. Under the repair it
is elided, and the index answers from stale bytes. The forgery has to match the
recorded mtime to the nanosecond and the recorded size exactly, so it is
deliberate, not accidental — but it is a real narrowing of the guarantee, in the
same family as the "path reuse" row the model already documents as outside
itself.

What is *not* given up: the `touch -r` hole the ctime leg was added for stays
closed, because an in-place write keeps its inode and fails the discriminator.
That is the whole reason to prefer this over the obvious alternative of a
`--trust-mtime` style knob, which would reopen it wholesale.

**And a wider hole closes, which the paragraphs above missed.** Recording a
per-file mtime does not merely cost a guarantee, it buys one, because the current
mtime leg is an *ordering* test against a single corpus-wide scalar rather than an
equality against a recorded value. `mtime >= anchor` admits **any** sufficiently
old timestamp, so today `touch -t 200001010000` on a rewritten file satisfies the
mtime leg outright and the ctime leg is the only thing standing. Under §4.3 the
live mtime must equal the *recorded* nanosecond — so an attacker who currently
needs merely a plausibly-old timestamp would need the exact one, plus the exact
size, plus a fresh inode.

That is the honest accounting, in both directions: the repair narrows one
guarantee (a same-size replacement with a nanosecond-exact forged mtime) and
tightens another (any-old-mtime becomes exact-mtime). It is a trade, not a
concession — which is a stronger position than this section originally claimed,
and it is the argument to lead with. [`PRIOR_ART.md`](PRIOR_ART.md) finding 5 is
where it came from: no surveyed tool compares clocks the way we do, and being the
outlier there is what made the weakness invisible.

Two consequences for whoever builds it, both from
[`src/corpus/fresh/fresh_test.zig`](../../src/corpus/fresh/fresh_test.zig), which
turns out to have written this section's argument down first.

**The engine's own tests corroborate the tightening.** The mtime-rewind test says
it outright — *"mtime really is behind the anchor, so ctime is the only reason this
file can still be surfaced"* — which is finding 5 stated by the code under test,
before any of this survey existed.

**And they pin two attacks that wear the transplant's exact clock signature.** The
rewind test and the rename test both assert `mtime < anchor`, `ctime >= anchor`,
and that the file is surfaced — the same three facts §2 measures on an extracted
tree. That is the defect restated as a feature, and it is why the repair cannot be
a clock change: nothing in those three facts separates a copy from either attack.
The inode does, one way each — the in-place rewind *keeps* its inode and is
refused, the rename brings a *new* one and is refused instead by the recorded
size (22 bytes of `COMPLETELY OTHER BYTES` against 25 of `the bytes the index
knows`). So under §4.3 the rename test would pass **on the size leg alone**, where
today it passes on ctime. Anyone implementing this should widen it to equal-length
content so it keeps testing what its name claims, and neither test may be
"adjusted until the new code passes": they encode today's contract deliberately,
so touching them is a **spec change that must cite this dossier**.

### 4.5 Where the decision has to live — the part that is a refactor

§4.3 reads like an edit to one function. It is not, and the reason is a property
of the package worth stating before anyone starts.

`fresh/sweep.zig` is deliberately *pure mechanism*: its own header promises it
"knows nothing of doc-ids, trigram candidates, the persisted index" — and yet it
is where the predicate is applied, at both the bulk and the portable leg. A
recorded fact is by definition index knowledge, so the repair cannot be dropped
into the sweep without inverting the layering the package is built on.

The shape that fits is to move the *decision* up and leave the *observation*
down: the sweep reports each candidate's live `(path, size, mtime, ino)`, and
`fresh.zig` — which already holds the `Persisted` handle — decides. That is a
better factoring than today's on its own terms (mechanism observes, policy
decides), and it means the sweep's output type widens from `[]const u8` to a
small record, which is the largest single mechanical edit in the job.

Two more facts about the blast radius, from reading it rather than guessing:

- **It is eight call sites across three artifact families**, not one. The
  trigram overlay (`fresh.zig`, `sweep.zig`), the content shard
  (`index/content/shard.zig`), the phantom treemap, the elide oracle
  (`cold/quarry/elide.zig`), the swarm descent, and the resident reconcile each
  compare live clocks against a scalar anchor. "The anchor stops being the only
  evidence the index carries" is therefore a change to a contract six packages
  share — which is the strongest argument for doing it once, properly, rather
  than as a local patch in the overlay that leaves five other paths still
  reading every transplanted file.
- **`RawStat` already carries `size`; nothing anywhere carries `ino`.**
  `corpus/read/inode.zig` projects `dev, mode, size, kind, birthtime, mtime,
  ctime` — despite the filename, the inode *number* is the one field the
  projection never asked for. So the walk-side cost in §4.2 is one new attribute
  on Darwin's bulk call and one new field on two structs, and the estimate can
  be trusted that far; what remains unmeasured is what asking
  `getattrlistbulk(2)` for it does to the drain.

### 4.6 Diagnostics are part of the repair

§2.3 is half the defect. A `gist status` that has the anchor and walks the tree
anyway can say *"anchor predates N of M files — pruning disabled"*, and that line
is what turns this class of failure from invisible into obvious. It should land
whether or not the predicate changes.

## 5. The mitigation, and why it is not the fix

Phase D is available today with no engine change: run `gist index` once, inside
the container, after the filesystem the queries will run against exists. The
anchor is then stamped past the extraction and everything works.

That is worth shipping immediately — it is one boot-time action and it recovers
the whole win. It is not the fix, for three reasons: it costs a full re-read of
the corpus (1.62s wall / 2.84 CPU-s here) to establish something the bytes on
disk already prove; it has to be remembered separately by every deployment that
ever ships a prebuilt index; and it leaves `gist index`-at-image-build-time —
the obvious, documented, apparently-correct thing to do — as a silent no-op.
An accelerator whose documented setup path yields nothing is a defect in the
accelerator.
