New `irregex` binary — the composed third face (ADR-367) over the one kernel:
the exact engine narrows a typed `CandidateSet`, then the compression engine
reasons only inside that subset, so an exact intent scopes the statistical one
instead of a caller unioning two independent queries by hand. Three closed
verbs: `context TEXT -e P…` (coverage packing over only the files that match
the patterns — each pick carries its exact mask AND its marginal bits, never a
fused score), `family PATTERN {--max-distance | --echo-min}` (fork families —
byte near-duplicates or renamed structural twins — among only the matching
files), and `provenance TEXT` (quote attribution re-verified against each
source's CURRENT bytes, so a phrase surfaces only if the live file still holds
it — never a stale line). `context`/`family` require an explicit scope
(`ROOT…` or `--all`); results on stdout (`--json` = NDJSON), diagnostics on
stderr, unknown verbs exit 2. The pure composition kernels live under
`src/search/compose/`; `gist` and `relate` stay the direct faces and forward
none of their verbs. Installed alongside them by `make install-gist`.
