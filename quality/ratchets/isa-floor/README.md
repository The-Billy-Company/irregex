# zig-isa-floor Ratchet

An inline `asm` block must ask for the feature it needs, not the architecture
that usually has it — that is the whole rule this gate freezes.

## Why This Exists

LLVM checks every instruction *it* selects against the target's subtarget. It
checks nothing inside an `asm` block — the template is a string handed to the
assembler, and the assembler encodes what it is given. So this compiles, links,
and ships:

```zig
return switch (builtin.cpu.arch) {
    .x86_64 => asm ("pshufb %[i], %[o]" ...),  // SSSE3
    ...
};
```

`pshufb` is SSSE3. The x86_64 baseline is SSE2. Nothing in the build says
otherwise, so an artifact built for generic x86_64 carries an instruction its
declared floor never promised — and a wheel tag has no way to say "actually,
SSSE3", so the first machine that took the tag at its word gets `SIGILL`
instead of a match.

That was live: the published `manylinux_2_17_x86_64`, `win_amd64`, and
`macosx_11_0_x86_64` artifacts each carried 55 `pshufb` sites under a declared
SSE2 floor. The fix was to predicate each arm on its feature, which is comptime
and free:

```zig
if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb %[i], %[o]" ...);
```

## The Rule

One finding per inline `asm` block whose mnemonic is not in `BASE_ISA` and
which no `cpu.has(` predicate covers, where "covers" means the predicate stands
between the enclosing `fn` declaration and the asm block. A negated guard
counts — a leaf helper with no fallback that `@compileError`s off-feature has
stated its precondition just as well as one that branches.

`BASE_ISA` is the exempt set: mnemonics in their architecture's *mandatory*
base ISA, where there is no optional feature to ask about and selecting on
`builtin.cpu.arch` is the whole truth. It holds one entry (`add`) and the check
fails closed around it — an unclassified mnemonic needs a guard. Adding to
the set is a one-line change that makes the claim "this needs no optional
feature" something a reviewer sees, rather than something silence implies.

## Scope

`src/**/*.zig`, minus `*_test.zig`, `*_fuzz.zig`, `*.gen.zig`, and
generated-header files. Inline `test "…" { … }` blocks stay *in* scope, unlike
the sibling ratchets: a test is compiled for the target too, and an illegal
instruction there is just as illegal.

Matching runs on a comment/string-blanked copy (`quality/ratchets/_lib/zigtext.py`),
so an `asm (…)` named in a doc comment is prose. The mnemonic itself is read back
out of the original bytes at the blanked copy's offset, because the asm template
*is* a string literal and has to survive blanking somewhere.

## What Is in the Baseline

Nothing. Every asm block in the tree is either feature-guarded or base-ISA, so
this gate is a floor rather than a burn-down, and any new row is a regression.
`test_isa_floor_ratchet.py` keeps that honest from both ends: it asserts the live
scan is empty, and it re-runs the detector against the *pre-fix* text of
`lanes.shuffle` to prove an empty baseline means "clean" and not "broken".

## Surface

```bash
python3 quality/ratchets/run.py isa-floor             # diff vs the baseline (CI gate)
python3 quality/ratchets/run.py isa-floor --refresh   # rewrite after a cleanup
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
