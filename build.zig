//! gist build graph — emits `libgist.a` (staticlib, Go cgo) + a
//! `libgist.{dylib,so,dll}` (dynamic, Python cffi dlopen) from a single
//! `src/root.zig` root. The two artifacts share one set of `@export`s pinned in
//! `include/gist.h`. Mirrors pkg/kernels/core + principia.

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Pin a low macOS deployment floor so the Mach-O object's LC_BUILD_VERSION
    // doesn't outrun the cgo link target (ld64 warns otherwise). Native
    // arch/CPU detection is preserved; cross-builds (-Dtarget=…) override.
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Dynamic lib (Python cffi dlopen). Owns the header install.
    const dynamic_lib = b.addLibrary(.{
        .name = "gist",
        .linkage = .dynamic,
        .root_module = root_module,
    });
    dynamic_lib.installHeader(b.path("include/gist.h"), "gist.h");
    b.installArtifact(dynamic_lib);

    // Static lib (Go cgo). On macOS, re-archive with Apple's `libtool -static`
    // so members are 8-byte aligned (Zig's archiver leaves them unaligned, which
    // ld64 rejects when linked into a cgo binary). Linux/LLD tolerates it.
    if (target.result.os.tag == .macos) {
        const obj = b.addObject(.{ .name = "gist", .root_module = root_module });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("libgist.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "libgist.a").step);
    } else {
        const static_lib = b.addLibrary(.{
            .name = "gist",
            .linkage = .static,
            .root_module = root_module,
        });
        b.installArtifact(static_lib);
    }

    // `zig build bench [-- <dirs…>]` — load a real corpus, build the index,
    // time the query slate. Run from the repo root so relative dirs resolve.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("gist", root_module);
    const bench_exe = b.addExecutable(.{ .name = "gist-bench", .root_module = bench_mod });

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("../../..")); // pkg/kernels/gist → repo root
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Build the index over given dirs and time the query slate");
    bench_step.dependOn(&run_bench.step);

    // `zig build verify [-- <battery_n> <seed>]` — emit gist's verified match
    // sets + the exact corpus list for the rg equality oracle (equality.sh).
    const run_verify = b.addRunArtifact(bench_exe);
    run_verify.setCwd(b.path("../../.."));
    run_verify.addArg("verify");
    if (b.args) |args| run_verify.addArgs(args);
    const verify_step = b.step("verify", "Emit gist match sets + corpus list for the rg equality diff");
    verify_step.dependOn(&run_verify.step);

    // `zig build cli -- index` (build + persist once) / `-- query <needle>`
    // (fresh-process cold-load + candidate-only verify) — the cold head-to-head.
    const run_cli = b.addRunArtifact(bench_exe);
    run_cli.setCwd(b.path("../../.."));
    if (b.args) |args| run_cli.addArgs(args);
    const cli_step = b.step("cli", "Cold one-shot CLI: `-- index`, then `-- query <needle>`");
    cli_step.dependOn(&run_cli.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Bench-side tests too — the SIMD `contains` carries a differential fuzz
    // against `std.mem.indexOf`, and it sits in the hot verify path, so CI must
    // run it. (`bench/bench.zig` imports `gist`; reuse the bench module.)
    const bench_tests = b.addTest(.{ .root_module = bench_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);

    // `zig build coverage` — same test binary under kcov → .local/coverage/
    // (Cobertura XML for `make census`). kcov must be on PATH.
    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(tests);
    const cov_step = b.step("coverage", "Run unit tests under kcov → .local/coverage/");
    cov_step.dependOn(&run_cov.step);
}
