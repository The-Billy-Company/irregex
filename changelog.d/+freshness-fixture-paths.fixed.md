---
doc_radar:
  sentinels:
    - file: src/corpus/fresh/fresh_test.zig
      contains: ['paths.slashed(fx.arena.allocator(), portal.scratchDir(&scratch))', 'try std.testing.expect(c.ctime >= fx.anchor_ns);', 'try std.testing.expect(!Fixture.surfaced(&out, quiet));']
---

We compare the real-tree freshness proof against canonical corpus paths on Windows. Ordinary writes, preserved-mtime writes and path replacement keep their existing timestamp and membership assertions; the fixture now gives its expected paths the same slash spelling as the walk.
