//! irregex build graph — THE library of the irregex ecosystem.
//!
//! This package is the engine: syntax → automata ladder → scan/verify → the
//! cold walk-and-emit pipeline → the warm resident core, plus the trigram /
//! crest / phantom persisted index tiers. It ships as a **Zig module**
//! (`@import("irregex")`) that the product packages (`relate`, `gist`,
//! `blast`) consume as siblings, plus its own C-ABI artifact — `libirgx` +
//! `include/irgx.h`: the regex-over-text plane (compile · is_match ·
//! find_all · captures) and the status/fault substrate all four ABIs share.
//! It installs no executables. The session-shaped ABI over a corpus lives in
//! `gist`; the kinship engine (and the cento quoter over this library's
//! FM-index) lives in `relate`.
//!
//! The test chassis is this package's own, and `gist`/`relate` mirror it by
//! reaching for `brigade.zig` through their dependency here: one ReleaseSafe
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

// libsais — the suffix-array constructor under the FM-index. No feature
// flags: LIBSAIS_OPENMP stays OFF, so the parallel entry points are
// preprocessed away and the archive needs no `libomp`. `-fno-sanitize=
// undefined` because the induced sort walks its suffix array with
// deliberately negative sentinel indices and one-past-the-end cursors — a
// codex build must fail as a Zig error, never as a sanitizer abort inside C.
// Provenance: vendor/libsais/README.md + the build.zig.zon `.lazy` row.
const libsais_cflags = [_][]const u8{
    "-fno-sanitize=undefined",
    "-std=c99",
};

/// One static archive per C floor per optimize mode, memoized — an adversarial
/// ReleaseSafe test must not run a Debug C library, and a ReleaseFast product
/// twin must not link a ReleaseSafe one. `.pic = true` so one archive serves
/// both a future shared object and every executable (macOS is PIC by default;
/// ELF non-PIC would reject the archive in a PIE link).
const Floor = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    pcre2: Memo = Memo.initFill(null),
    libsais: Memo = Memo.initFill(null),

    const Memo = std.EnumArray(std.builtin.OptimizeMode, ?*std.Build.Step.Compile);

    /// Links libc + both C floors onto `m`. libc is not incidental: the
    /// archives are C, and the macOS FSEvents historical journal
    /// (`src/corpus/fresh/journal.zig`) reaches CoreServices through libc's
    /// `dlopen`/`dlsym` at runtime rather than link-time framework bindings.
    fn under(self: *Floor, m: *std.Build.Module) void {
        m.link_libc = true;
        m.linkLibrary(self.pcre2At(m.optimize.?));
        m.linkLibrary(self.libsaisAt(m.optimize.?));
    }

    fn pcre2At(self: *Floor, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        if (self.pcre2.get(optimize)) |ready| return ready;
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true });
        mod.addIncludePath(self.b.path("vendor/pcre2/src"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/pcre2/src"), .files = &pcre2_sources, .flags = &pcre2_cflags });
        const lib = self.b.addLibrary(.{ .name = "pcre2irregex", .linkage = .static, .root_module = mod });
        self.pcre2.set(optimize, lib);
        return lib;
    }

    fn libsaisAt(self: *Floor, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        if (self.libsais.get(optimize)) |ready| return ready;
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true });
        mod.addIncludePath(self.b.path("vendor/libsais/include"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/libsais/src"), .files = &.{"libsais.c"}, .flags = &libsais_cflags });
        const lib = self.b.addLibrary(.{ .name = "libsais", .linkage = .static, .root_module = mod });
        self.libsais.set(optimize, lib);
        return lib;
    }
};

pub fn build(b: *std.Build) void {
    // macOS deployment floor: keep the emitted Mach-O's minos below any
    // plausible consumer link target. Windows floor:
    // win10_rs4 — `std.Io.net.has_unix_sockets` is comptime-false below it,
    // which would prune the entire resident tier out of a cross-build.
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // Debug info is worth its size to anyone developing against the engine and
    // worth nothing to someone who ran `pip install`. It is not a rounding error
    // either: on ELF the DWARF outweighs the code roughly four to one, so the
    // published Linux library is ~11 MB unstripped against ~2 MB stripped. Mach-O
    // hides the asymmetry by keeping DWARF in a separate `.dSYM`, which is why
    // only the ELF and PE artifacts look bloated. Off by default so a local build
    // stays debuggable; the wheel matrix asks for it explicitly.
    const strip = b.option(bool, "strip", "Omit debug info from emitted artifacts (packaging)");

    var floor = Floor{ .b = b, .target = target };

    // ── the public module (`@import("irregex")`) ──
    // What `relate`/`gist`/`blast` consume as a sibling-path dependency. PIC
    // because the product packages link it into PIE binaries and (in gist) a
    // shared C-ABI object.
    const engine = b.addModule("irregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .strip = strip,
    });
    floor.under(engine);

    // ── the C-ABI artifact (`libirgx` + `include/irgx.h`) ──
    // Rooted at the export shims, NOT at `src/root.zig`. A Zig `export fn` is
    // emitted by every compilation that reaches it, so shims living in the
    // library module would be duplicated into `libgist`, `librelate`, and
    // `libblast` — each of which imports it — and a host linking two of them
    // would hit a duplicate-symbol error for a symbol it asked for once.
    // Keeping them in the artifact's own root means the symbols exist exactly
    // where the library named after them is.
    const abi = b.createModule(.{
        .root_source_file = b.path("src/surface/ffi/exports.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
        .strip = strip,
        .imports = &.{.{ .name = "irregex", .module = engine }},
    });

    // Dynamic (Python cffi dlopens it) owns the header install; static is what
    // Go cgo and a Rust build.rs link. Zig's archiver leaves Mach-O members
    // non-8-byte-aligned, which Apple's ld64 rejects in a cgo link, so macOS
    // re-archives through `libtool -static`; LLD tolerates it.
    const dynamic_lib = b.addLibrary(.{ .name = "irgx", .linkage = .dynamic, .root_module = abi });
    dynamic_lib.installHeader(b.path("include/irgx.h"), "irgx.h");
    b.installArtifact(dynamic_lib);
    if (target.result.os.tag == .macos) {
        const obj = b.addObject(.{ .name = "irgx", .root_module = abi });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("libirgx.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "libirgx.a").step);
    } else {
        const static_lib = b.addLibrary(.{ .name = "irgx", .linkage = .static, .root_module = abi });
        b.installArtifact(static_lib);
    }

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
    // classes of it (`brigade.zig`). ~2x cores, not 1x: the build
    // runner keeps only cores-1 steps in flight, so over-decomposing turns its
    // scheduler into a work queue instead of idling a core beside a grinding
    // neighbor.
    const shards = b.option(
        usize,
        "test-shards",
        "how many parallel processes `zig build test` splits the unit-test binary across (default: 2x CPU count; 1 restores a single-process run)",
    ) orelse @min(@max(std.Thread.getCpuCount() catch 1, 1) * 2, 64);
    const brigade = b.path("brigade.zig");
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

    // The C-ABI artifact is a SEPARATE module (rooted at the export shims, see
    // above), and Zig collects tests only from a root module's own files — so
    // every test under `surface/ffi/exports.zig` and its siblings was compiled by
    // nothing and run by nothing. It gets its own binary, unsharded: a handful of
    // tests over shims and the C lowering of the warm corpus, where splitting
    // across processes costs more than it saves.
    //
    // Its own step, and folded into `test` only when nothing is filtered, because
    // brigade fails a shard whose filter matched none of its tests — correct for
    // one binary (you typo'd it), wrong across two, where a name living in the
    // other plane is not a typo. So an unfiltered run — the one a push is judged
    // by — covers both, and a filtered hunt names the plane it is hunting in.
    const abi_tests = b.addTest(.{
        .root_module = abi,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    const abi_step = b.step("test-abi", "Run the C-ABI artifact's unit tests (folded into `test`)");
    addShards(b, abi_tests, abi_step, 1, test_filter, test_skip);
    if (test_filter == null) test_step.dependOn(abi_step);

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

    // ── the shared measurement instruments ──
    // Published as named modules rather than kept private, because the lanes
    // that read them do not all live here: `gist`'s `gist-bench` reaches these
    // three through its dependency on this package, the same way it reaches
    // `brigade.zig`. That is the whole reason `bench/apparatus/harness` is in
    // `.paths`. Keeping ONE probe registry across both repos is what lets a
    // competitor race over there and an engine rung over here be compared by
    // class name; a second copy would silently stop meaning the same thing.
    const probes = b.addModule("probes", .{
        .root_source_file = b.path("bench/apparatus/harness/probes.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pmu = b.addModule("pmu", .{
        .root_source_file = b.path("bench/apparatus/harness/pmu.zig"),
        .target = target,
        .optimize = optimize,
        // It reaches libSystem and the kperf frameworks through `dlopen`, so the
        // module needs libc on its own account — not only when a lane that
        // imports it happens to ask for it.
        .link_libc = true,
    });
    const stats = b.addModule("stats", .{
        .root_source_file = b.path("bench/apparatus/harness/stats.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The verdict math every lane in both repos reports through — bootstrap CI
    // and Mann-Whitney. Nothing else compiles it, so without this it is dead
    // code that happens to be trusted.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = stats })).step);
    // The meter is trusted the same way, and for a sharper reason: it decides
    // whether every cycles/byte number in the certificate is a measurement or a
    // zero. Its tests are adverse — a swapped struct field, a short read, a
    // per-process counter masquerading as per-thread, or a cycle count that is
    // secretly wall-clock each fail one of them.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pmu })).step);

    // ── the measurement lab ──
    // Deliberately OFF the default install step: a bare `zig build` (and every
    // parity gate that rebuilds a product binary) pays only for the library and
    // its C ABI. Each lab executable installs on its own named step, so the
    // documented `sudo zig-out/bin/<exe>` re-runs keep working after e.g.
    // `zig build portbound`; `zig build lab` installs all of them at once.
    //
    // Only ENGINE lanes live here. The `gist-bench` harness moved to the `gist`
    // package with the binary it measures: its session mode drives a live
    // `gist serve` daemon, and this package cannot depend on the one downstream
    // of it. See gist/bench/README.md.
    const lab_step = b.step("lab", "Build + install the measurement-lab executables → zig-out/bin");

    // A rung that races an accelerator against the shipped ladder has to be
    // compiled the way the shipped ladder is, or the ratio is about the build
    // mode rather than the machine. Certificate lanes instead honour whatever
    // `-Doptimize` the caller asked for, since a cycles/byte number is a claim
    // about THIS build.
    const lab_optimize = b.option(
        std.builtin.OptimizeMode,
        "lab-optimize",
        "optimize mode for the production-posture rungs (default ReleaseFast — they race the shipped ladder)",
    ) orelse .ReleaseFast;
    const speed = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = lab_optimize,
        .pic = true,
    });
    floor.under(speed);

    const Lane = struct {
        step: []const u8,
        exe: []const u8,
        root: []const u8,
        blurb: []const u8,
        /// Production posture (races the shipped ladder) vs the caller's mode.
        posture: enum { shipped, asked } = .shipped,
        instrument: ?[]const u8 = null,
        /// `pmu.zig` reaches Apple's private kperf through `dlopen`.
        libc: bool = false,
        /// Lanes carrying their own unit tests, folded into `zig build test`.
        tested: bool = false,
    };
    for ([_]Lane{
        // Certificate layers — each answers "how far is this from a stated limit".
        .{ .step = "roofline", .exe = "gist-roofline", .root = "bench/bounds/roofline/bandwidth.zig", .posture = .asked, .instrument = "pmu", .libc = true, .tested = true, .blurb = "Layer-C optimality cert: STREAM read-bandwidth ceiling vs gist's scan" },
        .{ .step = "portbound", .exe = "gist-portbound", .root = "bench/bounds/port/measure.zig", .posture = .asked, .instrument = "pmu", .libc = true, .tested = true, .blurb = "Layer-B′ optimality cert: measured on-machine port bound (sudo for cycles)" },
        .{ .step = "lowerbound", .exe = "gist-lowerbound", .root = "bench/bounds/lowerbound/audit.zig", .posture = .asked, .instrument = "probes", .blurb = "Layer-D optimality cert: fail-closed algorithmic-floor byte-touch audit" },
        .{ .step = "scale", .exe = "gist-scale", .root = "bench/rungs/sliver/scale.zig", .posture = .asked, .instrument = "probes", .blurb = "Layer-J: fail-closed sub-trigram candidate-byte audit (directory vs sliver tier)" },
        .{ .step = "indexq", .exe = "gist-indexq", .root = "bench/rungs/sieve/indexq.zig", .posture = .asked, .instrument = "probes", .blurb = "Layer-L optimality cert: candidate-byte selectivity head-to-head vs csearch's own formula" },
        // Production rungs — each races one real accelerator against the real ladder.
        .{ .step = "crest", .exe = "crest", .root = "bench/rungs/crest/bench.zig", .blurb = "Crest production proof: sound forced-class-run sieve — pruning + speed vs the real matcher" },
        .{ .step = "sieve", .exe = "sieve", .root = "bench/rungs/sieve/bench.zig", .blurb = "Quotient-sieve production proof: per-position soundness, measured selectivity, kernel speed vs the shipped DFA" },
        .{ .step = "compose-rung", .exe = "compose-rung", .root = "bench/rungs/shuffle/bench.zig", .blurb = "Composition-rung production proof: whole-buffer agreement with the shipped DFA, interleaved throughput, and the armed-skip boundary row" },
        .{ .step = "parabix-rung", .exe = "parabix-rung", .root = "bench/rungs/parabix/bench.zig", .blurb = "Parabix-rung production proof: corpus-scale agreement with the shipped ladder, negative-case throughput vs both baselines, and the refusal rows" },
        .{ .step = "automata-rung", .exe = "automata-rung", .root = "bench/rungs/automata/bench.zig", .blurb = "Automata-layout proof: per-pattern automaton shape, and the match test priced both ways over one machine" },
        .{ .step = "patternid-rung", .exe = "patternid-rung", .root = "bench/rungs/patternid/bench.zig", .blurb = "PatternID gate: state-count cost of carrying a pattern mask in the determinizer's state key" },
        .{ .step = "multipattern", .exe = "multipattern", .root = "bench/rungs/multipattern/bench.zig", .blurb = "Multi-pattern race arm: per-document attribution throughput, fail-closed against N independent searches" },
        .{ .step = "sweep-rung", .exe = "sweep-rung", .root = "bench/rungs/sweep/bench.zig", .blurb = "Sweep-rung consumer proof: each recursive analysis raced against the fused interned-AST sweep, alone and bundled, fail-closed on any disagreement" },
        .{ .step = "ladder-price", .exe = "ladder-price", .root = "bench/rungs/price/bench.zig", .blurb = "Ladder price plane: re-time every auction coefficient in isolation (verify), and gate the auction's per-pattern picks against the measured-fastest machine (regret)" },
        .{ .step = "engine-census", .exe = "engine-census", .root = "bench/rungs/census/bench.zig", .instrument = "probes", .blurb = "Engine census: which ladder machine each certificate probe class actually compiles to" },
    }) |lane| {
        const shipped = lane.posture == .shipped;
        const mod = b.createModule(.{
            .root_source_file = b.path(lane.root),
            .target = target,
            .optimize = if (shipped) lab_optimize else optimize,
        });
        mod.addImport("irregex", if (shipped) speed else engine);
        if (lane.instrument) |name| mod.addImport(name, if (std.mem.eql(u8, name, "pmu")) pmu else probes);
        if (lane.libc) mod.link_libc = true;

        const exe = b.addExecutable(.{ .name = lane.exe, .root_module = mod });
        const install = &b.addInstallArtifact(exe, .{}).step;
        lab_step.dependOn(install);

        // Every lane runs from the package root. In the monorepo this was three
        // levels up, because the corpus and the package were different trees;
        // here they are the same tree.
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        if (b.args) |args| run.addArgs(args);
        const step = b.step(lane.step, lane.blurb);
        step.dependOn(&run.step);
        step.dependOn(install);
        if (lane.tested) test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    // Layer-B drift guard: the `probes/` copies must stay ≡ the real production
    // hot loops. Test-only — it publishes no number, it just refuses to let a
    // silent copy/production divergence ship inside a stale certificate.
    const probes_drift = b.createModule(.{
        .root_source_file = b.path("bench/bounds/port/probes_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    probes_drift.addImport("irregex", engine);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = probes_drift })).step);
}

/// Hang `shards` independent `Run` steps off one compiled test binary, each
/// owning a disjoint residue class of the (filtered) suite. The parallelism is
/// the build runner's: independent `Run` steps are already scheduled across
/// cores, so `brigade.zig` only decides which tests a process claims.
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
