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
//! The test chassis comes from the `brigade` package, as it does in every
//! sibling: one ReleaseSafe brigade-sharded unit-test binary (`test` /
//! `test-quick`), a compile-only `check` step for the --watch/ZLS loop, a kcov
//! `coverage` step, and the Linux/Windows cross-compile drift gates folded into
//! `test`.

const std = @import("std");
const builtin = @import("builtin");
const brigade = @import("brigade");

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
// interpreter. What is deliberately NOT here is a sanitizer opt-out: the
// vendored C is built with `.sanitize_c = .off` on its module (see `Floor`),
// which is the same decision stated where Zig owns it instead of smuggled in
// as a clang flag that countermands one Zig just added.
const pcre2_cflags = [_][]const u8{
    "-DHAVE_CONFIG_H",
    "-DPCRE2_CODE_UNIT_WIDTH=8",
    "-DPCRE2_STATIC",
    "-DSUPPORT_UNICODE",
    "-DSUPPORT_PCRE2_8",
    "-DSUPPORT_JIT",
    "-std=c11",
};

// libsais — the suffix-array constructor under the FM-index. No feature
// flags: LIBSAIS_OPENMP stays OFF, so the parallel entry points are
// preprocessed away and the archive needs no `libomp`. Provenance:
// vendor/libsais/README.md + the build.zig.zon `.lazy` row.
const libsais_cflags = [_][]const u8{"-std=c99"};

/// One static archive per C floor per optimize mode, memoized — an adversarial
/// ReleaseSafe test must not run a Debug C library, and a ReleaseFast product
/// twin must not link a ReleaseSafe one. `.pic = true` so one archive serves
/// both a future shared object and every executable (macOS is PIC by default;
/// ELF non-PIC would reject the archive in a PIE link).
///
/// Both archives are built `.sanitize_c = .off`, which is load-bearing in
/// exactly one mode: ReleaseSafe, where Zig otherwise instruments C with
/// trapping UBSan. Both libraries would trip it on purpose — PCRE2 on its
/// pointer/shift idioms, libsais on the negative sentinel indices and
/// one-past-the-end cursors the induced sort is built out of — and both are
/// well-defined in practice. A `-P` query must degrade to a clean error and a
/// codex build must fail as a Zig error; neither may abort inside C.
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
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true, .sanitize_c = .off });
        mod.addIncludePath(self.b.path("vendor/pcre2/src"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/pcre2/src"), .files = &pcre2_sources, .flags = &pcre2_cflags });
        const lib = self.b.addLibrary(.{ .name = "pcre2irregex", .linkage = .static, .root_module = mod });
        self.pcre2.set(optimize, lib);
        return lib;
    }

    fn libsaisAt(self: *Floor, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        if (self.libsais.get(optimize)) |ready| return ready;
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true, .sanitize_c = .off });
        mod.addIncludePath(self.b.path("vendor/libsais/include"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/libsais/src"), .files = &.{"libsais.c"}, .flags = &libsais_cflags });
        const lib = self.b.addLibrary(.{ .name = "libsais", .linkage = .static, .root_module = mod });
        self.libsais.set(optimize, lib);
        return lib;
    }
};

/// The codegen posture the command line asked for. Zig ships no rc file and no
/// `-mllvm` passthrough — `build.zig` *is* the configuration file — so `-D…` is
/// the entire surface between an operator and LLVM. Holding it as one value is
/// what keeps a module or artifact added later from silently missing a knob,
/// and the two setters are split because Zig splits them: the frame pointer is
/// a property of a module's codegen, everything else of the whole compilation
/// that links it.
const Codegen = struct {
    /// ReleaseFast omits the frame pointer, and the frame pointer is what a
    /// sampling profiler walks — so a profile of the shipped posture is a pile
    /// of unattributed leaves without this. A no-op on aarch64-darwin, whose
    /// platform ABI pins the register whatever LLVM would have preferred.
    frame_pointer: ?bool,
    /// Cross-language inlining over the Zig↔C seam (PCRE2's match entry,
    /// libsais's induced sort) plus whole-program IPO. Off by default because
    /// it moves real optimization work into the link, which every edit then
    /// pays for, and it only ever pays back in an artifact somebody ships.
    lto: std.zig.LtoMode,
    /// The rung between the two `-Dstrip` poles. DWARF is **79%** of the
    /// emitted Linux shared object — 9.24 MB of 11.73 MB, against 1.51 MB of
    /// `.text` — so "debuggable" and "small" read as opposites until the debug
    /// info is compressed rather than deleted. A `SHF_COMPRESSED` header in
    /// front of each `.debug_*` section is inflated by the consumer on demand,
    /// so the DWARF a debugger ends up reading is the same DWARF — where
    /// `-Dstrip` answers the size question by destroying it. Measured on this
    /// library: 11.72 MB → 4.83 MB (zlib) or 4.57 MB (zstd).
    ///
    /// **zlib is the default on ELF** and zstd is the ask, which inverts how
    /// the two codecs rank on the merits — zstd is better on all three axes at
    /// once (ratio, compression speed, decompression speed), which is the
    /// finding `ELFCOMPRESS_ZSTD` was standardized on (MaskRay, `zstd
    /// compressed debug sections`, 2022). It loses here on the only axis a
    /// default is decided by: who can read it. `ELFCOMPRESS_ZLIB` is the one
    /// value the generic ABI has always had and every binutils, gdb, and
    /// elfutils in service handles it, while zstd needs gdb 13.2 / binutils
    /// 2.40 / elfutils 0.189 / LLVM 16 and an older reader does not degrade —
    /// it refuses the section outright. So the default takes 59% of the win
    /// nobody can be broken by, and `-Ddebug-compress=zstd` takes the rest.
    ///
    /// ELF only, link-time only, and release-only. An archive is never
    /// linked, so `libirgx.a` is exactly the same bytes at every setting; and
    /// `-ODebug` emits DWARF this vintage of LLD cannot compress without
    /// segfaulting, which is why the default stands itself down there.
    debug_compress: std.zig.CompressDebugSections,
    /// A stripped artifact has no DWARF and therefore no identity: two builds
    /// of different commits are the same anonymous bytes, and a crash in a
    /// `pip install`ed wheel cannot be tied back to what produced it. A build
    /// ID is the standard answer — the note packagers, `debuginfod`, and
    /// symbolizers all match a separate debug file on — so `build` turns it on
    /// with `-Dstrip` rather than leaving the packaged artifact unattributable.
    build_id: ?std.zig.BuildId,

    fn module(cg: Codegen, m: *std.Build.Module) *std.Build.Module {
        if (cg.frame_pointer) |keep| m.omit_frame_pointer = !keep;
        return m;
    }

    fn artifact(cg: Codegen, c: *std.Build.Step.Compile) *std.Build.Step.Compile {
        c.lto = cg.lto;
        c.compress_debug_sections = cg.debug_compress;
        c.build_id = cg.build_id;
        // Both of these are link-time LLVM passes, and only LLD hosts them —
        // Zig's own ELF linker silently emits uncompressed sections instead of
        // refusing, which is the worse failure: an operator who asked for a
        // 4 MB library gets an 11 MB one and no diagnostic. Asking for either
        // is therefore also asking for LLD, so say it here instead of making
        // every caller pair the flags and discover that by error — or, for
        // compression, not discover it at all.
        if (cg.lto != .none or cg.debug_compress != .none) c.use_lld = true;
        return c;
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
    // Linux library measures 11.72 MB uncompressed against 1.88 MB stripped.
    // Mach-O hides the asymmetry by keeping DWARF in a separate `.dSYM`, which
    // is why only the ELF and PE artifacts look bloated. Off by default so a
    // local build stays debuggable; the wheel matrix is the one caller that
    // asks for it. It is also the *destructive* answer to the size question and
    // no longer the first one reached for — `-Ddebug-compress` below is already
    // on for a released ELF target, landing the same debuggable library at
    // 4.83 MB.
    const strip = b.option(bool, "strip", "Omit debug info from emitted artifacts (packaging)");

    // ── the mode the SHIPPED library is built in ──
    // A Debug `libirgx` is not a slower build of the library — for its callers
    // it is a different library. Compiling `\w` costs 2.3 ms optimized and
    // 108 ms unoptimized, and neither the Python nor the Go binding has any way
    // to know which one it dlopened; what a caller sees is an engine that
    // takes a tenth of a second to compile one class. `zig build` is also the
    // exact instruction all three binding READMEs give, so Debug was the
    // default reaching every consumer who did as they were told.
    //
    // So the artifact's mode belongs to its job rather than to the last `-D`
    // flag anyone typed — the same call the test binary already makes below
    // (pinned ReleaseSafe, for the checks). `-Doptimize` keeps governing the
    // module a dependent imports, `check` and `test` keep their own fast modes,
    // and `-Dlib-optimize=Debug` steps through the C ABI when that is the job.
    const lib_optimize = b.option(
        std.builtin.OptimizeMode,
        "lib-optimize",
        "optimize mode for the installed libirgx (default ReleaseFast — it is what a binding loads)",
    ) orelse .ReleaseFast;

    // ── the LLVM knobs, and where the granularity actually stops ──
    // Four tiers are reachable from a build script, coarsest first: the
    // **subtarget** (`-Dcpu=baseline+avx2`, which becomes LLVM's feature string
    // verbatim — `--verbose-llvm-cpu-features` prints back what it parsed), the
    // **per-module** codegen flags, the **link-time** passes LLD hosts (LTO,
    // section collection, debug-section compression), and the **pass
    // pipeline**, which has no `std.Build` surface at all because
    // `Step.Compile` carries nowhere to put a driver flag. `zig build ir`, at
    // the bottom of this file, is the way down to that last tier and names the
    // invocations. There is no fifth tier: Zig rejects `-mllvm`, deliberately,
    // and rejects it inside `-cflags` too.
    // Asked-for versus in-force, and the distinction is load-bearing: the ELF
    // default below has to stand itself down on a target or a posture where it
    // cannot work, while an *explicit* `-Ddebug-compress` on that same target
    // has to be refused. Collapsing the two would either fail every
    // `-Dstrip=true` build on its own default, or silently swallow a flag the
    // operator typed.
    const debug_compress_asked = b.option(std.zig.CompressDebugSections, "debug-compress", "Compress DWARF in place, ELF only (default zlib, which every reader handles; zstd is smaller and needs a 2023-era toolchain)");
    const codegen: Codegen = .{
        .frame_pointer = b.option(bool, "frame-pointer", "Keep the frame-pointer chain in optimized builds so a sampling profiler can walk it"),
        .lto = b.option(std.zig.LtoMode, "lto", "Link-time optimization for the shipped artifacts and the lab executables (default none)") orelse .none,
        .debug_compress = debug_compress_asked orelse
            if (target.result.ofmt == .elf and strip != true and lib_optimize != .Debug) .zlib else .none,
        // A build ID is only *needed* by the artifact that has lost its DWARF,
        // so it rides `-Dstrip` rather than being one more thing the packaging
        // matrix has to remember. `sha1` over Zig's cheaper `fast` because the
        // point is to be recognized by tools we do not own — `debuginfod`, the
        // distro debug-package splitters, the symbolizers — and a 20-byte note
        // is the shape all of them were built around. Overridable both ways:
        // `-Dbuild-id=fast` for the cheap 8-byte hash, `=none` to opt out.
        .build_id = b.option(std.zig.BuildId, "build-id", "Embed a linker build ID identifying this artifact (default: on with -Dstrip, the build that has no other identity)") orelse
            if (strip == true and target.result.ofmt == .elf) .sha1 else null,
    };
    // Three refusals, one shape: a flag that would be *silently* pointless is
    // worse than one that is missing, because the operator reads the posture
    // they asked for as the posture they got.
    //
    // On Darwin LTO is not slow or degraded — it is not a thing. It needs a
    // link-time pass pipeline, only LLD hosts one, and Zig has no LLD path for
    // Mach-O. Refusing here beats the driver's "using LLD to link macho files is
    // unsupported" three steps into a build the operator thought was running.
    // Cross-compiling from this machine is unaffected: `-Dtarget=x86_64-linux-gnu
    // -Dlto=thin` links through LLD and works.
    if (codegen.lto != .none and target.result.ofmt == .macho)
        std.process.fatal("-Dlto is unavailable for a {t} target: Zig links Mach-O with its own linker, and LTO requires LLD.", .{target.result.os.tag});
    // Compression is worse than unavailable off ELF — it is accepted. `SHF_COMPRESSED`
    // is an ELF section flag with no Mach-O or COFF equivalent (Mach-O keeps its
    // DWARF outside the image entirely, in a `.dSYM`), and the driver takes the
    // flag and emits exactly what it would have anyway.
    if (debug_compress_asked) |asked| {
        if (asked != .none and target.result.ofmt != .elf)
            std.process.fatal("-Ddebug-compress needs an ELF target ({t} emits {t}): SHF_COMPRESSED has no equivalent in that format, and the driver accepts the flag without doing anything.", .{ target.result.os.tag, target.result.ofmt });
        // And the two size levers are a choice, not a stack: strip emits no
        // debug sections, so there is nothing left for compression to act on.
        if (asked != .none and strip == true)
            std.process.fatal("-Ddebug-compress and -Dstrip=true contradict — strip leaves no debug sections to compress. Pick one: compressed keeps every DWARF byte at 41% of the size, stripped keeps none at 16%.", .{});
        // The one refusal that is not about semantics. LLD's compressor is
        // reached through a `parallelForEach` over the output sections, and on
        // the 29 MB of DWARF `-ODebug` emits for this library it faults in a
        // worker thread — `SIGSEGV`, no diagnostic, nothing written. Every
        // release mode compresses the same library cleanly (ReleaseSafe 4.90,
        // ReleaseFast 4.83, ReleaseSmall 1.37 MB with zlib), so this is a
        // ceiling on that one mode and not on the option. It is stated as a
        // refusal rather than absorbed as a silent downgrade because the crash
        // is the alternative, and a build that dies inside the linker reads
        // like a broken toolchain rather than a flag that was never going to
        // work. Retest it when the vendored LLD moves.
        if (asked != .none and lib_optimize == .Debug)
            std.process.fatal("-Ddebug-compress={t} crashes LLD at -Dlib-optimize=Debug: the compressor faults on the DWARF this library emits unoptimized. Use a release mode (all three compress fine), or drop the flag — the ELF default already stands itself down here.", .{asked});
    }

    var floor = Floor{ .b = b, .target = target };

    // ── the one place this package's semver lives ──
    // `build.zig.zon`'s `.version` is the single authority. `src/root.zig`
    // reads it through this option instead of restating it, so the two cannot
    // drift — the failure that put `engine_version` a minor behind for a whole
    // release. Every remaining copy is a packaging manifest that cannot import
    // anything (the contract, Cargo, PyPI, the Go mirror); those carry an
    // `x-release-please-version` marker and are moved from here by the release
    // bot, and `tools/version_parity.py` fails if one of them lags.
    //
    // The package name rides along so this generated file differs from the one
    // every sibling generates. Zig content-addresses it, and two packages whose
    // only option was an identical version string produced the SAME file — which
    // it then refuses as the root of two modules the moment `gist` links
    // `irregex`. Naming the package keeps them distinct and reads better anyway.
    const zon = @import("build.zig.zon");
    const version = b.addOptions();
    version.addOption([:0]const u8, "version", zon.version);
    version.addOption([:0]const u8, "package", @tagName(zon.name));

    // ── the public module (`@import("irregex")`) ──
    // What `relate`/`gist`/`blast` consume as a sibling-path dependency. PIC
    // because the product packages link it into PIE binaries and (in gist) a
    // shared C-ABI object.
    const engine = codegen.module(b.addModule("irregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .strip = strip,
    }));
    floor.under(engine);
    engine.addOptions("build_options", version);

    // ── the C-ABI artifact (`libirgx` + `include/irgx.h`) ──
    // Rooted at the export shims, NOT at `src/root.zig`. A Zig `export fn` is
    // emitted by every compilation that reaches it, so shims living in the
    // library module would be duplicated into `libgist`, `librelate`, and
    // `libblast` — each of which imports it — and a host linking two of them
    // would hit a duplicate-symbol error for a symbol it asked for once.
    // Keeping them in the artifact's own root means the symbols exist exactly
    // where the library named after them is.
    const abi = codegen.module(b.createModule(.{
        .root_source_file = b.path("src/surface/ffi/exports.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .link_libc = true,
        .strip = strip,
        .imports = &.{.{ .name = "irregex", .module = engine }},
    }));

    // The pair that actually ships, at `-Dlib-optimize`. A module carries its
    // own mode, so an optimized artifact rooted at a Debug engine would be an
    // optimized shim over the slow library — the twin has to go all the way
    // down. Kept separate from `abi` above rather than replacing it so the ABI
    // *tests* keep the mode a test wants and the edit loop stays where it was:
    // `zig build` compiles this pair, `zig build test-abi` compiles that one,
    // and neither step pays for the other. When the two modes agree there is
    // one of everything, which is what `-Dlib-optimize=Debug` asks for. (Named
    // `shipped_abi`, because `shipped` further down is a lab lane's posture.)
    const shipped_engine = if (lib_optimize == optimize) engine else blk: {
        const twin = codegen.module(b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = lib_optimize,
            .pic = true,
            .strip = strip,
        }));
        floor.under(twin);
        twin.addOptions("build_options", version);
        break :blk twin;
    };
    const shipped_abi = if (shipped_engine == engine) abi else codegen.module(b.createModule(.{
        .root_source_file = b.path("src/surface/ffi/exports.zig"),
        .target = target,
        .optimize = lib_optimize,
        .pic = true,
        .link_libc = true,
        .strip = strip,
        .imports = &.{.{ .name = "irregex", .module = shipped_engine }},
    }));

    // Dynamic (Python cffi dlopens it) owns the header install; static is what
    // Go cgo and a Rust build.rs link.
    const dynamic_lib = codegen.artifact(b.addLibrary(.{ .name = "irgx", .linkage = .dynamic, .root_module = shipped_abi }));
    dynamic_lib.installHeader(b.path("include/irgx.h"), "irgx.h");
    b.installArtifact(dynamic_lib);

    // The archive carries its own C floor on every target, so it links standing
    // alone. Everywhere a partial link exists that is done by packing a
    // partially-linked OBJECT. That is not symmetry for its own sake:
    // `addLibrary(.static)` archives this compilation's own objects and leaves
    // `linkLibrary` standing as an instruction for whoever links next — which,
    // for an archive, is a stranger who was never told. So the ELF `libirgx.a`
    // referenced `pcre2_compile_8` without carrying it, and a cgo or build.rs
    // consumer got undefined symbols unless they knew to hunt down two more
    // archives this package does not install; `bindings/rust/build.rs` routes
    // around it by linking the shared object instead, and the wheel vendoring
    // merges the floor in afterwards. macOS never had the bug, and not on
    // purpose — its ld64 workaround happened to route through an object, which
    // partially links, which pulls the C floor in. That accident is now the
    // design, and both arms ship an archive that links on its own.
    //
    // Zig's archiver leaves Mach-O members non-8-byte-aligned, which Apple's
    // ld64 rejects in a cgo link, so Darwin repacks through `libtool -static`;
    // everywhere else it is `zig ar`, the compiler already in hand rather than
    // one more host tool to have installed. Both arms install a plain FILE:
    // `installArtifact` publishes a name into the table a dependent's
    // `dep.artifact("irgx")` searches, the shared library above already owns
    // that name, and a second registration made the lookup ambiguous and
    // panicked the build runner — in every DEPENDENT, never here.
    //
    // `-Dlto` reaches the linked artifacts and deliberately not this object:
    // LTO would hand the archiver bitcode members, and whether those survive
    // into a cgo link is the consumer's linker's business, not ours to bet on.
    //
    // COFF is the one target that cannot get there through an object, because
    // it has no partial link: `zig build-obj` handed the two floor archives
    // refuses with "coff does not support linking multiple objects into one".
    // The property being bought is that the archive carries the C floor, and an
    // archive is a bag of members — so Windows buys it by splicing instead of
    // merging. `zig ar`'s `L` adds an input archive's *contents* rather than the
    // archive as a member, so the abi's own objects and both floors land in one
    // `libirgx.a` with the same closure the merged object has elsewhere. Only
    // the assembly differs; what a consumer links does not.
    const repack = switch (target.result.ofmt) {
        // Zig's archiver leaves Mach-O members unaligned (see above).
        .macho => b.addSystemCommand(&.{ "libtool", "-static", "-o" }),
        // `L` is only defined for `q` (append), which is what create means for
        // an output path the Run step mints fresh on every cache miss.
        .coff => b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "qcsL" }),
        else => b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "rcs" }),
    };
    const merged = repack.addOutputFileArg("libirgx.a");
    if (target.result.ofmt == .coff) {
        // Not installed as an artifact — see the ambiguity note above; it exists
        // only to hand the archiver this compilation's own objects.
        repack.addArtifactArg(b.addLibrary(.{ .name = "irgx", .linkage = .static, .root_module = shipped_abi }));
        repack.addArtifactArg(floor.pcre2At(lib_optimize));
        repack.addArtifactArg(floor.libsaisAt(lib_optimize));
    } else {
        repack.addArtifactArg(b.addObject(.{ .name = "irgx", .root_module = shipped_abi }));
    }
    b.getInstallStep().dependOn(&b.addInstallLibFile(merged, "libirgx.a").step);
    // Because it installs as a file, the archive is invisible to a dependent's
    // `dep.artifact("irgx")`, and the three faces need it: their own archives
    // deliberately do not fold the substrate in, so a static consumer of gist,
    // relate, or blast links the pair. gist used to reach for it with a `cp`
    // from `../irregex/zig-out/lib`, which is a different build than the one it
    // is being built against — on a cross-compile it copied this laptop's
    // Mach-O archive into a Linux prefix. Naming it here hands over the archive
    // from the dependency graph, so it is the right target by construction.
    b.addNamedLazyPath("libirgx.a", merged);

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
        const twin = codegen.module(b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = test_optimize,
            .pic = true,
        }));
        floor.under(twin);
        twin.addOptions("build_options", version);
        break :blk twin;
    };

    // One compiled test binary, N processes running disjoint residue classes of
    // it. `brigade.init` reads `-Dtest-shards` / `-Dtest-filter` / `-Dtest-skip`
    // and locates the runner inside its own package; the fan-out and the ~2x
    // cores default live there too.
    const bg = brigade.init(b, .{});
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = bg.runner(),
    });

    const test_step = b.step("test", "Run unit tests");
    bg.shard(test_step, tests, .{});

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
        .test_runner = bg.runner(),
    });
    const abi_step = b.step("test-abi", "Run the C-ABI artifact's unit tests (folded into `test`)");
    bg.shard(abi_step, abi_tests, .{ .count = 1 });
    if (!bg.narrowed()) test_step.dependOn(abi_step);

    // `zig build test-quick` — the same suite minus the declared long poles,
    // for the edit loop. A strictly weaker proof than `test`, and says so.
    const quick_step = b.step(
        "test-quick",
        b.fmt("Run unit tests except the {d} declared long poles (weaker than `test`)", .{deep_tests.len}),
    );
    bg.shard(quick_step, tests, .{ .skip = &deep_tests });

    // Debug twin for `check` (the step ZLS / --watch -fincremental drives) and
    // `coverage` (kcov needs full-fidelity DWARF). Carries the SAME brigade
    // runner: `@import("root")` inside a test resolves to the runner, so a
    // debug twin on the stock runner would compile a different program.
    const debug_tests = if (test_module == engine) tests else b.addTest(.{
        .root_module = engine,
        .test_runner = bg.runner(),
    });
    b.step("check", "Compile tests without running (fast --watch -fincremental loop / ZLS)")
        .dependOn(&debug_tests.step);

    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(debug_tests);
    bg.whole(run_cov);
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
            .blurb = "Cross-compile the library for x86_64-linux at both ISA floors (Sema+codegen, no link) — keeps the comptime-pruned Linux legs building",
            .queries = &.{
                // Baseline: SSE2, no byte permute. Every vector arm prunes to
                // its portable leg here, which is the only build that compiles
                // those legs at all.
                .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
                // x86-64-v2, which has SSSE3 — and which is the DEFAULT half of
                // this pair, in the sense that it is the floor the published
                // manylinux wheel declares and the shape almost every real
                // Linux host has. It is here because the vector arms that
                // `cpu.has(.x86, .ssse3)` now admits — `lanes.shuffle`'s
                // `pshufb` leg, the 16-lane composition, and the Parabix
                // transposition — are compiled by NO other query in this table.
                // Baseline above prunes them away and the AArch64 host builds
                // the NEON leg instead, so without this row the arms we ship to
                // the most common target in the world were reachable from no
                // gate on no machine: exactly the hole that let an arch-shaped
                // predicate sit in front of a feature-shaped requirement for as
                // long as it did.
                .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 } },
            },
        },
        .{
            .step = "check-portable",
            .blurb = "Cross-compile for the targets with no SIMD arm (Sema+codegen, no link) — keeps every `cpu.has` gate honest about the feature it names",
            .queries = &.{
                // AArch64 with NEON SUBTRACTED. Not a hypothetical target: it
                // is what any `-mcpu` without SIMD resolves to, and it broke.
                // `lanes.native` armed the composition by architecture, reached
                // `shufflePair`, and died on that function's own
                // `@compileError` — no artifact at all for anyone on an AArch64
                // profile without SIMD. An arch-shaped gate in front of a
                // feature-shaped requirement is invisible to every host that
                // happens to have the feature, so the only thing that sees it
                // is a build for a host that does not.
                .{
                    .cpu_arch = .aarch64,
                    .os_tag = .linux,
                    .abi = .gnu,
                    .cpu_model = .baseline,
                    .cpu_features_sub = std.Target.aarch64.featureSet(&.{.neon}),
                },
                // Neither NEON nor SSSE3 nor anything to fall back from: the
                // one target where `shuffle` and `pshufb` compile their
                // portable arms because there is no other arm to take.
                // `check-linux` above already covers x86_64 at baseline (SSE2),
                // which is the same story for the shuffle and the declared
                // floor of the published manylinux wheel.
                .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
            },
        },
        .{
            .step = "check-windows",
            .blurb = "Cross-compile the library for all three Windows triples (Sema+codegen, no link) — keeps portal's Win32 arm and the warm tier's Win32 arm building",
            .queries = &.{
                .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
                .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
                .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } },
                // The SSSE3 arms again, this time behind the Win32 legs — the
                // one combination where a vector kernel and a platform backend
                // are pruned by different conditions and could each be green
                // while their intersection does not compile.
                .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 }, .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 } },
            },
        },
    };
    for (cross_checks) |check| {
        const step = b.step(check.step, check.blurb);
        for (check.queries) |query| {
            const foreign = b.resolveTargetQuery(query);
            // Rooted at the C-ABI export surface, NOT at `src/root.zig`, for the
            // same reason the shipped `libirgx` is: Zig analyzes what a
            // compilation reaches, and a bare object over `root.zig` exports
            // nothing, so it reached almost none of the engine. That check
            // passed on an AArch64 target with NEON subtracted while the actual
            // library build for the same target failed to compile — a green
            // portability gate over code it never looked at. `export fn` is what
            // forces Sema down to the kernels these steps exist to keep honest.
            const foreign_engine = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = foreign,
                .optimize = .Debug,
                .link_libc = true,
            });
            foreign_engine.addOptions("build_options", version);
            const mod = b.createModule(.{
                .root_source_file = b.path("src/surface/ffi/exports.zig"),
                .target = foreign,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{.{ .name = "irregex", .module = foreign_engine }},
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
    // mode rather than the machine. Certificate lanes instead honor whatever
    // `-Doptimize` the caller asked for, since a cycles/byte number is a claim
    // about THIS build.
    const lab_optimize = b.option(
        std.builtin.OptimizeMode,
        "lab-optimize",
        "optimize mode for the production-posture rungs (default ReleaseFast — they race the shipped ladder)",
    ) orelse .ReleaseFast;
    const speed = codegen.module(b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = lab_optimize,
        .pic = true,
    }));
    floor.under(speed);
    // A faithful twin needs the engine's options too, not only its optimize
    // mode: `version_string` is lazily analyzed, so a lane that happens to
    // touch it would otherwise fail on a missing import rather than on
    // anything it did.
    speed.addOptions("build_options", version);

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
        .{ .step = "sweep-rung", .exe = "sweep-rung", .root = "bench/rungs/sweep/bench.zig", .blurb = "Sweep-rung consumer proof: each recursive analysis raced against the fused interned-AST sweep, alone and bundled, fail-closed on any disagreement" },
        .{ .step = "ladder-price", .exe = "ladder-price", .root = "bench/rungs/price/bench.zig", .instrument = "pmu", .libc = true, .blurb = "Ladder price plane: re-time every auction coefficient in isolation (verify), and gate the auction's per-pattern picks against the measured-fastest machine (regret)" },
        .{ .step = "engine-census", .exe = "engine-census", .root = "bench/rungs/census/bench.zig", .instrument = "probes", .blurb = "Engine census: which ladder machine each certificate probe class actually compiles to" },
        .{ .step = "partition-rung", .exe = "partition-rung", .root = "bench/rungs/partition/bench.zig", .libc = true, .tested = true, .blurb = "Partition rung: the math floor's two collapse primitives priced by regime — Moore vs Hopcroft vs auto on a blown-up quotient and on a chain, and the DAFSA's size against a sorted array as suffix sharing varies at a fixed key count" },
    }) |lane| {
        const shipped = lane.posture == .shipped;
        const mod = codegen.module(b.createModule(.{
            .root_source_file = b.path(lane.root),
            .target = target,
            .optimize = if (shipped) lab_optimize else optimize,
        }));
        mod.addImport("irregex", if (shipped) speed else engine);
        if (lane.instrument) |name| mod.addImport(name, if (std.mem.eql(u8, name, "pmu")) pmu else probes);
        if (lane.libc) mod.link_libc = true;

        const exe = codegen.artifact(b.addExecutable(.{ .name = lane.exe, .root_module = mod }));
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

        // `build-<lane>` — the same executable, installed but NOT run. The
        // certificate mint needs this for two reasons `zig build lab` cannot
        // serve: a lane whose measurement needs `sudo` has to exist before it is
        // invoked (Layer B′ reads counters), and a mint should not be aborted by
        // a production rung mid-refactor that no layer it splices reads.
        b.step(
            b.fmt("build-{s}", .{lane.step}),
            b.fmt("Install (do not run) {s}", .{lane.exe}),
        ).dependOn(install);
        // A lane carrying its own tests is a third plane, and it gets the same
        // treatment as the C-ABI one above for the same reason: its own step to
        // be hunted in, folded into `test` only when nothing is filtered. A
        // filter naming a lane's test is not a typo, so it must not fail the
        // main plane's shards — and the way to say that is for a narrowed run to
        // mean exactly one plane.
        if (lane.tested) {
            const lane_tests = b.addTest(.{ .root_module = mod, .test_runner = bg.runner() });
            const lane_step = b.step(
                b.fmt("test-{s}", .{lane.step}),
                b.fmt("Run {s}'s own unit tests (folded into `test`)", .{lane.exe}),
            );
            bg.shard(lane_step, lane_tests, .{ .count = 1 });
            if (!bg.narrowed()) test_step.dependOn(lane_step);
        }
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
    const drift_tests = b.addTest(.{ .root_module = probes_drift, .test_runner = bg.runner() });
    const drift_step = b.step("test-probes-drift", "Run the Layer-B probe/production drift guard (folded into `test`)");
    bg.shard(drift_step, drift_tests, .{ .count = 1 });
    if (!bg.narrowed()) test_step.dependOn(drift_step);

    // ── `zig build ir` — reading what LLVM actually did ──
    // The knobs at the top choose what LLVM is ALLOWED to emit; this is how you
    // find out what it emitted. One object, three views of that same
    // compilation, into `zig-out/llvm/`: the post-pipeline `.ll` (grep it for
    // the vector width a rung really got, or for the call that was supposed to
    // inline), the matching `.bc`, and the `.s` that `llvm-mca` reads —
    // `bench/bounds/port/mca.sh` already does the assembly half by hand for two
    // cross-compiled reference cores, and this is the same lever without a
    // µarch opinion.
    //
    // `-Dir=<file>` picks the root, at `-Dlab-optimize` (ReleaseFast) for the
    // same reason the production rungs run there: Debug IR is not the IR that
    // ships. The default root is the C-ABI surface rather than `src/root.zig`,
    // because Zig analyzes lazily and a library root that exports nothing
    // lowers to nothing — the export shims are what pull the real engine into
    // an object. That default is tens of megabytes of IR; point it at one probe
    // or leaf module to read a page instead.
    //
    // Below this the pass pipeline itself has no `std.Build` surface, so the
    // last tier is the driver, invoked directly. `-fopt-bisect-limit` runs only
    // the first N passes and names every one it then skipped, which is how you
    // find the pass that undid a vectorization; it needs a real emit beside it,
    // since `-fno-emit-bin` alone never enters LLVM at all:
    //
    //     zig build-obj <file> -O ReleaseFast -fno-emit-bin \
    //         -femit-llvm-ir=/tmp/at-N.ll -fopt-bisect-limit=N
    //     zig build-obj <file> --verbose-llvm-cpu-features   # the subtarget
    //         # string `-Dcpu=` actually produced, as LLVM parsed it
    //
    // and the escape hatch the `.bc` exists for: any pass pipeline you like via
    // an external `opt`, handed back to Zig as an input file. The LLVM major
    // must match the one this compiler links (0.16.0 → LLVM 21) — a newer
    // `opt`'s bitcode returns as `error: Invalid record`, which is a version
    // mismatch and not a corrupt module.
    //
    //     opt -passes='…' zig-out/llvm/root.bc -o tuned.bc && zig build-obj tuned.bc
    const ir_root = b.option([]const u8, "ir", "root source file `zig build ir` lowers (default src/surface/ffi/exports.zig)") orelse "src/surface/ffi/exports.zig";
    const ir_name = std.fs.path.stem(ir_root);
    const ir_mod = codegen.module(b.createModule(.{
        .root_source_file = b.path(ir_root),
        .target = target,
        .optimize = lab_optimize,
        // Matched to the shipped library module: both change codegen, so an
        // inspection built without them would be reading a different program.
        .pic = true,
        .link_libc = true,
    }));
    ir_mod.addOptions("build_options", version);
    // Only when the root is something else — two modules in one compilation may
    // not share a source file, and the default root IS the engine's.
    if (!std.mem.eql(u8, ir_root, "src/root.zig")) ir_mod.addImport("irregex", speed);
    const ir_obj = b.addObject(.{ .name = ir_name, .root_module = ir_mod });
    const ir_step = b.step("ir", "Emit optimized LLVM IR + bitcode + assembly for -Dir=<file> → zig-out/llvm/");
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ ir_obj.getEmittedLlvmIr(), "ll" },
        .{ ir_obj.getEmittedLlvmBc(), "bc" },
        .{ ir_obj.getEmittedAsm(), "s" },
    }) |view| {
        const dest = b.fmt("llvm/{s}.{s}", .{ ir_name, view[1] });
        ir_step.dependOn(&b.addInstallFileWithDir(view[0], .prefix, dest).step);
    }
}
