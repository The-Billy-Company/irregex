//! gist build graph — the candidate-search index kernel. The dual
//! static+dynamic C-ABI artifact, the macOS archive realign, and the
//! `test`/`coverage` steps live in the shared `kernelkit` chassis
//! (pkg/kernels/core). This file declares the kernel plus two executables
//! built on it: the production `gist` CLI (`src/surface/face/gist/main.zig`, the
//! `index`/`status` lifecycle verbs plus the bare `<pattern>`/`rg` search
//! front door) and the separate `gist-bench` harness
//! (`bench/apparatus/harness/bench.zig`, the `bench`/`verify`/`certify` tooling). Production CLI
//! and benchmark tooling no longer share a binary.
//!
//! Build-speed contract: a bare `zig build` installs ONLY the product surface
//! (gist + relate CLIs and the C-ABI libs). The six bench/certificate lab
//! executables (gist-bench, gist-roofline, gist-lowerbound, gist-portbound,
//! relate-knn, codex-scale) install on their own named steps — and all at once
//! via `zig build lab` — so the everyday build/install loop never pays for
//! measurement tooling it doesn't run.

const std = @import("std");
const kernelkit = @import("kernelkit");

// ── the suite's long poles (`zig build test-quick` stands these aside) ──
// 991 unit tests cost 1059 s end to end; these four cost 669 s of it, so they
// set the makespan of ANY sharded run — a shard is a process, and a process
// cannot split one test. Each is a compile-bound differential (hundreds of
// powerset DFA builds under the leak-tracking test allocator) carrying an
// explicit coverage floor, so the cost is real proof and the sweep must not be
// trimmed to make the clock look better. They stay in `zig build test`; the
// quick tier just doesn't pretend to have run them.
// Costs measured with `BRIGADE_TIMES=1` on a 16-core M-series box.
const deep_tests = [_][]const u8{
    "word-boundary Unicode quit path", // 320 s
    "word-boundary differential vs Pike", // 160 s
    "symbolic: line differential vs the Pike VM", // 101 s
    "symbolic: document differential vs the Pike VM", // 88 s
};

// ── the vendored C floor ──
// Third-party C compiled from pinned sources under `vendor/`, never from the
// host: no system libpcre2, no system libsais, so the build is byte-
// reproducible on any machine. One row per static archive; provenance (release
// URL, sha256, which subset is kept and why) lives in that library's
// `vendor/<name>/README.md`. Feature selection is `-D` flags here — visible and
// reviewable — so the vendored sources stay byte-identical to upstream and an
// update is a clean re-vendor rather than a patch to reconcile. Both libraries
// are bound with explicit `extern` declarations rather than `@cImport`, so no
// module outside this file needs their include paths.
const Vendored = struct {
    /// Static-archive name (must not collide with a system library's).
    name: []const u8,
    /// Header search path for the archive's own sources, repo-relative.
    include: []const u8,
    /// C source root, repo-relative; `files` are relative to it.
    src: []const u8,
    files: []const []const u8,
    flags: []const []const u8,
};

const floor_libs = [_]Vendored{
    .{
        .name = "pcre2irregex", // the opt-in `-P` backend
        .include = "vendor/pcre2/src",
        .src = "vendor/pcre2/src",
        .files = &pcre2_sources,
        .flags = &pcre2_cflags,
    },
    .{
        .name = "libsais", // the codex FM-index's suffix-array constructor
        .include = "vendor/libsais/include",
        .src = "vendor/libsais/src",
        .files = &.{"libsais.c"},
        .flags = &libsais_cflags,
    },
};

// The 8-bit PCRE2 library sources: the canonical set from PCRE2's own
// NON-AUTOTOOLS-BUILD guide (step 4). pcre2_jit_compile.c #includes the sljit
// backend from ../deps/sljit relative to the src dir, so the vendored src↔deps
// layout must be preserved.
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
// the 8-bit library, Unicode/UTF, JIT, and static linkage. SUPPORT_JIT is
// always compiled in; on an sljit-unsupported target the backend self-disables
// and `pcre2_jit_compile` reports an error, which the Zig wrapper treats as
// "no JIT" and falls back to the interpreter. `-fno-sanitize=undefined` keeps
// Zig's C UBSan from trapping on PCRE2's intentional, well-defined-in-practice
// pointer/shift idioms — a `-P` query must degrade to a clean error, never a
// sanitizer abort.
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

// libsais compiles with no feature flags at all: LIBSAIS_OPENMP stays OFF, so
// the parallel entry points are preprocessed away and the archive needs no
// `libomp` (a dependency neither the toolchain nor the ledger carries).
// `-fno-sanitize=undefined` matches the PCRE2 rationale — the induced sort
// walks its suffix array with deliberately negative sentinel indices and
// one-past-the-end cursors, and a codex build must fail as a Zig error, never
// as a sanitizer abort inside C.
const libsais_cflags = [_][]const u8{
    "-fno-sanitize=undefined",
    "-std=c99",
};

/// The vendored C floor every module that compiles the engine stands on.
///
/// `under(m)` is the entire surface: it wires libc and links every archive in
/// `floor_libs`, each built at **that module's own** optimize — an adversarial
/// ReleaseSafe test must not run a Debug C library, and the ReleaseFast CLI
/// must not link a ReleaseSafe one. Archives are memoized per optimize mode, so
/// the modules standing on the floor share one build of it per mode instead of
/// recompiling PCRE2 once each. Admitting a third vendored library is a row in
/// `floor_libs`; no call site changes.
const Floor = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    built: Memo = Memo.initFill(null),

    const Archives = [floor_libs.len]*std.Build.Step.Compile;
    const Memo = std.EnumArray(std.builtin.OptimizeMode, ?Archives);

    /// Links libc + the whole floor onto `m`.
    ///
    /// libc is not incidental: the archives are C, and the macOS FSEvents
    /// historical journal (`src/corpus/fresh/journal.zig`, the one-shot
    /// index-amend replay) reaches CoreServices/CoreFoundation through libc's
    /// `dlopen`/`dlsym` at runtime rather than link-time framework bindings —
    /// so the cold search binary never loads (or pays the launch-time
    /// initializers of) frameworks only an amend arms. `link_libc` also wires
    /// the SDK sysroot; macOS links libSystem regardless.
    fn under(self: *Floor, m: *std.Build.Module) void {
        m.link_libc = true;
        for (self.at(m.optimize.?)) |archive| m.linkLibrary(archive);
    }

    fn at(self: *Floor, optimize: std.builtin.OptimizeMode) Archives {
        if (self.built.get(optimize)) |ready| return ready;
        var made: Archives = undefined;
        for (floor_libs, &made) |lib, *slot| {
            // `.pic = true` is what lets ONE archive serve both consumers of the
            // floor. The kernel ships a dual static+dynamic C-ABI artifact, and
            // an ELF shared object may only absorb position-independent objects:
            // without this, every cross target with ELF+non-PIC-by-default (all
            // the Linux/BSD ones) fails the `libirregex.so` link with thousands
            // of "relocation R_… cannot be used against symbol; recompile with
            // -fPIC" errors, while macOS — PIC by default — builds clean and
            // hides it. The alternative, a second non-PIC archive per optimize
            // for the executables, doubles the floor's build cost to buy a GOT
            // indirection the hot loops never touch (the match engine is Zig;
            // PCRE2 is the opt-in `-P` backend and libsais runs once per index).
            const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true });
            mod.addIncludePath(self.b.path(lib.include));
            mod.addCSourceFiles(.{ .root = self.b.path(lib.src), .files = lib.files, .flags = lib.flags });
            slot.* = self.b.addLibrary(.{ .name = lib.name, .linkage = .static, .root_module = mod });
        }
        self.built.set(optimize, made);
        return made;
    }
};

pub fn build(b: *std.Build) void {
    // The unit-test binary is pinned to ReleaseSafe: gist's suite is dominated
    // by differential-fuzz loops (DFA vs Pike, powerset language equivalence,
    // adversarial oracles, index-loader mutation soak) that exist to trip
    // safety checks — which ReleaseSafe keeps, at optimized speed. Debug ran
    // the same suite ~4× slower (5.5 min vs ~80 s) for no extra checking.
    // `-Dtest-optimize=Debug` still yields a Debug test binary when stepping
    // through a failure; the kcov `coverage` binary stays build-wide Debug.
    const k = kernelkit.addKernel(b, .{
        .name = "irregex",
        .test_optimize = .ReleaseSafe,
        .deep_tests = &deep_tests,
    });

    // Stand every engine module that compiles the kernel (root + the
    // ReleaseSafe test twin when `test_optimize` diverges) on the vendored C
    // floor, each at its own optimize.
    var floor = Floor{ .b = b, .target = k.target };
    var engine_buf: [2]*std.Build.Module = undefined;
    for (kernelkit.engineModules(k, &engine_buf)) |m| floor.under(m);

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
    // Twin of the root at the CLI optimize — decorations aren't copied.
    const cli_engine = kernelkit.twin(k, cli_optimize);
    floor.under(cli_engine);
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/face/gist/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    cli_mod.addImport("irregex", cli_engine);
    const cli_exe = b.addExecutable(.{ .name = "gist", .root_module = cli_mod });
    b.installArtifact(cli_exe);
    // `gist` alone, for callers that want the CLI under test and not its two
    // siblings. The portability sweep (`bench/conformance/targets/`) cross-compiles 22
    // targets and only ever executes `gist`, so building `relate` and `irregex`
    // for each of them triples a sweep for nothing. `install` is unchanged — this
    // is an additional entry point into the same artifact, not a narrowing.
    b.step("gist", "Build + install just the `gist` CLI (the portability sweep's unit)")
        .dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // ── the `relate` binary — compression-as-search (similar/echoes/pack) ──
    // Same engine module, same ReleaseFast product posture; a second thin face
    // over the shared kernel, not a second engine.
    const relate_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/face/relate/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    relate_mod.addImport("irregex", cli_engine);
    const relate_exe = b.addExecutable(.{ .name = "relate", .root_module = relate_mod });
    b.installArtifact(relate_exe);

    // ── the `irregex` binary — the composed face (context/family/provenance) ──
    // ADR-367: exact match narrows a CandidateSet, compression reasons inside
    // it. Same engine module, same ReleaseFast product posture; a third thin
    // face over the shared kernel, not a third engine.
    const compose_mod = b.createModule(.{
        .root_source_file = b.path("src/surface/face/irregex/main.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    compose_mod.addImport("irregex", cli_engine);
    const compose_exe = b.addExecutable(.{ .name = "irregex", .root_module = compose_mod });
    b.installArtifact(compose_exe);

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

    // ── cross-target drift gate (`check-linux` / `check-windows`, both folded into `test`) ──
    // A dev box compiles one OS's legs and comptime-prunes every other's, so the
    // pruned ones rot silently — exactly how a `std.posix.close`/`std.c.fstatat`
    // removal in Zig 0.16 went unnoticed on the Linux side. Each foreign target
    // here compiles the full CLI module as an OBJECT: complete Sema + codegen over
    // every line that target can reach, but no cross-build of the C floor and no
    // link (the extern declarations suffice), so the gate stays cheap enough to
    // ride every `zig build test`.
    //
    // What each one is watching:
    //
    //   * linux — the statx raw-stat shim (`read/inode.zig`), the inotify watcher
    //     (`session/watch/watch.zig`), and every `std.os.linux` call they make.
    //   * windows — `portal.zig`'s whole Win32 arm (`NtCreateFile` descent,
    //     demand-paged section map, `NtQueryDirectoryFile` directory drain,
    //     `GetFileType` device classification, `GetFinalPathName` realpath) plus
    //     the resident tier's Win32 arm: the AFD readiness wait and its socket
    //     nudge pair (`conduit/vigil.zig`), the socket byte I/O behind the frame
    //     grammar, the share-mode singleton, the detached `CreateProcessW`
    //     spawn, and the `ReadDirectoryChangesW` freshness watcher over an I/O
    //     completion port (`session/watch/notify.zig`). None of it is reachable
    //     from a POSIX build, so nothing else can prove it compiles.
    //
    // Windows is three triples because word size and instruction set are separate
    // risks, and both have already bitten: 32-bit is where a `u64` state counter
    // dividing a `usize` stops narrowing back on its own, and aarch64 is the
    // runner GitHub actually rents for the native lane. Cross-compiling only the
    // triple you happen to deploy proves the least interesting one.
    const cross_checks = [_]struct {
        step: []const u8,
        blurb: []const u8,
        queries: []const std.Target.Query,
    }{
        .{
            .step = "check-linux",
            .blurb = "Cross-compile the CLI for x86_64-linux (Sema+codegen, no link) — keeps the comptime-pruned Linux legs building",
            .queries = &.{.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }},
        },
        .{
            .step = "check-windows",
            .blurb = "Cross-compile the CLI for all three Windows triples (Sema+codegen, no link) — keeps portal's Win32 arm and the warm tier's Win32 arm building",
            // `win10_rs4` on purpose, and it is load-bearing rather than
            // decorative: `std.Io.net.has_unix_sockets` is comptime-false below
            // that release, which would prune the ENTIRE resident tier out of
            // this gate — the daemon's AFD readiness wait, its socket byte I/O,
            // its singleton, its detached spawn — and leave the gate green over
            // code it never looked at. The floor `_buildkit` applies to a normal
            // build is restated here because these are explicit queries, and an
            // explicit query is exactly what that floor steps aside for.
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
            const engine = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = foreign,
                .optimize = .Debug,
                .link_libc = true,
            });
            const face = b.createModule(.{
                .root_source_file = b.path("src/surface/face/gist/main.zig"),
                .target = foreign,
                .optimize = .Debug,
            });
            face.addImport("irregex", engine);
            const obj = b.addObject(.{
                .name = b.fmt("gist-check-{t}-{t}", .{ query.cpu_arch.?, query.os_tag.? }),
                .root_module = face,
            });
            step.dependOn(&obj.step);
            k.test_step.dependOn(&obj.step);
        }
    }

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

    // Similarity thresholds are probabilities/distances, not arbitrary floats.
    // Reject NaN, infinities, and out-of-range values before any corpus work;
    // otherwise IEEE comparisons silently turn a malformed query into no rows.
    const bad_distance_test = b.addRunArtifact(relate_exe);
    bad_distance_test.addArgs(&.{ "echoes", "--as", "copies", "--max-distance", "nan" });
    bad_distance_test.expectExitCode(2);
    bad_distance_test.expectStdErrMatch("finite number in [0,1]");
    k.test_step.dependOn(&bad_distance_test.step);
    const bad_echo_test = b.addRunArtifact(relate_exe);
    bad_echo_test.addArgs(&.{ "echoes", "--min-echo", "1.1" });
    bad_echo_test.expectExitCode(2);
    bad_echo_test.expectStdErrMatch("finite number in [0,1]");
    k.test_step.dependOn(&bad_echo_test.step);

    // A folded verb name is a coached exit, not an unknown-command dead end:
    // four names became flags on `similar`/`echoes`, and muscle memory (plus
    // every doc written before the fold) still types them. The unit tests pin
    // the rendering; this pins that a real `relate dups` invocation reaches it.
    const folded_test = b.addRunArtifact(relate_exe);
    folded_test.addArgs(&.{"dups"});
    folded_test.expectExitCode(2);
    folded_test.expectStdErrMatch("relate echoes --as copies");
    k.test_step.dependOn(&folded_test.step);

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
    // (`irregex_open`/`irregex_search[_with_options]`/`irregex_close`) over a generated two-line fixture:
    // a full stream must fire on BOTH matching lines with the first hit on line 1
    // and a single whole-needle submatch (byte-accurate offsets reach C); a
    // callback that returns non-zero must STOP after the first line yet still
    // report IRREGEX_MATCH (the abort return, ABI v2); the additive options
    // entry must enforce smart-case/Unicode/invert/quiet/max-count and reject malformed
    // options; and a no-match query must return IRREGEX_OK without firing.
    // It closes on ADR-373 law 7's pull: an allocation the seam refuses reports
    // the `resource` fault BY NAME through `irregex_last_fault` instead of taking
    // the process with it, a declinature and an argument rejection report no fault
    // at all, and the next successful call must not hand back the stale one.
    // The needle lives ONLY in the fixture (a separate dir from this C source),
    // so it can never self-match.
    const ffi_fixture = b.addWriteFiles();
    _ = ffi_fixture.add("fixture.txt", "gist_ffi_smoke_needle on line one\ngist_ffi_smoke_needle on line two\nsmartcase_needle\nSMARTCASE_NEEDLE\n");
    const c_smoke_source = b.addWriteFiles().add("gist_c_abi_smoke.c",
        \\#include "irregex.h"
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include <string.h>
        \\
        \\static int g_hits;
        \\static uint64_t g_first_line;
        \\static size_t g_first_nsub, g_first_start, g_first_end;
        \\static uint32_t g_first_kind;
        \\
        \\/* Records the FIRST hit's shape, then continues the stream. */
        \\static int32_t on_match(void *ctx, const irregex_match *m) {
        \\    (void)ctx;
        \\    if (g_hits == 0) {
        \\        g_first_line = m->line_number;
        \\        g_first_nsub = m->nsubmatches;
        \\        g_first_kind = m->kind;
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
        \\    irregex_search_options opts = {sizeof opts, IRREGEX_FIXED, 0u, 0u, 0u};
        \\
        \\    /* full stream: both lines match; first hit is line 1, whole-needle span. */
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_MATCH) return 22;
        \\    if (g_hits != 2 || g_first_line != 1u || g_first_nsub != 1u) return 23;
        \\    if (g_first_start != 0u || g_first_end != nlen) return 24;
        \\
        \\    /* early stop: the callback aborts after the first line -> one hit, MATCH. */
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match_stop, NULL) != IRREGEX_MATCH) return 25;
        \\    if (g_hits != 1) return 26;
        \\
        \\    /* options path: cap per file, quiet suppresses callbacks, -m0 matches nothing. */
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_MAX_COUNT;
        \\    opts.max_count = 1u;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_MATCH) return 27;
        \\    if (g_hits != 1) return 28;
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_QUIET;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_MATCH) return 29;
        \\    if (g_hits != 0) return 30;
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_MAX_COUNT;
        \\    opts.max_count = 0u;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_OK) return 31;
        \\    const char smart_lower[] = "smartcase_needle";
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_SMART_CASE;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)smart_lower, sizeof smart_lower - 1u, &opts, on_match, NULL) != IRREGEX_MATCH) return 32;
        \\    if (g_hits != 2) return 33;
        \\    const char smart_upper[] = "SMARTCASE_NEEDLE";
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)smart_upper, sizeof smart_upper - 1u, &opts, on_match, NULL) != IRREGEX_MATCH) return 34;
        \\    if (g_hits != 1) return 35;
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_NO_UNICODE;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_MATCH) return 36;
        \\    if (g_hits != 2) return 37;
        \\    opts.flags = IRREGEX_FIXED | IRREGEX_INVERT;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_MATCH) return 41;
        \\    if (g_hits != 2 || g_first_line != 3u || g_first_nsub != 0u) return 42;
        \\    opts.flags = IRREGEX_FIXED;
        \\    opts.before_context = 1u;
        \\    opts.after_context = 1u;
        \\    g_hits = 0;
        \\    if (irregex_search(s, (const uint8_t *)smart_lower, sizeof smart_lower - 1u, &opts, on_match, NULL) != IRREGEX_MATCH) return 43;
        \\    if (g_hits != 3 || g_first_line != 2u || g_first_kind != IRREGEX_KIND_CONTEXT) return 44;
        \\    opts.struct_size = 0u;
        \\    if (irregex_search(s, (const uint8_t *)needle, nlen, &opts, on_match, NULL) != IRREGEX_INVALID) return 38;
        \\
        \\    /* no match still returns OK and never fires. */
        \\    g_hits = 0;
        \\    opts = (irregex_search_options){sizeof opts, IRREGEX_FIXED, 0u, 0u, 0u};
        \\    if (irregex_search(s, (const uint8_t *)"zzz_absent_needle_zzz", 21u, &opts, on_match, NULL) != IRREGEX_OK) return 39;
        \\    if (g_hits != 0) return 40;
        \\    irregex_close(s);
        \\
        \\    /* ── the PULL-cursor surface (additive; same warm engine) ── */
        \\    irregex_engine *e = NULL;
        \\    if (irregex_engine_open(roots, 1u, &e) != IRREGEX_OK || e == NULL) return 45;
        \\    irregex_search_request req = {0};
        \\    req.struct_size = sizeof req;
        \\    req.flags = IRREGEX_FIXED;
        \\    req.pattern = (const uint8_t *)needle;
        \\    req.pattern_len = nlen;
        \\
        \\    /* pull every record: two lines match; first is line 1, whole-needle span. */
        \\    irregex_cursor *cur = NULL;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_OK || cur == NULL) return 46;
        \\    if (irregex_cursor_matched(cur) != 1) return 47;
        \\    irregex_match rec;
        \\    int32_t st = irregex_cursor_next(cur, &rec);
        \\    if (st != IRREGEX_MATCH || rec.line_number != 1u || rec.nsubmatches != 1u) return 48;
        \\    if (rec.submatches[0].start != 0u || rec.submatches[0].end != nlen) return 49;
        \\    int pulled = 1;
        \\    while ((st = irregex_cursor_next(cur, &rec)) == IRREGEX_MATCH) pulled++;
        \\    if (st != IRREGEX_OK || pulled != 2) return 50;
        \\    irregex_cursor_close(cur);
        \\
        \\    /* next_batch: one call drains both records into a slice. */
        \\    cur = NULL;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_OK) return 51;
        \\    irregex_match batch[4];
        \\    size_t written = 0;
        \\    if (irregex_cursor_next_batch(cur, batch, 4u, &written) != IRREGEX_MATCH || written != 2u) return 52;
        \\    if (batch[0].line_number != 1u || batch[1].line_number != 2u) return 53;
        \\    if (irregex_cursor_next_batch(cur, batch, 4u, &written) != IRREGEX_OK || written != 0u) return 54;
        \\    irregex_cursor_close(cur);
        \\
        \\    /* max_results budget stops at a record boundary but still reports matched. */
        \\    req.max_results = 1u;
        \\    cur = NULL;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_OK) return 55;
        \\    if (irregex_cursor_matched(cur) != 1) return 56;
        \\    pulled = 0;
        \\    while (irregex_cursor_next(cur, &rec) == IRREGEX_MATCH) pulled++;
        \\    if (pulled != 1) return 57;
        \\    irregex_cursor_close(cur);
        \\    req.max_results = 0u;
        \\
        \\    /* a pre-tripped cancel token yields a clean empty result, never a crash. */
        \\    irregex_cancel *tok = NULL;
        \\    if (irregex_cancel_new(&tok) != IRREGEX_OK || tok == NULL) return 58;
        \\    irregex_cancel_request(tok);
        \\    req.cancel = tok;
        \\    cur = NULL;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_OK) return 59;
        \\    if (irregex_cursor_next(cur, &rec) != IRREGEX_OK) return 60;
        \\    irregex_cursor_close(cur);
        \\    irregex_cancel_free(tok);
        \\    req.cancel = NULL;
        \\
        \\    /* an unsupported pattern declines with STALE (answer cold), never a cursor. */
        \\    const char look[] = "needle(?=X)";
        \\    req.flags = 0u;
        \\    req.pattern = (const uint8_t *)look;
        \\    req.pattern_len = sizeof look - 1u;
        \\    cur = NULL;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_STALE) return 61;
        \\
        \\    /* fail-closed: a bad struct_size is rejected; status_message is never NULL. */
        \\    req.struct_size = 0u;
        \\    if (irregex_search_cursor(e, &req, &cur) != IRREGEX_INVALID) return 62;
        \\    if (irregex_status_message(IRREGEX_STALE) == NULL) return 63;
        \\
        \\    /* ── the last-fault pull (ADR-373 law 7) ── */
        \\    irregex_fault f;
        \\    f.struct_size = 0u; /* size-checked like every other entry */
        \\    if (irregex_last_fault(&f) != IRREGEX_INVALID) return 64;
        \\    if (irregex_last_fault(NULL) != IRREGEX_INVALID) return 65;
        \\    f.struct_size = sizeof f;
        \\    /* The declinature and the INVALID above were not faults: nothing to say. */
        \\    if (irregex_last_fault(&f) != IRREGEX_OK) return 66;
        \\
        \\    /* Force a REAL taxonomy fault through the FFI: a root count whose byte
        \\     * size overflows is refused by the allocator, so the seam reports the
        \\     * `resource` domain rather than the host losing the process. */
        \\    irregex_session *doomed = NULL;
        \\    if (irregex_open(roots, (size_t)-1 / 4u, &doomed) != IRREGEX_OOM) return 67;
        \\    if (doomed != NULL) return 68;
        \\    if (irregex_last_fault(&f) != IRREGEX_MATCH) return 69;
        \\    if (f.status != IRREGEX_OOM) return 70;
        \\    if (f.name == NULL || strcmp(f.name, "OutOfMemory") != 0) return 71;
        \\    if (f.path != NULL || f.path_len != 0u || f.has_at != 0) return 72;
        \\    if (irregex_last_fault(&f) != IRREGEX_MATCH) return 73; /* not consumed */
        \\
        \\    /* The assertion this design exists for: a SUCCESSFUL call must not hand
        \\     * back the stale fault. */
        \\    irregex_cancel *fresh = NULL;
        \\    if (irregex_cancel_new(&fresh) != IRREGEX_OK) return 74;
        \\    if (irregex_last_fault(&f) != IRREGEX_OK) return 75;
        \\    irregex_cancel_free(fresh);
        \\
        \\    irregex_engine_close(e);
        \\    return 0;
        \\}
        \\
    );
    const c_smoke_mod = b.createModule(.{
        .target = k.target,
        .optimize = k.optimize,
    });
    // No framework wiring: the engine object reaches CoreServices/CoreFoundation
    // via runtime `dlopen` (journal.zig), so it exports no FSEvents/CF externs.
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.addCSourceFile(.{
        .file = c_smoke_source,
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_smoke_mod.addObject(b.addObject(.{
        .name = "gist-c-abi-smoke-kernel",
        .root_module = k.root_module,
    }));
    // The kernel object carries the engine's extern references into the C floor
    // (PCRE2, libsais); the smoke exe stands on a matching floor so those
    // symbols resolve. The C ABI itself touches neither, but the whole engine
    // module is compiled into the object.
    floor.under(c_smoke_mod);
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
        .root_source_file = b.path("bench/apparatus/harness/bench.zig"),
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

    // `zig build certify` — Layer A of the dominance-and-fit certificate: per-class
    // single-thread cycles/byte + bootstrap-CI (PMU via kperf; run under `sudo`
    // for cycles, else wall-clock). Emits .local/gist-verify/CERTIFICATE.md.
    const run_certify = b.addRunArtifact(bench_exe);
    run_certify.setCwd(b.path("../../.."));
    run_certify.addArg("certify");
    if (b.args) |args| run_certify.addArgs(args);
    const certify_step = b.step("certify", "Layer-A optimality cert: per-class cycles/byte + bootstrap CI");
    certify_step.dependOn(&run_certify.step);
    certify_step.dependOn(bench_install);

    // `zig build flagbench` — per-function micro-profiles for the three flags
    // agents reach for most (-i / -n / -v): the ONE hot function each adds,
    // timed in isolation and self-checked byte-identical (bench/apparatus/harness/flagbench.zig).
    const run_flagbench = b.addRunArtifact(bench_exe);
    run_flagbench.setCwd(b.path("../../.."));
    run_flagbench.addArg("flagbench");
    if (b.args) |args| run_flagbench.addArgs(args);
    const flagbench_step = b.step("flagbench", "Per-function micro-profiles for -i / -n / -v (byte-identity self-checked)");
    flagbench_step.dependOn(&run_flagbench.step);
    flagbench_step.dependOn(bench_install);

    // `zig build sessionprof` — per-function micro-profiles for the WARM SESSION
    // seams (fold / invert / lines / shm / record stream / render lanes), timed
    // in-process so a refactor's effect isn't drowned by the socket + reconcile
    // walk that `bench -- session` measures. `--baseline <report.json>` turns the
    // run into a before/after comparison with a Mann-Whitney verdict per seam.
    const run_sessionprof = b.addRunArtifact(bench_exe);
    run_sessionprof.setCwd(b.path("../../.."));
    run_sessionprof.addArg("sessionprof");
    if (b.args) |args| run_sessionprof.addArgs(args);
    const sessionprof_step = b.step("sessionprof", "Per-function micro-profiles for the warm session seams (answer-digest self-checked)");
    sessionprof_step.dependOn(&run_sessionprof.step);
    sessionprof_step.dependOn(bench_install);

    // Bench-side tests too — the harness-local `stats.zig` bootstrap-CI +
    // Mann-Whitney unit tests. (`bench/apparatus/harness/bench.zig` imports `gist`; reuse the
    // bench module; the engine tests ride `k.test_step` via `src/root.zig`.)
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_mod })).step);

    // ── `relate-knn` — the compression-as-embedding proof harness ──
    // Runs the REAL relate engine (zipper cross-parse / LZJD sketch) as a
    // k-NN text classifier over a labeled manifest, emitting accuracy + build/
    // query cost as JSON. The sibling driver (bench/conformance/relate/) races it against
    // gzip-kNN (ACL 2023) and a static-embedding model. Run from the repo root.
    const relate_knn_mod = b.createModule(.{
        .root_source_file = b.path("bench/conformance/relate/knn.zig"),
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
    const relate_knn_step = b.step("relate-knn", "Run the relate engine as a k-NN classifier over a labeled manifest");
    relate_knn_step.dependOn(&run_relate_knn.step);
    relate_knn_step.dependOn(relate_knn_install);

    // ── `codex-scale` — the compressed self-index proof harness ──
    // Runs the REAL codex (src/corpus/index/codex/) over slices of an on-disk corpus:
    // index bits/char vs measured H0/H2, count/find latency across sizes
    // (flat in n), byte-exact restore from the index alone, every timed count
    // verified against a naive scan. bench/bounds/codex/race.sh adds compressor
    // baselines on identical slices. Run from the repo root.
    const codex_scale_mod = b.createModule(.{
        .root_source_file = b.path("bench/bounds/codex/scale.zig"),
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
    // `bench/apparatus/harness/`'s module root (Zig forbids importing a source file
    // outside a module's own root directory) so they're wired as independent,
    // named modules instead — mirroring how `bench_mod` already wires `gist`.
    const probes_mod = b.createModule(.{
        .root_source_file = b.path("bench/apparatus/harness/probes.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    const pmu_mod = b.createModule(.{
        .root_source_file = b.path("bench/apparatus/harness/pmu.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });

    // ── `gist-roofline` — Layer C: single-thread STREAM read-bandwidth ceiling ──
    const roofline_mod = b.createModule(.{
        .root_source_file = b.path("bench/bounds/roofline/bandwidth.zig"),
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
        .root_source_file = b.path("bench/bounds/lowerbound/audit.zig"),
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

    // ── `gist-scale` — Layer J: the sub-trigram tier's candidate-byte payoff ──
    const scale_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/sliver/scale.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    scale_mod.addImport("irregex", k.root_module);
    scale_mod.addImport("probes", probes_mod);
    const scale_exe = b.addExecutable(.{ .name = "gist-scale", .root_module = scale_mod });
    const scale_install = &b.addInstallArtifact(scale_exe, .{}).step;
    lab_step.dependOn(scale_install);
    const run_scale = b.addRunArtifact(scale_exe);
    run_scale.setCwd(b.path("../../.."));
    if (b.args) |args| run_scale.addArgs(args);
    const scale_step = b.step("scale", "Layer-J: fail-closed sub-trigram candidate-byte audit (directory vs sliver tier)");
    scale_step.dependOn(&run_scale.step);
    scale_step.dependOn(scale_install);

    // ── `gist-indexq` — Layer L: index quality head-to-head against csearch ──
    // One corpus, one built index, one evaluator, one verifier — only the
    // trigram FORMULA differs between arms (gist-base / gist / csearch, the
    // last lifted verbatim by `bench/rungs/sieve/csearch_plan.py`).
    const indexq_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/sieve/indexq.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    indexq_mod.addImport("irregex", k.root_module);
    indexq_mod.addImport("probes", probes_mod);
    const indexq_exe = b.addExecutable(.{ .name = "gist-indexq", .root_module = indexq_mod });
    const indexq_install = &b.addInstallArtifact(indexq_exe, .{}).step;
    lab_step.dependOn(indexq_install);
    const run_indexq = b.addRunArtifact(indexq_exe);
    run_indexq.setCwd(b.path("../../.."));
    if (b.args) |args| run_indexq.addArgs(args);
    const indexq_step = b.step("indexq", "Layer-L optimality cert: candidate-byte selectivity head-to-head vs csearch's own formula");
    indexq_step.dependOn(&run_indexq.step);
    indexq_step.dependOn(indexq_install);

    // ── `crest` — production proof: the forced-class-run necessary condition ──
    // Links the REAL engine (the crest kernel now lives INSIDE it, at
    // src/kernel/primitives/crest.zig, wired into the index sidecar + both read-elision
    // oracles) and walks the REAL corpus to prove the sieve is sound
    // (matched ⇒ ¬pruned, fail-closed) and prunes the literal-free
    // class-repetition zone where the trigram index prunes 0%. Writing +
    // proofs: research/crest/. Kernel unit tests ride `zig build test` via
    // root.zig's test block (kernel/primitives/crest.zig tests, corpus/index/crest/sidecar_test.zig).
    const crest_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/crest/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    crest_bench_mod.addImport("irregex", cli_engine);
    const crest_exe = b.addExecutable(.{ .name = "crest", .root_module = crest_bench_mod });
    const crest_install = &b.addInstallArtifact(crest_exe, .{}).step;
    lab_step.dependOn(crest_install);
    const run_crest = b.addRunArtifact(crest_exe);
    run_crest.setCwd(b.path("../../.."));
    if (b.args) |args| run_crest.addArgs(args);
    const crest_step = b.step("crest", "Crest production proof: sound forced-class-run sieve — pruning + speed vs the real matcher");
    crest_step.dependOn(&run_crest.step);
    crest_step.dependOn(crest_install);

    // ── `warden` — what the resident memory ceiling costs on the alloc path ───
    // A safety feature that shows up in a throughput benchmark is not worth
    // having, so this decomposes the wrapper's cost (bare / passthru / warden)
    // against the allocator the daemon really gets, and FAILS on regression
    // rather than merely reporting. Correctness of the bound itself rides
    // `zig build test` via root.zig (exec/session/warden/*.zig tests).
    const warden_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/warden/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    // Imports the metered allocator ALONE rather than the whole engine: it
    // depends on nothing but `std`, so the thing being timed is the thing being
    // measured, with no unrelated compile in the way.
    warden_bench_mod.addImport("warden", b.createModule(.{
        .root_source_file = b.path("src/exec/session/warden/warden.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    }));
    const warden_exe = b.addExecutable(.{ .name = "warden", .root_module = warden_bench_mod });
    const warden_install = &b.addInstallArtifact(warden_exe, .{}).step;
    lab_step.dependOn(warden_install);
    const run_warden = b.addRunArtifact(warden_exe);
    run_warden.setCwd(b.path("../../.."));
    if (b.args) |args| run_warden.addArgs(args);
    const warden_step = b.step("warden", "Resident memory ceiling: what the bound costs per allocation, decomposed vs a no-op wrapper");
    warden_step.dependOn(&run_warden.step);
    warden_step.dependOn(warden_install);

    // ── `sieve` — production proof: the SP-quotient necessary condition ──────
    // Links the REAL engine (the sieve lives inside it at
    // src/kernel/match/regex/linear/sieve/, entered through regex.zig's seal)
    // and walks the REAL corpus to prove the over-approximation is sound at
    // every byte position (matched ⇒ survived, fail-closed), to publish the
    // measured selectivity beside the compile-time estimate that gates it, and
    // to time the register-resident kernel against the shipped DFA in the same
    // run. Unit + differential tests ride `zig build test` via root.zig.
    const sieve_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/sieve/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    sieve_bench_mod.addImport("irregex", cli_engine);
    const sieve_exe = b.addExecutable(.{ .name = "sieve", .root_module = sieve_bench_mod });
    const sieve_install = &b.addInstallArtifact(sieve_exe, .{}).step;
    lab_step.dependOn(sieve_install);
    const run_sieve = b.addRunArtifact(sieve_exe);
    run_sieve.setCwd(b.path("../../.."));
    if (b.args) |args| run_sieve.addArgs(args);
    const sieve_step = b.step("sieve", "Quotient-sieve production proof: per-position soundness, measured selectivity, kernel speed vs the shipped DFA");
    sieve_step.dependOn(&run_sieve.step);
    sieve_step.dependOn(sieve_install);

    // ── `census` — which machine actually answers each certificate class ─────
    // The certificate reports what a class costs; it cannot report which rung
    // produced that cost, and a rung declines by being ABSENT — so a silently
    // unarmed accelerator reads as a merely-modest win. This prints the ladder's
    // own compile-time `Admission` per probe, so that gap is observable.
    const census_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/census/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — matches what shipped
    });
    census_mod.addImport("irregex", cli_engine);
    census_mod.addImport("probes", probes_mod);
    const census_exe = b.addExecutable(.{ .name = "engine-census", .root_module = census_mod });
    const census_install = &b.addInstallArtifact(census_exe, .{}).step;
    lab_step.dependOn(census_install);
    const run_census = b.addRunArtifact(census_exe);
    run_census.setCwd(b.path("../../.."));
    if (b.args) |args| run_census.addArgs(args);
    const census_step = b.step("engine-census", "Engine census: which ladder machine each certificate probe class actually compiles to");
    census_step.dependOn(&run_census.step);
    census_step.dependOn(census_install);

    // ── `compose-rung` — production proof: composition vs the shipped DFA ────
    // Links the REAL engine (the rung lives inside it at
    // src/kernel/match/regex/linear/compose/, entered through regex.zig's seal)
    // so the baseline arm IS `Dfa.docMatch` rather than a reimplementation of
    // it. Both arms are timed over one contiguous buffer, interleaved round by
    // round in this process, and the armed-skip boundary row is published
    // rather than buried. Unit + differential tests ride `zig build test`.
    const rung_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/shuffle/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    rung_bench_mod.addImport("irregex", cli_engine);
    const rung_exe = b.addExecutable(.{ .name = "compose-rung", .root_module = rung_bench_mod });
    const rung_install = &b.addInstallArtifact(rung_exe, .{}).step;
    lab_step.dependOn(rung_install);
    const run_rung = b.addRunArtifact(rung_exe);
    run_rung.setCwd(b.path("../../.."));
    if (b.args) |args| run_rung.addArgs(args);
    const rung_step = b.step("compose-rung", "Composition-rung production proof: whole-buffer agreement with the shipped DFA, interleaved throughput, and the armed-skip boundary row");
    rung_step.dependOn(&run_rung.step);
    rung_step.dependOn(rung_install);

    // ── `ladder-price` — the auction's numbers, measured instead of quoted ───
    // Every other rung lane races one accelerator against the DFA. This one
    // audits the PRICES those races produced: it re-times each coefficient in
    // `ladder/price.zig` in isolation (mint/verify) and then ignores the model
    // entirely, running every machine a pattern admits to check that the
    // auction's pick really was the measured-fastest one (regret). Cheap by
    // construction — one 8 MiB synthetic haystack, no corpus, no giant table —
    // because a gate that costs a minute gets switched off.
    const price_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/price/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    price_mod.addImport("irregex", cli_engine);
    const price_exe = b.addExecutable(.{ .name = "ladder-price", .root_module = price_mod });
    const price_install = &b.addInstallArtifact(price_exe, .{}).step;
    lab_step.dependOn(price_install);
    const run_price = b.addRunArtifact(price_exe);
    run_price.setCwd(b.path("../../.."));
    if (b.args) |args| run_price.addArgs(args);
    const price_step = b.step("ladder-price", "Ladder price plane: re-time every auction coefficient in isolation (verify), and gate the auction's per-pattern picks against the measured-fastest machine (regret)");
    price_step.dependOn(&run_price.step);
    price_step.dependOn(price_install);

    // ── `parabix-rung` — production proof: bit-parallel scan vs the ladder ────
    // Links the REAL engine and arms the REAL rung through regex.zig's seal
    // (src/kernel/match/regex/linear/parabix/), so both baseline arms are
    // production code: the whole shipped verdict ladder AND the bare table-walk
    // DFA whose load-latency floor the rung was designed against. Throughput is
    // measured on a per-row adversarial near-miss buffer (a boolean scan returns
    // at the first hit, so a matching haystack times the match position, not the
    // engine); agreement is measured over the real corpus. Unit + Pike
    // differential tests ride `zig build test` via root.zig.
    const pbx_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/parabix/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    pbx_bench_mod.addImport("irregex", cli_engine);
    const pbx_exe = b.addExecutable(.{ .name = "parabix-rung", .root_module = pbx_bench_mod });
    const pbx_install = &b.addInstallArtifact(pbx_exe, .{}).step;
    lab_step.dependOn(pbx_install);
    const run_pbx = b.addRunArtifact(pbx_exe);
    run_pbx.setCwd(b.path("../../.."));
    if (b.args) |args| run_pbx.addArgs(args);
    const pbx_step = b.step("parabix-rung", "Parabix-rung production proof: corpus-scale agreement with the shipped ladder, negative-case throughput vs both baselines, and the refusal rows");
    pbx_step.dependOn(&run_pbx.step);
    pbx_step.dependOn(pbx_install);

    // ── `automata-rung` — the machine algebra, priced per function ───────────
    // The other rungs race a whole accelerator against the shipped DFA; this one
    // races INSIDE it, because every claim in research/automata/CLAIM.md is a
    // claim about one function and a binary race cannot attribute those. Both
    // arms walk the SAME automaton in this process, interleaved, and the
    // superseded match test is reconstructed from the shipped bound so the two
    // arms are provably the same machine. Fail-closed on verdict agreement.
    const automata_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/automata/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    automata_mod.addImport("irregex", cli_engine);
    const automata_exe = b.addExecutable(.{ .name = "automata-rung", .root_module = automata_mod });
    const automata_install = &b.addInstallArtifact(automata_exe, .{}).step;
    lab_step.dependOn(automata_install);
    const run_automata = b.addRunArtifact(automata_exe);
    run_automata.setCwd(b.path("../../.."));
    if (b.args) |args| run_automata.addArgs(args);
    const automata_step = b.step("automata-rung", "Automata-layout proof: per-pattern automaton shape, and the match test priced both ways over one machine");
    automata_step.dependOn(&run_automata.step);
    automata_step.dependOn(automata_install);

    // ── `patternid-rung` — does attribution-in-the-key cost states? ─────────
    // Gates the pattern-set attribution design: the same union NFA determinized
    // twice, differing only in whether the state key's trailing word holds the
    // pattern mask or just its non-emptiness. A measurement rig rather than the
    // engine (all 256 bytes, fixed assertion gap) — both arms identical, so the
    // ratio is the claim and the absolute counts are not.
    const patternid_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/patternid/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize,
    });
    patternid_mod.addImport("irregex", cli_engine);
    const patternid_exe = b.addExecutable(.{ .name = "patternid-rung", .root_module = patternid_mod });
    const patternid_install = &b.addInstallArtifact(patternid_exe, .{}).step;
    lab_step.dependOn(patternid_install);
    const run_patternid = b.addRunArtifact(patternid_exe);
    run_patternid.setCwd(b.path("../../.."));
    if (b.args) |args| run_patternid.addArgs(args);
    const patternid_step = b.step("patternid-rung", "PatternID gate: state-count cost of carrying a pattern mask in the determinizer's state key");
    patternid_step.dependOn(&run_patternid.step);
    patternid_step.dependOn(patternid_install);

    // ── `multipattern` — Layer K: the Hyperscan/Vectorscan race, gist's arm ──
    // Links the REAL kernel (PatternSet ships inside it at
    // src/kernel/batch/patterns.zig) and answers the same per-document
    // attribution question `bench/rungs/multipattern/vscan.c` puts to Vectorscan over
    // byte-identical inputs. `--verify` re-derives the whole attribution vector
    // with N INDEPENDENT single-pattern searches and exits non-zero on the
    // first disagreement, so no timing is ever published without the contract.
    const multipattern_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/multipattern/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    multipattern_mod.addImport("irregex", cli_engine);
    const multipattern_exe = b.addExecutable(.{ .name = "multipattern", .root_module = multipattern_mod });
    const multipattern_install = &b.addInstallArtifact(multipattern_exe, .{}).step;
    lab_step.dependOn(multipattern_install);
    const run_multipattern = b.addRunArtifact(multipattern_exe);
    run_multipattern.setCwd(b.path("../../.."));
    if (b.args) |args| run_multipattern.addArgs(args);
    const multipattern_step = b.step("multipattern", "Multi-pattern race arm: per-document attribution throughput, fail-closed against N independent searches");
    multipattern_step.dependOn(&run_multipattern.step);
    multipattern_step.dependOn(multipattern_install);

    // ── `sweep-rung` — per-consumer proof for the interned-AST fabric ────────
    // Races the REAL recursive walkers (analysis.zig, parabix/admit.zig) against
    // the REAL fused sweep (regex/ast/), both reached through regex.zig's seal,
    // one row per consumer. Two columns, because the claim decomposes: a
    // consumer asking one question pays the whole build, while the compile path
    // asking all of them pays it once. Answers are compared before any time is
    // published, and a question whose arms disagree exits non-zero — so a
    // faster wrong answer can never read as a win.
    const sweep_mod = b.createModule(.{
        .root_source_file = b.path("bench/rungs/sweep/bench.zig"),
        .target = k.target,
        .optimize = cli_optimize, // product-speed posture — this is a timing tool
    });
    sweep_mod.addImport("irregex", cli_engine);
    const sweep_exe = b.addExecutable(.{ .name = "sweep-rung", .root_module = sweep_mod });
    const sweep_install = &b.addInstallArtifact(sweep_exe, .{}).step;
    lab_step.dependOn(sweep_install);
    const run_sweep = b.addRunArtifact(sweep_exe);
    run_sweep.setCwd(b.path("../../.."));
    if (b.args) |args| run_sweep.addArgs(args);
    const sweep_step = b.step("sweep-rung", "Sweep-rung consumer proof: each recursive analysis raced against the fused interned-AST sweep, alone and bundled, fail-closed on any disagreement");
    sweep_step.dependOn(&run_sweep.step);
    sweep_step.dependOn(sweep_install);

    // ── `gist-portbound` — Layer B′: the port bound MEASURED on this machine ──
    // Runs the same drift-guarded probes as portcert.sh's static llvm-mca bound,
    // natively under the PMU (cycles/byte + cycles/step). Fail-closed without
    // root: reports wall-clock and labels cycles NOT-measured; the sudo rung is
    // `sudo zig-out/bin/gist-portbound` after `zig build -Doptimize=ReleaseFast`.
    const portbound_mod = b.createModule(.{
        .root_source_file = b.path("bench/bounds/port/measure.zig"),
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
        .root_source_file = b.path("bench/bounds/port/probes_test.zig"),
        .target = k.target,
        .optimize = k.optimize,
    });
    portcert_test_mod.addImport("irregex", k.root_module);
    k.test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = portcert_test_mod })).step);
}
