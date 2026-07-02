//! gist build graph — the candidate-search index kernel. The dual
//! static+dynamic C-ABI artifact, the macOS archive realign, and the
//! `test`/`coverage` steps live in the shared `kernelkit` chassis
//! (pkg/kernels/core). This file declares the kernel plus two executables
//! built on it: the production `gist` CLI (`src/commands/cli/main.zig`, the
//! `index`/`status` lifecycle verbs plus the bare `<pattern>`/`rg` search
//! front door) and the separate `gist-bench` harness
//! (`bench/harness/bench.zig`, the `bench`/`verify`/`certify` tooling). Production CLI
//! and benchmark tooling no longer share a binary.

const std = @import("std");
const kernelkit = @import("kernelkit");

pub fn build(b: *std.Build) void {
    const k = kernelkit.addKernel(b, .{ .name = "gist" });

    // ── the `gist` CLI executable (the product surface) ──
    // `zig build cli -- index` (build + persist once) / `-- status` /
    // `-- <pattern> [PATH...] [flags]` (shape via --rank/--json). NOTE: this
    // `run` step executes the freshly compiled exe straight from Zig's cache —
    // it does NOT refresh `zig-out/bin/gist`; run a plain `zig build`
    // (the default "install" step) first if a script or manual test shells
    // that path directly.
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
    b.step("cli", "gist CLI: `-- index`, `-- status`, `-- <pattern> [flags]`")
        .dependOn(&run_cli.step);

    // ── the `gist-bench` harness executable (bench/verify/certify tooling) ──
    // Run from the repo root so relative dirs + output paths resolve there.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness/bench.zig"),
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
    // Mann-Whitney unit tests. (`bench/harness/bench.zig` imports `gist`; reuse the
    // bench module; the engine tests ride `k.test_step` via `src/root.zig`.)
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);

    // Shared modules for the Layer B/C/D executables below, each living outside
    // `bench/harness/`'s module root (Zig forbids importing a source file
    // outside a module's own root directory) so they're wired as independent,
    // named modules instead — mirroring how `bench_mod` already wires `gist`.
    const probes_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness/probes.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    const pmu_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness/pmu.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });

    // ── `gist-roofline` — Layer C: single-thread STREAM read-bandwidth ceiling ──
    const roofline_mod = b.createModule(.{
        .root_source_file = b.path("bench/roofline/bandwidth.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    roofline_mod.addImport("gist", k.root_module);
    roofline_mod.addImport("pmu", pmu_mod);
    roofline_mod.link_libc = true; // pmu.zig's kperf dlopen path, same as bench_mod
    const roofline_exe = b.addExecutable(.{ .name = "gist-roofline", .root_module = roofline_mod });
    b.installArtifact(roofline_exe);
    const run_roofline = b.addRunArtifact(roofline_exe);
    run_roofline.setCwd(b.path("../../.."));
    if (b.args) |args| run_roofline.addArgs(args);
    b.step("roofline", "Layer-C optimality cert: STREAM read-bandwidth ceiling vs gist's scan")
        .dependOn(&run_roofline.step);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = roofline_mod })).step);

    // ── `gist-lowerbound` — Layer D: algorithmic-floor byte-touch audit ──
    const lowerbound_mod = b.createModule(.{
        .root_source_file = b.path("bench/lowerbound/lowerbound.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    lowerbound_mod.addImport("gist", k.root_module);
    lowerbound_mod.addImport("probes", probes_mod);
    const lowerbound_exe = b.addExecutable(.{ .name = "gist-lowerbound", .root_module = lowerbound_mod });
    b.installArtifact(lowerbound_exe);
    const run_lowerbound = b.addRunArtifact(lowerbound_exe);
    run_lowerbound.setCwd(b.path("../../.."));
    if (b.args) |args| run_lowerbound.addArgs(args);
    b.step("lowerbound", "Layer-D optimality cert: fail-closed algorithmic-floor byte-touch audit")
        .dependOn(&run_lowerbound.step);

    // Layer-B drift guard (`probes/` copies ≡ the real production hot loops) —
    // wired into `zig build test` so a silent copy/production divergence fails
    // CI loudly instead of shipping a stale certificate.
    const portcert_test_mod = b.createModule(.{
        .root_source_file = b.path("bench/portcert/probes_test.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    portcert_test_mod.addImport("gist", k.root_module);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = portcert_test_mod })).step);
}
