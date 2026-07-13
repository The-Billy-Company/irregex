`ratio_regress.py` + `ratio_baseline.json` gate gist's cold gist/rg speedup
floors (principia-style ratios). The hermetic `--committed` mode reads the
published `certify_macro.csv`; `GIST_BENCH=1 make bench-gist-ratio` optionally
remeasures live. The certificate artifact is republished under
`bench/certify/artifact/` (**11 win / 0 parity / 0 loss** vs ripgrep on Apple
M4 Max) so README cold-dominance claims are evidence again, and `ci_order.sh`
runs the ratio gate after the bundle integrity check.
