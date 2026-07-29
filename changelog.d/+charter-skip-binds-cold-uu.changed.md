Charter `skip` now binds cold search too, including `-uu`. It used to size only
the index and relate corpora — cold walks consulted gitignore and the hidden
rule alone, so `--no-ignore --hidden` walked straight into every directory the
tree had declared out of the corpus. On this repo that meant a `-uu` sweep of
`.local`'s multi-gigabyte scratch (lint proofs, bench corpora, daemon state),
which is what turned an interactive search into a minutes-long read of build
artifacts.

The cold prune now asks `haystack.isPolicySkip` first: charter `skip`,
`GIST_SKIP`, and `<outDir()>/skips.list`. Those are structural — a fact about
which directories exist in the corpus — so `-uu` and `-g` cannot un-hide them.
Pointing a root at the directory itself (`gist PAT .local`) still searches what
you named; only descending into it from a parent is refused. The generic
baseline (`.git`, `node_modules`, …) stays off the cold path on purpose:
ripgrep parity requires `-uu` to enter those.

`.irregex.toml` now declares `skip = ["graphify-out", ".local"]`. Proven on this
tree: a root `-uu` for a token that lives in thirty `.local` fixtures returns
only the four tracked/target copies and zero `.local/` paths; the same query
scoped to `.local` still finds all thirty; and `-uu` over `.git` still answers
(ripgrep parity — `.git` is baseline, not charter).
