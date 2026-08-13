# Transplant — how the claim dies

Two separable claims, so two falsification strategies. The defect claim (§1) is
about a measurement and dies to a measurement. The repair claim (§2) is about a
guarantee and dies to an adverse case.

The existing law already has adverse tests — `src/corpus/fresh/fresh_test.zig`
writes real files and drives real syscalls to prove an ordinary write is
surfaced, that an mtime rewound behind the anchor is still surfaced *through*
ctime, and that a rename over an indexed path is surfaced;
`src/corpus/tree/bulkstat_test.zig` pins the predicate's boundary exhaustively.
Everything below belongs beside those, not in a new suite.

## 1. Falsifying the defect

The defect claim is: *after a reproduction, a warm query costs what an unindexed
query costs.*

It dies if the two numbers separate. So the harness must always report the
`--no-index` control **from the same phase**, never the warm number alone and
never a control measured before the reproduction. A phase whose control is
missing proves nothing, because the absolute cost of a query moves with page
cache warmth, corpus size, and pattern selectivity; only the ratio within one
phase is a claim.

Three things would falsify or narrow it:

- **A platform where the reproduction does not move ctime.** The claim rests on
  POSIX requiring `utimensat(2)` to mark ctime. A filesystem that fabricates or
  caches metadata (NFS with attribute caching, a FUSE layer) may not, and the
  law already declares itself advisory there. The harness should therefore state
  the filesystem it ran on rather than implying universality.
- **A cover set that moves between phases.** The mechanism claim is that the
  prefilter is untouched and the freshness union is what widens. If the cover-set
  column differs across phases, the diagnosis in PROOF.md §2.2 is wrong even if
  the timings hold, and the dossier needs rewriting rather than patching.
- **A corpus small enough that reading it all is free.** At 15,013 files the
  effect is 9.6× CPU. On a hundred files it is noise. The harness should refuse
  to publish a ratio below a corpus floor rather than report a flattering one.

### The reproduction must stay honest

`os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))` — writing back the file's own
mtime — is used deliberately in place of a real `tar -x`, because it is the same
syscall with the same argument and it isolates the one variable. That is a
strength only as long as it stays checked: the harness should also run once
against a genuine round-trip (`tar -cf … && tar -xf …` into a fresh directory,
or a real image build) and assert the clock relationship it produces matches the
simulated one. If those two ever disagree, the simulation is the thing that is
wrong.

## 2. Falsifying the repair

The repair claim is: *the inode discriminator elides a transplant while keeping
every case the ctime leg was added for.*

It dies to any case below that elides when it must read. Each is a real-syscall
test, not a predicate unit test, because the point is what the filesystem
actually reports.

| case | construction | must |
|---|---|---|
| **mtime rewind** | write new bytes in place through an existing fd, then `utimensat` mtime back below the anchor | **read** — same inode, so the discriminator refuses |
| **same-size rewind** | as above, with content of identical length | **read** — this is the case the size check alone would miss, and the inode is what catches it |
| **transplant** | `cp -p` / `copy2` the whole tree, or extract a tar of it | **elide** — new inode, recorded size and mtime both match |
| **transplant plus one edit** | reproduce, then modify one file | read exactly that file, elide the rest |
| **replacement with a forged mtime** | write a new file with the same length, `utimensat` its mtime to the recorded value, `rename` over the indexed path | **elide, and that is the documented hole** — the test exists to pin that we know, so a future reader finds an assertion rather than a surprise |
| **no recorded metadata** | an index built before the format carried `(size, mtime, ino)` | read — a missing record is never evidence |
| **metadata unavailable** | a filesystem that declines to report ino or size | read — same posture as a declined clock |
| **inode reuse** | delete an indexed file, create another that lands on the same inode number with a matching size and a forged mtime | read — the inode being *equal* is never on its own a reason to elide; only a *changed* inode is affirmative evidence |

The last row is the one worth stating loudly, because it inverts the intuition:
the discriminator uses inode *inequality* as evidence of a copy. Equality is
never evidence of anything, since a filesystem may reuse a number freely.

### 2.1 The two cases the prior-art pass added

Both come out of [`PRIOR_ART.md`](PRIOR_ART.md), and neither was in the table
above until a real precedent named it. The first is a *win* the repair has to
prove it earns; the second is someone else's shipped bug, which our predicate
claims it cannot have.

| case | construction | must |
|---|---|---|
| **the any-old-mtime forgery** | rewrite an indexed file in place, then `utimensat` its mtime to something far *below* the anchor (`touch -t 200001010000`) rather than to the recorded value | **read** — and it must be the *recorded-mtime* comparison that catches it, not the ctime leg. Assert this with ctime disregarded, or the test passes for the wrong reason |
| **Bazel's case: a persistent inode across a content change** | write new content of identical length into a *new* file and `mv` it over the indexed path on a filesystem where that reuses the inode — or rewrite in place with a flattened, constant mtime shared by several files | **read** — the inode did not change, so the discriminator refuses, which is exactly the correctness bug Bazel had to add ctime to fix |

The first is the falsifier for the claim in `PROOF.md` §4.4 that this is a trade
rather than a concession. It **fails against the code as it stands today**: right
now that file's rewound mtime satisfies `mtime < anchor` and only ctime saves the
read, so a test written against the current engine with ctime disregarded proves
the weakness before the repair exists. Write it first, watch it fail, and it stops
being an argument and becomes a measurement.

## 3. What must not regress

- **The four-command staleness demo** in
  [`src/corpus/fresh/README.md`](../../src/corpus/fresh/README.md) — where this
  engine answers `b.txt c.txt` while csearch answers nothing and zoekt answers
  `a.txt` — is the law's headline claim and must produce byte-identical output
  before and after. It is the cheapest possible check that the repair did not
  buy speed with correctness.
- **The bulk drain's throughput.** If the extra attributes make the walk slower
  than the pruning they enable, the repair is a loss on a tree that has *not*
  been transplanted, which is the common case. The measurement that decides this
  is the walk in isolation, not a whole query: profile the drain, not the suite.
- **The certificate.** Whatever the repair wins has to land in
  `bench/certificate/` so it cannot silently regress, and whatever the drain
  costs has to land there too. A one-sided entry is how a regression hides.
