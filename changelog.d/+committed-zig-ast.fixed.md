---
doc_radar:
  sentinels:
    - file: .githooks/pre-push
      contains: ['sources+=("${path}")', 'mise install --locked -j 1 zig', 'ast-check "./${path}"', 'git archive "${local_sha}"']
---

We check changed Zig files before pushing, using the native AST checker and the pushed commit's locked toolchain. It catches declaration errors without compiling the engine and checks committed bytes even when the working tree has other edits. Markdown-only and Zig-only pushes work with macOS's bundled Bash. Full native CI still proves compilation and behavior.
