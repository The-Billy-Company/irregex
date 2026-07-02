`gist rg` no longer ignore-filters a positional PATH argument itself — only
what's found beneath it, matching ripgrep's own depth-0 exemption
(`crates/ignore/src/walk.rs`'s `add_parents`: ancestor ignore state is loaded
at the root, but the root entry is never matched against it, only its
descendants are). Previously, naming a directory that an ancestor
`.gitignore` happened to match (e.g. `gist rg pat upstream/some-dir` when `upstream/`
is gitignored at the repo root) silently returned zero results — a
divergence from real `rg`, which always searches an explicitly-named path
while still honoring ignore rules nested *inside* it. This made `gist rg
--files`/`--iglob` unusable as a `find`/`find -iname` replacement for any
path under a gitignored ancestor, forcing a fallback to raw `find`.

Fixed with a new `Ignore.scopeToRoot` in `ignore.zig`: a component-depth
floor on the rule matcher that exempts a positional root's own path segments
from CWD/ancestor-sourced rules (`Rule.base == ""`) while leaving rules
loaded from *within* the given root's own subtree unaffected. Verified
byte-identical against real `find -iname` and `rg -n -i <files>` on the
reproducing case, and against the full `rgsuite` differential-parity harness
(441 mined ripgrep cases, 278/278 supported-surface parity, zero regressions).
