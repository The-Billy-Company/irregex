//! gist build graph — the candidate-search index kernel. The dual
//! static+dynamic C-ABI artifact, the macOS archive realign, and the
//! `test`/`coverage` steps live in the shared `kernelkit` chassis
//! (pkg/kernels/core); this file declares the kernel plus its bespoke
//! bench tooling — `bench`/`verify`/`cli`/`certify` all reuse one corpus-loading
//! executable, and the SIMD `contains` differential fuzz rides the `test` step.

const std = @import("std");
const kernelkit = @import("kernelkit");

pub fn build(b: *std.Build) void {
    const k = kernelkit.addKernel(b, .{ .name = "gist" });

    // `zig build bench [-- <dirs…>]` — load a real corpus, build the index, time
    // the query slate. Run from the repo root so relative dirs resolve.
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
    // root-cache recompile: `sudo pkg/kernels/gist/zig-out/bin/gist-bench certify`
    // (from repo root). `zig build install` (the default step) drops it there.
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("../../..")); // pkg/kernels/gist → repo root
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

    // `zig build cli -- index` (build + persist once) / `-- query <needle>`
    // (fresh-process cold-load + candidate-only verify) — the cold head-to-head.
    const run_cli = b.addRunArtifact(bench_exe);
    run_cli.setCwd(b.path("../../.."));
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "Cold one-shot CLI: `-- index`, then `-- query <needle>` / `-- regex <pattern>`")
        .dependOn(&run_cli.step);

    // `zig build certify` — Layer A of the optimality certificate: per-class
    // single-thread cycles/byte + bootstrap-CI (PMU via kperf; run under `sudo`
    // for cycles, else wall-clock). Emits .local/gist-verify/CERTIFICATE.md.
    const run_certify = b.addRunArtifact(bench_exe);
    run_certify.setCwd(b.path("../../.."));
    run_certify.addArg("certify");
    if (b.args) |args| run_certify.addArgs(args);
    b.step("certify", "Layer-A optimality cert: per-class cycles/byte + bootstrap CI")
        .dependOn(&run_certify.step);

    // Bench-side tests too — the SIMD `contains` carries a differential fuzz
    // against `std.mem.indexOf`, and it sits in the hot verify path, so CI must
    // run it. (`bench/bench.zig` imports `gist`; reuse the bench module.)
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);
}
