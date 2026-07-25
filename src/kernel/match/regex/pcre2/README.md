---
doc_radar:
  sentinels:
    - description: "Pcre handle remains the opt-in backend surface"
      file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/engine.zig
      contains: ["pub const Pcre", "lineMatch"]
    - description: "literal extraction never over-claims for index elision"
      file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/literal.zig
      contains: "pub fn"
---

# `kernel/match/regex/pcre2/` — opt-in PCRE2 JIT backend

The escape hatch for lookaround, backreferences, and named captures the
linear Thompson/DFA tier cannot express. Selected by `-P` / `--pcre2`, or by
`--engine auto` only when the linear compiler returns unsupported.

Hermetic sources: [`../../../../../vendor/pcre2/`](../../../../../vendor/pcre2/)
(PCRE2 10.47). No system `libpcre2`.

## Files

| File           | Job                                                                                                                                            |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `ffi.zig`      | Minimal explicit-`extern` C-ABI surface of the vendored 8-bit library (`_8` symbols). No `@cImport`; `build.zig` links `pcre2Library`.         |
| `engine.zig`   | `Pcre` handle: compile (JIT + interpreter fallback), immutable shared program, per-thread `Sim` scratch, `lineMatch` / `docMatch` / `bufMatch` |
| `literal.zig`  | Sound required-literal extraction for the trigram prefilter — longest ASCII run every match must contain, or `""`. Never over-claims.          |
| `captures.zig` | Capture-group bridge unified with the linear capture shape                                                                                     |
| `backend.zig`  | Wiring into the engine-neutral `Matcher` seam in `../linear/ladder/matcher.zig`                                                                |

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

Vendor version bumps, resource ceilings, or literal-extraction soundness.
Linear-default patterns do not belong here — keep them in `../linear/`.
