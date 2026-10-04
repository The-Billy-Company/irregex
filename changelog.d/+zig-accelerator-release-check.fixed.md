---
doc_radar:
  sentinels:
    - file: .github/workflows/release.yml
      contains: ["Check the accelerator's Zig compiler fallback", "toolchain.compilers = lambda: [['zig', 'cc']]", 'toolchain.compile(out, zig_target=target.zig, zig_cpu=target.cpu)', 'toolchain.check_macos_floor(out, target.tag)', 'spec.loader.exec_module(module)']
---

We compile and import the accelerator with the pinned Zig C compiler during release builds. It uses the wheel matrix's target and CPU policy, and its binary must pass the same platform check as the packaged accelerator. This keeps the compiler fallback checked when the runner's ordinary C compiler succeeds first.
