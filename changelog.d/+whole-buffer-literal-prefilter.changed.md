Close the searcher-loop gap to ripgrep on needle-less literal alternations
(`function|const|return|struct`) — the case with no single required literal for
the existing per-line gate to skip on, so gist ran the engine on EVERY line
while `rg` scanned the whole buffer through a Teddy prefilter. A new fused
multi-literal primitive `scan.simd.indexOfAnyPos` (the position-returning twin of
`containsAny`: one pass, per-needle first+last-byte SIMD fingerprints OR'd into a
survivor mask, leftmost verified survivor wins) drives a whole-buffer prefilter:
one sweep marks the candidate lines around literal hits, and the per-line
classify then skips ~every non-candidate without an engine run. Wired into both
the text emit (`output.zig` — `file`/`onlyMatching`/`countMatches`/`passthru`)
and the `--json` classification (`json.zig`), gated on `re.lits`
(`analysis.pureLiterals` — the same match-equivalence set `matchSpan` uses, empty
under `-i`/`-w`/`-U`). The mask is a SUPERSET of the true match set (a hit in a
line's trailing `\r`/terminator maps to that line — the engine still confirms
each candidate), never a subset, and declines under `-v` (a match LACKS the
literals) and `--stop-on-nonmatch`, so output stays byte-identical.

Byte-identical to ripgrep — `bench/rgsuite` `run.py` 409/409 (parallel and
serial), the `indexOfAnyPos` differential-fuzz oracle green (leftmost-hit vs the
`std.mem.indexOfPos` minimum over random needle sets/resume offsets), and 49/49
edge-corpus spot-checks (no-trailing-newline, CRLF, single-line, first/last-line
hits, blank-line runs, empty) across `-o`/`-c`/plain/`-n`/`--column`/`-A`/`-v`.
Measured on a 57 MB single-file corpus (A/B vs the pre-change litSpan binary):
`-o function|const|return|struct` 257→76 ms (3.4×), `--json` 283→102 ms (2.8×),
`-c` 230→51 ms (4.5×). The gap to `rg` on the alternation collapses from 11.8× to
3.6× (`-o`), 3.9× to 1.5× (`--json`), and 14× to 3.0× (`-c`).
