# CREST training evidence

This dependency-free Python package reads the supplied training/evaluation ZIP
in place. It never extracts the archive and never exposes the sealed `test` or
`excluded_cross_boundary` partitions.

Construction first bounds ZIP member, directory, zero-byte, expanded-size, and
compression-ratio work, then streams every checksum-declared member through
SHA-256. That integrity pass includes the sealed partitions without returning
their bytes through any analysis API. Manifest-derived dataset fingerprints are
unavailable until the full pass succeeds and every partition digest agrees.
Directory-backed packages open every root, directory component, and member
through nonblocking confined descriptors; no-follow fallbacks bind pre/open/post
device and inode identity so FIFO and symlink replacement races fail closed.

Selection sees only the manifest and `train.jsonl`. Validation can score only
prefixes of that frozen ranking after proving that training and validation have
disjoint call and session keys. Every artifact carries a content-derived
dataset fingerprint and an explicit fail-closed promotion gate:

- `q=4` is not promotion-eligible;
- an adaptive predicate dictionary is not promotion-eligible;
- query-trace coverage is not accepted as corpus evidence.

Run the synthetic corpus-independent suite:

```bash
PYTHONPATH=research/crest/training \
  python3 -m unittest discover \
  -s research/crest/training/tests -p 'test_*.py'
```

The user-provided ZIP can be consumed later without extraction:

```bash
export CREST_DATA_PACKAGE="/Users/alexanderlitovchenko/Downloads/MMC Analysis/NeuroEthics/Bandits/OSS/crest_training_evaluation_data_v1.zip"
PYTHONPATH=research/crest/training \
  python3 -m crest_training fingerprint --package "$CREST_DATA_PACKAGE"
```

Proposal and validation commands require explicit output paths outside the data
package. Their output is research evidence only; production configuration must
be authorized by the separate held-out corpus benchmark evidence.
