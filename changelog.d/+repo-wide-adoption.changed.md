Graduate GIST from the doc-radar canary to the repository-wide search
substrate (ADR-352): every first-party executable ripgrep consumer now drives
the certified `gist` engine — the trust/codegen lints (`user-id`, `policy`,
`fronts`, `boundary-gates`), doc-radar's count/files/still-here wrappers, the
relocator + restructure + comment-quality + pentest tooling, the
`fetchjson`/`readjson`/`resource_static`/`vox`/chaos shell scripts, and the
Bridge's `atelier_grep` (resolved binary, with `atelier_health` reporting
`gist_available`). Patternless `rg --files` inventories moved to the git index,
each consumer carries a committed `*_gist_parity.py` guard, and a fail-closed
`gist-adoption` ratchet ratchets first-party ripgrep executions to zero. Raw
`rg` survives only as GIST's independent parity/benchmark oracle.
