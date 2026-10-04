---
doc_radar:
  sentinels:
    - file: .github/workflows/release.yml
      contains: ['name: Validate both consumer archive sets', 'name: consumer-archives', 'bindings/go/libirgx_*.a', 'bindings/rust/vendor/**/libirgx.a']
    - file: bindings/go/scripts/vendor_libraries.py
      contains: ['reuse(native_archives, target.zig, target.cpu, archive)']
    - file: bindings/rust/scripts/vendor_libraries.py
      contains: ['reuse(native_archives, target.zig, target.cpu, archive)']
---

We validate both consumer archive sets on the release runner and export their checked bytes. The Go and Rust scripts reuse each producer target, then apply their existing floor, strip and link checks. The separate artifact carries those twelve outputs; the six producer archives retain their existing layout. Manual release builds run the same checks without publishing.
