Replaced the README's two pre-CSR-index-rewrite figures (`gist-competitive`,
`gist-field-race`) with four new ones driven by a full fresh run of the
seven-tool field race and the fail-closed certificate:
`gist-cold-field` (11-needle cold literal range + win rate), `gist-warm-dominance`
(warm-session geomean/miss plus a 50-query session-time comparison),
`gist-regex-matrix` (all 22 regex tiers × all 7 tools), and `gist-certify-forest`
(median + 95% CI forest plot for the fail-closed certificate). The certificate's
2 previously-flaky-export classes finished clean on re-run: gist now goes
9 win · 2 loss vs ripgrep across all 11 probe classes (up from 8/3 pre-rewrite),
and edges out zoekt on cold-query geomean (1.09×) for the first time — the
accompanying prose numbers throughout the Benchmarks section were updated to
match.
