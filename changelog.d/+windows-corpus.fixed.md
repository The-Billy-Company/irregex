---
doc_radar:
  sentinels:
    - file: src/corpus/tree/haystack.zig
      contains: ['paths.slashInPlace(buf);']
    - file: src/exec/session/watch/notify.zig
      contains: ['const Action = enum(u32)', 'directory and haystack.isPolicySkip(std.fs.path.basename(rel))', 'self.session.dirty_log.note(std.fs.path.dirname(path) orelse root.abs)']
    - file: .github/workflows/windows.yml
      contains: ['test_filter:', "github.event_name == 'workflow_dispatch' && inputs.test_filter || ''"]
---

We keep corpus paths slash-separated on Windows, discard notifications for excluded directory entries, and track parent membership changes without widening in-place file edits. The adverse-packet proof checks permanent distrust while the real subscription stays live. Windows diagnostics can filter the existing suite; normal CI still runs it whole.

The diagnostic errno fixture now follows the [Microsoft CRT contract](https://learn.microsoft.com/en-us/cpp/c-runtime-library/errno-constants), rather than assuming Darwin's numbers on Windows.
