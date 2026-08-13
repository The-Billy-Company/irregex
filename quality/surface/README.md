# The Export Gate

`charter.zone` governs what a file *inside* this package may reach.
Nothing governed what the package **hands out**, and it showed: seventeen
`regex_*` names shaped by one bench harness sat in the public surface with no
note saying who they were for, next to a `commands` namespace that existed
because a CLI once wanted that spelling. A reader arriving at `src/root.zig`
could not tell the vocabulary every signature is written in from a door opened
for one benchmark.

This closes the other side of the zone. Every top-level `pub` in `src/root.zig`
must have a row in [`contract/exports.toml`](../../contract/exports.toml) naming
its tier and stating, in one line, who it is for; every row must name something
the root still exports.

## The Three Tiers

- **stable** rows promise semver — the name will not move or change shape
  inside a major version, and a consumer can write against it.
- **provisional** rows are real, documented, and useful, but the shape is
  still being learned — they may move in a minor version with a note.
- **internal** rows version in lockstep with this repository and promise
  nothing to anyone else — the product seam the sibling packages reach
  through, plus any retired spelling kept only as a redirect.

An `internal` row may carry `now = "<address>"`, which marks it a retired
spelling and says where the name went. The gate checks that address still
resolves, so a migration note can never point at a door that stopped answering.

## Declaring a Breaking Change

Deleting an exported name is a breaking change, and the `[removed]` table is
where that change gets written down. The gate diffs `src/root.zig` against the
last `vX.Y.Z` release tag's `root.zig`: any name the release exported that the
current tree no longer does must have a `[removed]` row saying what replaced
it, and any `[removed]` row naming something the release never actually
exported has gone stale and must be deleted.

The gate checks against the release tag rather than the version number in
`build.zig.zon`, because release-please owns that number — the working tree
sits at the last released version until the release PR moves it, so gating on
"has the major bumped yet" would stay red for the whole development window.
Declaring a removal is something a change can do the day it happens.

The `[removed]` block ends on its own: once the next major tag ships without
those names, the diff against the newest release stops finding them missing,
and every row in the table goes stale. The fix at that point is deleting the
rows, not renewing them.

## Scheduling a Retired Spelling

A second check applies only when an `[internal]` row carries a `now` — a name
still exported for compatibility while it points somewhere else. Every row
like that must be named in a `[deprecation]` table with a `remove_in` version,
and that version must still be ahead of the version `build.zig.zon` currently
declares.

A `remove_in` the shipped version has already reached is a plan that can never
come due, so the gate treats it as a fault rather than carrying it forever
while it looks temporary. Prose cannot notice a schedule quietly going stale;
a comparison against the manifest can.

## Which Planes C Can Reach

The tiers say what a Zig caller gets. A third table says which of those a C
caller can reach, and it exists because nothing said so.

`contract/bindings.toml` is horizontal across the three bindings, and every lane
under it starts from the ABI. A plane that never got an `export fn` is therefore
absent from the header, absent from all three bindings, and reported by nobody.
That is not a hypothetical either: the corpus planes were finished, tested and
exported to Zig while a C host could not open a tree.

So every `stable` and `provisional` export answers the question, in exactly one
of two tables. A `[door]` row names one symbol `include/irgx.h` must declare —
the cheapest proof a way in exists, not an inventory of the plane's verbs, which
the header and the parity gate already hold.

A `[door.none]` row is the decision that a plane has no C door, and it carries
the same weight a waiver does. Two species live there. One is the product — the
ranking weights, the rg-shaped output, the flag grammar, the preferences file —
where an ABI verb would publish our taste as somebody else's contract. The other
is the floor, generic over comptime types, with no C shape to publish at all.

`[internal]` is exempt and may not be listed. It promises nothing to anyone, so
whether C can reach it is not a question it owes an answer to.

Comments are stripped before the header is read. This header carries a paragraph
naming the doorless planes, and a rule that read prose would take that paragraph
as proof they have doors.

## What It Catches

- A new `pub` added to the root with no row, so the surface grew by accident.
- A row whose name left the root, so the contract describes a package that no
  longer exists.
- A retired spelling pointing at a replacement that was itself renamed.
- A name the last release exported quietly disappearing with no `[removed]`
  row explaining what replaced it, or a `[removed]` row naming something the
  release never exported.
- A retired internal spelling with no `[deprecation]` schedule, or one whose
  `remove_in` version has already shipped.
- A name declared in two tiers, an empty `why`, or an empty `now`.
- A promised export that says nothing about whether C can reach it, a `[door]`
  naming a symbol the header does not declare, or a `[door.none]` with no reason.

Anything indented is out of scope on purpose. What a namespace exposes under
its own door is that namespace's business — this gate is about the front door.

## Running It

Run the gate the same way CI does, then run the detector's own proofs:

```bash
python3 quality/surface/check.py     # the gate (CI runs this)
python3 quality/surface/test_check.py  # the detector's own proofs
```

Exit `0` is clean, `1` is drift, `2` is a malformed contract. It is stdlib-only
Python with no dependencies and no Zig: the question is what the file says, so
compiling the engine to answer it would tie a millisecond check to a toolchain
it has no other use for. That is the same reasoning the ratchets next door
run on.

A broken contract reports only itself. Every export looks undeclared when the
tables are unreadable, and printing fifty-three drift lines caused by one typo
would bury the fault that caused them.

## When It Fails

The fix is a row, or the name coming back out. Adding a row is not a rubber
stamp — the `why` is the point, and a name nobody can write a `why` for is a
name that should not be public. Deleting a row to go green when the export is
still there is the forbidden move, the same way lifting a ratchet baseline is.
