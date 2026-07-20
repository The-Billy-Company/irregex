# gist CLI-shape admission matrix — measured

_gist cold-indexed vs ripgrep over the six Billy source roots. A WIN needs a lower median **and** Mann-Whitney p < 0.05 (fail-closed). Parity is correctness-proven separately (`matrix.py parity`: gist-idx == gist-noidx == rg). The one declared `loss` is the known common-`-U` lazy-dotstar hole, kept visible on purpose until the `-U` emit path is parallelized._

| shape | dims | gist ms | rg ms | speedup | p | verdict |
|---|---|--:|--:|--:|--:|:--|
| `literal-rare-files` | linear·fixed·rootless·files·rare | 131.0 | 411.8 | 3.14x | <0.001 | ✅ win |
| `literal-common-files` | linear·fixed·rootless·files·common | 187.4 | 439.2 | 2.34x | <0.001 | ✅ win |
| `literal-rare-count` | linear·fixed·rootless·count·rare | 121.5 | 438.0 | 3.61x | <0.001 | ✅ win |
| `literal-rare-lines` | linear·fixed·rootless·lines·rare | 117.2 | 420.8 | 3.59x | <0.001 | ✅ win |
| `literal-rare-only-matching` | linear·only-matching·rootless·lines·rare | 165.7 | 391.9 | 2.37x | <0.001 | ✅ win |
| `word-common-files` | linear·word·rootless·files·common | 142.4 | 451.2 | 3.17x | <0.001 | ✅ win |
| `ignore-case-rare-files` | linear·ignore-case·rootless·files·rare | 293.4 | 419.0 | 1.43x | <0.001 | ✅ win |
| `maxcount-common-lines` | linear·max-count·rootless·lines·common | 191.9 | 440.6 | 2.30x | <0.001 | ✅ win |
| `invert-count-subtree` | linear·invert·subtree·count·common | 5.1 | 9.0 | 1.78x | <0.001 | ✅ win |
| `regex-anchored-rare-files` | linear·plain·rootless·files·rare | 151.5 | 436.8 | 2.88x | <0.001 | ✅ win |
| `regex-alternation-files` | linear·plain·rootless·files·common | 106.0 | 419.6 | 3.96x | <0.001 | ✅ win |
| `glob-go-rare-files` | linear·fixed·glob·files·rare | 86.6 | 102.3 | 1.18x | <0.001 | ✅ win |
| `type-go-rare-files` | linear·fixed·type·files·rare | 70.5 | 102.4 | 1.45x | <0.001 | ✅ win |
| `subtree-rare-lines` | linear·fixed·subtree·lines·rare | 38.6 | 63.9 | 1.66x | <0.001 | ✅ win |
| `pcre-lookahead-rare-files` | pcre·lookahead·rootless·files·rare | 117.8 | 421.5 | 3.58x | <0.001 | ✅ win |
| `pcre-lookahead-common-files` | pcre·lookahead·rootless·files·common | 181.4 | 400.4 | 2.21x | <0.001 | ✅ win |
| `pcre-backref-files` | pcre·backref·rootless·files·common | 14522.4 | 13596.4 | 0.94x | 0.436 | ≈ parity |
| `multiline-rare-files` | multiline·plain·rootless·files·rare | 868.7 | 727.0 | 0.84x | 0.019 | ❌ loss |
| `multiline-common-lazy-dotstar-files` | multiline·lazy-dotstar·rootless·files·common | 1919.9 | 685.2 | 0.36x | <0.001 | ❌ loss |

**16 win · 1 parity · 2 loss** across 19 shapes.
