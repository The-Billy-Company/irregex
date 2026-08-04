# zig-dup-helper ratchet

One definition per helper. The same helper body must not be copy-pasted across
files — that is the parity-bug class where twin engines share a hand-copied
helper, a fix lands in one copy, and the other silently keeps the bug.

## The Detection Rule

Detection is deliberately conservative. A finding is a container-level `fn`
body that is byte-identical after normalization across two or more different
files; normalization strips comments and collapses whitespace, while
string-literal content is preserved, so two bodies that differ only in a
message are distinct.

Only *substantial* bodies participate — 40 or more normalized non-space
characters and 3 or more statement `;` — so trivial one-line wrappers, which
legitimately recur, never fire. Duplicates *within* one file don't count (a
different smell). Parsing is a comment/string-aware brace matcher that fails
closed on unbalanced input.

A deliberately-kept identical copy opts out with a `// dup-allow: <reason>`
marker in the comment block immediately above the `fn`.

Scope: `src/**/*.zig`, excluding `*_test.zig`, `*.gen.zig`, and generated-header
files.

## Surface

```bash
python3 quality/ratchets/run.py dup-helper             # diff vs dup-helper.baseline (CI gate)
python3 quality/ratchets/run.py dup-helper --refresh   # rewrite after a deliberate dedup pass
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
