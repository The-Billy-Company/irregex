# zig-dup-helper ratchet

One definition per helper. The same helper body must not be copy-pasted across
files — that is the parity-bug class where twin engines share a hand-copied
helper, a fix lands in one copy, and the other silently keeps the bug.

## Detection (conservative by design)

A finding is a container-level `fn` body that is **byte-identical after
normalization across ≥ 2 different files**. Normalization strips comments and
collapses whitespace; string-literal content is preserved, so two bodies that
differ only in a message are distinct.

Only *substantial* bodies participate — ≥ 40 normalized non-space characters AND
≥ 3 statement `;` — so trivial one-line wrappers, which legitimately recur, never
fire. Duplicates *within* one file don't count (a different smell). Parsing is a
comment/string-aware brace matcher that fails closed on unbalanced input.

**Opt-out:** a deliberately-kept identical copy is exempted by a
`// dup-allow: <reason>` marker in the comment block immediately above the fn.

Scope: `src/**/*.zig`, excluding `*_test.zig`, `*.gen.zig`, and generated-header
files.

## Surface

```bash
python3 quality/ratchets/run.py dup-helper             # diff vs dup-helper.baseline (CI gate)
python3 quality/ratchets/run.py dup-helper --refresh   # rewrite after a deliberate dedup pass
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
