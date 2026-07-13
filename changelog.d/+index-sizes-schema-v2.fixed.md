`index_size_accounting.py` now emits schema_version 2 (`posting_bytes` /
`path_bytes` / `freshness_bytes` / `required_bytes` / `workspace_bytes` +
`required_files`), matching `check_artifacts.py` — certificate/verify outputs
stay in `workspace_bytes` and no longer inflate the cache total. Unblocks
publishing a HEAD-bound certificate bundle.
