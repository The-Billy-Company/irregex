# Transplant — prior art

**Referee pass: 2026-08-09, revised the same day.** Adversarial posture: the null
hypothesis is that this has been done. Every citation below is a URL that was
actually fetched and quoted from; where something is from memory and was not
verified, it says so inline. Two claims in the first pass were **wrong and are
corrected in place**, both flagged here rather than quietly edited: Bazel does
consult ctime (it added it deliberately), and "every prior resolution is a knob"
overlooked the two git mechanisms that are not.

Read this before believing `PROOF.md` §4 is an invention. The short version: the
**defect** is ours, the **tension** is thoroughly explored — one tool below argues
for the ctime leg in almost the same words `src/corpus/fresh/` does, and another
added the leg for the exact inverse reason — and the **answers already shipped**
are a config knob in three tools plus, in git, stat-only revalidation and a
capability probe. Those last two are the precedents worth building on, because an
agent-facing tool has no operator to ask. The one move §4 makes that is genuinely
unclaimed cuts both ways: it admits a forgery the ctime leg catches today, and
closes a wider one that leg is currently the *only* thing catching.

## What was searched

**Engines:** Google/Bing, then direct fetches of primary documentation.

**Query families (~25 queries):** `core.trustctime` rationale and history; git
index stat-cache fields; ctime after `tar -x` / OCI layer extraction / `rsync
-t` / `cp -p`; whether any syscall sets ctime; ccache sloppiness and CI
checkouts; borgbackup files-cache inode instability; restic parent-snapshot
change detection; "inode changed" false-dirty in content indexers; Bazel local
file digest / `FileStateValue`; zoekt shard freshness; Google Code Search
`cindex` reindex condition; Watchman/fsmonitor as a stat-cache replacement;
`--files-cache` on network filesystems.

**Read in full (fetched, quoted below):** the `git config` documentation for
`core.trustctime` and `core.checkStat`; **git commit 1ce4790 as a raw patch**, so
the motivation and the `read-cache.c` comparison are quoted from source rather
than from doc prose; the ccache manual's sloppiness table; `borg create`'s
files-cache section including its ctime-vs-mtime rationale; the `rsync(1)` man
page on the quick-check algorithm; **Bazel PR #18115** and its backport notes.

**Not verified — treat as claims, not citations.** zoekt's and `csearch`'s
freshness conditions (zoekt builds shards keyed by git object IDs, `cindex`
compares mtime — from memory, unread); restic's parent-snapshot heuristic; the
`racy-git.adoc` timings quoted below (taken from a second-hand reading of that
document, not a fetch of it). None of these carry a finding on their own.

## Neighbors

### git — stores the same tuple, and reaches the opposite conclusion

git's index is a stat cache over the working tree, and its default comparison is
the widest of anything surveyed. From
[`git config`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corecheckStat),
on `core.checkStat`:

> When missing or is set to `default`, many fields in the stat structure are
> checked to detect if a file has been modified since Git looked at it. When
> this configuration variable is set to `minimal`, sub-second part of mtime and
> ctime, the uid and gid of the owner of the file, the inode number (and the
> device number, if Git was compiled to use it), are excluded from the check […]

So git already carries **per-file ctime *and* inode** and consults both — the
exact two facts `PROOF.md` §4 wants to add to this engine's artifacts. That is the
strongest single result of this survey: the *data* in the proposed repair is
not novel, it is what git has recorded per path since the beginning.

What git does with it is the inversion. Every field is a **disqualifier**: any
mismatch, inode included, means "possibly modified, re-read the content". A
changed inode makes git *less* willing to trust the cache, where §4 makes this
engine *more* willing. Nobody surveyed uses inode inequality as evidence of anything.

**Git's comparison is an equality; ours is an ordering.** From the patch that
added the knob, in `read-cache.c`:

```c
if (ce->ce_mtime != (unsigned int) st->st_mtime)
        changed |= MTIME_CHANGED;
if (trust_ctime && ce->ce_ctime != (unsigned int) st->st_ctime)
        changed |= CTIME_CHANGED;
```

Each clock is checked against **the value recorded for that file**. This engine
checks live clocks against **one scalar for the whole corpus** — `built.ns`, a single
epoch-ns — asking `mtime >= anchor`. Nothing surveyed occupies that point, and it
has a consequence that changes §4's honesty accounting; see finding 5 below.

**Git hit our failure mode, and the primary source names our own tool class.**
The introducing commit
([1ce4790](https://github.com/git/git/commit/1ce4790bfaacba7c8ec4f0b2f8e5b0dc02a6dc42),
Alex Riesen, 2008-07-28) says why:

> A new configuration variable 'core.trustctime' is introduced to allow ignoring
> st_ctime information when checking if paths in the working tree has changed,
> because there are situations where it produces too much false positives. Like
> when **file system crawlers keep changing it when scanning and using the ctime
> for marking scanned files.**

Git's ctime escape hatch exists because of **content indexers** — the class of
tool this engine *is*. Git shipped it so a search index would stop making `git status`
lie; we need the mirror image, so an external reproducer stops making a search
index inert. (The published config text broadens this to "file system crawlers
and some backup systems", but the commit and the `git-update-index` paragraph it
adds both describe tools that *mark files processed*, and neither names a backup
product. Attribute the motivation to crawlers.)

**And the knob is not the only thing git shipped — this is where my first reading
was wrong.** Two other mechanisms in the same codebase are closer to what this
engine needs than the config variable:

- **`git update-index --refresh` is §5's mitigation, with precedent.** It
  re-proves each entry against that entry's own recorded stat, reading no
  content, and the newly written index becomes the fresh boundary — stat-only
  revalidation that advances the anchor.
  `Documentation/technical/racy-git.adoc` measures it turning a whole-tree
  suspicious `diff-files` from 1.68s into 0.02s, which is structurally our phase
  C → phase D.
- **The untracked cache chose an empirical probe over a boolean.** Facing an
  accelerator whose soundness depends on a filesystem property git cannot assume,
  git shipped `git update-index --test-untracked-cache`, which *tries the property
  and declines* rather than asking a human to assert it. That is the shape an
  agent-facing tool wants: a knob needs an operator who knows their tree came out
  of a tarball, and in a container nobody is there to set it.

### borgbackup — the same argument, written down, in a backup tool

The closest true precedent, because borg's files cache decides exactly what
this engine's freshness law decides: *may I skip reading this file's bytes?* Its
default mode is
[`ctime,size,inode`](https://borgbackup.readthedocs.io/en/stable/usage/create.html),
and its rationale is `src/corpus/fresh/README.md`'s argument almost verbatim:

> **ctime** is a rather safe way to detect changes to a file (metadata and
> contents) as it cannot be set from user space. […] **mtime** usually works and
> only updates if file contents were changed. But mtime can be arbitrarily set
> from user space, e.g., to set mtime back to the same value it had before a
> content change happened. This can be used maliciously as well as well-meant,
> but in both cases mtime-based cache modes can be problematic.

That is the `touch -r` case, independently derived, and it is decisive for one
question this dossier had to answer: **the ctime leg is not over-engineering.**
A backup tool with a decade of field exposure reaches the same conclusion from
the same premise. Any repair that simply deletes the leg is arguing against
borg, git, and our own model at once.

Borg also documents the *inode* half of the trade, from the other direction:

> **inode number:** better safety, but often unstable on network file systems […]
> such files will always be considered modified. You can use modes without inode
> in this case to improve performance, but the reliability of change detection
> might be reduced.

"Will always be considered modified" is phase C of our measurement, in borg's
vocabulary, and it surfaces to users as the FAQ entry *"I am seeing 'A' (added)
status for an unchanged file!?"*. The remedy is again a knob: `ctime,size` or
`mtime,size`. Six modes, an operator choice, no automatic discrimination.

### ccache — a named sloppiness flag for exactly this

ccache's fast path compares timestamps instead of hashing content, and the
[manual](https://ccache.dev/manual/latest.html) ships a sloppiness flag whose
entire purpose is the transplant:

> **`file_stat_matches_ctime`** — Use case: When controlling file timestamps
> manually. Effect: Ignores status change time when `file_stat_matches` is
> enabled. Trade-off: May miss some file system changes.

Third independent tool, third knob. The convergence is the finding: everyone
who has built a stat-based read-elision cache has met the ctime problem, and
every one of them has resolved it by exporting the decision to a human.

### rsync — the pole that excludes ctime by default

[`rsync(1)`](https://download.samba.org/pub/rsync/rsync.1):

> Rsync finds files that need to be transferred using a "quick check" algorithm
> (by default) that looks for files that have changed in size or in
> last-modified time.

Size and mtime; ctime and inode are not consulted. This is the design this engine
would have if the ctime leg were simply dropped, and it is a perfectly respectable
default — for a tool whose failure mode is a re-copy, not a wrong answer to a
search. rsync's escape hatch runs the *other* way (`--checksum`, `--ignore-times`)
because for rsync the cheap check is the risk and reading is the fallback. Note
also `--size-only`, which exists "when starting to use rsync after using another
mirroring system which may not preserve timestamps exactly" — clock distrust
after a reproduction, one more time.

### Bazel — the mirror image, and it *added* ctime

I asserted above, from memory and flagged as unverified, that Bazel avoids clocks
in favor of digests and has no ctime leg. That was wrong in exactly the way I
said would force a reframing, so here is the correction.

Bazel **added** ctime to its file-digest cache key in April 2023
([PR #18115](https://github.com/bazelbuild/bazel/pull/18115), backported to 5.4.1
and 6.1.2), and the reason is the sharpest possible contrast with ours:

> File digests are now additionally keyed by ctime […] this may be required for
> correctness in cases where **different files have identical mtime and inode
> number**. For example, this can happen on Linux when files are extracted from a
> tar file with fixed mtime and are then replaced with `mv`, **which preserves
> inodes.**

Read that against §4.2 and the two cases turn on the same two questions with
opposite answers:

| | does mtime carry information? | does the inode change? | so the discriminator is |
|---|---|---|---|
| Bazel's bug | **No** — `--mtime` flattened to a constant by reproducible-build tooling | **No** — `mv` preserves it | ctime, the only field left |
| this engine's bug | **Yes** — a faithful reproduction restores the true mtime | **Yes** — extraction mints new inodes | the inode; ctime is the useless field |

So Bazel is not counter-evidence to §4, and citing it as such would be as lazy as
my original claim that it agreed. It is the same analysis reaching the opposite
conclusion from the opposite inputs — which is the best available evidence that
the analysis is the right one to be doing.

It also answers the strongest objection to §4.3 directly: **the failure Bazel had
to fix cannot occur under our predicate.** Their bad case is an inode that
*persists* across a content change, and §4.3 refuses to elide unless the inode
*differs*. Their fix and ours are compatible; they simply had the other half of
the field available.

### Content addressing — the principled answer this engine cannot afford

ccache's default mode and zoekt's git-object-keyed shards sidestep clocks by
identifying files by content digest (zoekt still *unverified*, see above). It is
the correct answer and it is unavailable here: computing a digest requires reading
the file, and reading the file is the exact cost the elision exists to avoid. Any
content-addressed design for this engine collapses into "always read", which is
phase C — the defect, chosen deliberately.

**Nor does birth time help**, which is the first thing anyone proposes. `ctime`
is unforgeable but moves on extraction; `st_birthtime` sounds like the stable
alternative, but it is stamped when the *inode* is created, so for a transplanted
file it **is** the extraction instant — numerically the same useless answer as
ctime, and read-only on every platform that reports it.

The same objection retires the other obvious idea, an `fsmonitor`/Watchman-style
change feed: it requires a resident daemon that observed the writes, and a
freshly extracted container has no such observer by construction.

## The finding

1. **The ctime leg is well-founded.** borg derives it independently, git defaults
   to trusting it, Bazel added it. Deleting it is not a repair.
2. **The transplant failure is known, in at least four tools, under four names**
   (`core.trustctime`, `--files-cache` inode instability,
   `file_stat_matches_ctime`, and Bazel's inverse). Our contribution is not
   noticing it; it is measuring what it costs a *search* index and observing that
   in a container it is not a corner case but the only case.
3. **Not every prior resolution is a knob — and that corrects my first reading.**
   Three tools ship one, but git also ships `update-index --refresh` (stat-only
   revalidation that advances the boundary, which is §5) and
   `--test-untracked-cache` (probe the property, decline if absent). An
   agent-facing tool has no operator to ask, so *those* are the precedents to
   build on, not the config variable.
4. **§4's discriminator is unclaimed, and inverted from every tool that records
   an inode.** git and borg both require it to be *equal* to trust the cache; §4
   requires it to be *different*. The inversion is sound for the band §4 restricts
   itself to, and Bazel's 2023 bug — an inode that *persisted* across a content
   change — is precisely the case §4.3 still refuses. But absence of prior art
   here is not evidence of a gap in the field; nobody else's cache had to work
   with no operator present.
5. **The repair is a trade, not a pure concession — §4.4 undersells its own
   position.** This follows from the equality-vs-ordering difference above. This
   engine's mtime leg is today *strictly weaker* than git's or rsync's:
   `mtime >= anchor` admits **any** sufficiently old value, so
   `touch -t 200001010000` defeats it outright and only the ctime leg saves us. Under §4.3, mtime must **equal the
   recorded nanosecond** — so a forger who today needs only a plausibly-old
   timestamp would then need the exact one, plus the exact size, plus a fresh
   inode. §4.4 presents the change as purely admitting a new forgery. It also
   closes a wider one, and the dossier should say so in both directions.

## Gaps worth closing before any external claim

- **Patents:** not searched. Backup/dedup vendors patent aggressively around
  change detection, so the negative here is weak.
- **zoekt and `csearch`:** still asserted from memory. Neither's freshness
  condition was read at source level, and it is unknown whether `csearch`'s index
  format records per-file stat data at all.
- **A ctime-preserving unpack path:** there is strong structural reason to think
  no container runtime can have one — OCI tarballs carry no ctime field, and no
  syscall sets it — but that is absence of evidence, not proof.
- **Time Machine** was my original guess for git's motivating case and is
  **unsupported**: the confirmed macOS ctime-churn triggers in the git archives
  are `revisiond`, Xcode metadata writes, and hard-linking. Do not repeat it.

Closed since the first pass: git's rationale (read from commit 1ce4790 itself,
not doc text) and Bazel (read from PR #18115 — and it was the opposite of what I
asserted, so the section is rewritten rather than patched).
