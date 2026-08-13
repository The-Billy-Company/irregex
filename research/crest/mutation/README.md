# CREST mutation proof

`mutate.py` copies the current irregex checkout to an external temporary
directory, then injects safety-critical defects into the CREST document
kernel, forced-query calculus, columnar execution, and persisted sidecar. The
live checkout is never mutated.

Each mutant's exact focused test is compiled **and linked without execution**,
then its binary is run separately under `runner.zig`. A mutant is **killed**
only when the runner emits machine evidence that the exact source-bound test
returned a Zig `Test*` assertion error or panicked. A signal, timeout, skipped
or wrong test, runner failure, unrelated nonzero exit, compile error, or linker
error is **invalid**. A passing exact test **survives**.

The deterministic JSON report binds the result to the Git commit and tree, the
full mutation-catalog digest, Zig version/target/compiler digest, and a digest
of every tracked or unignored source byte in the copied snapshot. Dirty
development trees are supported explicitly: the report says `working_tree:
"dirty"` and carries a separate dirty-tree digest rather than claiming the
commit was the tested source. Schema v3 also stores each focused runner's
canonical machine records and timeout/return-code facts. `--verify` replays the
same classifier for every mutant and rejects any edited verdict, reason, site
count, return code, timeout, or evidence status even when the summary was
rewritten to agree.

```bash
python3 research/crest/mutation/mutate.py
```

Use `--verbose` to send failing Zig output to stderr without contaminating the
JSON receipt. `--publication` first runs the complete `zig build test` suite in
the isolated copy; it is intentionally much slower than the focused mutation
proof.

Write receipts outside the checkout, then reject source, catalog, or toolchain
drift before reusing one:

```bash
python3 research/crest/mutation/mutate.py > /tmp/crest-mutation.json
python3 research/crest/mutation/mutate.py --verify /tmp/crest-mutation.json
```

The stdlib-Python harness tests cover exact mutation-site generation, linker
and signal failures, wrong-test evidence, source/catalog drift, stable JSON,
and copy isolation:

```bash
python3 -m unittest discover \
  -s research/crest/mutation -p 'test_*.py'
```

The mutant catalog pins:

- predicate-set intersection and nullable certificates in `swell.zig`;
- exact-threshold, rank ordering, UTF-8 continuation transparency, saturating
  document joins, query saturation, and schema binding in `crest.zig`;
- columnar threshold direction;
- sidecar build binding and sparse-overflow recovery.

These are all synthetic, corpus-independent checks. Corpus-scale soundness and
selectivity remain the separate `zig build crest` production proof.
