# `src/commands/irregex/` — the irregex CLI faces

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

Output contract: results on stdout (`--json` = NDJSON), diagnostics and the
timing line on stderr — the same split every other gist face keeps.
