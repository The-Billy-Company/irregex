# CREST research evidence

`publication.py` seals any CREST evidence payload set with:

- SHA-256 for every payload and a detached manifest digest;
- one no-follow, nonblocking descriptor snapshot whose exact bytes feed both
  semantic verification and those SHA-256 values;
- the full source commit and dataset fingerprint;
- hashed Python/Git/Zig toolchain and host platform metadata;
- a mechanically derived list of missing or semantically invalid corpus artifacts;
- an immutable prohibition on automatic `q=4` or adaptive-dictionary promotion.

It is repository-local and has no Billy contract, registry, or code-generation
dependency. A complete evidence package is still review input, never permission
to change production defaults.

Run the corpus-independent tests:

```bash
python3 -m unittest discover \
  -s research/crest/evidence -p 'test_*.py'
```

`complete` requires a canonical corpus manifest plus q1, q4, fixed-dictionary,
adaptive-dictionary, and mutation reports. Corpus reports use
`irregex-crest-corpus-publication-artifact-v1`, bind the same source revision,
dataset, corpus manifest, and query workload, prove zero false negatives and
violations, and carry the filename-appropriate profile. Mutation evidence is
the native `irregex-crest-corpus-independent` schema v3 emitted by
`research/crest/mutation/mutate.py`; its verifier replays every canonical
per-mutant runner record against the live mutation contract and checks nested
source/toolchain/catalog provenance, with all 11 mutants killed and none
surviving or invalid. Presence or valid JSON alone never advances the status,
and completion remains review input rather than promotion authorization.
