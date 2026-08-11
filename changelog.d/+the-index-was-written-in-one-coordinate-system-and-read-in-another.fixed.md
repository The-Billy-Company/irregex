Anchoring the artifact home at the tree finished half a job. The artifacts were
now one per checkout, but what a query thought it was standing in was still the
directory it was standing in, so a search from `services/ai` read the tree's
index, decided it belonged to somebody else, and switched every accelerator off.
The whole point of the move was that a subdirectory search gets to ride the
tree's index, and it didn't.

Making the checkout the tree identity is what closes that, and it opens
something worse, because two coordinate systems now name the same file.
Everything persisted in the home - the trigram path table, the content shard's
document names, the directory-membership snapshot - is written relative to the
CHECKOUT. A walk emits paths relative to the WORKING DIRECTORY, because that is
what rg prints and output parity is not up for negotiation. So an index-keyed
lookup crosses between them, and a lookup that forgets does not fail loudly: it
asks for `notes.md`, finds a real doc for a real file, and that file is a
different one. Two callers spend that doc id on skipping a read and one spends
it on serving bytes, so the cost of forgetting is a wrong answer, not a slow
one - a subtree file that matches, elided because its namesake at the root
doesn't.

The offset between the two is `home.station`, and the rebase lives in the three
lookups themselves rather than at their call sites: the elide oracle's path
table, the content shard's, and the phantom snapshot's root resolve. Those are
the only doors into checkout coordinates, so above them nothing has to know a
coordinate system exists, and a new caller cannot forget. A search at the tree
root - the overwhelmingly common case - pays an acquire load and a length test.

Builds go the other way. A build is a statement about the tree, so
`corpus.enterTree` stands the process at the checkout root before it walks:
`gist index` from `services/ai` indexes the repository, exactly as it does from
the root, and names every file from the root. Without that it indexed the
subtree, wrote `notes.md` for a file the tree holds at `services/ai/notes.md`,
stamped the result with the tree's binding, and the next query at the root
faithfully tried to open a file that was never there - `No such file or
directory`, exit 2, on a tree where nothing was wrong. Roots are re-expressed
through the filesystem rather than by editing path text, resolved before the
move and relativized after, because a charter's roots already carry `../..` to
reach the tree and a lexical `..`-collapse answers wrong through a symlink.
An explicitly named root is still a scope; it just gets named from the tree, so
the same command means the same corpus wherever it was typed.
