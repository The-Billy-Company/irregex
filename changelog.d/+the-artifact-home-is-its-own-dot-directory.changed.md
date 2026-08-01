The artifact home moved from `.local/gist-verify/` to `.gist/`. Everything the
engine persists lives there - the trigram index, the kinship and fragment
atlases, the codex shelf, the freshness anchor, the daemon socket, and
`skips.list`. The old spelling was inherited from the monorepo this package was
extracted from, where `.local/` was that repo's machine-local scratch
convention and `gist-verify` was one bucket inside it. Neither half means
anything in a clone that has never seen that tree, and a reader who found the
directory could not tell whether it was ours. `.gist` names itself the way
`.git`, `.ruff_cache`, `.mypy_cache`, and `.pytest_cache` do, and it reads
correctly against the `GIST_DIR` override that was already there.

This orphans any index you already built; nothing reads the old directory
anymore, so the first query after upgrading answers live and slower. `gist
index` rebuilds it in about three seconds, and `relate index --shelf` does the
same for the kinship side. If you would rather keep the old location - a shared
volume, a path you already back up, a tree where `.gist` is taken - `GIST_DIR`
still pins it: `GIST_DIR=.local/gist-verify gist index` puts everything back
where it was. Delete the stale directory yourself; we will not remove bytes we
no longer claim to own.

`.gist` also joined the corpus baseline skip set, next to `.zig-cache` and
`node_modules`. The artifact home sits inside the walk root by default, so
without this the tool indexes its own index - a couple of hundred megabytes of
its own exhaust, on every tree, with no way to have wanted it. It is baseline
rather than charter policy because it holds for any tree with no configuration
at all. Naming the directory as a root still searches it, the same escape the
rest of the baseline offers.
