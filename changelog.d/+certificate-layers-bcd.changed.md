Committed certificate carries all four layers (A–D), and minting is one
command: `make bench-gist-certify` (or `certify.sh`, which auto-splices
B/B′/C/D). `check_artifacts.py` fail-closes if any layer section or side-car
is missing; `CERT_SUDO=1` prompts once for measured kperf cycles.
