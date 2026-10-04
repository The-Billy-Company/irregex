---
doc_radar:
  sentinels:
    - file: src/corpus/tree/haystack.zig
      contains: ['pub fn underSkippedDir(path: []const u8) bool', 'pub fn underPolicySkippedDir(path: []const u8) bool', 'fn underSkip(path: []const u8, comptime skipped: fn ([]const u8) bool) bool']
    - file: src/root.zig
      contains: ['const skipped: *const fn ([]const u8) bool = haystack.underSkippedDir;', 'public haystack underSkippedDir keeps its published unary call and admission', 'public watcher subscription accepts its published named-field initializer']
    - file: src/corpus/fresh/fresh.zig
      contains: ['haystack.underSkippedDir(path)']
    - file: src/exec/session/reconcile/annals.zig
      contains: ['haystack.underPolicySkippedDir(rel)']
    - file: src/exec/session/watch/notify.zig
      contains: ['haystack.underPolicySkippedDir(rel)']
---

We keep the published `haystack.underSkippedDir(path)` call and its persisted-corpus admission. Resident watchers use the declared-policy helper, so unignored baseline directories still retire stale answers.
