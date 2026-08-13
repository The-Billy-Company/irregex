# kernel/regex/pcre2 — opt-in PCRE2 JIT backend

The escape hatch for lookaround, backreferences, and named captures the linear Thompson/DFA tier cannot express. It is selected by `-P`/`--pcre2`, or by `--engine auto` only when the linear compiler returns unsupported.

Its hermetic sources live at [`../../../../vendor/pcre2/`](../../../../vendor/pcre2/) (PCRE2 10.47). There is no dependency on a system `libpcre2`.

## Files

- **`ffi.zig`** is the minimal explicit-`extern` C-ABI surface of the vendored 8-bit library (`_8` symbols). It uses no `@cImport`; `build.zig` links `pcre2Library`.
- **`engine.zig`** defines the `Pcre` handle: compile (JIT plus interpreter fallback), an immutable shared program, per-thread `Sim` scratch, `lineMatch`/`docMatch`/`bufMatch`, and the caller ceilings below.
- **`literal.zig`** does sound required-literal extraction for the trigram prefilter — the longest ASCII run every match must contain, or `""`. It never over-claims.
- **`shadow.zig`** builds a linear-time over-approximation of a PCRE pattern, so the byte-class DFA pre-filters and PCRE2 only confirms survivors. It rewrites by erasure (assertions), splice (backreferences), and relaxation (atomics/possessive).
- **`captures.zig`** bridges capture groups, unified with the linear capture shape.
- **`backend.zig`** is the stable module entry wiring `Pcre`/`Options`/`Span` into the engine-neutral `Matcher` seam (`../matcher.zig`).
- **`backend_test.zig`** holds adversarial tests: lookaround, backreferences, resource ceilings, invalid UTF-8, JIT-versus-interpreter parity, and the shadow's gated-versus-ungated differential.

## The Shadow

`shadow.zig` rewrites a PCRE pattern into this package's linear syntax such that the shadow's language is a superset of the PCRE language. A line the shadow rejects provably cannot match, so the O(1)/byte DFA answers it and PCRE2 never touches those bytes. The same containment makes the shadow's NFA-derived literals sound for the PCRE pattern, handing `-P` queries the trigram index prefilter they would otherwise lack.

Every rewrite rule is provably language-growing or language-preserving.

- **Erasure.** Every zero-width assertion is dropped; dropping a constraint only grows the language.
- **Splice.** A backreference is spliced with a rewritten copy of its group's source.
- **Relaxation.** Atomic groups and possessive quantifiers become greedy; removing commitment only adds matches.

Anything whose containment is not trivially provable — recursion, subroutine calls, conditionals — bails: no shadow, and PCRE2 runs raw exactly as before. Under-approximating the *rewriter* costs only speed; over-approximating the *language* would be a soundness bug.

## Caller Ceilings

`compileLimited` takes a `mark.Limits`, and every `Sim` built from that program runs under it. A null field is *this arm's own default*, not "unlimited", so an all-null `Limits` builds the match context the arm has always built — a 10,000,000-step budget, a 10,000-frame depth, and no heap ceiling at all.

| Field | Reaches PCRE2 as | Notes |
|---|---|---|
| `steps` | `pcre2_set_match_limit` | Honored by the JIT as well as the interpreter |
| `depth` | `pcre2_set_depth_limit` | Interpreter only |
| `heap_bytes` | `pcre2_set_heap_limit` | Interpreter only; PCRE2 counts it in **kibibytes**, so the conversion floors |
| `states` | — | Inert: this arm builds no automaton |

Naming `depth` or `heap_bytes` **withdraws the JIT**. PCRE2's fast path forwards `limit_match` alone, so a JIT-compiled program would silently ignore those two — and a ceiling the fast path does not read is a safety property in name only. The interpreter is always the guaranteed fallback, so the cost is speed and the gain is that the ceiling is real.

A ceiling the caller actually named reads back as `ceilingHit()` (which one) and `budgetVerdict()` (`error.BudgetExceeded`). A ceiling they did *not* name — the arm's own default tripping on catastrophic input — stays the fail-closed no-match it has always been, because a fault about a request nobody made would be a lie.

## Invariants

- **Concurrency.** One compiled `Pcre` is shared read-only; all mutable match state is per-thread scratch. PCRE2 match data is never shared.
- **Resource caps.** A match limit or depth limit trips a clean no-match instead of hanging, fail-closed.
- **Unicode and invalid UTF-8.** UTF plus UCP plus `PCRE2_MATCH_INVALID_UTF` lets binary or partial text match valid spans without erroring, matching `rg -P`.
- **Sound literals or none.** If sound literals cannot be proven, the engine scans rather than risk a false-negative elision.

## When To Edit

Edit here for vendor version bumps, resource ceilings, shadow rewrite rules, or literal-extraction soundness. Linear-default patterns do not belong here; keep them in `../linear/`.
