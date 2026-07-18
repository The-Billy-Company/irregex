# `src/faces/hydra/` — the compression-search faces

The `similar`, `dups`, and `patterns` verbs — gist's native shapes over the
`src/irregex/` primitives (match ∪ relate ∪ weave). Like `--rank`, these are
gist vocabulary with no rg equivalent:

| Verb                  | Primitive           | Question it answers                                                                           |
| --------------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| `gist similar <path>` | `sketch`            | what else in this tree is _like_ this file?                                                   |
| `gist dups`           | `sketch`            | which files are near-duplicates of each other?                                                |
| `gist patterns -e P…` | `patterns` + `loom` | one walk, N patterns — which pattern hit where, shaped (`--by`/`--under`/`--top`) engine-side |

Corpus policy: these verbs load the **index corpus** (`corpus.load` — every
non-binary file under the roots minus VCS/build subtrees), the same policy
`gist index` uses. They are corpus analytics, not per-file greps; the
rg-parity walk (gitignore precedence, `-g` scoping) stays with the search
engine in `../ripgrep/`.

`patterns` additionally rides the persisted trigram index when it can: if
**every** pattern yields a sound prefilter (not caseless, ≥3-byte literal or
alternation cover) and the roots sit inside the indexed corpus, it unions
per-pattern candidates (freshness-widened, root-scope gated) and reads only
those files in parallel shards — the same elide-only contract as the
single-pattern engine, never a different answer. Caseless, prefilter-less, or
out-of-corpus runs fall back to the full corpus read.

Output contract: results on stdout (`--json` = NDJSON), diagnostics and the
timing line on stderr — the same split every other gist face keeps.
