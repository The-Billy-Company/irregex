---
doc_radar:
  sentinels:
    - description: "hydra is a real installed binary (second exe in the build graph)"
      file: pkg/kernels/irregex/build.zig
      contains: '.name = "hydra"'
    - description: "the gist CLI sheds these verbs with a redirect stub, not a silent literal search"
      file: pkg/kernels/irregex/src/faces/cli/main.zig
      contains: "moved to the hydra binary"
---

# `src/faces/hydra/` — the compression-search binary

**What if compression was a text search algorithm?** hydra is that question as
a product: the `similar`, `dups`, and `patterns` verbs over the
`src/primitives/` irregex tier (match ∪ relate ∪ weave), shipped as its own
binary riding the same kernel, corpus policy, and persisted trigram index as
`gist` — one engine, two faces. `make install-gist` installs both
(`~/.local/bin/{gist,hydra}`).

| Verb                   | Primitive           | Question it answers                                                                           |
| ---------------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| `hydra similar <path>` | `sketch`            | what else in this tree is _like_ this file?                                                   |
| `hydra dups`           | `sketch`            | which files are near-duplicates of each other?                                                |
| `hydra patterns -e P…` | `patterns` + `loom` | one walk, N patterns — which pattern hit where, shaped (`--by`/`--under`/`--top`) engine-side |

`hydra --schema` emits the machine-readable capability manifest
(`schema.zig`); `main.zig` is the thin dispatch shell, `irregex.zig` the verb
drivers (reached through the engine module as `commands.irregex`).

Corpus policy: these verbs load the **index corpus** (`corpus.load` — every
non-binary file under the roots minus VCS/build subtrees), the same policy
`gist index` uses. They are corpus analytics, not per-file greps; the
rg-parity walk (gitignore precedence, `-g` scoping) stays with the search
engine in `../gist/ripgrep/`.

`patterns` additionally rides the persisted trigram index when it can: if
**every** pattern yields a sound prefilter (not caseless, ≥3-byte literal or
alternation cover) and the roots sit inside the indexed corpus, it unions
per-pattern candidates (freshness-widened, root-scope gated) and reads only
those files in parallel shards — the same elide-only contract as the
single-pattern engine, never a different answer. Caseless, prefilter-less, or
out-of-corpus runs fall back to the full corpus read.

Output contract: results on stdout (`--json` = NDJSON), diagnostics and the
timing line on stderr — the same split every gist face keeps.
