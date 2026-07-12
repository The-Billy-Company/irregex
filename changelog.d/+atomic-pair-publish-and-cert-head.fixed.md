Index publish is now generation-atomic (`gens/<id>/` + `pair.gen`) so concurrent
loaders never observe a mixed `index.gist`/`paths.list` pair; persist tests cover
torn-stage and concurrent-load regressions. Certificate provenance requires
`machine.git_commit ==` clean HEAD (`check_artifacts.py --require-head`); the
committed artifact is stubbed pending republish. README parity language no longer
counts ORDER as byte-identical, and documents `--sort`/`--sortr` as accepted-but-ignored.
