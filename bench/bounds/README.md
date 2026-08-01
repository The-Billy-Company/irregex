# bench/bounds

**Distance from a stated limit** — Layers B–D and F of the certificate. Where
`dominance/` measures gist against rivals, this bucket measures gist against
_physics and information theory_: the memory roof, the candidate-byte floor, the
static/measured instruction budget, and the order-0 entropy bound.

| Folder                                | What                                                                                                                      |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| [`port/`](port/README.md)             | was `portcert/` — the portability/instruction budget: `measure.zig` on-machine + `mca.sh` (llvm-mca static) → `report.py` |
| [`roofline/`](roofline/README.md)     | the memory roof — `bandwidth.zig` measures achievable bandwidth, `report.py` places gist against it                       |
| [`lowerbound/`](lowerbound/README.md) | the information-theoretic candidate-byte floor — `audit.zig` + `report.py`                                                |
| `relate/bench/bounds/codex/`           | the self-index against its order-0 entropy bound — `scale.zig` + `race.sh` (drives Layer F)                               |

These are spliced into the certificate by `certificate/mint/splice.sh`; the
frozen numbers live in `certificate/artifact/`.
