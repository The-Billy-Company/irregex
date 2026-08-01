The rg-conformance suite scored `-e ')('` as a design decline — *gist refuses
this by design, use `-P`* — which was never true, and the new diagnostic made it
say so out loud. Chasing it down turned up something better than a
classification bug.

`)(` is not a regex. ripgrep answers it anyway because it wraps every pattern in
`(?:...)`, which pairs the user's stray parens with its own: `)(` compiles as
`(?:)()`, a valid pattern matching the empty string at every position, which is
exactly what `rg --json` reports. So rg's exit 0 is not evidence that the pattern
is valid — it silently searched for something nobody asked for. gist refuses it,
and PCRE2 agrees there is nothing there to compile.

The case is still NA, because gist cannot claim parity with an answer it
considers wrong, and it is not a FAIL, because refusing a malformed pattern is
the fail-closed contract working. What changed is that the recorded reason is now
the true one. `is_malformed_refusal` reads the engine's own verdict — the CLI
prints that line only after PCRE2 refused too — so the scorer is not re-deriving
a judgment the engine already made.

The differential fuzzer learns the same verdict as `malformed`, kept separate from
`declined` because the two ask for opposite responses: one means another tier
could answer this, the other means no tier can. Without it a generated `)(` would
have landed in the ratcheted residual as a fresh divergence class and failed the
next certificate mint over a case gist gets right.

Scoreboard unmoved: 411 PASS / 14 NA / 21 SKIP, 100.0% supported-surface parity.
