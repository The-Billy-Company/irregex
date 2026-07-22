Cut the `--json` record stream's serial-engine cost with two byte-identical
emit-path changes (`src/surface/exec/cold/emit/json.zig`). The classification
loop now threads the engine's required-literal `simd.Gate`
(`serial.zig::requiredLiteralGate`, the same gate the line path uses) from `run`
→ `runParallel`/shards → `emitOne` → `emitFile`: a line lacking the pattern's
forced literal skips the NFA entirely. Sound only when non-inverted — exactly
when the gate exists — so the `-v` classification is unchanged. And each matched
line's spans are now enumerated ONCE at classification and cached on the `Line`
(`matchSpans`), reused for both the `matches` tally (`countMatches` became a sum,
no engine) and `submatches` emission (`emitSubmatches` iterates the cache), so a
matched line pays the engine once instead of up to three times; the dead
`firstSpan` is removed. Byte-identical to `rg --json` on both engines
(`bench/rgsuite` core/multiline/pcre cases green). Measured on a frozen 54 MB /
1.7 M-line single-file corpus (read/walk ≈ 0, serial emit isolated, A/B vs the
pre-change binary): `func` 638→124 ms (5.2×), `func\s+\w+` 966→277 ms (3.5×),
`WalletService` 523→92 ms (5.7×), `import` 591→100 ms (5.9×) — a 3.5–5.9×
internal emit speedup on top of the earlier `jsonstr` SIMD rewrite. This narrows
but does not overtake `rg --json`, which still leads because `--json` disables
gist's index read-elision (it must tally `searches`/`bytes_searched` for every
searched file), racing rg's parallel walk+search+emit without gist's index
advantage; the standing `--json` claim remains byte-parity, not a speed win.
