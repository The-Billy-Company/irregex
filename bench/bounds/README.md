# bench/bounds

**Distance from a stated limit** — Layers B–D of this package's own
certificate, plus a pointer to Layer F, which lives with the kinship package.
Where the face package's `bench/dominance/` measures the shipped CLI against
rivals, this bucket measures the engine against *physics and information
theory*: the memory roof, the candidate-byte floor, and the static/measured
instruction budget.

- **[`port/`](port/README.md)** was `portcert/` — the portability and
  instruction budget: `measure.zig` on-machine plus `mca.sh` (`llvm-mca`
  static) feeding `report.py`.

- **[`roofline/`](roofline/README.md)** is the memory roof — `bandwidth.zig`
  measures achievable bandwidth, and `report.py` places the engine's real
  scan against it.

- **[`lowerbound/`](lowerbound/README.md)** is the information-theoretic
  candidate-byte floor — `audit.zig` plus `report.py`.

- **The kinship package's `bench/bounds/codex/`** is the self-index against
  its own order-0 entropy bound — `scale.zig` plus `race.sh`, which drives
  Layer F.

These three splice into this package's own certificate by running
`certificate/mint/mint.sh`; the frozen numbers live in
`certificate/artifact/`.
