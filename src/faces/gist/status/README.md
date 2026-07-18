---
doc_radar:
  sentinels:
    - description: "machine status contract stays versioned and CLI-addressable"
      file: pkg/kernels/irregex/src/faces/gist/status/status.zig
      contains: ["pub const schema_version = 1;", "pub const Snapshot = struct"]
    - description: "status JSON remains discoverable through the CLI"
      file: pkg/kernels/irregex/src/faces/cli/main.zig
      contains: 'std.mem.eql(u8, value, "--json")'
---

# gist/src/faces/gist/status

The `gist status` verb — read-only introspection of the persisted index.

| File         | Role                                                                                                                                                                                                                                                                                                                                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status.zig` | Answers "am I ready to search fast, and how fresh?" — index presence, files indexed, distinct trigrams, postings, on-disk size, build age vs the freshness anchor, corpus roots. Derived from the same mmap'd artifacts the query path loads (`index/persist.zig`) + the freshness anchor (`corpus/fresh.zig`); no build, no scan, no mutation. |

A missing index is reported as an actionable state (run `index`), never an
error, so `status` is safe to call blind. See [`../../../README.md`](../../../README.md).

## Machine contract

`gist status --json` emits one compact, newline-terminated JSON object. It is
derived from the same snapshot as the human report and writes no human prose to
stdout or stderr. The v1 shape is:

```json
{
  "schema_version": 1,
  "state": "ready",
  "index": {
    "path": ".local/gist-verify/index.gist",
    "paths_file": ".local/gist-verify/paths.list",
    "files_indexed": 28194,
    "distinct_trigrams": 518707,
    "postings": 35129882,
    "index_bytes": 44564480,
    "paths_bytes": 1677722
  },
  "freshness": {
    "anchor_unix_ns": 1784160000000000000,
    "age_seconds": 12.5
  },
  "roots": ["services", "libs", "clients", "contracts", "scripts", "quality"]
}
```

Fields are stable within `schema_version: 1`; additions are allowed, while a
rename, removal, type change, or semantic change requires a version bump.
`state` is `ready` only when the persisted index/path pair loads and validates.
Otherwise it is `unavailable`, `index` is `null`, and both freshness values are
`null`. Counts and sizes are integer units (`index_bytes` / `paths_bytes` are
bytes); `anchor_unix_ns` is Unix epoch nanoseconds; `age_seconds` is a
non-negative number measured when the snapshot is collected. `roots` preserves
the configured corpus-root order.
