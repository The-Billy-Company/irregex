`gist --rank` now honors ripgrep's default binary-file policy, so the ranked
view is a true reordering of the `gist -l` set rather than a superset. The
`--rank` no-fabrication certificate invariant caught the divergence: because
the ranked read pass scanned every candidate's full bytes, a symbol living
only in a committed binary's symbol table (e.g. `atomic.(*Int32).Store` inside
`scripts/observe/trust/mdns_verify/mdns_verify`) surfaced as a ranked hit that
the locate path — and rg — correctly skip.

- `ranked.zig`'s `fileDoc` clips a NUL-bearing walked file to the bytes rg's
  quit strategy committed before the NUL (`grepfile.committedPrefix`), matching
  the locate default; `-a`/`--text` (`binary_detect = false`) reads the whole
  body as text, exactly as `gist -la` does. The rule threads through all three
  rank paths — cold index (`run`), live `--no-index` (`runLive`), and the warm
  daemon (`renderLive`, where the resident rank path previously leaked binaries
  its own `-l`/`-c` visitors already dropped).
- The `--rank` certificate lane report (`certify_rank_report.py`) now parses
  ranked rows whose paths contain spaces (`(.+?)` up to the `:line [kind]`
  anchor, not `\S+?`) and decodes captures with `surrogateescape`, so a
  non-UTF-8 source line can no longer abort the whole lane.

Proven by a new fail-closed `fileDoc` unit test and re-validated end-to-end:
all six rank probes hold 0 fabrication.
