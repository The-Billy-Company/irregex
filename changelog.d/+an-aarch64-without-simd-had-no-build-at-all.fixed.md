An AArch64 target without NEON now builds. It did not, and the failure was a
hard compile error rather than a slow path.

`lanes.native` is the gate that decides whether to arm the 32-lane composition,
and it read `switch (builtin.cpu.arch) { .aarch64, .aarch64_be => true, else =>
false }`. NEON is an optional AArch64 feature, not a guaranteed one. So on any
profile without SIMD the gate said yes, `run` dispatched to `runNative`,
`Algebra.compose` reached `shufflePair`, and that function's own
`@compileError` - "lanes.shufflePair is NEON-only - callers gate on `native`" -
ended the build. Nothing shipped for that target. `zig build
-Dtarget=aarch64-linux-gnu -Dcpu=baseline-neon` reproduces it exactly.

The leaf stated its requirement in the feature's terms and the gate in front of
it answered in the architecture's, which is the same mistake the `isa-floor`
ratchet exists to stop one level down, in the `asm` blocks. A ratchet that reads
asm templates cannot see a boolean derived from the wrong question. So the gate
now asks the same question the leaf does: `builtin.cpu.has(.aarch64, .neon)`.

Big-endian was never affected - `cpu.has(.aarch64, .neon)` is true on
`aarch64_be`, so the arm the old switch reached for by name it now reaches by
capability, and that target builds before and after. x86_64 at baseline was not
affected either; its 16-lane shuffle has a portable arm to fall back to, where
the 32-lane one has none.

`zig build check-portable` is the new step that keeps it fixed, and it fails
with the original error the moment the arch-shaped predicate comes back.
