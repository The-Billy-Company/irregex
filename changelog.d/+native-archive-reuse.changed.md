---
doc_radar:
  sentinels:
    - file: bindings/go/scripts/vendor_libraries.py
      contains: ['"--native-archives"', 'reuse(native_archives, target.zig, target.cpu, archive)']
    - file: bindings/rust/scripts/vendor_libraries.py
      contains: ['"--native-archives"', 'reuse(native_archives, target.zig, target.cpu, archive)']
    - file: tools/archives.py
      contains: ['version not in parity["stamped"](blob)', 'destination.write_bytes(blob)']
---

We can refresh the Go and Rust archives from the existing hosted release export. The owning scripts select the producer's exact target and CPU, require this tree's version, and run their usual floor, strip and consumer-link checks on a private copy. Missing or stale inputs fail without a local rebuild. Local native builds remain the default; artifact provenance still requires the workflow's exact source identity.
