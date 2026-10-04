---
doc_radar:
  sentinels:
    - file: .githooks/pre-push
      contains: ["sources+=(\"${path}\")", "mise install --locked -j 1 zig", "ast-check \"./${path}\"", "git archive \"${local_sha}\""]
    - file: src/corpus/fresh/fresh_test.zig
      contains: ["const slashed = @import(\"../scope/paths.zig\").slashed;", "slashed(fx.arena.allocator(), portal.scratchDir(&scratch))", "try std.testing.expect(c.ctime >= fx.anchor_ns);", "try std.testing.expect(!Fixture.surfaced(&out, quiet));"]
    - file: .github/workflows/release.yml
      contains: ["name: Validate both consumer archive sets", "name: consumer-archives", "bindings/go/libirgx_*.a", "bindings/rust/vendor/**/libirgx.a", "Check the accelerator's Zig compiler fallback", "toolchain.compilers = lambda: [['zig', 'cc']]", "toolchain.compile(out, zig_target=target.zig, zig_cpu=target.cpu)", "toolchain.check_macos_floor(out, target.tag)", "spec.loader.exec_module(module)"]
    - file: bindings/go/scripts/vendor_libraries.py
      contains: ["reuse(native_archives, target.zig, target.cpu, archive)", "\"--native-archives\"", "fault.at_space != IRGX_AT_PATTERN", "irgx_last_fault(&fault) != IRGX_OK"]
    - file: bindings/rust/scripts/vendor_libraries.py
      contains: ["reuse(native_archives, target.zig, target.cpu, archive)", "\"--native-archives\"", "fault.at_space != IRGX_AT_PATTERN", "irgx_last_fault(&fault) != IRGX_OK"]
    - file: bindings/python/hatch_build.py
      contains: ["out, zig_target=zig_target, zig_cpu=_zig_cpu(zig_target) if zig_target else None", "toolchain.check_macos_floor(source, platform_tag)", "toolchain.check_macos_floor(accel, platform_tag)"]
    - file: bindings/python/accel/toolchain.py
      contains: ["-mmacosx-version-min=", "\"xcrun\", \"vtool\", \"-show-build\""]
    - file: tools/archives.py
      contains: ["version not in parity[\"stamped\"](blob)", "destination.write_bytes(blob)"]
    - file: src/corpus/tree/haystack.zig
      contains: ["pub fn underSkippedDir(path: []const u8) bool", "pub fn underPolicySkippedDir(path: []const u8) bool", "fn underSkip(path: []const u8, comptime skipped: fn ([]const u8) bool) bool", "paths.slashInPlace(buf);"]
    - file: src/root.zig
      contains: ["const skipped: *const fn ([]const u8) bool = haystack.underSkippedDir;", "public haystack underSkippedDir keeps its published unary call and admission", "public watcher subscription accepts its published named-field initializer"]
    - file: src/corpus/fresh/fresh.zig
      contains: ["haystack.underSkippedDir(path)"]
    - file: src/exec/session/reconcile/annals.zig
      contains: ["haystack.underPolicySkippedDir(rel)"]
    - file: src/exec/session/watch/notify.zig
      contains: ["haystack.underPolicySkippedDir(rel)", "const Action = enum(u32)", "directory and haystack.isPolicySkip(std.fs.path.basename(rel))", "self.session.dirty_log.note(std.fs.path.dirname(path) orelse root.abs)"]
    - file: src/exec/session/watch/inotify.zig
      contains: ["haystack.isPolicySkip(e.name)", "self.session.dirty_log.note(parent);"]
    - file: src/exec/session/watch/rig.zig
      contains: [".macos, .linux, .windows => true"]
    - file: .github/workflows/windows.yml
      contains: ["test_optimize:", "default: ReleaseSafe", "-Dtest-optimize=$($env:IRREGEX_TEST_OPTIMIZE)", "test_filter:", "github.event_name == 'workflow_dispatch' && inputs.test_filter || ''", "archive_diagnostic:", "python tools/archive_diagnostic.py --out", "cache-dependency-path:", "bindings/go/libirgx_*.a", "cache: false"]
    - file: .github/workflows/ci.yml
      contains: ["cache-dependency-path:", "bindings/go/libirgx_*.a", 'CGO_ENABLED: "1"']
    - file: bindings/go/bridge.go
      contains: ["//go:build cgo"]
    - file: tools/archive_diagnostic.py
      contains: ["for compiler_strip in (True, False):", "probe(\"committed\", target.archive, required=False)", "corrected-go-suite", "DLL_PROBE", "probe(\"alternate-linker\", committed, required=True, compiler=compiler)", "irregex-go-cache-alternate"]
    - file: .github/actions/setup-zig-windows/action.yml
      contains: ["linker-diagnostic:", 'default: "false"', "if (-not $diagnostic -and $declared -ne $ver)", "$target = 'aarch64-windows'", "sha256 mismatch"]
    - file: build.zig
      contains: ["\"test-optimize\"", "orelse .ReleaseSafe;"]
    - file: towncrier.toml
      contains: ["ignore = [ \".gitkeep\", \"README.md\" ]", "wrap = false"]
    - file: bindings/python/pyproject.toml
      contains: ['extend = "../../quality/ruff.toml"', 'src = [ "../.." ]']
    - file: quality/ruff.toml
      contains: ['line-length = 100', 'target-version = "py312"', 'extend-exclude = [ "*.gen.py" ]']
---

# Release notes

We write a fragment in the same PR as every user-visible, API, behavior,
performance or security change. Skip only comment-only, format-only or
internal refactors with no observable change; when unsure, write the fragment.

```bash
towncrier create '+<slug>.<type>.md'
# write the fragment body, then on release:
towncrier build --version x.y.z
```

Fragments are plain Markdown for the person reading the release. Towncrier
folds their bodies into [the changelog](../CHANGELOG.md) verbatim, then removes
the fragments; we don't hand-edit those notes into the changelog mid-PR.

## Fragment types

Names use `+<slug>.<type>.md`, with a type of `note`, `added`, `changed`,
`deprecated`, `removed`, `fixed` or `security`. A `note` frames the release
before its categories; use it at most once per release.

## Source checks

Keep source assertions in this README's `doc_radar` frontmatter, never in a
fragment. They check the live source behind the notes; don't point them at
fragments that disappear when folded.

[Towncrier's config](../towncrier.toml) ignores this guide and keeps fragment
layout intact. The assertions stay checked after a release; machine metadata
stays out of the public notes.
