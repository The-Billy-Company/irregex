//! gist `rg` — the fused work-stealing walk+read+match+emit engine (the fast path).
//!
//! The serial engine walks the tree single-threaded, reads candidates in a
//! second phase, then matches+emits in a third — three passes, one core doing
//! the walk and the emit. ripgrep fuses all three into one work-stealing
//! parallel walk (`ignore::WalkParallel`), which is exactly what this plane is:
//! a queue of DIRECTORY tasks; each worker pops a directory, lists it in ONE
//! `getattrlistbulk` syscall batch (name+type+mtime+ctime per sibling — the
//! timestamps power inline index elision with no separate freshness stat-walk),
//! applies the ignore verdict, pushes child directories back on the queue, and
//! searches child FILES on the spot, writing each hit to stdout the instant it
//! is rendered. Never globally reordered after the fact.
//!
//! This file is the plane's FACE: who may ride it (`eligible`), and the run
//! lifecycle (`run`) that freezes the shared config, races the elide loader
//! against the walk, fans out the crew, and folds the per-worker tallies into
//! one exit code. The machinery it orchestrates lives in siblings —
//! [`queue`](queue.zig) (the work-stealing spine), [`crew`](crew.zig) (worker
//! state + pool topology), [`descent`](descent.zig) (the directory walk),
//! [`sift`](sift.zig) (per-file read→gate→match→render), [`sink`](sink.zig)
//! (the shared stdout writer), and [`roster`](roster.zig) (the same walk as a
//! callable file-set enumerator for the resident daemon).
//!
//! Thread-safety is by construction, not locks: the base `Ignore` (CWD/ancestor
//! tier) is FROZEN before fan-out and read via `decideAt` (root depth passed per
//! call, never a mutable field); each directory's own ignore rules live in an
//! immutable `IgNode` chained to its parent's, built once by the worker that
//! entered the directory and only read thereafter. Workers touch only their own
//! arena; the one shared structure is the task queue.
//!
//! Dispatch policy (`eligible`): the recursive-walk cases every agent session
//! actually hits — default search, `-l`, `-c`, `-o`, `-n`, context, `-w`/`-i`/
//! `-F`/`-x`, `-t`/`-g` scoping, `--files`, `--files-without-match`, `--stats`
//! — run here. The long tail that carries cross-file or stateful semantics
//! (`-L` symlink cycles, `-q`, `-r` captures, `--max-filesize`, explicit FILE
//! args, stdin) stays on the proven serial engine.

const std = @import("std");
const args = @import("../../argv/args.zig");
const assay = @import("../../../../../assay/assay.zig");
const corpus_mod = @import("../../../../../corpus/tree/corpus.zig");
const crest = @import("../../../../../kernel/primitives/crest.zig");
const crew = @import("crew.zig");
const descent = @import("descent.zig");
const elide = @import("../../quarry/elide.zig");
const notice = @import("../../quarry/notice.zig");
const stats = @import("../../read/stats.zig");
const hints = @import("../../emit/hints.zig");
const ignore = @import("../../../../../corpus/tree/ignore.zig");
const ingest = @import("../../read/ingest.zig");
const json = @import("../../emit/json.zig");
const paths_mod = @import("../../../../../corpus/scope/paths.zig");
const writ = @import("../../writ/writ.zig");
const queue = @import("queue.zig");
const serial = @import("../serial.zig");
const shard_mod = @import("../../../../../corpus/index/content/shard.zig");
const simd = @import("../../../../../kernel/match/scan/simd.zig");
const sink_mod = @import("sink.zig");
const treemap = @import("../../../../../corpus/index/phantom/treemap.zig");

const Cfg = crew.Cfg;
const Dir = std.Io.Dir;
const DirTask = queue.DirTask;
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
const Opts = args.Opts;
const Outcome = @import("../../../../cli/outcome.zig").Outcome;
const Queue = queue.Queue;
const Sink = sink_mod.Sink;
const Worker = crew.Worker;
const defaultWorkerCount = crew.defaultWorkerCount;
const die = args.die;
const emitSorted = crew.emitSorted;
const oom = args.oom;
const rootDepth = paths_mod.rootDepth;
const workerMain = descent.workerMain;

/// Can this invocation run on the parallel engine byte-identically? Everything
/// here must ALSO hold in `serial.zig`'s dispatch (it calls this) — the serial
/// engine remains the semantic reference for whatever this declines.
///
/// The `GIST_NO_PARALLEL` parity-gate knob (which forces the serial reference so
/// both engines can run one case list) is the FIRST thing checked, via the
/// single `assay.serialForced` joint the emit shards and `json.runParallel`
/// share — see its doc comment for why plane selection routes through one
/// predicate. That knob exists SOLELY to catch the class of bug this function's
/// own history proves possible: the parallel engine landed a day after a
/// serial-engine-only ignore-parity fix and silently missed it (see
/// `ignore.zig`'s `skipFromVerdict` — it now takes the same whitelist-override
/// pair `shouldSkip` does).
pub fn eligible(io: std.Io, parsed: args.Parsed, o: Opts, re: ?*const Matcher) bool {
    if (assay.serialForced()) return false;
    // `-l` / `--files-without-match` ride the walk only while the fused boolean
    // IS their answer (`pathVerdictFused`); any flag that redefines the verdict
    // sends the mode to the serial engine, which applies it correctly.
    if (o.mode.pathPerFile() and !pathVerdictFused(o, re)) return false;
    // `-U`/--multiline rides the pipeline: each worker's per-file render goes
    // through the same `Emitter.buffer` whole-buffer model the serial engine
    // uses (multiline.zig owns the span/line semantics), so the walk + literal
    // gate + index elision that carry every linear win apply to `-U` too.
    // `--stats` and `--files-without-match` ride the fused walk (per-worker
    // tallies / inverted `-l` emit); `-q` still needs the serial short-circuit
    // (first hit wins, cancel the walk), and `-r`/`--max-filesize`/`-L` keep
    // their serial collect semantics.
    if (o.follow or o.quiet or o.replace != null or o.max_filesize != 0) return false;
    // `--json` RIDES the walk (the streaming win every other mode gets): each
    // worker emits ripgrep's per-file `begin`/`match`/`end` records via the shared
    // `json.emitOne` and tallies a per-worker `json.Stats`; `run` sums them into
    // the single trailing `summary`. It declines only when it would need
    // per-thread capture scratch (`-r`, gated above) or a content transform
    // (`-z`/`-E`) whose decoded bytes the walk's JSON path doesn't rewrite — those
    // keep the serial collect-then-shard path (`serial.run`'s `o.mode == .json` block).
    if (o.mode == .json and (o.search_zip or o.encoding != .auto)) return false;
    // `--include-zero` must emit a `path:0` line for EVERY searched file, so it
    // needs the serial engine's whole-file loop with the literal gate + index
    // elision disabled — the streaming sink here culls non-matching files.
    if (o.include_zero) return false;
    // A device-bounded walk (`--one-file-system`) needs cross-file device state
    // the streaming walk can't carry, so it stays serial.
    if (o.one_file_system) return false;
    // `--sort`/`--sortr` rides the fused parallel walk for the PATH key: each
    // worker holds its rendered per-file output (already in its arena) keyed by
    // path instead of racing it to stdout, and `run` orders the whole result
    // once after the walk — a parallel walk+read+match feeding a single sort,
    // which beats ripgrep's single-threaded sorted traversal (`emitSorted`).
    // The exclusions keep byte-parity with the serial sort oracle: time keys
    // (modified/accessed/created) need a per-file stat the fused walk skips;
    // `--files` (no pattern) already wins on the serial stat-only listing; a
    // machine-consumed `--json` stream keeps its serial collect path; and rg
    // orders ASCENDING multi-root path per-argv-root (`lessAscPathWalk`), which
    // the rootless streaming walk doesn't track — descending is global, so it
    // rides regardless of root count.
    switch (o.sort_key) {
        .none => {},
        .path => if (o.mode == .json or o.mode == .files or (parsed.roots.len > 1 and !o.sort_reverse)) return false,
        .modified, .accessed, .created => return false,
    }
    // `-z`/`-E` ride the parallel engine; `--pre`/`--binary` do not (see
    // `transformsRidePipeline`). Kept as a pure, unit-tested seam so a future
    // edit can't silently drop `-z` back to the serial engine unnoticed.
    if (!transformsRidePipeline(o)) return false;
    // `-P`/`--pcre2` rides the parallel engine like the linear default: its
    // per-worker PCRE2 scratch is thread-confined, and the match-limit latch
    // (the exit-2-on-catastrophic-backtracking rg parity) is a process-global
    // atomic every worker stores into, folded into the exit code below.
    // Every positional root must be a directory — an explicit FILE arg carries
    // rg's "never ignore-filtered, error-if-unopenable" semantics (serial).
    for (parsed.roots) |r| {
        var d = Dir.cwd().openDir(io, r, .{}) catch return false;
        d.close(io);
    }
    return true;
}

/// Can the fused walk answer a per-file YES/NO verdict (`-l`,
/// `--files-without-match`) by itself? Its ONLY rendering of those two modes is
/// the early-exit whole-buffer boolean in `sift.emitBody` (`Cfg.fast_l`), so
/// this predicate is simultaneously the fast path's guard and the mode's
/// admission ticket — `eligible` declines the whole run when it is false, rather
/// than letting the per-file render fall through to standard match lines.
///
/// Each excluded flag either changes what "this file matches" MEANS (`-v`
/// inverts it, `-w` bounds it, `--crlf`/`--null-data` redefine the line, `-m`
/// caps it, `--stop-on-nonmatch` truncates the file) or asks for something the
/// boolean does not produce (`-o`, `--passthru`, `--vimgrep`, `-r`, a `--stats`
/// tally); under `-U` the boolean must be PROVEN equal to the whole-buffer emit
/// model's verdict (`bufBoolExact`).
///
/// The decline is a real bug fix, not caution: `bench/rgsuite/fuzz.py` caught
/// `--files-without-match` paired with any of these streaming ordinary match
/// lines, and — under `--sort path`, where the sink rewrites each delivered
/// record as its path — listing the file set rg EXCLUDES. The serial engine's
/// `render.fileWithoutMatch` has always applied the modifiers correctly, so
/// routing there is both the fix and the oracle.
pub fn pathVerdictFused(o: Opts, re: ?*const Matcher) bool {
    return !o.invert and !o.word and !o.crlf and !o.null_data and o.max_per_file == 0 and !o.only_matching and
        !o.passthru and !o.vimgrep and !o.stop_on_nonmatch and o.replace == null and !o.stats and
        (!o.multiline or (re != null and re.?.bufBoolExact()));
}

test "a per-file verdict rides the fused walk only when no flag redefines it" {
    const t = std.testing;
    try t.expect(pathVerdictFused(.{}, null));
    // Every one of these changes the verdict or the row — each was a live
    // divergence against rg before the decline landed.
    try t.expect(!pathVerdictFused(.{ .invert = true }, null));
    try t.expect(!pathVerdictFused(.{ .word = true }, null));
    try t.expect(!pathVerdictFused(.{ .crlf = true }, null));
    try t.expect(!pathVerdictFused(.{ .null_data = true }, null));
    try t.expect(!pathVerdictFused(.{ .max_per_file = 1 }, null));
    try t.expect(!pathVerdictFused(.{ .only_matching = true }, null));
    try t.expect(!pathVerdictFused(.{ .passthru = true }, null));
    try t.expect(!pathVerdictFused(.{ .vimgrep = true }, null));
    try t.expect(!pathVerdictFused(.{ .stop_on_nonmatch = true }, null));
    try t.expect(!pathVerdictFused(.{ .replace = "X" }, null));
    try t.expect(!pathVerdictFused(.{ .stats = true }, null));
    // `-U` needs a matcher whose whole-buffer boolean is proven exact; without
    // one there is nothing to consult, so it declines rather than guessing.
    try t.expect(!pathVerdictFused(.{ .multiline = true }, null));
}

/// The content-transform half of the pipeline-eligibility contract, factored out
/// pure so the routing decision is unit-testable without a filesystem walk.
///
/// `-z`/`--search-zip` (decompress) and `-E`/`--encoding` (transcode) RIDE the
/// parallel engine: each worker rewrites its own file on a private arena — native
/// `std.compress` in-process, or a thread-safe `std.process.run` for the
/// external-codec tail — then matches+emits it, fusing the decode with the match
/// that rg pays serially per file. `--pre` DECLINES (it must keep rg's
/// "preprocessor receives the file PATH as argv[1]" contract with a single-writer
/// stderr + exit-2 latch on the serial engine); `--binary`/`-uuu` DECLINES (the
/// whole-file NUL-bearing binary search path is serial). `-z` and `-E` are always
/// safe here because their rewrite is a pure per-file byte function. See
/// `ingest.zig` + `searchFile`'s transform branch.
pub fn transformsRidePipeline(o: Opts) bool {
    return o.pre == null and !o.binary;
}

test "transform routing: -z/-E ride the pipeline; --pre/--binary decline" {
    const t = std.testing;
    // plain + the two transforms that ride the parallel engine
    try t.expect(transformsRidePipeline(.{}));
    try t.expect(transformsRidePipeline(.{ .search_zip = true }));
    try t.expect(transformsRidePipeline(.{ .encoding = .utf16le }));
    try t.expect(transformsRidePipeline(.{ .search_zip = true, .encoding = .windows_1252 }));
    // the two that must stay serial
    try t.expect(!transformsRidePipeline(.{ .pre = "decompress.sh" }));
    try t.expect(!transformsRidePipeline(.{ .binary = true }));
    // a transform paired with a serial-only flag still declines (serial wins)
    try t.expect(!transformsRidePipeline(.{ .search_zip = true, .binary = true }));
    try t.expect(!transformsRidePipeline(.{ .search_zip = true, .pre = "p.sh" }));
}
/// Fan out, walk, search, stream, exit. `filters` powers inline index elision;
/// `file_needle` may reject a whole body, while `line_needle` only avoids regex
/// execution and remains valid for passthru. Never returns.
pub fn run(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, o: Opts, re: ?*const Matcher, use_color: bool, filters: []const []const u8, plan: ?elide.Plan, sieve: crest.Swell, file_needle: ?simd.Gate, line_needle: ?simd.Gate, icfg: *const ingest.Config) noreturn {
    // Run-scoped monotonic stopwatch for the fused walk — feeds the real
    // `elapsed`/`elapsed_total` in the `--stats`/`--json` summary (was hardcoded
    // `0.000000`) and the `.query`-lens stderr diagnostic, the serial engine's twin.
    const search_span = assay.Span.open(io);
    // Heading needs a printable path: `--no-filename` suppresses the header
    // like rg (the walk is recursive, so `.auto` filenames are always on here).
    const heading = o.groups();
    // `--stats` must visit every admitted file for `files searched` /
    // `bytes searched`, so the index oracle (which drops proven non-matches)
    // stays off — the fused walk still beats serial's collect-then-shard.
    // `--files-without-match` KEEPS elision: a proven non-match IS the emit.
    const want_elision = !o.stats and elide.indexElisionWanted(io, parsed, filters, plan, sieve);
    // Internal gate-only contract: load synchronously and fail closed unless
    // the real elision oracle is admitted. This makes freshness_fs.sh prove the
    // accelerated path instead of accidentally passing via an async/full-read
    // fallback. It is intentionally not a CLI flag.
    const require_elision = assay.envSpan("GIST_TEST_REQUIRE_ELISION") != null;
    if (require_elision and !want_elision) die("gist: test-required index elision was not eligible\n", .{});
    // The elide oracle loads on its own thread while the walk runs, keeping
    // mmap validation, sparse posting decode, and path-table setup off the
    // serial query prefix.
    var lazy: elide.Lazy = .{};
    if (want_elision) {
        if (require_elision) {
            lazy.admit(gpa, io, o, filters, plan, sieve);
            if (lazy.val == null) die("gist: test-required index elision was declined\n", .{});
            if (!elide.testHasElidableFile(io, &lazy.val.?)) die("gist: test-required index elision found no elidable live file\n", .{});
            lazy.ready.store(true, .release);
        } else {
            // Detached: if every worker out-walks the load and gives up on
            // elision, nobody waits on this thread — `run` exits the process and
            // the OS reclaims it. (`lazy`/`o`/`filters` outlive it either way:
            // this frame never returns.)
            if (std.Thread.spawn(.{}, elide.Lazy.loaderMain, .{ &lazy, gpa, io, o, filters, plan, sieve })) |t| t.detach() else |_| {
                lazy.admit(gpa, io, o, filters, plan, sieve);
                lazy.ready.store(true, .release);
            }
        }
    } else lazy.ready.store(true, .release);

    // Phantom tree.map. The snapshot carries MEMBERSHIP only (names + kinds),
    // so every admission axis stays sound by construction: ignore/hidden/glob
    // verdicts are decided live per entry, admission-widening flags (`-uu`,
    // `--hidden`, `-g` whitelists, `--ignore-file`) at worst re-admit a
    // subtree the build never descended — which walks live via `not_walked` —
    // and explicit roots resolve to their snapshot record by name (a root the
    // snapshot can't place just walks live). `GIST_NO_PHANTOM` (internal,
    // undocumented — the `GIST_NO_PARALLEL` idiom) forces the live walk for
    // parity gates.
    var snap_view: ?treemap.View = if (assay.envSpan("GIST_NO_PHANTOM") == null) treemap.load(io) else null;

    // Content shard. Loaded for a body-reading walk broad enough to amortize the
    // one-time map + doc-table build (`broadIndexedRoots`, same rung the elide
    // loader uses): every unchanged corpus file the walk would open is served
    // from the mapping instead — the across-the-board full-scan win. Skipped for
    // `--files` (no bytes read) and transform runs (`-z`/`-E` need live bytes,
    // and the shard never holds compressed inputs anyway). `GIST_NO_SHARD`
    // (internal, undocumented — the `GIST_NO_PHANTOM` idiom) forces live reads
    // for the parity gate. Membership + freshness only, so it is fail-open.
    const want_shard = assay.envSpan("GIST_NO_SHARD") == null and !o.no_index and o.mode != .files and !icfg.active() and elide.broadIndexedRoots(parsed.roots);
    var shard_view: ?shard_mod.View = if (want_shard) shard_mod.load(gpa, io) else null;

    var ig = ignore.Ignore.init(gpa, io, ignore.Options.from(o), parsed.roots) catch oom();
    const compiled = ignore.Compiled.build(gpa, &ig) catch oom();
    var q: Queue = .{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);
    var sink: Sink = .{ .q = &q, .io = io, .heading = heading, .join_groups = o.wantsContext() and o.mode.frames() and !heading, .group_sep = o.groupSep() };
    // Pure-literal alternation gate/equivalence (see `Cfg.file_alts`): only when
    // no single required literal already gates, and never for modes that must
    // read every body (`-v` needs zero-hit files; passthru emits them).
    // `--stats` keeps the gate: a miss still tallies via `gateMiss` (zero hits +
    // full bytes) without a regex run — faster than serial's ungated collect.
    const lits: []const []const u8 = if (re) |m| m.lits() else &.{};
    const file_alts: []const []const u8 = if (lits.len > 0 and file_needle == null and !o.invert and !o.passthru) lits else &.{};
    // Equivalence proof: the whole-file gate that will run (`file_needle`, a
    // single pure literal, or `file_alts`, a pure alternation) IS the pattern.
    // A caseless gate carries its own producer-proven equivalence (`.equiv`,
    // mined from the raw unfolded twin in `serial.zig::caselessGate`).
    const lits_equiv = (file_needle != null and (file_needle.?.equiv or (lits.len == 1 and std.mem.eql(u8, lits[0], file_needle.?.bytes)))) or file_alts.len > 0;
    // Under `-U` the fused boolean is `bufMatch`; admit it only when that
    // boolean provably equals the whole-buffer emit model's `-l` /
    // `--files-without-match` verdict (`bufBoolExact` — a nullable `\z`-style
    // pattern falls to `Emitter.buffer`).
    const fast_l = o.mode.pathPerFile() and pathVerdictFused(o, re);
    var gate_len: usize = if (file_needle) |n| n.bytes.len else 0;
    for (file_alts) |n| gate_len = @max(gate_len, n.len);
    const cfg: Cfg = .{
        .o = o,
        .re = re,
        .ig = &ig,
        .compiled = if (compiled) |*c| c else null,
        .lazy = if (want_elision) &lazy else null,
        .file_needle = file_needle,
        .file_alts = file_alts,
        .lits_equiv = lits_equiv,
        .gate_len = gate_len,
        .line_needle = line_needle,
        .fast_l = fast_l,
        .use_color = use_color,
        // `.auto` shows names too: the walk is recursive by construction.
        .show_name = o.filename != .never,
        .heading = heading,
        .join_groups = sink.join_groups,
        .binary_detect = writ.binaryDetect(o),
        .files_mode = o.mode == .files,
        .ingest = if (icfg.active()) icfg else null,
        .snap = if (snap_view) |*v| v else null,
        .shard = if (shard_view) |*v| v else null,
        .sink = &sink,
        .collect_sorted = o.sort_key != .none,
    };
    const roots: []const []const u8 = if (parsed.roots.len > 0) parsed.roots else &.{"."};
    {
        var seed: std.ArrayList(DirTask) = .empty;
        defer seed.deinit(gpa);
        for (roots) |r| {
            const prefix = if (std.mem.eql(u8, r, ".") and parsed.roots.len == 0) "" else std.mem.trimEnd(u8, r, "/");
            const scope_prefix = paths_mod.cwdRelative(gpa, io, prefix);
            // Each root resolves to its snapshot record by name (dir 0 = the
            // CWD root); an unplaceable root simply walks live.
            const six = if (snap_view) |*v| treemap.resolve(v, scope_prefix) orelse treemap.not_walked else treemap.not_walked;
            seed.append(gpa, .{ .disk = r, .rel = prefix, .scope = scope_prefix, .depth = 0, .root_depth = rootDepth(prefix), .chain = null, .snap_ix = six }) catch oom();
        }
        q.push(seed.items);
    }

    // Worker topology is OS-aware (see `defaultWorkerCount`): macOS keeps the
    // measured six-worker ceiling (kernel-serialized walk) and halves it for
    // traversal-only / narrow / selective runs; every other OS scales to all
    // logical CPUs like ripgrep. `GIST_WORKERS` remains absolute.
    const ncpu = std.Thread.getCpuCount() catch 6;
    const narrow_scope = parsed.roots.len > 0 and !elide.broadIndexedRoots(parsed.roots);
    // A transforming run (-z/--pre/-E) does CPU-bound per-file work — inflate
    // (gzip/xz/zstd) or transcode — that scales to every core, exactly like the
    // serial engine's parallel read-shards (`serial.zig` `readCandidates` fans out
    // to `min(candidates, ncpu)`). The 6-worker ceiling is tuned for the
    // syscall/namei-bound plaintext walk, where more threads only add fd + namei
    // contention; it throttles decode-heavy codecs (xz/zstd) below the serial
    // path, so a transforming pipeline lifts the cap to all logical CPUs.
    var nworkers = if (icfg.active()) @max(1, ncpu) else defaultWorkerCount(ncpu, o.mode == .files or want_elision or narrow_scope);
    // -j/--threads caps the pool explicitly (rg's `--threads`); 0 keeps gist's
    // adaptive topology. `GIST_WORKERS` still overrides everything (parity gates).
    if (o.threads != 0) nworkers = @max(1, o.threads);
    if (assay.envSpan("GIST_WORKERS")) |s| if (std.fmt.parseInt(usize, s, 10) catch null) |n| {
        nworkers = @max(1, n);
    };
    const workers = gpa.alloc(Worker, nworkers) catch oom();
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .gpa = gpa, .cfg = &cfg, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| {
        w.arena.deinit();
        w.out.deinit(gpa);
        w.recs.deinit(gpa);
    };

    crew.muster(gpa, workers, workerMain) catch oom();

    // `--sort`/`--sortr path`: the fused walk held every worker's rendered output
    // in its arena keyed by path (`deliver`/`bufferPath`) instead of racing it to
    // stdout. Order the whole result once now and replay it through the SAME
    // `Sink` — a single global sort over a parallel walk+read+match, so separators
    // and the matched-files exit code stay byte-identical to the serial oracle,
    // just sorted. Falls through to the shared exit tail below.
    if (cfg.collect_sorted) emitSorted(gpa, &sink, workers, o, use_color);

    // Every byte is already on stdout — each worker streamed its fragments
    // through `sink.emit` the instant it rendered them (see `Sink`). Nothing
    // left to stitch or write; a walk error (unreadable dir) trumps match/
    // no-match (rg parity — see `reportWalkError`), otherwise `sink.matched_files`
    // alone decides the exit code.
    // Announce a soft/hard output-budget cut (the streaming `Sink` aborted the
    // walk when `writeStdout` refused past the ceiling — corpus.zig). One-time,
    // stderr-only, a no-op when nothing was truncated; runs before either exit.
    corpus_mod.finishOutput();
    // A `-P` worker that tripped a resource limit on catastrophic input latched
    // the process-global fault — mirror ripgrep's exit 2 over the accumulated
    // (already-streamed) output, via the serial engine's own `pcreFaultExit`
    // renderer so the two engines' fault text can't drift.
    if (re) |m| serial.pcreFaultExit(m);
    // The no-match hint seam (mirrors the serial engine's): a clean exit-1
    // search run — not `--files`, not `--quiet`, no walk error — gets shape-
    // derived stderr guidance. The streamed walk has no cheap total-files
    // count, so the summary omits it rather than report a partial number.
    // rg's implicit-path heuristic (search modes only, never `--files`): a
    // GUESSED root whose walk admitted zero files means a filter excluded
    // everything — stderr note + exit 2, never a silent exit-1 "no matches".
    const nothing_searched = re != null and parsed.roots.len == 0 and !q.files_seen.load(.acquire);
    if (nothing_searched) notice.printNothingSearched();
    // `--json`: every worker streamed its per-file `begin`/records/`end` blocks;
    // sum their per-worker tallies and write the single trailing `summary` record
    // (rg's stream always ends with it, even on no match) as the last stdout line.
    // The stream's file order is worker-discovery order — order-insensitive, the
    // same contract as the plain walk's fragments and the parity harness's
    // `sort -u` set compare. No `noMatches` stderr hint (rg's serial `--json`
    // path emits none either — it would only pollute a machine-consumed stream).
    if (o.mode == .json) {
        var st: json.Stats = .{};
        for (workers) |*wk| st.fold(wk.jstats);
        var sbuf: std.ArrayList(u8) = .empty;
        json.summary(gpa, &sbuf, st, search_span.read(io));
        _ = corpus_mod.writeStdout(sbuf.items);
        stats.diagSearch(gpa, o.mode == .json, st, search_span.read(io));
        (Outcome{ .matched = st.get(.files_with_match) > 0, .faulted = q.walk_error.load(.acquire) or nothing_searched }).exit();
    }
    // `--stats`: every worker streamed its match fragments; fold their per-
    // worker tallies, stamp `files_with_match` / `bytes_printed` from the sink
    // (the serial engine does the same post-pass), and append ripgrep's trailing
    // stats block. Quiet is declined by `eligible`, so the match stream always
    // ran and the sink's write count is what rg's standard printer would have
    // tallied — `stats.bytesPrinted` decides whether this mode tallies at all.
    if (o.stats) {
        var st: stats.Stats = .{};
        for (workers) |*wk| st.foldExcept(wk.stats, &.{.bytes_printed});
        st.set(.files_with_match, sink.matched_files);
        st.set(.bytes_printed, stats.bytesPrinted(o, sink.bytes_printed));
        var sbuf: std.ArrayList(u8) = .empty;
        stats.emitStats(gpa, &sbuf, st, search_span.read(io));
        _ = corpus_mod.writeStdout(sbuf.items);
        stats.diagSearch(gpa, o.mode == .json, st, search_span.read(io));
        (Outcome{ .matched = sink.matched_files > 0, .faulted = q.walk_error.load(.acquire) or nothing_searched }).exit();
    }
    // `--files-without-match`: `matched_files` counts files that LACKED the
    // pattern (each `bufferPath` → `emitFilesChunk`), so exit 0 iff at least
    // one such file was found — ripgrep's success predicate for this mode.
    if (re != null and !o.quiet and o.mode != .files and !o.mode.negated() and sink.matched_files == 0 and !nothing_searched and !q.walk_error.load(.acquire))
        hints.noMatches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), null);
    (Outcome{ .matched = sink.matched_files > 0, .faulted = q.walk_error.load(.acquire) or nothing_searched }).exit();
}
