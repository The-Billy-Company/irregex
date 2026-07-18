---
doc_radar:
  sentinels:
    - description: "hydra is a real installed binary (second exe in the build graph)"
      file: pkg/kernels/irregex/build.zig
      contains: '.name = "hydra"'
    - description: "the gist CLI sheds these verbs with a redirect stub, not a silent literal search"
      file: pkg/kernels/irregex/src/gist/faces/cli/main.zig
      contains: "moved to the hydra binary"
---

# `src/hydra/` — the compression-search engine

**What if compression was a text search algorithm?** hydra is that question
as a package: a separate engine beside gist, built on the observation of
Benedetto, Caglioti & Loreto ("Language Trees and Zipping", 2001) that a
compressor's model of one text prices any other text — so *how few bits it
takes to describe this with that already warm* is a distance, with no
parsing, no tokenizer, and no language list. gist answers *"where is this
exact pattern?"*; hydra answers *"what is this LIKE?"*. The math is
hand-rolled rather than borrowed: no gzip run, no LZ78 parse — a
corpus-priced fingerprint index for recall and an exact suffix-automaton
cross-parse for precision (see [`engine/`](engine/README.md)).

It is a proper package, not a face over gist's kernel: `engine/` owns the
relate machinery, `cli/` is the thin binary shell. What hydra shares with
gist it shares through the package's shared floor only — the
[`../primitives/`](../primitives/README.md) math tier (LZ78 dictionary
sketches, multi-pattern attribution, loom shaping) and the
[`../corpus/`](../corpus/README.md) walk — never gist's kernel internals.
`make install-gist` installs both binaries (`~/.local/bin/{gist,hydra}`).

## Layout

| Folder    | What                                                                                        |
| --------- | -------------------------------------------------------------------------------------------- |
| `engine/` | the retrieval core (`lexicon.zig` recall + `zipper.zig` precision) and the verb drivers (`verbs.zig`) |
| `cli/`    | the `hydra` binary — dispatch shell (`main.zig`) + `--schema` capability manifest (`schema.zig`) |

## Verbs

| Verb                   | Machinery           | Question it answers                                                                           |
| ---------------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| `hydra search <text>`  | `lexicon` + `zipper` | which files would _describe_ this text most cheaply? (retrieval by conditional description length; score = coding gain ∈ [0,1]) |
| `hydra similar <path>` | `sketch`            | what else in this tree is _like_ this file?                                                   |
| `hydra dups`           | `sketch`            | which files are near-duplicates of each other?                                                |
| `hydra patterns -e P…` | `patterns` + `loom` | one walk, N patterns — which pattern hit where, shaped (`--by`/`--under`/`--top`) engine-side |

Corpus policy: the verbs load the **index corpus** (every non-binary file
under the roots minus VCS/build subtrees — `corpus.load`), the same
wider-than-gitignore policy `gist index` uses. They are corpus analytics, not
per-file greps; the rg-parity walk stays with gist.

Output contract: results on stdout (`--json` = NDJSON), diagnostics and the
timing line on stderr — the same split every gist face keeps.
