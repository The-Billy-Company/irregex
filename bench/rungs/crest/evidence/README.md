# CREST Release Evidence

This leaf turns the production CREST proof into a revision-bound, independently
verifiable package. It uses only the Python standard library and writes only
under `.local/crest-evidence/`.

## Running It

From the repository root:

```bash
# One independently timed profile per invocation; both bind the same manifest.
cd <irregex-repo-root>
mise exec -- zig build crest -- --rank 1 --budget 8 --runs 20 --warmup 3
mise exec -- zig build crest -- --rank 4 --budget 8 --runs 20 --warmup 3

# Publication is stricter: clean tree, pinned HEAD, real benchmark + every gate.
python3 bench/rungs/crest/evidence/crest_evidence.py package

# Verify a package without trusting its prose.
python3 bench/rungs/crest/evidence/crest_evidence.py \
  verify .local/crest-evidence/package-<full-commit>

# Re-render the monograph from git-show bytes at that package's revision.
python3 bench/rungs/crest/evidence/crest_evidence.py \
  monograph .local/crest-evidence/package-<full-commit>
```

`package` refuses a dirty tree, runs the command slate frozen in
`contract/crest_evidence.toml`, checks the tree and revision again, creates a
`git archive`, and verifies the completed package before publishing it. It
never copies source claims from the working tree: the monograph reads each
source document with `git show COMMIT:path`. Benchmark numbers come only from
the package's `crest-run.json`. The test receipt covers the exact-oracle fixture
drift check, oracle/training/evidence suites, full Zig tests, and all mutation
kills through `publication_tests.py`.

## Package Contract

The package contains:

- **the source commit**, and a Git archive whose complete tar identity
  (paths, bytes, executable modes, metadata, and PAX revision) must reproduce
  byte-for-byte from that object in the verifier's Git database.
- **the run evidence** — profile-qualified CSV/JSON, ordered raw nanosecond samples, fixed
  matcher regressions, deterministic seeds, four randomized mode
  differentials (ASCII/Unicode × case-sensitive/caseless), and a byte-sorted
  corpus path/size/SHA-256 manifest.
- **provenance metadata** — benchmark and test transcripts, command receipts,
  machine/OS/CPU/memory/storage/filesystem/power/cache-condition metadata
  (unsupported probes are `null` with a note), and hashes for each artifact.
- **the monograph** — a revision-bound document plus two detached hashes.

`evidence-manifest.json` SHA-256-binds every payload;
`EVIDENCE-MANIFEST.sha256` binds that manifest. Its in-document `Monograph
SHA-256 (canonical content)` field normalizes itself to 64 zeroes. A full
final-file self-hash cannot be embedded without changing the file, so
`CREST-MONOGRAPH.sha256` is the detached SHA-256 of the complete Markdown
bytes. The verifier enforces both.

Missing files, hash drift, an unavailable Git object, any source path/byte/mode/
revision substitution, altered matcher results, wrong seeds/sample counts, an
unsorted corpus manifest, or any `matched && pruned` result fail closed.

## ZIP corpus adapter

`corpus_archive.py` validates ZIP paths, collisions, links, encryption, member
sizes, and compression ratios before staging files read-only in a fresh
temporary directory. The benchmark process receives only that temporary root.
The adapter forwards one validated q/B profile, verifies zero matched-and-pruned
documents, records profile-qualified artifact hashes, and removes the staging
tree afterward.

The supplied archive is accepted directly, but its corpus-dependent benchmark
has deliberately **not** been run:

```bash
mkdir -p .local/crest-evidence
python3 bench/rungs/crest/evidence/corpus_archive.py run \
  --archive "/path/to/held-out-corpus.zip" \
  --rank 1 --budget 8 --runs 20 --warmup 3 \
  --receipt .local/crest-evidence/archive-q1-b8-receipt.json

python3 bench/rungs/crest/evidence/corpus_archive.py run \
  --archive "/path/to/held-out-corpus.zip" \
  --rank 4 --budget 8 \
  --runs 20 --warmup 3 \
  --receipt .local/crest-evidence/archive-q4-b8-receipt.json
```

The two receipts bind `q1-b8` and `q4-b8` to the same frozen corpus-manifest
hash. Both measure the production q4 sidecar; `query_rank` selects q1 or q4
requirements independently of `sidecar_q=4`. This adds q4 measurement
capability only: the release contract authorizes `q1-b8` and explicitly blocks
`q4-b8` from promotion pending held-out review.
