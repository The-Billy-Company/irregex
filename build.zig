//! gist build graph — the candidate-search index kernel. The dual
//! static+dynamic C-ABI artifact, the macOS archive realign, and the
//! `test`/`coverage` steps live in the shared `kernelkit` chassis
//! (pkg/kernels/core). This file declares the kernel plus two executables
//! built on it: the production `gist` CLI (`src/commands/cli/main.zig`, the
//! `index`/`query`/`regex`/`rank`/`grep`/`rg` verbs) and the separate
//! `gist-bench` harness (`bench/bench.zig`, the `bench`/`verify`/`certify`
//! tooling). Production CLI and benchmark tooling no longer share a binary.

const std = @import("std");
const kernelkit = @import("kernelkit");

pub fn build(b: *std.Build) void {
    const k = kernelkit.addKernel(b, .{ .name = "gist" });

    // ── the `gist` CLI executable (the product surface) ──
    // `zig build cli -- index` (build + persist once) / `-- query <needle>` /
    // `-- regex <pattern>` / `-- rank <needle>` / `-- grep …` / `-- rg …`.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/cli/main.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    cli_mod.addImport("gist", k.root_module);
    const cli_exe = b.addExecutable(.{ .name = "gist", .root_module = cli_mod });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.setCwd(b.path("../../..")); // pkg/kernels/gist → repo root
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "gist CLI: `-- index`, then `-- query`/`-- regex`/`-- rank`/`-- grep`/`-- rg`")
        .dependOn(&run_cli.step);

    // ── the `gist-bench` harness executable (bench/verify/certify tooling) ──
    // Run from the repo root so relative dirs + output paths resolve there.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    bench_mod.addImport("gist", k.root_module);
    // Layer-A certify mode reads hardware perf counters through Apple's private
    // kperf framework via `dlopen` (std.DynLib) — needs libc.
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{ .name = "gist-bench", .root_module = bench_mod });
    // Install to zig-out/bin so the cycles/byte pass can run under sudo without a
    // root-cache recompile: `sudo pkg/kernels/gist/zig-out/bin/gist-bench certify`.
    b.installArtifact(bench_exe);

    // `zig build bench [-- <dirs…>]` — load a real corpus, build the index, time
    // the query slate (`-- scanbench` isolates the SIMD scan primitive).
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("../../.."));
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Build the index over given dirs and time the query slate")
        .dependOn(&run_bench.step);

    // `zig build verify [-- <battery_n> <seed>]` — emit gist's verified match
    // sets + the exact corpus list for the rg equality oracle (equality.sh).
    const run_verify = b.addRunArtifact(bench_exe);
    run_verify.setCwd(b.path("../../.."));
    run_verify.addArg("verify");
    if (b.args) |args| run_verify.addArgs(args);
    b.step("verify", "Emit gist match sets + corpus list for the rg equality diff")
        .dependOn(&run_verify.step);

    // `zig build certify` — Layer A of the optimality certificate: per-class
    // single-thread cycles/byte + bootstrap-CI (PMU via kperf; run under `sudo`
    // for cycles, else wall-clock). Emits .local/gist-verify/CERTIFICATE.md.
    const run_certify = b.addRunArtifact(bench_exe);
    run_certify.setCwd(b.path("../../.."));
    run_certify.addArg("certify");
    if (b.args) |args| run_certify.addArgs(args);
    b.step("certify", "Layer-A optimality cert: per-class cycles/byte + bootstrap CI")
        .dependOn(&run_certify.step);

    // Bench-side tests too — the harness-local `stats.zig` bootstrap-CI +
    // Mann-Whitney unit tests. (`bench/bench.zig` imports `gist`; reuse the
    // bench module; the engine tests ride `k.test_step` via `src/root.zig`.)
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);
}
