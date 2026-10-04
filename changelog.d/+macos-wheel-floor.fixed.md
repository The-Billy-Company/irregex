---
doc_radar:
  sentinels:
    - file: bindings/python/hatch_build.py
      contains: ['out, zig_target=zig_target, zig_cpu=_zig_cpu(zig_target) if zig_target else None', 'toolchain.check_macos_floor(source, platform_tag)', 'toolchain.check_macos_floor(accel, platform_tag)']
    - file: bindings/python/accel/toolchain.py
      contains: ['-mmacosx-version-min=', '"xcrun", "vtool", "-show-build"']
---

We build the macOS accelerator at the wheel's declared deployment floor instead of inheriting the build host's newer OS. Bare source builds bind the engine to their tag too, and the Zig C-compiler fallback uses the engine's target and CPU policy. Apple's tools check both binaries before packaging; a mismatched architecture or newer minimum OS fails the build. Building macOS wheels now requires Apple's Command Line Tools. Installed consumers keep the same API and need no compiler.
