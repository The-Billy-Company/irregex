---
doc_radar:
  counts:
    - description: "the tier is exactly three primitives + three test siblings + this README"
      glob: pkg/kernels/irregex/src/primitives/*
      unit: files
      equals: 7
  sentinels:
    - description: "the tier is a first-class root export, tests wired into zig build test"
      file: pkg/kernels/irregex/src/root.zig
      contains: ['pub const irregex = struct', 'primitives/sketch_test.zig', 'primitives/patterns_test.zig', 'primitives/loom_test.zig']
    - description: "the frozen sketch resolution this README quotes (bottom-k size, phrase floor)"
      file: pkg/kernels/irregex/src/primitives/sketch.zig
      contains: ['pub const k = 128', 'pub const min_phrase = 3']
---

# `src/primitives/` — the irregular-expression primitives

The tier that makes gist's engine _set-shaped_. A regular expression answers
one question about one pattern; the agent workload asks three others, and this
folder owns their primitives — match ∪ relate ∪ weave — for the faces (CLI
verbs, Python bindings, a future FFI) to consume:

| Module         | Half       | Primitive                                                                                                                                                                                                        |
| -------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `patterns.zig` | **match**  | `PatternSet` — N intents compiled once, exact per-pattern attribution (`docMask` / `lineHits`), a fused `(?:a)\|(?:b)` gate that can only skip work, never change an answer                                      |
| `sketch.zig`   | **relate** | `Sketch` — compression kinship: an LZ78 phrase dictionary bottom-k min-hashed to 128×u64; `distance` = 1 − Jaccard (LZJD, Raff & Nicholas 2017; signal per Benedetto/Caglioti/Loreto's relative-entropy zipping) |
| `loom.zig`     | **weave**  | `Plan` — a closed filter → group → sort → limit op set executed engine-side over attributed `Row`s; data, not a language                                                                                         |

Design rules, inherited from `engine/query.zig` and binding here too:

- **Exactness over the gate.** A `PatternSet` answer must equal N independent
  single-pattern runs, bit for bit — the tests hold it to that oracle, with
  the gate forced both on and off.
- **Fail-closed, never fatal.** Every entry returns a typed error; an
  inexpressible fused gate silently degrades to confirm-only, never to a
  wrong answer or a `die()`.
- **Immutable after compile/build.** Compiled sets and built sketches are
  value-shareable across walk workers; all mutable state lives in caller-owned
  per-thread `Scratch`.
- **Determinism.** Same bytes ⇒ same sketch; same plan + rows ⇒ same answer
  (all orderings are total, ties never swap).

Each `*_test.zig` sibling is wired into `zig build test` via `src/root.zig`.
Fixtures are embedded, never the live tree — this checkout is edited by ~10
agents concurrently.
