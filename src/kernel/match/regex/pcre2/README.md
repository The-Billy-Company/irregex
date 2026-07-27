---
doc_radar:
  sentinels:
    - description: "Pcre handle remains the opt-in backend surface"
      file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/engine.zig
      contains: ["pub const Pcre", "lineMatch"]
    - description: "literal extraction never over-claims for index elision"
      file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/literal.zig
      contains: "pub fn"
    - description: "the shadow pre-filters PCRE patterns with a linear over-approximation"
      file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/shadow.zig
      contains: ["overapprox", "Bail"]
---

# `kernel/match/regex/pcre2/` — opt-in PCRE2 JIT backend

The escape hatch for lookaround, backreferences, and named captures the
linear Thompson/DFA tier cannot express. Selected by `-P` / `--pcre2`, or by
`--engine auto` only when the linear compiler returns unsupported.

Hermetic sources: [`../../../../../vendor/pcre2/`](../../../../../vendor/pcre2/)
(PCRE2 10.47). No system `libpcre2`.

## Files

| File               | Job                                                                                                                                                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ffi.zig`          | Minimal explicit-`extern` C-ABI surface of the vendored 8-bit library (`_8` symbols). No `@cImport`; `build.zig` links `pcre2Library`.                                                                                  |
| `engine.zig`       | `Pcre` handle: compile (JIT + interpreter fallback), immutable shared program, per-thread `Sim` scratch, `lineMatch` / `docMatch` / `bufMatch`.                                                                          |
| `literal.zig`      | Sound required-literal extraction for the trigram prefilter — longest ASCII run every match must contain, or `""`. Never over-claims.                                                                                    |
| `shadow.zig`       | A linear-time **over-approximation** of a PCRE pattern, so the byte-class DFA pre-filters and PCRE2 only confirms survivors. Rewrites by erasure (assertions), splice (backrefs), and relaxation (atomics/possessive). |
| `captures.zig`     | Capture-group bridge unified with the linear capture shape.                                                                                                                                                              |
| `backend.zig`      | Stable module entry wiring `Pcre`/`Options`/`Span` into the engine-neutral `Matcher` seam (`../linear/ladder/matcher.zig`).                                                                                             |
| `backend_test.zig` | Adversarial tests: lookaround, backrefs, resource ceilings, invalid UTF-8, JIT↔interpreter parity, and the shadow's gated-≡-ungated differential.                                                                       |

## The shadow — linear pre-filter for backtracking patterns

`shadow.zig` rewrites a PCRE pattern into gist's linear syntax such that the
shadow's language is a **superset** of the PCRE language. A line the shadow
rejects provably cannot match, so the O(1)/byte DFA answers it and PCRE2 never
touches those bytes. The same containment makes the shadow's NFA-derived
literals sound for the PCRE pattern, handing `-P` queries the trigram index
prefilter they would otherwise lack.

The rewrite rules (each provably language-growing or -preserving):

- Every zero-width assertion is **erased** — dropping a constraint only grows
  the language.
- A backreference is **spliced** with a rewritten copy of its group's source.
- Atomic groups / possessive quantifiers → greedy — removing commitment only
  adds matches.

Anything whose containment is not trivially provable (recursion, subroutine
calls, conditionals) **bails**: no shadow, PCRE2 runs raw exactly as before.
Under-approximating the *rewriter* costs only speed; over-approximating the
*language* would be a soundness bug.

## Invariants

- **Concurrency** — one compiled `Pcre` shared read-only; all mutable match
  state is per-thread scratch. PCRE2 match data is never shared.
- **Resource caps** — match limit / depth limit trip a clean no-match instead
  of hanging (fail-closed).
- **Unicode / invalid UTF-8** — UTF+UCP + `PCRE2_MATCH_INVALID_UTF` so binary
  / partial text matches valid spans without erroring (`rg -P` parity).
- If sound literals cannot be proven, gist **scans** rather than risk a
  false-negative elision.

## When to edit

Vendor version bumps, resource ceilings, shadow rewrite rules, or
literal-extraction soundness. Linear-default patterns do not belong here —
keep them in `../linear/`.
