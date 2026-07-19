//! gist build graph — the candidate-search index kernel. The dual
//! static+dynamic C-ABI artifact, the macOS archive realign, and the
//! `test`/`coverage` steps live in the shared `kernelkit` chassis
//! (pkg/kernels/core). This file declares the kernel plus two executables
//! built on it: the production `gist` CLI (`src/gist/faces/cli/main.zig`, the
//! `index`/`status` lifecycle verbs plus the bare `<pattern>`/`rg` search
//! front door) and the separate `gist-bench` harness
//! (`bench/harness/bench.zig`, the `bench`/`verify`/`certify` tooling). Production CLI
//! and benchmark tooling no longer share a binary.
//!
//! Build-speed contract: a bare `zig build` installs ONLY the product surface
//! (gist + hydra CLIs and the C-ABI libs). The six bench/certificate lab
//! executables (gist-bench, gist-roofline, gist-lowerbound, gist-portbound,
//! relate-knn, codex-scale) install on their own named steps — and all at once
//! via `zig build lab` — so the everyday build/install loop never pays for
//! measurement tooling it doesn't run.

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
    return b.addLibrary(.{ .name = "pcre2irregex", .linkage = .static, .root_module = mod });
}

/// Wire the CoreServices (FSEvents) + CoreFoundation (CFRunLoop) frameworks the
/// macOS resident watcher (`src/gist/session/watch.zig`) calls into. Applied to every
/// module that compiles the engine and produces a final link — including the
/// C-ABI smoke exe, which links the engine as an object (framework flags don't
/// propagate across `addObject`, only `addImport`). No-op off macOS. `link_libc`
/// only wires the SDK sysroot; macOS links libSystem regardless.
fn linkWatcherFrameworks(m: *std.Build.Module, frameworks: ?[]const u8) void {
    const fw = frameworks orelse return;
    m.link_libc = true;
    m.addSystemFrameworkPath(.{ .cwd_relative = fw });
    m.linkFramework("CoreServices", .{});
    m.linkFramework("CoreFoundation", .{});
}

pub fn build(b: *std.Build) void {
    // The unit-test binary is pinned to ReleaseSafe: gist's suite is dominated
    // by differential-fuzz loops (DFA vs Pike, powerset language equivalence,
    // adversarial oracles, index-loader mutation soak) that exist to trip
    // safety checks — which ReleaseSafe keeps, at optimized speed. Debug ran
    // the same suite ~4× slower (5.5 min vs ~80 s) for no extra checking.
    // `-Dtest-optimize=Debug` still yields a Debug test binary when stepping
    // through a failure; the kcov `coverage` binary stays build-wide Debug.
    const k = kernelkit.addKernel(b, .{ .name = "irregex", .test_optimize = .ReleaseSafe });

    // kernelkit pins `os_version_min`, so Zig treats the target as cross-ish and
    // skips native SDK auto-detection — resolve the SDK's framework dir once here
    // (null off macOS) and hand it to every engine-linking module below.
    const darwin_frameworks: ?[]const u8 = if (k.target.result.os.tag == .macos)
        b.fmt("{s}/System/Library/Frameworks", .{std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), "\n")})
    else
        null;
    linkWatcherFrameworks(k.root_module, darwin_frameworks);

    // Link the vendored PCRE2 backend into the engine module (and thus every
    // artifact built from it: the C-ABI libs, the test binary, and the
    // bench/roofline/lowerbound/portcert executables that import it). The CLI
    // links its own copy built at the CLI optimize level (below).
    const pcre2_engine = pcre2Library(b, k.target, k.optimize);
    k.root_module.linkLibrary(pcre2_engine);

    // The ReleaseSafe-pinned test module is a twin of the root module, so it
    // needs the same decorations: the frameworks and a PCRE2 built at ITS
    // optimize (the PCRE2 adversarial tests shouldn't run a Debug C library).
    if (k.test_module != k.root_module) {
        linkWatcherFrameworks(k.test_module, darwin_frameworks);
        k.test_module.linkLibrary(pcre2Library(b, k.target, k.test_module.optimize.?));
    }

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
    linkWatcherFrameworks(cli_engine, darwin_frameworks);
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/gist/faces/cli/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    cli_mod.addImport("irregex", cli_engine);
    const cli_exe = b.addExecutable(.{ .name = "gist", .root_module = cli_mod });
    b.installArtifact(cli_exe);

    // ── the `hydra` binary — compression-as-search (similar/dups/patterns) ──
    // Same engine module, same ReleaseFast product posture; a second thin face
    // over the shared kernel, not a second engine.
    const hydra_mod = b.createModule(.{
        .root_source_file = b.path("src/hydra/cli/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    hydra_mod.addImport("irregex", cli_engine);
    const hydra_exe = b.addExecutable(.{ .name = "hydra", .root_module = hydra_mod });
    b.installArtifact(hydra_exe);

    // ── `zig build lab` — the measurement-lab install umbrella ──
    // The six bench/certificate executables below are deliberately OFF the
    // default install step: a bare `zig build` (and `make build-gist` /
    // `make install-gist` / every parity gate that rebuilds the CLI) pays only
    // for the product surface. Each lab exe still installs on its own named
    // step, so the documented `sudo zig-out/bin/<exe>` re-runs keep working
    // after e.g. `zig build certify`; `zig build lab` installs all six.
    const lab_step = b.step("lab", "Build + install the bench/certificate lab executables (gist-bench, roofline, lowerbound, portbound, relate-knn, codex-scale) → zig-out/bin");

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.setCwd(b.path("../../..")); // pkg/kernels/irregex → repo root
    if (b.args) |args| run_cli.addArgs(args);
    b.step("cli", "gist CLI: `-- index`, `-- status`, `-- <pattern> [flags]`")
        .dependOn(&run_cli.step);

    // ── cross-target drift gate (`zig build check-linux`, folded into `test`) ──
    // The Linux legs — the statx raw-stat shim (grepfile.zig), the inotify
    // watcher (session/watch.zig), and every `std.os.linux` call they make —
    // are comptime-pruned on the macOS dev boxes, so only a cross compile can
    // see them break (exactly how a `std.posix.close`/`std.c.fstatat` removal
    // in Zig 0.16 rotted unnoticed). Compile the full CLI module for
    // x86_64-linux-gnu as an OBJECT: full Sema + codegen over every
    // Linux-reachable line, no PCRE2 C cross-build and no link (the extern
    // declarations suffice), so the gate stays cheap and cache-friendly.
    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const check_engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = linux_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/gist/faces/cli/main.zig"),
        .target = linux_target,
        .optimize = .Debug,
    });
    check_mod.addImport("irregex", check_engine);
    const check_obj = b.addObject(.{ .name = "gist-check-linux", .root_module = check_mod });
    const check_linux = b.step("check-linux", "Cross-compile the CLI for x86_64-linux (Sema+codegen, no link) — keeps the comptime-pruned Linux legs building");
    check_linux.dependOn(&check_obj.step);
    k.test_step.dependOn(&check_obj.step);

    // Machine lifecycle contract: valid JSON is emitted whether the shared
    // machine-local index is ready or unavailable. Unit tests pin every field;
    // this black-box guard pins CLI dispatch and keeps prose off stderr.
    const status_json_test = b.addRunArtifact(cli_exe);
    status_json_test.setCwd(b.path("../../.."));
    status_json_test.addArgs(&.{ "status", "--json" });
    status_json_test.expectExitCode(0);
    status_json_test.expectStdOutMatch("\"schema_version\":1");
    status_json_test.expectStdOutMatch("\"state\":");
    k.test_step.dependOn(&status_json_test.step);

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
    search_verb_test.addArgs(&.{ "search", "gist_search_verb_regression_needle_xyz", "--no-index", "pkg/kernels/irregex/build.zig" });
    search_verb_test.expectExitCode(0);
    k.test_step.dependOn(&search_verb_test.step);

    // Ranked search must remain useful before the index is warmed (or when its
    // persisted pair is incomplete). --no-index deterministically exercises the
    // same live-rank fallback without mutating the shared machine-local cache.
    const live_rank_test = b.addRunArtifact(cli_exe);
    live_rank_test.setCwd(b.path("../../.."));
    live_rank_test.addArgs(&.{ "gist_live_rank_regression_needle_xyz", "--rank", "--no-index", "pkg/kernels/irregex/build.zig" });
    live_rank_test.expectExitCode(0);
    live_rank_test.expectStdOutMatch("pkg/kernels/irregex/build.zig:");
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
    inline_flag_test.addArgs(&.{ "(?i)gist_inline_flag_regression_n[e]edle_xyz", "--no-index", "pkg/kernels/irregex/build.zig" });
    inline_flag_test.expectExitCode(0);
    k.test_step.dependOn(&inline_flag_test.step);
    // gist_inline_flag_regression_NeEdLe_xyz ← the fixture the guard case-folds onto

    // Companion guard: `--engine auto` must ESCALATE to the PCRE2 backend for a
    // pattern the linear engine declines (here a lookahead) — not die with the
    // linear "outside gist's linear-time syntax" exit-2. The pattern is a literal
    // followed by a lookahead `(?=_TAIL)`; it can only match where `_TAIL`
    // immediately follows, which is the fixture comment below — NOT this addArgs
    // line, where the literal is followed by the raw `(?=…)` bytes. So a match at
    // all requires (a) auto actually escalating to PCRE2 and (b) PCRE2 honoring
    // the lookahead. A non-escalating auto dies exit 2; a broken lookahead finds
    // nothing exit 1 — either way the guard fails closed. `--no-index` keeps it
    // deterministic against the shared, concurrently-edited tree.
    const auto_escalate_test = b.addRunArtifact(cli_exe);
    auto_escalate_test.setCwd(b.path("../../.."));
    auto_escalate_test.addArgs(&.{ "--engine", "auto", "gist_auto_escalation_regression_needle_xyz(?=_TAIL)", "--no-index", "pkg/kernels/irregex/build.zig" });
    auto_escalate_test.expectExitCode(0);
    k.test_step.dependOn(&auto_escalate_test.step);
    // gist_auto_escalation_regression_needle_xyz_TAIL ← the fixture auto escalates PCRE2 onto

    // Compile, link, and run a real C consumer against the C ABI. This catches
    // calling-convention, header, symbol, and contract drift that the
    // toolchain-free gist-contract text gate cannot observe. Beyond the version
    // + trigram primitives it drives the rung-3 warm session end to end
    // (`irregex_open`/`irregex_search`/`irregex_close`) over a generated two-line fixture:
    // a full stream must fire on BOTH matching lines with the first hit on line 1
    // and a single whole-needle submatch (byte-accurate offsets reach C); a
    // callback that returns non-zero must STOP after the first line yet still
    // report IRREGEX_MATCH (the abort return, ABI v2); and a no-match query must
    // return IRREGEX_OK without firing (never `die()`s). The needle lives ONLY in
    // the fixture (a separate dir from this C source), so it can never self-match.
    const ffi_fixture = b.addWriteFiles();
    _ = ffi_fixture.add("fixture.txt", "gist_ffi_smoke_needle on line one\ngist_ffi_smoke_needle on line two\n");
    const c_smoke_source = b.addWriteFiles().add("gist_c_abi_smoke.c",
        \\#include "irregex.h"
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\
        \\static int g_hits;
        \\static uint64_t g_first_line;
        \\static size_t g_first_nsub, g_first_start, g_first_end;
        \\
        \\/* Records the FIRST hit's shape, then continues the stream. */
        \\static int32_t on_match(void *ctx, const irregex_match *m) {
        \\    (void)ctx;
        \\    if (g_hits == 0) {
        \\        g_first_line = m->line_number;
        \\        g_first_nsub = m->nsubmatches;
        \\        if (m->nsubmatches > 0u) { g_first_start = m->submatches[0].start; g_first_end = m->submatches[0].end; }
        \\    }
        \\    g_hits++;
        \\    return 0; /* continue */
        \\}
        \\
        \\/* Aborts the stream after the first matching line. */
        \\static int32_t on_match_stop(void *ctx, const irregex_match *m) {
        \\    (void)ctx;
        \\    (void)m;
        \\    g_hits++;
        \\    return 1; /* stop */
        \\}
        \\
        \\int main(void) {
        \\    const uint8_t text[] = {'a', 'b', 'c', 'a', 'b', 'c'};
        \\    uint32_t out[sizeof text] = {0};
        \\    if (irregex_abi_version() != 2u) return 10;
        \\    if (irregex_trigram_count(text, 2u, out) != 0u) return 11;
        \\    const size_t count = irregex_trigram_count(text, sizeof text, out);
        \\    if (count != 3u) return 12;
        \\    for (size_t i = 1; i < count; ++i)
        \\        if (out[i - 1] >= out[i]) return 13;
        \\    const char *ver = irregex_version();
        \\    if (ver == NULL || ver[0] < '0' || ver[0] > '9') return 14;
        \\
        \\    /* warm session over the CWD fixture tree (set by the build). */
        \\    irregex_session *s = NULL;
        \\    const char *roots[] = {"."};
        \\    if (irregex_open(roots, 1u, &s) != IRREGEX_OK) return 20;
        \\    if (s == NULL) return 21;
        \\    const char needle[] = "gist_ffi_smoke_needle";
        \\    const size_t nlen = sizeof needle - 1u;
        \\
        \\    /* full stream: both lines match; first hit is line 1, whole-needle span. */
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, IRREGEX_FIXED, on_match, NULL) != IRREGEX_MATCH) return 22;
        \\    if (g_hits != 2 || g_first_line != 1u || g_first_nsub != 1u) return 23;
        \\    if (g_first_start != 0u || g_first_end != nlen) return 24;
        \\
        \\    /* early stop: the callback aborts after the first line -> one hit, MATCH. */
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, IRREGEX_FIXED, on_match_stop, NULL) != IRREGEX_MATCH) return 25;
        \\    if (g_hits != 1) return 26;
        \\
        \\    /* no match still returns OK and never fires. */
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)"zzz_absent_needle_zzz", 21u, IRREGEX_FIXED, on_match, NULL) != IRREGEX_OK) return 27;
        \\    if (g_hits != 0) return 28;
        \\    irregex_close(s);
        \\    return 0;
        \\}
        \\
    );
    const c_smoke_mod = b.createModule(.{
        .target = k.target,
        .optimize = k.optimize,
        .link_libc = true,
    });
    linkWatcherFrameworks(c_smoke_mod, darwin_frameworks); // engine object pulls in FSEvents externs
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
    // Run in the generated fixture dir so `irregex_open(".")` walks exactly the one
    // seeded file — deterministic and isolated from the concurrently-edited tree.
    run_c_smoke.setCwd(ffi_fixture.getDirectory());
    run_c_smoke.expectExitCode(0);
    k.test_step.dependOn(&run_c_smoke.step);

    // ── the `gist-bench` harness executable (bench/verify/certify tooling) ──
    // Run from the repo root so relative dirs + output paths resolve there.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness/bench.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    bench_mod.addImport("irregex", k.root_module);
    // Layer-A certify mode reads hardware perf counters through Apple's private
    // kperf framework via `dlopen` (std.DynLib) — needs libc.
    bench_mod.link_libc = true;
    const bench_exe = b.addExecutable(.{ .name = "gist-bench", .root_module = bench_mod });
    // Installed to zig-out/bin (on the named steps + `lab`, not the default
    // install) so the cycles/byte pass can run under sudo without a root-cache
    // recompile: `sudo pkg/kernels/irregex/zig-out/bin/gist-bench certify`.
    const bench_install = &b.addInstallArtifact(bench_exe, .{}).step;
    lab_step.dependOn(bench_install);

    // `zig build bench [-- <dirs…>]` — load a real corpus, build the index, time
    // the query slate (`-- scanbench` isolates the SIMD scan primitive).
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("../../.."));
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Build the index over given dirs and time the query slate");
    bench_step.dependOn(&run_bench.step);
    bench_step.dependOn(bench_install);

    // `zig build verify [-- <battery_n> <seed>]` — emit gist's verified match
    // sets + the exact corpus list for the rg equality oracle (equality.sh).
    const run_verify = b.addRunArtifact(bench_exe);
    run_verify.setCwd(b.path("../../.."));
    run_verify.addArg("verify");
    if (b.args) |args| run_verify.addArgs(args);
    const verify_step = b.step("verify", "Emit gist match sets + corpus list for the rg equality diff");
    verify_step.dependOn(&run_verify.step);
    verify_step.dependOn(bench_install);

    // `zig build certify` — Layer A of the optimality certificate: per-class
    // single-thread cycles/byte + bootstrap-CI (PMU via kperf; run under `sudo`
    // for cycles, else wall-clock). Emits .local/gist-verify/CERTIFICATE.md.
    const run_certify = b.addRunArtifact(bench_exe);
    run_certify.setCwd(b.path("../../.."));
    run_certify.addArg("certify");
    if (b.args) |args| run_certify.addArgs(args);
    const certify_step = b.step("certify", "Layer-A optimality cert: per-class cycles/byte + bootstrap CI");
    certify_step.dependOn(&run_certify.step);
    certify_step.dependOn(bench_install);

    // Bench-side tests too — the harness-local `stats.zig` bootstrap-CI +
    // Mann-Whitney unit tests. (`bench/harness/bench.zig` imports `gist`; reuse the
    // bench module; the engine tests ride `k.test_step` via `src/root.zig`.)
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);

    // ── `relate-knn` — the compression-as-embedding proof harness ──
    // Runs the REAL hydra relate engine (zipper cross-parse / LZJD sketch) as a
    // k-NN text classifier over a labeled manifest, emitting accuracy + build/
    // query cost as JSON. The sibling driver (bench/relate/) races it against
    // gzip-kNN (ACL 2023) and a static-embedding model. Run from the repo root.
    const relate_knn_mod = b.createModule(.{
        .root_source_file = b.path("bench/relate/knn.zig"),
        .target = k.target,
        .optimize = cli_optimize, // the product-speed posture — this is a timing tool
    });
    relate_knn_mod.addImport("irregex", cli_engine);
    const relate_knn_exe = b.addExecutable(.{ .name = "relate-knn", .root_module = relate_knn_mod });
    const relate_knn_install = &b.addInstallArtifact(relate_knn_exe, .{}).step;
    lab_step.dependOn(relate_knn_install);
    const run_relate_knn = b.addRunArtifact(relate_knn_exe);
    run_relate_knn.setCwd(b.path("../../.."));
    if (b.args) |args| run_relate_knn.addArgs(args);
    const relate_knn_step = b.step("relate-knn", "Run the hydra relate engine as a k-NN classifier over a labeled manifest");
    relate_knn_step.dependOn(&run_relate_knn.step);
    relate_knn_step.dependOn(relate_knn_install);

    // ── `codex-scale` — the compressed self-index proof harness ──
    // Runs the REAL codex (src/codex/) over slices of an on-disk corpus:
    // index bits/char vs measured H0/H2, count/find latency across sizes
    // (flat in n), byte-exact restore from the index alone, every timed count
    // verified against a naive scan. bench/codex/race.sh adds compressor
    // baselines on identical slices. Run from the repo root.
    const codex_scale_mod = b.createModule(.{
        .root_source_file = b.path("bench/codex/scale.zig"),
        .target = k.target,
        .optimize = cli_optimize, // the product-speed posture — this is a timing tool
    });
    codex_scale_mod.addImport("irregex", cli_engine);
    const codex_scale_exe = b.addExecutable(.{ .name = "codex-scale", .root_module = codex_scale_mod });
    const codex_scale_install = &b.addInstallArtifact(codex_scale_exe, .{}).step;
    lab_step.dependOn(codex_scale_install);
    const run_codex_scale = b.addRunArtifact(codex_scale_exe);
    run_codex_scale.setCwd(b.path("../../.."));
    if (b.args) |args| run_codex_scale.addArgs(args);
    const codex_scale_step = b.step("codex-scale", "Prove the codex self-index at scale: entropy-bound space, flat-in-n count, exact restore");
    codex_scale_step.dependOn(&run_codex_scale.step);
    codex_scale_step.dependOn(codex_scale_install);

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
    roofline_mod.addImport("irregex", k.root_module);
    roofline_mod.addImport("pmu", pmu_mod);
    roofline_mod.link_libc = true; // pmu.zig's kperf dlopen path, same as bench_mod
    const roofline_exe = b.addExecutable(.{ .name = "gist-roofline", .root_module = roofline_mod });
    const roofline_install = &b.addInstallArtifact(roofline_exe, .{}).step;
    lab_step.dependOn(roofline_install);
    const run_roofline = b.addRunArtifact(roofline_exe);
    run_roofline.setCwd(b.path("../../.."));
    if (b.args) |args| run_roofline.addArgs(args);
    const roofline_step = b.step("roofline", "Layer-C optimality cert: STREAM read-bandwidth ceiling vs gist's scan");
    roofline_step.dependOn(&run_roofline.step);
    roofline_step.dependOn(roofline_install);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = roofline_mod })).step);

    // ── `gist-lowerbound` — Layer D: algorithmic-floor byte-touch audit ──
    const lowerbound_mod = b.createModule(.{
        .root_source_file = b.path("bench/lowerbound/lowerbound.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    lowerbound_mod.addImport("irregex", k.root_module);
    lowerbound_mod.addImport("probes", probes_mod);
    const lowerbound_exe = b.addExecutable(.{ .name = "gist-lowerbound", .root_module = lowerbound_mod });
    const lowerbound_install = &b.addInstallArtifact(lowerbound_exe, .{}).step;
    lab_step.dependOn(lowerbound_install);
    const run_lowerbound = b.addRunArtifact(lowerbound_exe);
    run_lowerbound.setCwd(b.path("../../.."));
    if (b.args) |args| run_lowerbound.addArgs(args);
    const lowerbound_step = b.step("lowerbound", "Layer-D optimality cert: fail-closed algorithmic-floor byte-touch audit");
    lowerbound_step.dependOn(&run_lowerbound.step);
    lowerbound_step.dependOn(lowerbound_install);

    // ── `gist-portbound` — Layer B′: the port bound MEASURED on this machine ──
    // Runs the same drift-guarded probes as portcert.sh's static llvm-mca bound,
    // natively under the PMU (cycles/byte + cycles/step). Fail-closed without
    // root: reports wall-clock and labels cycles NOT-measured; the sudo rung is
    // `sudo zig-out/bin/gist-portbound` after `zig build -Doptimize=ReleaseFast`.
    const portbound_mod = b.createModule(.{
        .root_source_file = b.path("bench/portcert/portbound.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    portbound_mod.addImport("irregex", k.root_module);
    portbound_mod.addImport("pmu", pmu_mod);
    portbound_mod.link_libc = true; // pmu.zig's kperf dlopen path, same as bench_mod
    const portbound_exe = b.addExecutable(.{ .name = "gist-portbound", .root_module = portbound_mod });
    const portbound_install = &b.addInstallArtifact(portbound_exe, .{}).step;
    lab_step.dependOn(portbound_install);
    const run_portbound = b.addRunArtifact(portbound_exe);
    run_portbound.setCwd(b.path("../../.."));
    if (b.args) |args| run_portbound.addArgs(args);
    const portbound_step = b.step("portbound", "Layer-B′ optimality cert: measured on-machine port bound (sudo for cycles)");
    portbound_step.dependOn(&run_portbound.step);
    portbound_step.dependOn(portbound_install);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = portbound_mod })).step);

    // Layer-B drift guard (`probes/` copies ≡ the real production hot loops) —
    // wired into `zig build test` so a silent copy/production divergence fails
    // CI loudly instead of shipping a stale certificate.
    const portcert_test_mod = b.createModule(.{
        .root_source_file = b.path("bench/portcert/probes_test.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    portcert_test_mod.addImport("irregex", k.root_module);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = portcert_test_mod })).step);
}
