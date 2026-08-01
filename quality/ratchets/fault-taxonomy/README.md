# zig-fault-taxonomy ratchet

**The irregex fault vocabulary is closed.** Zig unifies error names globally, so
`error.Corrupt`, `error.BadFormat` and `error.CorruptIndex` all meaning "these
persisted bytes are untrustworthy" was worse than untidy — synonyms cannot be
handled uniformly and homonyms merge silently. Five domains are declared once in
`src/fault.zig` and mirrored in `contract/engine.toml`'s `[fault_domains]` block.
This ratchet is what stops a sixth spelling from accreting the same way.

## The rule

One finding per error name **produced** by production Zig that is not a member of
a declared `[fault_domains]` domain. The vocabulary is read from
`contract/engine.toml` at run time — the driver hardcodes no member list — and a
missing or empty block is a hard error, never an empty allowlist that flags the
world.

**Synonymy is not judged semantically.** No mechanical rule can decide that
`BadFormat` means what `Corrupt` means, and a ratchet that guessed would be
unpredictable. So it enforces the property that makes synonyms impossible —
closure — and a new spelling of an existing fact is caught the same way a
genuinely new fact is. Only the fix differs: map it onto the existing member, or
add a member to the contract *and* to `fault.zig`.

## Structural exclusions (never a list of names)

| Excluded | Why |
| --- | --- |
| `*_test.zig` · `*_fuzz.zig` · inline `test "…" { … }` blocks | `error.SkipZigTest` / `error.TestUnexpectedResult` are std.testing's, and a fuzz harness's `error.LoadersDisagree` is an oracle assertion, not a kernel fault |
| a name declared only in a **non-`pub` named `const`** error set | file-private control flow — it cannot reach another module's handler, so it cannot become a synonym anyone must unify. This is the PCRE2 shadow rewriter's `const Err = error{ Bail, OutOfMemory };` |
| a **consuming** `error.X` — a `=>` prong label or an `==` / `!=` operand | it *handles* a name that came from elsewhere (usually `std`), it does not mint one. This is what keeps every propagated std error out of the count without maintaining a list of std error names |
| a `return error.X` from a function whose **declared error set is std's own** | the signature obliges it. `portal.ntMap` returns `MapError!Mapping` where `const MapError = std.posix.MMapError`, so `error.PermissionDenied` there is std's vocabulary restated, not irregex's minted — the POSIX arm of the same `pub fn map` returns the identical name from inside `std.posix.mmap`, where nothing counts it either |

Deliberately narrow: an *inline* anonymous set in a private function signature
does **not** count as private, because an inferred error set propagates it out of
the file anyway. Matching runs on a comment/string-blanked copy of each file
(`quality/ratchets/_lib/zigtext.py`), so a name quoted in a doc comment is prose.

## Why the std-set exclusion cannot be gamed

It rests on the **compiler**, not on this driver knowing what std's members are.
A function declaring an explicit error set may only `return` a member of it, and
Zig rejects anything else at that exact token — so minting a private name inside
one of these bodies is not a finding the rule hides, it is a build failure.
Every fence exists to keep that guarantee load-bearing:

- **Per function, innermost.** A nested `fn` is judged on its own signature, so
  a closure inside a std-set body earns no amnesty, and neither does the rest of
  the file.
- **`return error.X` only.** A name bound to a local, or declared in an
  `error{…}` set inside the body, is never coerced into the declared set, so the
  compiler proves nothing about it and neither does the ratchet.
- **An explicit set only.** `!T` infers its set from whatever the body returns —
  the opposite of a closed vocabulary — so an inferred signature is never
  excluded.
- **The root is pinned.** The rule engages only in a file that binds `std`, in
  real code, *only* to `@import("std")`; one level of local aliasing is resolved
  (`MapError`, or a head alias like `const posix = std.posix`), and a name bound
  twice resolves to nothing. So `const MapError = error{ Sneaky };` and
  `std.posix.MMapError || error{ Sneaky }` both stay counted.

Scope: `src/**/*.zig`, minus the suffixes above, `*.gen.zig`, and
generated-header files.

## The three fixes

1. **A new spelling of an existing fact** (`BadFormat`/`CorruptIndex` → `Corrupt`)
   — import `src/fault.zig` and return the declared member.
2. **A declinature** ("a slower tier can answer this") — it is not a fault at
   all. Return `fault.Answer(T){ .declined = … }` with one of the
   `[decline_reasons]` in `contract/engine.toml`.
3. **A genuinely new fault the taxonomy lacks** — add the member to the right
   domain in `src/fault.zig` **and** to `[fault_domains]`. Both, or the mirror
   check fails.

## Surface

```bash
python3 quality/ratchets/run.py fault-taxonomy             # diff vs the baseline (CI gate)
python3 quality/ratchets/run.py fault-taxonomy --refresh   # rewrite after a deliberate cleanup
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
