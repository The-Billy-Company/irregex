---
doc_radar:
  sentinels:
    - file: .github/workflows/windows.yml
      contains: ['test_optimize:', 'default: ReleaseSafe', '-Dtest-optimize=$($env:IRREGEX_TEST_OPTIMIZE)']
    - file: build.zig
      contains: ['"test-optimize"', 'orelse .ReleaseSafe;']
---

We can select Debug for a filtered Windows diagnostic run and get the test runner's existing assertion traces. Full and reusable Windows runs keep their ReleaseSafe default.
