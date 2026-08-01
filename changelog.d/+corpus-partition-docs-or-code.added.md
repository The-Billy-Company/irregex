`--docs` / `--code` / `--data` and their `--no-` complements, a corpus axis
orthogonal to `-t <language>`. `-t` answers "which language is this?", which is
the wrong grain for the question anyone actually asks — never "is this
reStructuredText" but "am I reading the paper trail, or the implementation?".
Spelling that with `-t` means naming sixteen types and still missing the
extensionless `CHANGELOG`; spelling it with `-g` means hand-assembling globs that
no longer say what they were for.

New `corpus/scope/genus.zig` owns the partition: three genera, total and
disjoint, so a flag and its `--no-` form are exact complements and no path falls
through. Selections union, each name is also a type name (so `-t docs` and
`--type-add 'docs:notes/**'` work and no new configuration key was needed), and
the whole thing is daemon-warm — the selection rides `query_ext` as a two-byte
trailer, verified byte-identical against the cold run for every polarity.

**`code` is the leftover, never a recognized set.** An unfamiliar extension, a
generated blob, or a file with no extension lands there, so the worst a gap in
the table can do is show `--code` one line too many; the alternative default (a
fourth `unknown` genus excluded from `--code`) turns every gap into a silent
miss, the one failure an agent cannot detect. Same asymmetry decides the hard
case: a doc directory or a `CHANGELOG`-class name only promotes what no language
type claimed, so `docs/notes.md` is docs while `docs/conf.py` and a docs site's
`*.tsx` stay code. A genus also narrows only — unlike `-t`/`-g` it never
un-hides, because an un-hiding default would surface all of `.git/`.

Against the `-t` union a person types instead — derived at run time from
`gist --type-list --docs ∩ rg --type-list`, 25 type names, so it can be neither
strawmanned nor left to drift — **2.9× faster cold and 21× warm** (geomean over
the needle slate, `bench/dominance/partition/`, answer keep disabled so the warm
arm is a search and not a memoized recall). On the tracked corpus the two rosters
land within one file of each other, which is what a derived rival should do; what
a genus knows that a basename glob cannot is proven on the lane's hermetic tree
instead, where the union calls **three build recipes prose** (`CMakeLists.txt` —
rg's `txt` type is `*.txt`, with no way to except a basename) and cannot name
**two extensionless documents** gist promotes by location and by name. Those
counts are asserted by equality against a written-down contract, not a captured
measurement. No grep-class tool ships this axis at all: ripgrep's type globs are
basename-only, so a `docs/` rule is inexpressible there even by hand
(ripgrep#3339, open); ugrep's `text` type is five extensions with no code
counterpart; zoekt links go-enry's `Prose`/`Data` classifiers and never calls them.

Both halves are permanently gated. `partition_parity.sh` proves the set
identities over the live tree on every `zig build test` — totality, disjointness,
each `--no-` form as an exact complement, `-t`/`-T` alias parity, index and
resident session as acceleration only, no genus un-hiding a path the walk
refused, and the location rule still rescuing extensionless documents.
`bench-gist-partition` holds the speed and the classification contract.

The classification is comptime-proved against the 223-row type table in both
directions — a new `-t` type is a compile error until it is classified, a renamed
one until the rename lands here — and the runtime shadow set that keeps
`CMakeLists.txt` a build recipe is derived from the table rather than listed, so
a new collision on either side cannot go unnoticed. `genus_test.zig` re-derives
the whole answer from the declaration for every glob in the table, with an
explicit dispute list rather than a tolerance.
