# `corpus/index/phantom/` — the phantom walk snapshot

`tree.map` is the persisted directory-membership snapshot behind gist's
**phantom walk**: instead of re-enumerating ~5k directories with
`openat`+`getattrlistbulk`+`close` on every cold query (the syscall floor that
dominates walk-bound shapes like `-g`/`-t` filters), a query proves each
recorded directory unchanged with **one `lstat`** — POSIX bumps a directory's
mtime/ctime on any membership change — and serves its child list straight from
the mapping. Only directories whose clocks moved (or that the build never
descended and the live ignore verdict now admits) are listed live.

Soundness split: the snapshot proves **membership** only. File **content**
freshness stays on the file's own clocks exactly as the T3 overlay defines it —
an admitted file is `lstat`ed live before index elision may skip it. Ignore
_rules_ are always read live from disk; the snapshot only says which ignore
files exist (their creation/deletion is a membership change and stales the
directory).

That split is also why a fresh snapshot is not automatically worth serving, and
the walk decides per directory on **cost** rather than on freshness alone
(`descent.zig`: `phantom_stat_budget`). A served entry carries no timestamps, so
when the query wants clocks each admitted file pays its own path-resolving
`lstat`, where the live listing would have recovered every child's clocks inside
the one `getattrlistbulk` it was already making. Serving is cheaper per directory
and one stat dearer per admitted file, so there is a break-even, and **it is
measured at six admitted files rather than derived from a syscall count.**
Counting syscalls (a listing is three, the probing `lstat` spends one, so two are
left for files) reads as tidy but prices a listing as three fixed calls, when
`getattrlistbulk` resolves attributes for every entry in the directory - so a
listing's real cost scales with the directory's width. That undercounted by ~3x.
Both a primitive A/B (a path-resolving `lstat` costs 1.6-2.7 us against 1.9-2.7 us
for one listed entry, putting break-even at 6.1-8.8) and an end-to-end cap sweep
(the knee at 6, flat past it) land in the same place. Counting the admitted
children still costs nothing extra - the pass that notes which ignore files exist
was already walking them - so a directory over the budget declines before
spending a syscall at all.

Measured over 157,758 files of Linux + TypeScript source (minimum of 30+ runs;
this machine hosts ~10 coworker agents, so the minimum is the statistic that
reproduces):

| query                  | snapshot off | serve whenever fresh | serve on the budget |
| ---------------------- | -----------: | -------------------: | ------------------: |
| `-g '*.rst' import`    |     117.6 ms |              30.6 ms |         **11.3 ms** |
| `-l EXPORT_SYMBOL_GPL` |     114.0 ms |             199.6 ms |        **102.5 ms** |
| `-l <no match>`        |     116.9 ms |             198.1 ms |        **102.8 ms** |
| `--files`              |     104.0 ms |               8.0 ms |          **8.0 ms** |

The filtered row is what the snapshot is for: ~one child admitted per directory,
**10.4×** an all-live walk. The broad rows are what the budget fixes — serving
unconditionally traded ~10k directory listings for ~158k stats and _lost_ to not
having a snapshot at all, where pricing it recovers **1.95×** and lands slightly
ahead of the all-live walk (a broad query still serves the directories that happen
to hold at most the budget's worth of admitted files). `--files` wants no clocks,
so nothing is budgeted, every recorded directory is served, and that class is
untouched at ~13×.

Those four rows were taken when the budget was 2; the retune to 6 does not
disturb the shape they show, because a finite budget is what averts the
serve-unconditionally collapse and 6 is still finite. What the retune buys is
corpus-shaped: **1.18-1.38×** on a 20k-file corpus of mostly generated and
ignored siblings, where many directories hold the 3-6 admitted files the old
constant excluded, and inside noise (0.85-1.16×, 6 at 0.96-1.08×) over
llvm-project's 175k files, where a directory is typically 10-50 source files and
so exceeds any small cap either way.

Build: `gist index` (whole-CWD corpora only), self-anchored, atomically
published beside the trigram artifacts. Fail-open everywhere: a missing,
corrupt, or foreign `tree.map` just returns the walk to its live path.
