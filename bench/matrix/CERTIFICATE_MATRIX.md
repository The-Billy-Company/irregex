# gist CLI-shape admission matrix — measured

_gist cold-indexed vs ripgrep over the six Billy source roots. A WIN needs a lower median **and** Mann-Whitney p < 0.05 (fail-closed). Parity is correctness-proven separately (`matrix.py parity`: gist-idx == gist-noidx == rg). Every shape is a declared win — the former `-U` losses fell to the parallel multiline DFA and the former backref parity to the PCRE2 shadow gate; a future declared `loss` would stay report-only in its own row so no aggregate can bury it._

| shape                                 | dims                                         | gist ms |   rg ms | speedup |      p | verdict |
| ------------------------------------- | -------------------------------------------- | ------: | ------: | ------: | -----: | :------ |
| `literal-rare-files`                  | linear·fixed·rootless·files·rare             |    44.2 |   400.4 |   9.07x | <0.001 | ✅ win  |
| `literal-common-files`                | linear·fixed·rootless·files·common           |    94.7 |   426.0 |   4.50x | <0.001 | ✅ win  |
| `literal-rare-count`                  | linear·fixed·rootless·count·rare             |    45.3 |   402.9 |   8.90x | <0.001 | ✅ win  |
| `literal-rare-lines`                  | linear·fixed·rootless·lines·rare             |    44.9 |   403.7 |   8.99x | <0.001 | ✅ win  |
| `literal-rare-only-matching`          | linear·only-matching·rootless·lines·rare     |    51.2 |   408.2 |   7.97x | <0.001 | ✅ win  |
| `word-common-files`                   | linear·word·rootless·files·common            |    64.0 |   413.8 |   6.47x | <0.001 | ✅ win  |
| `ignore-case-rare-files`              | linear·ignore-case·rootless·files·rare       |    61.5 |   401.8 |   6.53x | <0.001 | ✅ win  |
| `maxcount-common-lines`               | linear·max-count·rootless·lines·common       |    99.3 |   428.0 |   4.31x | <0.001 | ✅ win  |
| `invert-count-subtree`                | linear·invert·subtree·count·common           |     3.7 |     8.5 |   2.28x | <0.001 | ✅ win  |
| `regex-anchored-rare-files`           | linear·plain·rootless·files·rare             |    81.3 |   408.7 |   5.03x | <0.001 | ✅ win  |
| `regex-alternation-files`             | linear·plain·rootless·files·common           |    46.0 |   402.3 |   8.74x | <0.001 | ✅ win  |
| `glob-go-rare-files`                  | linear·fixed·glob·files·rare                 |    14.3 |   112.0 |   7.80x | <0.001 | ✅ win  |
| `type-go-rare-files`                  | linear·fixed·type·files·rare                 |    13.9 |   105.6 |   7.58x | <0.001 | ✅ win  |
| `subtree-rare-lines`                  | linear·fixed·subtree·lines·rare              |     6.4 |    68.8 |  10.73x | <0.001 | ✅ win  |
| `pcre-lookahead-rare-files`           | pcre·lookahead·rootless·files·rare           |    45.3 |   383.0 |   8.45x | <0.001 | ✅ win  |
| `pcre-lookahead-common-files`         | pcre·lookahead·rootless·files·common         |    82.2 |   386.3 |   4.70x | <0.001 | ✅ win  |
| `pcre-backref-files`                  | pcre·backref·rootless·files·common           |   671.2 | 10808.6 |  16.10x | <0.001 | ✅ win  |
| `multiline-rare-files`                | multiline·plain·rootless·files·rare          |    92.8 |   391.6 |   4.22x | <0.001 | ✅ win  |
| `multiline-common-lazy-dotstar-files` | multiline·lazy-dotstar·rootless·files·common |    99.1 |   402.8 |   4.07x | <0.001 | ✅ win  |

**19 win · 0 parity · 0 loss** across 19 shapes.
