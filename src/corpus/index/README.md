---
doc_radar:
  counts:
    - description: "index keeps nine packages: seven indexes (trigrams · crest · codex · atlas · frag · phantom · content) over two substrate packages (frame · postings)"
      glob: pkg/kernels/irregex/src/corpus/index/*
      unit: dirs
      equals: 9
  sentinels:
    - description: "the elision contract every index package is built on"
      file: pkg/kernels/irregex/src/surface/exec/cold/engine/README.md
      contains: "Index is an accelerator, not an authority."
    - description: "every mapped artifact loads through the one shared protocol"
      file: pkg/kernels/irregex/src/corpus/index/frame/frame.zig
      contains: ["pub fn mapArtifact"]
---

# `src/corpus/index/` — candidate, self, and kinship indexes

Persisted structures that may **elide reads, never own truth**. The live walk
(`corpus/` + `corpus/tree/`) decides which files exist; indexes only
prove that some of them cannot match (or answer count/find/restore /
kinship without a full scan). `--no-index`, a missing anchor, or a corrupt
artifact always degrades to slower-but-identical answers.

Nine packages, but not nine indexes. **Seven** publish an artifact and answer a
question from it; **two** are the substrate they are all built on. Reading the
directory as nine peers is the fastest way to conclude there are too many.

## The seven indexes, by what they eliminate

| Package                 | Eliminates                               | Job                                                                                                  |
| ----------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [`trigrams/`](trigrams) | files that cannot match                  | **T0** positional trigram candidate index + **T3** mtime/ctime freshness + codicil incremental amend |
| [`crest/`](crest)       | files a literal-free pattern can't match | Per-doc forced-class-run vectors (`crest.bin`) for literal-free class runs                           |
| [`phantom/`](phantom)   | `openat`+`getattrlistbulk` syscalls      | Directory-membership snapshot (`tree.map`): one lstat proves a dir, walk elided                      |
| [`content/`](content)   | `openat`+`read`+`close` syscalls         | Corpus-content blob (`content.shard`): one mmap serves unchanged bytes, no open                      |
| [`codex/`](codex)       | the corpus itself                        | FM-index self-index: `count` / `find` / `restore` at entropy space                                   |
| [`atlas/`](atlas)       | re-sketching every file                  | Persisted LZJD sketches + silhouettes for warm `relate similar` / `echoes`                           |
| [`frag/`](frag)         | re-sketching every function              | Persisted per-function silhouettes (`concepts.frag`) for a warm `--unit function`                    |

Four different eliminations, and no two indexes make the same one. `trigrams`
and `crest` rule candidates out by pattern; `phantom` and `content` remove
syscalls the walk would otherwise repeat; `codex` answers without consulting the
corpus at all; `atlas` and `frag` answer resemblance, which no exact structure
can. An index that duplicated another's elimination would be the one to delete.

## The two substrate packages

| Package                 | Job                                                                                                                                                                                                    |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`frame/`](frame)       | Wire discipline: LE ints, fail-closed cursor, NUL catalogs, `onDisk` gate, the mmap/atomic-write primitives, the `tree.root` binding, and `mapArtifact` — the load protocol every mapped artifact runs |
| [`postings/`](postings) | LEB128 + CSR blob codecs the trigram bodies ride                                                                                                                                                       |

Neither answers a query. They exist so the seven can't drift on how bytes are
framed, mapped, and proved — see [`frame/README.md`](frame) for why the load
protocol is a function rather than a convention.

## The one law

> Index is an accelerator, not an authority.

That sentence is load-bearing. `bench/gates/index_elision_parity.sh` asserts
indexed ≡ unindexed byte-exact line multisets and exit codes, normalizing only
the parallel walk's incidental cross-file scheduling order. Soundness rules:

- Trigram AND of required literals ≥ 3 bytes is a **sound** candidate set
  (false positives OK; false negatives forbidden).
- Freshness stamps the wall-clock anchor **before** reading the corpus;
  missing timestamps or a missing anchor fail closed (live-read).
- Crest `decode` nulls on framing mismatch → query runs without the sieve.
- Codicil (incremental amend) postings are false-positive only (union, never
  subtract); false-negative holes are closed by construction.
- Atlas / corrupt / `--no-index` → live rebuild, byte-identical answers.
- An artifact that cannot prove which tree it describes, or that carries an
  anchor from the future, does not load at all (`frame.mapArtifact`). Both are
  silent-wrong-answer failures rather than slow ones, so they refuse.

## When to edit here

- On-disk magic, layout, or generation-atomic publish of a pair
  (`trigrams` + `crest`, atlas shelf).
- Freshness model or codex layer math. The mmap load path itself is
  `frame.mapArtifact` — change it there, once, not per artifact.
- Anything that could change which files are skipped — that needs a gate
  update in the same change.

Theory for the crest sieve lives in
[`../../../research/crest/`](../../../research/crest/); production math is
[`../../kernel/primitives/crest.zig`](../../kernel/primitives/crest.zig).
