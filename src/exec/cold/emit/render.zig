//! One file's result, rendered: the per-file core both emit paths share.
//!
//! `renderFile` is the whole of it — binary decision, line collection, match
//! emission, the `--stats` tally — and it is deliberately the SAME code whether
//! the serial bottom loop calls it once per file or a parallel shard folds a
//! slice of files independently. That is what makes the two paths incapable of
//! drifting: there is no second rendering to keep in sync.
//!
//! Everything a shard must not own stays out: no output-budget break, no
//! `--heading`/`join_groups` group state that would span a shard boundary (the
//! driver gates those onto the serial path). A shard therefore folds its slice
//! into its own arena and the driver merges IN ORDER, so parallel output is
//! byte-identical to serial output — the property the rgsuite differential
//! harness exists to prove.

const std = @import("std");
const portal = @import("../../../portal.zig");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const beacon = @import("../../../surface/cli/beacon.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const captures_mod = @import("../../../kernel/regex/regex.zig");
const binary = @import("../read/binary.zig");
const ingest = @import("../read/ingest.zig");
const intake = @import("../quarry/intake.zig");
const legible = @import("../../../corpus/read/legible.zig");
const ml = @import("multiline.zig");
const output = @import("output.zig");
const par = @import("../../../kernel/math/parallel.zig");
const pcre2 = @import("../../../kernel/regex/regex.zig").pcre2;
const simd = @import("../../../kernel/scan/simd.zig");
const stats = @import("../read/stats.zig");
const verify = @import("../../../kernel/scan/verify.zig");
const writ = @import("../writ/arm.zig");

const Caps = captures_mod.Caps;
const Emitter = output.Emitter;
const InFile = intake.InFile;
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Opts = args.Opts;
const Stats = stats.Stats;
const collectLines = legible.collectLines;
const die = @import("../../../surface/cli/outcome.zig").die;
const visibleBody = ingest.visibleBody;
const compileCaps = writ.compileCaps;
const emitStats = stats.emitStats;
const fileMatchStats = stats.fileMatchStats;
const oom = @import("../../../surface/cli/outcome.zig").oom;

/// Render one file's search result into `em.out` exactly as the serial bottom
/// loop does — the per-file core shared by that loop and every parallel emit
/// shard (`emitSharded`). Threads the running `--stats` tally, the
/// `files_with_match` counter, and the `--heading`/context `first`-group flag
/// through pointers so a shard folds its slice independently and the driver
/// merges. It owns no loop control (no output-budget break — the caller's) and,
/// when the driver has gated `--heading`/`join_groups` onto the serial path,
/// those branches stay inert.
pub fn renderFile(em: *Emitter, f: InFile, stat: *Stats, matched_files: *usize, first: *bool, binary_detect: bool, count_zero: bool, heading: bool, join_groups: bool, show_name: bool) void {
    const a = em.a;
    const o = em.o;
    const re = em.re;
    const out = em.out;
    const body = visibleBody(o.encoding, f.bytes);
    // An empty file has nothing to print, but rg still SEARCHED it: its `--stats`
    // block counts the file and zero bytes (measured — rg says `3 files searched`
    // over two files and an empty one, where we used to say 2).
    if (body.len == 0 and !count_zero) {
        if (o.stats) stat.bump(.files_searched);
        return;
    }
    // Whole-buffer or per-line? `-U` asks for the block model but only a
    // pattern that can eat a `\n` gets it (`ml.sliceModel`) — everything below
    // that reads "am I multiline?" means this, never the bare flag.
    const slice_model = ml.sliceModel(re, o);
    if (binary_detect) if (verify.firstNulWide(a, body)) |nul| {
        if (!(slice_model and !binary.multilineBinary(body.len, nul))) {
            em.base = @intFromPtr(body.ptr);
            em.body_end = em.base + body.len;
            em.way = null;
            if (o.stats) _ = tallyFile(em, f, stat, body, &.{}, nul);
            if (binary.handleBinary(a, re, o, out, em, f.path, f.explicit, body, nul, show_name)) matched_files.* += 1;
            return;
        }
    };
    // The line-free literal fast path (`Emitter.fileLit`) reads `body` directly —
    // a candidate-jump scanner that never materializes the line array — so skip
    // `collectLines` entirely when it's eligible (its guards exclude `--stats`,
    // so the stats block below still collects lines when it needs them).
    const fast = !slice_model and em.litFastEligible();
    // The fused `-c`/`-l` class-run paths answer from the whole buffer —
    // skip the line split they'd never read (`--stats` still needs it).
    const fused = !slice_model and !fast and !o.stats and em.fusedFileEligible();
    var lines: std.ArrayList([]const u8) = .empty;
    if (!slice_model and !fast and !fused) collectLines(a, body, o.term(), &lines);
    if (o.stats) _ = tallyFile(em, f, stat, body, lines.items, null);
    const before = out.items.len;
    // Two separable halves, because rg separates them: heading GROUPS the run
    // (a blank line between file groups) and, if the path is being shown at
    // all, titles each group with it. `-I`/`--no-filename` removes the title
    // and keeps the grouping — `rg --heading -I` over two files still emits the
    // blank line. `--null` terminates the title path like every other place a
    // bare path is printed.
    if (heading) {
        if (!first.*) out.append(a, '\n') catch oom();
        if (show_name) em.heading(f.path);
    }
    const titled = out.items.len;
    em.base = @intFromPtr(body.ptr);
    em.body_end = em.base + body.len;
    em.way = null; // the OSC-8 destination is per-file; rebuilt on first locator
    em.openOn(body); // re-price the gate + sweep anchors on THIS file's bytes
    const hits = if (slice_model) em.buffer(f.path, body) else if (fast) em.fileLit(f.path, body, 0, body.len, 0, true) else em.file(f.path, lines.items);
    // Whether this file OPENS A GROUP is whether it wrote anything, which is
    // not the same question as whether it matched: `--passthru` prints a
    // non-matching file in full, and that group is titled and separated like
    // any other (only the exit code still turns on `hits`). Keying the retract
    // on `hits` instead discarded the passthru body along with its title.
    if (out.items.len > titled) {
        // The gap between two files is a context gap like any other, so it is
        // the same `Opts.groupSep` — inserted back-to-front, both pieces
        // landing at the group's start.
        if (join_groups and !first.* and out.items.len > before) {
            if (o.groupSep()) |s| {
                out.insertSlice(a, before, s[1]) catch oom();
                out.insertSlice(a, before, s[0]) catch oom();
            }
        }
        first.* = false;
    } else if (heading) out.shrinkRetainingCapacity(before);
    if (hits > 0) matched_files.* += 1;
}

pub fn inFileWeight(_: void, f: InFile) usize {
    return f.bytes.len;
}

/// The cold bottom emit loop, data-parallel over `files` (covers `--stats`,
/// `--sort/--sortr`, `-r` replace, `--count`, and plain line output — every
/// mode that lands here after the parallel READ). Precondition: the caller has
/// already gated OUT `--heading`, context `join_groups`, and `--quiet` (their
/// cross-file separator / short-circuit state resists an order-free split), so
/// each file is independent. Shards are CONTIGUOUS file ranges (byte-balanced by
/// `shardBounds`), each rendered by the SAME `renderFile` into its own arena
/// buffer with its own `Emitter`/`Sim`/(replace) `Caps` and running `Stats`;
/// the driver then concatenates the buffers in file order and SUMS the tallies —
/// byte-identical to the serial loop. Merges into the caller's `out`, `stat`,
/// and `matched_files`. `bounds` is the precomputed `shardBounds` result.
pub fn emitSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, o: Opts, eff: []const u8, is_pcre: bool, use_color: bool, line_needle: ?simd.Gate, files: []const InFile, bounds: []const usize, stat: *Stats, matched_files: *usize, binary_detect: bool, count_zero: bool, show_name: bool) void {
    const nthr = bounds.len - 1;
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        eff: []const u8,
        is_pcre: bool,
        use_color: bool,
        needle: ?simd.Gate,
        files: []const InFile,
        binary_detect: bool,
        count_zero: bool,
        show_name: bool,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        // One entry per file, in order: where that file ends and how much of it
        // was content — the boundary the ordered merge (`appendBudgeted`)
        // truncates on so the parallel soft-cap cut lands byte-identical to the
        // serial loop's break, under color and hyperlinks as well as plain.
        marks: std.ArrayList(corpus_mod.Mark) = .empty,
        stat: Stats = .{},
        matched: usize = 0,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var sim: ?Matcher.Sim = Matcher.Sim.init(sa, sh.re) catch null;
            var caps_store: ?Caps = if (sh.o.replace != null) compileCaps(sa, sh.o, sh.eff, sh.is_pcre) else null;
            var em = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = if (sh.o.groups()) false else sh.show_name, .out = &sh.buf, .caps = if (caps_store) |*cp| cp else null, .use_color = sh.use_color, .needle = sh.needle, .sim = if (sim) |*s| s else null };
            var first = true;
            for (sh.files) |f| {
                renderFile(&em, f, &sh.stat, &sh.matched, &first, sh.binary_detect, sh.count_zero, false, false, sh.show_name);
                sh.marks.append(sa, .{ .end = sh.buf.items.len, .content = sh.buf.items.len - em.chrome }) catch oom();
            }
        }
    };

    const shards = a.alloc(Shard, nthr) catch oom();
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .eff = eff,
        .is_pcre = is_pcre,
        .use_color = use_color,
        .needle = line_needle,
        .files = files[bounds[i]..bounds[i + 1]],
        .binary_detect = binary_detect,
        .count_zero = count_zero,
        .show_name = show_name,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);

    // Merge in file order through the one budget-aware concatenation. `--stats`
    // (which searches every file and truncates nothing) merges whole; otherwise
    // the soft cap cuts at the first file crossing the ceiling, and later shards
    // are dropped — the serial loop's early break, reproduced deterministically.
    // `matched_files` only gates the exit code / no-match hint (never emitted
    // bytes), so the cut shard's whole tally is a safe upper bound.
    for (shards) |*sh| {
        stat.foldExcept(sh.stat, &.{.bytes_printed});
        matched_files.* += sh.matched;
        if ((corpus_mod.appendBudgeted(a, out, sh.buf.items, sh.marks.items, !o.stats) catch oom()) != null) break;
    }
}

/// Byte-balanced, LINE-ALIGNED split points over one file's `body` for the
/// single-file fast-path shards. ripgrep is hard-wired single-threaded on one
/// file (`paths.is_one_file ⇒ threads=1`); this is the parallelism it
/// structurally can't use. Each interior boundary is advanced to the next line
/// START (`\n`+1) so every shard owns whole lines and no matching line straddles
/// two shards. Returns `n+1` offsets (`[0]=0`, `[n]=body.len`), or null when the
/// body is below the parallel floor, one core, or collapses to a single range.
pub fn lineShardBounds(body: []const u8, term: u8, a: std.mem.Allocator) ?[]const usize {
    if (body.len < par.min_bytes) return null;
    const cores = portal.cpuCount() catch 1;
    const nthr = @min(@min(cores, body.len / par.min_bytes), par.max_shards);
    if (nthr < 2) return null;
    const cuts = a.alloc(usize, nthr + 1) catch return null;
    cuts[0] = 0;
    var n: usize = 1;
    var i: usize = 1;
    while (i < nthr) : (i += 1) {
        const approx = body.len / nthr * i;
        const nl = simd.memchr(body, approx, term) orelse break; // no terminator ahead → last shard swallows the tail
        const start = nl + 1;
        if (start >= body.len) break;
        if (start > cuts[n - 1]) {
            cuts[n] = start;
            n += 1;
        }
    }
    cuts[n] = body.len;
    n += 1;
    if (n < 3) return null; // fewer than two real shards → keep it serial
    return cuts[0..n];
}

/// Single-file data parallelism for the line-free literal fast path — the win
/// ripgrep leaves on the table for a lone big file. Splits `f`'s body into
/// line-aligned shards (`lineShardBounds`), runs `Emitter.fileLit` on each in
/// parallel over the SHARED global body (so byte offsets, the unterminated tail,
/// and `-n` line numbers via each shard's precomputed base are all global), then
/// merges: emit modes concatenate the shard buffers in line order; count modes
/// SUM the partials and print one `path:N`. Returns false (caller falls back to
/// the serial `renderFile`) when the file is binary, below the shard floor, or
/// otherwise ineligible. Byte-identical to the serial fast path — same
/// `fileLit`, just cut at line boundaries and folded back in order.
pub fn emitFileSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), em: *Emitter, re: *const Matcher, o: Opts, use_color: bool, needle: ?simd.Gate, f: InFile, matched_files: *usize, binary_detect: bool, show_name: bool) bool {
    const body = visibleBody(o.encoding, f.bytes);
    if (body.len == 0) return false;
    // A NUL flips this file onto the binary path (summary/quit-at-NUL) — leave
    // that to the serial `renderFile`, which owns the binary decision.
    if (binary_detect and verify.firstNulWide(gpa, body) != null) return false;
    const cuts = lineShardBounds(body, o.term(), a) orelse return false;
    const nthr = cuts.len - 1;

    // `-n` needs each shard's starting (global) line number: a cumulative newline
    // count over the gaps (one SIMD pass total), paid only when line numbers show.
    const base_ln = a.alloc(usize, nthr) catch return false;
    if (o.line_num) {
        base_ln[0] = 0;
        for (1..nthr) |i| {
            base_ln[i] = base_ln[i - 1] + simd.countByte(body[cuts[i - 1]..cuts[i]], o.term());
        }
    } else @memset(base_ln, 0);

    const counting = o.mode.counting();
    // ONE anchor decision for this document, minted before any shard exists and
    // copied into every shard's Emitter. Minting it inside `fileLit` instead would
    // re-sample the same body once per core, and the sampling budget is priced
    // against a single sample per document.
    const doc_needle = if (needle) |g| g.on(body) else null;
    const doc_lit_plan = Emitter.docLitPlan(o, re, body);
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        use_color: bool,
        needle: ?simd.Gate,
        lit_plan: ?simd.Plan,
        show_name: bool,
        path: []const u8,
        body: []const u8,
        base_addr: usize,
        end_addr: usize,
        lo: usize,
        hi: usize,
        base_lineno: usize,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        n: usize = 0,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var sim: ?Matcher.Sim = Matcher.Sim.init(sa, sh.re) catch null;
            var e = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = sh.show_name, .out = &sh.buf, .use_color = sh.use_color, .needle = sh.needle, .lit_plan = sh.lit_plan, .sim = if (sim) |*s| s else null, .base = sh.base_addr, .body_end = sh.end_addr };
            sh.n = e.fileLit(sh.path, sh.body, sh.lo, sh.hi, sh.base_lineno, false);
        }
    };

    const shards = a.alloc(Shard, nthr) catch return false;
    const base_addr = @intFromPtr(body.ptr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .use_color = use_color,
        .needle = doc_needle,
        .lit_plan = doc_lit_plan,
        .show_name = show_name,
        .path = f.path,
        .body = body,
        .base_addr = base_addr,
        .end_addr = base_addr + body.len,
        .lo = cuts[i],
        .hi = cuts[i + 1],
        .base_lineno = base_ln[i],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);

    var total: usize = 0;
    for (shards) |*sh| total += sh.n;
    if (counting) {
        // One tally line for the whole file (`bufTally` honors `--include-zero`).
        _ = em.bufTally(f.path, total);
    } else {
        for (shards) |*sh| out.appendSlice(a, sh.buf.items) catch oom();
    }
    if (total > 0) matched_files.* += 1;
    return true;
}

/// One file's `--files-without-match` verdict + emit: skip a detected binary,
/// else test whether the pattern appears anywhere (the `-U` whole-buffer tally
/// or the per-line scan) and print the path when it does NOT. `caps` is
/// irrelevant to a boolean hit — replacement text never changes the count — so,
/// like `anyMatch`, the buffer scan passes null: no shared capture VM to race
/// across shards. Shared by the serial loop and every parallel shard so the two
/// can't drift.
///
/// Returns this file's contribution to the RUN's success, which in this mode is
/// rg's inverted predicate — `SummarySink::has_match` is `match_count == 0` for
/// `PathWithoutMatch`, so "found no match" IS the success. That is a different
/// question from "printed a row", and the two part company on exactly one file
/// shape: a walked binary, whose search is abandoned and therefore found nothing
/// (counts) but which rg's printer still refuses to list (no row). Deriving the
/// exit code from the emitted bytes instead made us exit 1 over a binary-only
/// tree where rg exits 0.
pub fn fileWithoutMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, em: *Emitter, lsim: *Matcher.Sim, wssp: ?*Matcher.SpanSim, needle: ?simd.Gate, f: InFile, out: *std.ArrayList(u8)) bool {
    const body = visibleBody(o.encoding, f.bytes);
    // A WALKED NUL-bearing file is dropped: rg's Summary printer never lists it
    // (measured — `rg --files-without-match -e zzz .` over a tree holding a
    // NUL file omits it). An EXPLICIT path arg is rg's "binary explicit"
    // posture, searched whole as text, so it IS listable — the same asymmetry
    // `binary.handleBinary` applies to `-l`. We used to drop both, losing a
    // file rg reports (found by the differential fuzzer).
    //
    // The rule is `renderFile`'s, byte for byte: the first NUL ANYWHERE in the
    // body (rg detects it in whatever buffer it lands in), with `-U`'s clause
    // that a NUL past the sniff window the slice model never reads leaves the
    // file text. This used to ask `corpus.isBinary`, whose 8 KiB window is the
    // INDEX's membership rule, not the searcher's — so a NUL in the tail of a
    // large file went unseen here and we listed a path rg suppresses. The
    // three flags are `writ.binaryDetect` inlined (this file is below writ).
    if (body.len > 0 and !f.explicit and !o.text and !o.binary and !o.null_data) {
        if (verify.firstNulWide(a, body)) |nul| {
            if (!(ml.sliceModel(re, o) and !binary.multilineBinary(body.len, nul))) return true;
        }
    }
    const any = if (ml.sliceModel(re, o)) bufferAnyHit(a, re, o, null, needle, f.path, body) else blk: {
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        // `-v` inverts what counts as a match here too, so a file whose every
        // line FAILS the pattern is a file full of inverted matches — not a
        // file "without match". rg prints nothing and exits 1 for
        // `-v --files-without-match` over a pattern nothing matches.
        for (lines.items) |line| if (lineHit(em, lsim, wssp, needle, line) != o.invert) break :blk true;
        break :blk false;
    };
    // The path IS the row here, exactly as in `-l`, so it is the click target —
    // this mode's whole output is a list of files to go open. No budget applies
    // to `--files-without-match` (see below), so no chrome to account for.
    if (!any) out.print(a, "{s}{s}", .{ beacon.anchor(a, f.path), if (o.null_sep) "\x00" else o.outTerm() }) catch oom();
    return !any;
}

/// One file's `--stats` contribution: rg's `matches` / `matched lines` /
/// `files searched` / `bytes searched`. `nul` is the binary cutoff when detection
/// fired — a WALKED NUL-bearing file only contributes its committed prefix (an
/// explicit path arg contributes the whole body, and under the `-U` slice model
/// nothing at all, which is what rg searches in each case), and the binary caller
/// therefore passes no line array: the bounded prefix is re-split here.
///
/// Extracted so `--files-without-match` can report the same tally it always
/// should have. rg searches a file identically in that mode and prints the same
/// stats block — only the emit differs — but our negated path exited before
/// any tally, printing paths and then NO stats block at all.
/// Returns whether the file contained a match, so a caller that cannot infer it
/// from its own emission (`--files-without-match`, which prints the opposite set)
/// can still keep rg's `N files contained matches` honest.
fn tallyFile(em: *Emitter, f: InFile, stat: *Stats, body: []const u8, lines: []const []const u8, nul: ?usize) bool {
    const a = em.a;
    const o = em.o;
    const slice_model = ml.sliceModel(em.re, o);
    stat.bump(.files_searched);
    var fs: stats.FileStat = undefined;
    var bytes: usize = undefined;
    if (nul) |cut| {
        const searched: []const u8 = if (f.explicit) body else if (slice_model) body[0..0] else body[0..binary.committedPrefix(body, cut)];
        var blines: std.ArrayList([]const u8) = .empty;
        defer blines.deinit(a);
        if (!slice_model) collectLines(a, searched, o.term(), &blines);
        fs = fileMatchStats(em.re, a, o, searched, blines.items, em.needle);
        bytes = if (f.explicit and slice_model) cut else fs.bytes;
    } else {
        fs = fileMatchStats(em.re, a, o, body, lines, em.needle);
        bytes = fs.bytes;
    }
    stat.add(.matches, fs.matches);
    stat.add(.matched_lines, fs.lines);
    stat.add(.bytes_searched, bytes);
    return fs.lines != 0;
}

/// `--files-without-match --stats`: the path emit and the tally, which are
/// independent — the paths rg lists are the files that LACKED the pattern, while
/// the stats block reports the search it ran to find that out. Kept next to
/// `fileWithoutMatch` (and off the sharded fan-out, which owns no `Stats`) so the
/// mode has exactly one tallying caller.
pub fn withoutMatchTallied(a: std.mem.Allocator, re: *const Matcher, o: Opts, em: *Emitter, lsim: *Matcher.Sim, wssp: ?*Matcher.SpanSim, needle: ?simd.Gate, f: InFile, out: *std.ArrayList(u8), stat: *Stats, binary_detect: bool) bool {
    const without = fileWithoutMatch(a, re, o, em, lsim, wssp, needle, f, out);
    const body = visibleBody(o.encoding, f.bytes);
    // An empty file is still a searched file with zero bytes — `renderFile`'s
    // empty arm counts it the same way.
    if (body.len == 0) {
        stat.bump(.files_searched);
        return without;
    }
    const nul = if (binary_detect) verify.firstNulWide(a, body) else null;
    const matched = if (nul != null) tallyFile(em, f, stat, body, &.{}, nul) else blk: {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(a);
        if (!ml.sliceModel(re, o)) collectLines(a, body, o.term(), &lines);
        break :blk tallyFile(em, f, stat, body, lines.items, null);
    };
    if (matched) stat.bump(.files_with_match);
    return without;
}

/// `--files-without-match`, data-parallel over `files`. Each file is independent
/// (a file lacking the pattern prints its path, in file order, with NO output
/// budget — the serial loop has none either), so shards render contiguous ranges
/// through the SAME `fileWithoutMatch` into per-arena buffers with their own
/// boolean `Sim` / (word) `SpanSim` / `Emitter`, then the driver concatenates the
/// buffers in file order — byte-identical to the serial loop. Merges into `out`.
/// Returns the OR of every shard's per-file verdict, the same run-success answer
/// the serial loop folds (see `fileWithoutMatch`) — a shard holding only walked
/// binaries emits nothing yet still carries the run to exit 0.
pub fn filesWithoutSharded(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, o: Opts, needle: ?simd.Gate, files: []const InFile, bounds: []const usize) bool {
    const nthr = bounds.len - 1;
    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        needle: ?simd.Gate,
        files: []const InFile,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        without: bool = false,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var lsim = Matcher.Sim.init(sa, sh.re) catch die("engine init failed\n", .{});
            var wss: ?Matcher.SpanSim = if (sh.o.word) (Matcher.SpanSim.init(sa, sh.re) catch null) else null;
            const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
            var em = Emitter{ .a = sa, .re = sh.re, .o = sh.o, .show_name = false, .out = &sh.buf, .needle = sh.needle };
            for (sh.files) |f| {
                if (fileWithoutMatch(sa, sh.re, sh.o, &em, &lsim, wssp, sh.needle, f, &sh.buf)) sh.without = true;
            }
        }
    };

    const shards = a.alloc(Shard, nthr) catch oom();
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .needle = needle,
        .files = files[bounds[i]..bounds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    par.fanOut(Shard, shards, threads, Shard.run);
    var without = false;
    for (shards) |*sh| {
        out.appendSlice(a, sh.buf.items) catch oom();
        without = without or sh.without;
    }
    return without;
}

/// Mirror ripgrep's exit 2 when a `-P` search tripped a resource limit mid-run
/// (catastrophic backtracking hitting the match/depth limit, a JIT stack
/// overflow): the PCRE2 arm latched the fault and returned a silent no-match to
/// the emitter, so any accumulated stdout is flushed first (earlier files'
/// genuine matches, exactly as rg leaves them) and then the run exits 2 rather
/// than reporting a bogus no-match. A no-op for the linear engine (always 0).
/// `pub`: the parallel engine folds the same process-global latch into its own
/// exit through this one renderer, so the two engines' fault text can't drift.
pub fn pcreFaultExit(re: *const Matcher) void {
    if (re.matchError() == 0) return;
    var buf: [256]u8 = undefined;
    assay.diag("gist: PCRE2: error matching: {s}\n", .{pcre2.matchErrorMessage(&buf)});
    std.process.exit(2);
}

/// One line's match verdict — the CRLF trim, the required-literal SIMD gate,
/// then the `-w`-aware word hit or the plain engine hit (the same wss-gated
/// classify the per-line emit path applies): shared by --files-without-match
/// and the -q/--quiet scan so the two can't drift. Inline: it sits in those
/// modes' per-line loops.
inline fn lineHit(em: *Emitter, sim: *Matcher.Sim, wss: ?*Matcher.SpanSim, needle: ?simd.Gate, line: []const u8) bool {
    const mv = if (em.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    return (needle == null or needle.?.in(mv)) and (if (wss) |s| em.lineHitWord(s, mv) else em.re.lineMatch(sim, mv));
}

/// `-U` whole-buffer boolean: render into a throwaway buffer and reuse the
/// multiline emitter's tally (invert/word/zero-width baked in). Shared by the
/// --files-without-match and -q/--quiet scans so the two can't drift.
pub fn bufferAnyHit(a: std.mem.Allocator, re: *const Matcher, o: Opts, caps: ?*Caps, needle: ?simd.Gate, path: []const u8, body: []const u8) bool {
    var scratch: std.ArrayList(u8) = .empty;
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = &scratch, .base = @intFromPtr(body.ptr), .caps = caps, .needle = needle };
    return em.buffer(path, body) > 0;
}

/// `-q/--quiet`: true as soon as any file matches (short-circuits). Under `-U` the
/// whole-buffer emitter's tally (invert/word/zero-width baked in) is the boolean;
/// otherwise the per-line scan against the (possibly inverted) line selection.
pub fn anyMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, needle: ?simd.Gate, files: []const InFile) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    const wssp: ?*Matcher.SpanSim = if (wss) |*s| s else null;
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    // Pure-literal presence short-circuit (`-q`'s early-exit twin of `-l`): a
    // literal carries no terminator, so it always lands inside some line, and
    // `litFastEligible` guarantees that line matches — hence a match EXISTS iff
    // any literal occurs. One `indexOfAnyPos` sweep stops at the first hit
    // instead of materializing every line of a huge body (the `collectLines`
    // tail that made `-q` scan the whole file). `-v` is excluded by eligibility.
    const slice_model = ml.sliceModel(re, o);
    const lit_fast = !slice_model and em.litFastEligible();
    const lits = re.lits();
    for (files) |f| {
        const body = visibleBody(o.encoding, f.bytes);
        if (body.len == 0 or (corpus_mod.isBinary(body) and !o.text and !o.binary)) continue;
        if (lit_fast) {
            // A whole-buffer sweep that stops at the first hit, so it is exactly the
            // shape the anchor pair governs and it gets this file's own decision
            // rather than the shipped table's — measured 4.5x on a 200 MB body whose
            // local alphabet inverts the table. Once per file, which is the grain
            // `docLitPlan`'s size gate is priced against.
            if (simd.indexOfAnyPosWith(body, 0, lits, Emitter.docLitPlan(o, re, body)) != null) return true;
            continue;
        }
        if (slice_model) {
            if (bufferAnyHit(a, re, o, null, needle, f.path, body)) return true;
            continue;
        }
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        for (lines.items) |line| if (lineHit(&em, &sim, wssp, needle, line) != o.invert) return true;
    }
    return false;
}

const Regex = captures_mod.Regex;

test "--files-without-match: an unlistable binary still answers `found no match`" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "zzz") };
    defer m.deinit();
    const o = Opts{ .mode = .files_without_match };
    // The per-file arena every real caller hands in (serial loop and shard
    // alike): line collection and the printed path are freed in one drop.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var lsim = try Matcher.Sim.init(a, &m);
    var em = Emitter{ .a = a, .re = &m, .o = o, .show_name = false, .out = &out };

    // A walked NUL-bearing file. rg's Summary printer refuses to list it, so no
    // path may reach `out` — yet the search it abandoned found no match, and
    // `SummarySink::has_match` for this mode is `match_count == 0`, so the file
    // still carries the run to exit 0. Reading the exit code off the printed
    // bytes instead made us exit 1 over a binary-only tree where rg exits 0.
    const bin = InFile{ .path = "bin.dat", .scope = ".", .bytes = "head\n\x00\x01 buried\n" };
    try t.expect(fileWithoutMatch(a, &m, o, &em, &lsim, null, null, bin, &out));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // A text file lacking the pattern is the listable half of the same verdict.
    const txt = InFile{ .path = "a.txt", .scope = ".", .bytes = "nothing here\n" };
    try t.expect(fileWithoutMatch(a, &m, o, &em, &lsim, null, null, txt, &out));
    try t.expect(std.mem.indexOf(u8, out.items, "a.txt") != null);

    // A file that HAS the pattern is the only `false`: no row, and nothing
    // toward the exit code either.
    out.clearRetainingCapacity();
    const hit = InFile{ .path = "b.txt", .scope = ".", .bytes = "zzz\n" };
    try t.expect(!fileWithoutMatch(a, &m, o, &em, &lsim, null, null, hit, &out));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // A NUL in the TAIL, past the 8 KiB window the index's membership rule
    // looks at. rg reads the file buffer by buffer and detects it wherever it
    // lands, so it lists nothing; we asked `corpus.isBinary` here, saw a
    // clean first 8 KiB, and printed a path rg suppresses (`rg
    // --files-without-match -e generated .` over a 140 KB file ending in a NUL:
    // rg omits it, we listed it). The searcher's rule is the whole body.
    out.clearRetainingCapacity();
    const tail = try std.mem.concat(a, u8, &.{ "line of text\n" ** 1024, "\x00 buried\n" });
    try t.expect(corpus_mod.binary_window < tail.len - 10); // the window really is passed
    const late = InFile{ .path = "late.dat", .scope = ".", .bytes = tail };
    try t.expect(fileWithoutMatch(a, &m, o, &em, &lsim, null, null, late, &out));
    try t.expectEqual(@as(usize, 0), out.items.len);
}
