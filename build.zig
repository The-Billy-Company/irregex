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

// ── vendored PCRE2 10.47 (the opt-in `-P` backend) ──
// Hermetic: the exact upstream release is pinned under vendor/pcre2/ and
// compiled from source here — no system/global libpcre2 is ever consulted, so
// the build is byte-reproducible on any machine. Provenance (release URL +
// sha256) lives in vendor/pcre2/README.md. The 8-bit library sources are the
// canonical set from PCRE2's own NON-AUTOTOOLS-BUILD guide (step 4);
// pcre2_jit_compile.c #includes the sljit backend from ../deps/sljit relative
// to the src dir, so the vendored src↔deps layout must be preserved.
const pcre2_sources = [_][]const u8{
    "pcre2_auto_possess.c", "pcre2_chartables.c",     "pcre2_chkdint.c",
    "pcre2_compile.c",      "pcre2_compile_cgroup.c", "pcre2_compile_class.c",
    "pcre2_config.c",       "pcre2_context.c",        "pcre2_convert.c",
    "pcre2_dfa_match.c",    "pcre2_error.c",          "pcre2_extuni.c",
    "pcre2_find_bracket.c", "pcre2_jit_compile.c",    "pcre2_maketables.c",
    "pcre2_match.c",        "pcre2_match_data.c",     "pcre2_match_next.c",
    "pcre2_newline.c",      "pcre2_ord2utf.c",        "pcre2_pattern_info.c",
    "pcre2_script_run.c",   "pcre2_serialize.c",      "pcre2_string_utils.c",
    "pcre2_study.c",        "pcre2_substitute.c",     "pcre2_substring.c",
    "pcre2_tables.c",       "pcre2_ucd.c",            "pcre2_valid_utf.c",
    "pcre2_xclass.c",
};

// Feature selection lives here (visible + reviewable) rather than by editing
// the vendored config.h, which stays byte-identical to upstream's
// config.h.generic. HAVE_CONFIG_H pulls in that header for the value-macro
// defaults (MATCH_LIMIT, LINK_SIZE, NEWLINE_DEFAULT, …); the -D flags turn on
// the 8-bit library, Unicode/UTF, JIT, and static linkage. `-fno-sanitize=
// undefined` keeps Zig's C UBSan from trapping on PCRE2's intentional, well-
// defined-in-practice pointer/shift idioms — a `-P` query must degrade to a
// clean error, never a sanitizer abort.
const pcre2_cflags = [_][]const u8{
    "-DHAVE_CONFIG_H",
    "-DPCRE2_CODE_UNIT_WIDTH=8",
    "-DPCRE2_STATIC",
    "-DSUPPORT_UNICODE",
    "-DSUPPORT_PCRE2_8",
    "-DSUPPORT_JIT",
    "-fno-sanitize=undefined",
    "-std=c11",
};

/// Build the vendored PCRE2 8-bit library (JIT included) as one static archive
/// at `optimize`. SUPPORT_JIT is always compiled in; on an sljit-unsupported
/// target the backend self-disables and `pcre2_jit_compile` reports an error,
/// which the Zig wrapper treats as "no JIT" and falls back to the interpreter.
fn pcre2Library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(b.path("vendor/pcre2/src"));
    mod.addCSourceFiles(.{
        .root = b.path("vendor/pcre2/src"),
        .files = &pcre2_sources,
        .flags = &pcre2_cflags,
    });
    return b.addLibrary(.{ .name = "pcre2gist", .linkage = .static, .root_module = mod });
}

pub fn build(b: *std.Build) void {
    const k = kernelkit.addKernel(b, .{ .name = "gist" });

    // Link the vendored PCRE2 backend into the engine module (and thus every
    // artifact built from it: the C-ABI libs, the test binary, and the
    // bench/roofline/lowerbound/portcert executables that import it). The CLI
    // links its own copy built at the CLI optimize level (below).
    const pcre2_engine = pcre2Library(b, k.target, k.optimize);
    k.root_module.linkLibrary(pcre2_engine);

    // ── the `gist` CLI executable (the product surface) ──
    // `zig build cli -- index` (build + persist once) / `-- status` /
    // `-- <pattern> [PATH...] [flags]` (shape via --rank/--json). NOTE: this
    // `run` step executes the freshly compiled exe straight from Zig's cache —
    // it does NOT refresh `zig-out/bin/gist`; run a plain `zig build`
    // (the default "install" step) first if a script or manual test shells
    // that path directly.
    //
    // The CLI is gist's product surface — the on-PATH binary (`~/.local/bin/gist`
    // → `zig-out/bin/gist`) whose entire reason to exist is out-running ripgrep.
    // A Debug build is 4–8× slower and reads to a caller like a hang, so the CLI
    // (and the engine module it links, where the hot loops live) defaults to
    // ReleaseFast regardless of the build-wide `-Doptimize` — a bare `zig build`
    // must never install a slow debug `gist`. `-Dcli-optimize=Debug` still yields
    // a debug CLI for engine debugging. Tests / coverage / the C-ABI libs keep
    // the standard (safety-checked, DWARF-carrying) default optimize untouched,
    // so this dedicated module pair leaves those graphs exactly as they were.
    const cli_optimize = b.option(
        std.builtin.OptimizeMode,
        "cli-optimize",
        "optimize mode for the installed gist CLI (default ReleaseFast — the product surface's whole point is speed)",
    ) orelse .ReleaseFast;
    const cli_engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    // The installed CLI is the speed-critical product surface (ReleaseFast by
    // default), so it links a PCRE2 built at the same optimize level rather than
    // the (possibly Debug) engine copy.
    cli_engine.linkLibrary(pcre2Library(b, k.target, cli_optimize));
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/commands/cli/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    cli_mod.addImport("gist", cli_engine);
    const cli_exe = b.addExecutable(.{ .name = "gist", .root_module = cli_mod });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.setCwd(b.path("../../..")); // pkg/kernels/gist → repo root
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "gist CLI: `-- index`, `-- status`, `-- <pattern> [flags]`")
        .dependOn(&run_cli.step);

    // Black-box CLI regression guard (wired into `zig build test`): an explicit
    // PATH arg that can't be opened must be reported to stderr and force exit 2
    // (ripgrep's error class) — NOT dropped silently with a "no match" exit 1,
    // which read to a caller like an instant crash on a typo'd path
    // (`gist search tel` → "search" pattern in nonexistent path "tel"). Spawns
    // the freshly compiled exe so the fix can never silently regress.
    const badpath_test = b.addRunArtifact(cli_exe);
    badpath_test.setCwd(b.path("../../.."));
    badpath_test.addArgs(&.{ "gist_badpath_regression_needle", "gist_definitely_nonexistent_path_xyz" });
    badpath_test.expectExitCode(2);
    badpath_test.expectStdErrMatch("No such file or directory");
    k.test_step.dependOn(&badpath_test.step);

    // Companion guard: the habit-safe `search` verb must be CONSUMED, so the
    // token after it is the pattern (and the token after THAT a path) — not
    // silently re-read. This needle string lives in this very build.zig (the
    // addArgs below), so WITH the verb `gist search <needle> --no-index <file>`
    // finds it and exits 0; absent the verb it parses as pattern="search",
    // path="<needle>", dies opening the nonexistent path with exit 2 ("No such
    // file"). Asserting exit 0 fails closed the instant the verb stops being
    // stripped. `--no-index` forces the pure live walk so the guard tests the
    // dispatch/arg-parsing (its purpose), not index freshness, and stays
    // deterministic + fast (one file) under the concurrently-edited tree.
    const search_verb_test = b.addRunArtifact(cli_exe);
    search_verb_test.setCwd(b.path("../../.."));
    search_verb_test.addArgs(&.{ "search", "gist_search_verb_regression_needle_xyz", "--no-index", "pkg/kernels/gist/build.zig" });
    search_verb_test.expectExitCode(0);
    k.test_step.dependOn(&search_verb_test.step);

    // Ranked search must remain useful before the index is warmed (or when its
    // persisted pair is incomplete). --no-index deterministically exercises the
    // same live-rank fallback without mutating the shared machine-local cache.
    const live_rank_test = b.addRunArtifact(cli_exe);
    live_rank_test.setCwd(b.path("../../.."));
    live_rank_test.addArgs(&.{ "gist_live_rank_regression_needle_xyz", "--rank", "--no-index", "pkg/kernels/gist/build.zig" });
    live_rank_test.expectExitCode(0);
    live_rank_test.expectStdOutMatch("pkg/kernels/gist/build.zig:");
    live_rank_test.expectStdErrMatch("live-scanned");
    k.test_step.dependOn(&live_rank_test.step);
    // gist_live_rank_regression_needle_xyz ← fallback fixture

    // Companion guard: a leading `(?i)` inline-flag directive (rust-regex/rg
    // syntax) must be HONORED (stripped, run-wide caseless) — not rejected as a
    // bad pattern with exit 2, which is what a regression in
    // `stripLeadingFlags`/`combinePatterns` produces. The fixture below is the
    // ONLY case-fold target: the pattern spells the needle lowercase with a
    // `[e]` class (so the pattern's own addArgs literal can never self-match),
    // while the fixture is case-twisted (`NeEdLe`). A match therefore REQUIRES
    // both the directive strip AND the case fold: a case-sensitive engine
    // finds nothing (exit 1) and a directive-rejecting one dies (exit 2) —
    // either way the guard fails closed.
    const inline_flag_test = b.addRunArtifact(cli_exe);
    inline_flag_test.setCwd(b.path("../../.."));
    inline_flag_test.addArgs(&.{ "(?i)gist_inline_flag_regression_n[e]edle_xyz", "--no-index", "pkg/kernels/gist/build.zig" });
    inline_flag_test.expectExitCode(0);
    k.test_step.dependOn(&inline_flag_test.step);
    // gist_inline_flag_regression_NeEdLe_xyz ← the fixture the guard case-folds onto

    // Compile, link, and run a real C consumer against the deliberately minimal
    // ABI. This catches calling-convention, header, symbol, and primitive-contract
    // drift that the toolchain-free gist-contract text gate cannot observe.
    const c_smoke_source = b.addWriteFiles().add("gist_c_abi_smoke.c",
        \\#include "gist.h"
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\int main(void) {
        \\    const uint8_t text[] = {'a', 'b', 'c', 'a', 'b', 'c'};
        \\    uint32_t out[sizeof text] = {0};
        \\    if (gist_abi_version() != 1u) return 10;
        \\    if (gist_trigram_count(text, 2u, out) != 0u) return 11;
        \\    const size_t count = gist_trigram_count(text, sizeof text, out);
        \\    if (count != 3u) return 12;
        \\    for (size_t i = 1; i < count; ++i)
        \\        if (out[i - 1] >= out[i]) return 13;
        \\    const char *ver = gist_version();
        \\    if (ver == NULL || ver[0] < '0' || ver[0] > '9') return 14;
        \\    return 0;
        \\}
        \\
    );
    const c_smoke_mod = b.createModule(.{
        .target = k.target,
        .optimize = k.optimize,
        .link_libc = true,
    });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.addCSourceFile(.{
        .file = c_smoke_source,
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_smoke_mod.addObject(b.addObject(.{
        .name = "gist-c-abi-smoke-kernel",
        .root_module = k.root_module,
    }));
    // The kernel object carries the engine's PCRE2 extern references; the smoke
    // exe links a matching PCRE2 so those symbols resolve (the C ABI itself does
    // not touch PCRE2, but the whole engine module is compiled into the object).
    c_smoke_mod.linkLibrary(pcre2_engine);
    const c_smoke = b.addExecutable(.{
        .name = "gist-c-abi-smoke",
        .root_module = c_smoke_mod,
    });
    const run_c_smoke = b.addRunArtifact(c_smoke);
    run_c_smoke.expectExitCode(0);
    k.test_step.dependOn(&run_c_smoke.step);

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
