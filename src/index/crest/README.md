---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/math/crest.zig
    - pkg/kernels/irregex/research/crest/PROOF.md
  sentinels:
    - file: pkg/kernels/irregex/src/index/crest/sidecar.zig
      contains:
        - "GISTCRS1"
        - "pub fn decode"
---

# index/crest — the persisted crest-vector sidecar

The disk half of the **crest sieve** (kernel: `src/math/crest.zig`, proof:
`research/crest/PROOF.md`): one `u16^K` crest vector per indexed doc, doc-id
order, staged under the same `gens/<id>/` directory and published by the same
`pair.gen` flip as `index.gist`/`paths.list` — so a reader can never pair the
table with a foreign doc-id space.

| File | Concern |
| --- | --- |
| `sidecar.zig` | codec (`writeInto`/`decode`, fail-closed) + the parallel `build` pass |
| `sidecar_test.zig` | round-trip identity + adversarial malformed-blob suite |

`decode` is zero-copy over the caller's mapping and returns null on **any**
disagreement (magic, doc count, lattice arity, element width, exact length,
alignment); the query then simply runs without the sieve. Consumers: the
read-elision oracles in `runtime/cold/engine/{serial,parallel}.zig`.
