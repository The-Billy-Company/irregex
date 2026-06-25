# gist/bench

Benchmark harness for the `gist` code-locator kernel. `bench.zig` loads a real
corpus (every code file under the given dirs), builds the T0 trigram `Index`,
and times the query slate — reporting corpus size, one-time build cost, index
footprint, and per-query candidate count + median latency.

```bash
cd pkg/kernels/gist
zig build -Doptimize=ReleaseFast bench                 # default Billy source roots
zig build -Doptimize=ReleaseFast bench -- services libs # scope to specific dirs
```

The run step sets cwd to the repo root, so dir arguments are repo-root-relative.
The candidate count is a **sound superset** of `rg`'s true match-file count; the
gap is the trigram filter's false-positive rate (verified away by the caller's
real regex). Set the numbers against a correctly-scoped `rg` baseline (scope to
source dirs — an unscoped `rg` from repo root drags through ~99 GB of `target/`

- caches and is not a fair comparison).
