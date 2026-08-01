# CREST release evidence

This leaf turns the production CREST proof into a revision-bound, independently
verifiable package. It uses only the Python standard library and writes only
under `.local/crest-evidence/`.

## Run

From the repository root:

```bash
# Exploratory proof; raw samples and matcher differentials land in .local.
cd <irregex-repo-root>
zig build crest -- --runs 20 --warmup 3

# Publication is stricter: clean tree, pinned HEAD, real benchmark + Zig tests.
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
the package's `crest-run.json`.

## Package contract

The package contains:

- the exact source commit and a Git archive whose complete tar identity
  (paths, bytes, executable modes, metadata, and PAX revision) must reproduce
  byte-for-byte from that object in the verifier's Git database;
- `crest.csv`, ordered raw nanosecond samples, fixed matcher regressions,
  deterministic seeds, four randomized mode differentials (ASCII/Unicode ×
  case-sensitive/caseless), and a byte-sorted corpus path/size/SHA-256 manifest;
- benchmark and test transcripts, command receipts, machine/OS/CPU/memory/
  storage/filesystem/power/cache-condition metadata (unsupported probes are
  `null` with a note), and hashes for each artifact;
- a revision-bound monograph and two detached hashes.

`evidence-manifest.json` SHA-256-binds every payload;
`EVIDENCE-MANIFEST.sha256` binds that manifest. Its in-document `Monograph
SHA-256 (canonical content)` field normalizes itself to 64 zeroes. A full
final-file self-hash cannot be embedded without changing the file, so
`CREST-MONOGRAPH.sha256` is the detached SHA-256 of the complete Markdown
bytes. The verifier enforces both.

Missing files, hash drift, an unavailable Git object, any source path/byte/mode/
revision substitution, altered matcher results, wrong seeds/sample counts, an
unsorted corpus manifest, or any `matched && pruned` result fail closed.
