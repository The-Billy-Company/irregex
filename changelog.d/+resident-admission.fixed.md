---
doc_radar:
  sentinels:
    - file: src/exec/session/reconcile/annals.zig
      contains: ['haystack.underSkippedDir(rel, haystack.isPolicySkip)']
    - file: src/corpus/fresh/fresh.zig
      contains: ['haystack.underSkippedDir(path, haystack.isSkipDir)']
    - file: src/exec/session/watch/inotify.zig
      contains: ['haystack.isPolicySkip(e.name)', 'self.session.dirty_log.note(parent);']
    - file: src/exec/session/watch/rig.zig
      contains: ['.macos, .linux, .windows => true']
---

We keep resident watch admission aligned with cold search. Unignored baseline directories stay covered, their edits advance the annals and retire held answers, and declared policy subtrees stay excluded. Persisted index freshness keeps its baseline skips. Linux joins the shared real-tree barrier suite and records parent membership for entry changes; the Windows freshness fixture now expects our canonical slash spelling throughout.
