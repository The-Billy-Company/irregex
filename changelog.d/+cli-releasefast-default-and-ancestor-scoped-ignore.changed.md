The `gist` CLI — the on-PATH product binary (`~/.local/bin/gist` →
`zig-out/bin/gist`) whose whole reason to exist is out-running ripgrep — now
builds **ReleaseFast by default**, so a bare `zig build` (the step that
refreshes the installed binary) can no longer silently install a Debug build.
A Debug `gist` is 4–8× slower — a rare literal over the repo took ~4.5 s and a
common substring (`tel`) ~8.3 s — which reads to a caller like a hang ("runs
forever"). The same queries on the ReleaseFast binary are ~0.9 s (near
ripgrep's ~0.5 s over the same six roots), the search path it was always meant
to be. The build stays overridable: `zig build -Dcli-optimize=Debug` yields a
debug CLI for engine work, and tests / kcov coverage / the C-ABI libs keep
their standard safety-checked, DWARF-carrying default optimize untouched — the
CLI now links a dedicated ReleaseFast engine module so only the product surface
is affected.

The gitignore matcher (`ignore.zig`) is now bucketed by source directory
instead of one flat rule list. A candidate path can only be governed by rules
from its own ancestor directories — a `.gitignore` scopes its subtree, never a
sibling's — so `decide` consults just the CWD/ancestor tier plus each ancestor
dir's bucket (O(path depth)) rather than testing every path against every rule
ever loaded anywhere in the tree (O(paths × rules): rules were never scoped
back out as the walk unwound). Loaded-dir dedup moved from a linear scan to a
hash set (O(dirs), not O(dirs²)). Verdicts are byte-identical — the same rule
sequence per path, minus the sibling rules that could never match — verified
against the full `rgsuite` differential harness (275 supported-surface PASS,
no ignore regression) and an unchanged 16 179-file walk set; ~10–13% faster on
whole-tree queries here, and asymptotically far better on deep, ignore-heavy
trees.
