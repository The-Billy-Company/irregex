//! irregex build graph — THE library of the irregex ecosystem.
//!
//! This package is the engine: syntax → automata ladder → scan/verify → the
//! cold walk-and-emit pipeline → the warm resident core, plus the trigram /
//! crest / phantom persisted index tiers. It ships as a **Zig module**
//! (`@import("irregex")`) that the product packages (`relate`, `gist`,
//! `blast`) consume as siblings; it installs no executables and no C-ABI
//! artifact of its own. The session-shaped C ABI (include/*.h + surface/ffi)
//! lives in `gist`; the kinship/codex engines live in `relate`.
//!
//! The test chassis mirrors kernelkit's (`../_buildkit`): one ReleaseSafe
//! brigade-sharded unit-test binary (`test` / `test-quick`), a compile-only
//! `check` step for the --watch/ZLS loop, a kcov `coverage` step, and the
//! Linux/Windows cross-compile drift gates folded into `test`.

const std = @import("std");
const builtin = @import("builtin");

// ── the suite's long poles (`zig build test-quick` stands these aside) ──
// Each is a compile-bound differential (hundreds of powerset DFA builds under
// the leak-tracking test allocator) carrying an explicit coverage floor, so
// the cost is real proof and the sweep must not be trimmed to make the clock
// look better. They stay in `zig build test`; the quick tier just doesn't
// pretend to have run them. Costs measured with `BRIGADE_TIMES=1`.
const deep_tests = [_][]const u8{
    "word-boundary Unicode quit path", // 320 s
    "word-boundary differential vs Pike", // 160 s
    "symbolic: line differential vs the Pike VM", // 101 s
    "symbolic: document differential vs the Pike VM", // 88 s
};

// ── the vendored C floor ──
// PCRE2, compiled from the pinned mirror under `vendor/pcre2/` — never from
// the host — so the build is byte-reproducible on any machine. Provenance
// (release URL, sha256, kept subset) lives in `vendor/pcre2/README.md`; the
// build.zig.zon `.lazy` row pins the upstream release by URL + content hash.
// Bound with explicit `extern` declarations rather than `@cImport`, so no
// module outside this file needs the include paths.
//
// The 8-bit PCRE2 sources: the canonical set from PCRE2's NON-AUTOTOOLS-BUILD
// guide (step 4). pcre2_jit_compile.c #includes the sljit backend from
// ../deps/sljit relative to the src dir, so the vendored src↔deps layout must
// be preserved.
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
// defaults; the -D flags turn on the 8-bit library, Unicode/UTF, JIT, and
// static linkage. SUPPORT_JIT is always compiled in; on an sljit-unsupported
// target the backend self-disables and the Zig wrapper falls back to the
// interpreter. `-fno-sanitize=undefined` keeps Zig's C UBSan from trapping on
// PCRE2's intentional, well-defined-in-practice pointer/shift idioms — a `-P`
// query must degrade to a clean error, never a sanitizer abort.
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

/// One PCRE2 static archive per optimize mode, memoized — an adversarial
/// ReleaseSafe test must not run a Debug C library, and a ReleaseFast product
/// twin must not link a ReleaseSafe one. `.pic = true` so one archive serves
/// both a future shared object and every executable (macOS is PIC by default;
/// ELF non-PIC would reject the archive in a PIE link).
const Floor = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    built: Memo = Memo.initFill(null),

    const Memo = std.EnumArray(std.builtin.OptimizeMode, ?*std.Build.Step.Compile);

    /// Links libc + the PCRE2 archive onto `m`. libc is not incidental: the
    /// archive is C, and the macOS FSEvents historical journal
    /// (`src/corpus/fresh/journal.zig`) reaches CoreServices through libc's
    /// `dlopen`/`dlsym` at runtime rather than link-time framework bindings.
    fn under(self: *Floor, m: *std.Build.Module) void {
        m.link_libc = true;
        m.linkLibrary(self.at(m.optimize.?));
    }

    fn at(self: *Floor, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        if (self.built.get(optimize)) |ready| return ready;
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true });
        mod.addIncludePath(self.b.path("vendor/pcre2/src"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/pcre2/src"), .files = &pcre2_sources, .flags = &pcre2_cflags });
        const lib = self.b.addLibrary(.{ .name = "pcre2irregex", .linkage = .static, .root_module = mod });
        self.built.set(optimize, lib);
        return lib;
    }
};

pub fn build(b: *std.Build) void {
    // macOS deployment floor: keep the emitted Mach-O's minos below any
    // plausible consumer link target (kernelkit's convention). Windows floor:
    // win10_rs4 — `std.Io.net.has_unix_sockets` is comptime-false below it,
    // which would prune the entire resident tier out of a cross-build.
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    var floor = Floor{ .b = b, .target = target };

    // ── the public module (`@import("irregex")`) ──
    // What `relate`/`gist`/`blast` consume as a sibling-path dependency. PIC
    // for the same reason kernelkit's chassis is: the product packages link it
    // into PIE binaries and (in gist) a shared C-ABI object.
    const engine = b.addModule("irregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    floor.under(engine);

    // The unit-test binary is pinned to ReleaseSafe: the suite is dominated by
    // differential-fuzz loops (DFA vs Pike, powerset language equivalence,
    // adversarial oracles, index-loader mutation soak) that exist to trip
    // safety checks — which ReleaseSafe keeps, at optimized speed. Debug ran
    // the same suite ~4x slower for no extra checking; `-Dtest-optimize=Debug`
    // still yields a Debug binary for stepping through a failure.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "optimize mode for the unit-test binary (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const test_module = if (test_optimize == optimize) engine else blk: {
        const twin = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = test_optimize,
            .pic = true,
        });
        floor.under(twin);
        break :blk twin;
    };

    // One compiled test binary, `shards` processes running disjoint residue
    // classes of it (kernelkit's brigade runner). ~2x cores, not 1x: the build
    // runner keeps only cores-1 steps in flight, so over-decomposing turns its
    // scheduler into a work queue instead of idling a core beside a grinding
    // neighbor.
    const shards = b.option(
        usize,
        "test-shards",
        "how many parallel processes `zig build test` splits the unit-test binary across (default: 2x CPU count; 1 restores a single-process run)",
    ) orelse @min(@max(std.Thread.getCpuCount() catch 1, 1) * 2, 64);
    const brigade = b.dependency("kernelkit", .{}).path("brigade.zig");
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "run only unit tests whose name contains one of these comma-separated substrings",
    );
    const test_skip = b.option(
        []const u8,
        "test-skip",
        "skip unit tests whose name contains one of these comma-separated substrings",
    );

    const test_step = b.step("test", "Run unit tests");
    addShards(b, tests, test_step, shards, test_filter, test_skip);

    // `zig build test-quick` — the same suite minus the declared long poles,
    // for the edit loop. A strictly weaker proof than `test`, and says so.
    const deep = std.mem.join(b.allocator, ",", &deep_tests) catch @panic("OOM");
    const quick_step = b.step(
        "test-quick",
        b.fmt("Run unit tests except the {d} declared long poles (weaker than `test`)", .{deep_tests.len}),
    );
    const quick_skip = if (test_skip) |s| b.fmt("{s},{s}", .{ s, deep }) else deep;
    addShards(b, tests, quick_step, shards, test_filter, quick_skip);

    // Debug twin for `check` (the step ZLS / --watch -fincremental drives) and
    // `coverage` (kcov needs full-fidelity DWARF). Carries the SAME brigade
    // runner: `@import("root")` inside a test resolves to the runner, so a
    // debug twin on the stock runner would compile a different program.
    const debug_tests = if (test_module == engine) tests else b.addTest(.{
        .root_module = engine,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    b.step("check", "Compile tests without running (fast --watch -fincremental loop / ZLS)")
        .dependOn(&debug_tests.step);

    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(debug_tests);
    run_cov.setEnvironmentVariable("BRIGADE_SHARD", "0/1");
    b.step("coverage", "Run unit tests under kcov → .local/coverage/ (Cobertura XML)")
        .dependOn(&run_cov.step);

    // ── cross-target drift gate (`check-linux` / `check-windows`, folded into `test`) ──
    // A dev box compiles one OS's legs and comptime-prunes every other's, so
    // the pruned ones rot silently. Each foreign target compiles the library
    // module as an OBJECT: complete Sema + codegen over every line that target
    // can reach, but no cross-build of the C floor and no link (the extern
    // declarations suffice), so the gate stays cheap enough to ride every
    // `zig build test`. Windows is three triples because word size and
    // instruction set are separate risks; win10_rs4 is load-bearing (see the
    // floor note above).
    const cross_checks = [_]struct {
        step: []const u8,
        blurb: []const u8,
        queries: []const std.Target.Query,
    }{
        .{
            .step = "check-linux",
            .blurb = "Cross-compile the library for x86_64-linux (Sema+codegen, no link) — keeps the comptime-pruned Linux legs building",
            .queries = &.{.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }},
        },
        .{
            .step = "check-windows",
            .blurb = "Cross-compile the library for all three Windows triples (Sema+codegen, no link) — keeps portal's Win32 arm and the warm tier's Win32 arm building",
            .queries = &.{
                .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
                .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
                .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
            },
        },
    };
    for (cross_checks) |check| {
        const step = b.step(check.step, check.blurb);
        for (check.queries) |query| {
            const foreign = b.resolveTargetQuery(query);
            const mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = foreign,
                .optimize = .Debug,
                .link_libc = true,
            });
            const obj = b.addObject(.{
                .name = b.fmt("irregex-check-{t}-{t}", .{ query.cpu_arch.?, query.os_tag.? }),
                .root_module = mod,
            });
            step.dependOn(&obj.step);
            test_step.dependOn(&obj.step);
        }
    }
}

/// Hang `shards` independent `Run` steps off one compiled test binary, each
/// owning a disjoint residue class of the (filtered) suite — kernelkit's
/// fan-out, restated here because this build declares no C-ABI kernel.
fn addShards(
    b: *std.Build,
    tests: *std.Build.Step.Compile,
    step: *std.Build.Step,
    shards: usize,
    filter: ?[]const u8,
    skip: ?[]const u8,
) void {
    for (0..shards) |i| {
        const run_shard = b.addRunArtifact(tests);
        run_shard.setEnvironmentVariable("BRIGADE_SHARD", b.fmt("{d}/{d}", .{ i, shards }));
        if (filter) |f| run_shard.setEnvironmentVariable("BRIGADE_FILTER", f);
        if (skip) |s| run_shard.setEnvironmentVariable("BRIGADE_SKIP", s);
        run_shard.expectExitCode(0);
        run_shard.setName(b.fmt("{s} shard {d}/{d}", .{ step.name, i, shards }));
        step.dependOn(&run_shard.step);
    }
}
