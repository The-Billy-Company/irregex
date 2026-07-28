// MONOLITHIC: rg --json emitter — the begin/match/context/end record sequence plus submatch and replacement encoding share one per-file message-stream state (sibling protocol to output.zig)
//! gist `rg --json` — ripgrep's JSON Lines record stream (ADR-parity output).
//!
//! Split from `run.zig`/`output.zig`: given each file's already-read bytes,
//! this module emits ripgrep's exact `--json` message sequence — one JSON object
//! per line: a `begin` per matched file, a `match`/`context` per emitted line
//! (with byte-accurate `submatches` and, under `-r`, per-match `replacement`),
//! an `end` with that file's stats, and a trailing `summary`. It reuses the one
//! regex engine (`matchSpan` for spans, capture VM for `-r`) and `output`'s
//! shared template expander, so there is no second matcher or replacer.
//!
//! The `stats` timing fields (`elapsed`, `elapsed_total`) carry the run's real
//! monotonic time (threaded in as an `assay.Duration`); inherently
//! non-reproducible, so the differential harness normalizes them on both sides
//! exactly as it already does for `--stats` seconds. `bytes_printed` is real
//! too now — measured from the `begin` mark to just before the `end` record,
//! which is exactly the write count rg's printer has tallied at that point (the
//! fuzzer caught the former fixed-0 placeholder). Every correctness field
//! (`matches`, `matched_lines`, `searches`, `bytes_searched`, and the whole
//! match/submatch structure) is emitted for real.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const binary = @import("../read/binary.zig");
const stats = @import("../read/stats.zig");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const output = @import("output.zig");
const jsonstr = @import("../../../surface/cli/jsonstr.zig");
const ml = @import("multiline.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const simd = @import("../../../kernel/scan/simd.zig");
const Opts = args.Opts;
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Caps = @import("../../../kernel/regex/regex.zig").Caps;

pub const File = struct { path: []const u8, body: []const u8, explicit: bool = false };

/// Running `--json` tallies — the SAME unified counter set the `--stats` block
/// uses (`stats.Stats`, an `assay.Tally`). `pub` because the parallel walk
/// engine (`engine/swarm/`) accumulates one per worker over its streamed
/// per-file records, then folds them for the single trailing `summary`. The JSON
/// summary reads `files_searched`/`files_with_match` under rg's `searches`/
/// `searches_with_match` names, and sums `bytes_printed` from the per-file `end`
/// records (so the worker fold is a plain `fold`, not `foldExcept`).
pub const Stats = stats.Stats;

/// Emit the full `--json` stream for `files` into `out`. Returns the final tally
/// (the caller derives the exit code from `files_with_match` and emits the
/// stderr search diagnostic). `elapsed` fills the trailing `summary` record's
/// timing objects.
pub fn run(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, files: []const File, needle: ?simd.Gate, elapsed: assay.Duration) Stats {
    var ss = Matcher.SpanSim.init(a, re) catch die("engine init failed\n", .{});
    defer ss.deinit();
    var st = Stats{};
    runFiles(a, out, re, &ss, caps, o, files, &st, needle);
    summary(a, out, st, elapsed);
    return st;
}

/// The serial `--json` record loop: stream every file's records into `out`,
/// threading the running `st` (no `summary` — the caller emits it once). Polls
/// the shared output budget between files, exactly the file-boundary truncation
/// `appendBudgeted` reproduces for the parallel shards.
fn runFiles(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, files: []const File, st: *Stats, needle: ?simd.Gate) void {
    for (files) |f| {
        // Bound the record buffer at the output ceiling (corpus.zig) before the
        // next file — the JSON stream, like the serial line path, accumulates
        // before a single flush, so this is the OOM guard for `--json`.
        if (!o.quiet and corpus_mod.outputFull(out.items.len)) break;
        emitOne(a, out, re, ss, caps, o, f, st, needle);
    }
}

/// Emit one file's `--json` records into `out`, tallying into `st` — the per-file
/// core shared by the serial `runFiles` and every parallel shard (`runParallel`),
/// so both encode byte-identically. No budget poll: serial polls between calls,
/// a shard renders its full range and the ordered merge (`appendBudgeted`) is the
/// one place the ceiling applies.
/// `pub`: the parallel walk engine calls this per streamed file (its own arena +
/// per-worker `SpanSim` and running `Stats`), so the walk-emitted `--json` stream
/// is produced by the identical encoder as the serial/shard path.
pub fn emitOne(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, f: File, st: *Stats, needle: ?simd.Gate) void {
    // An empty file is still a search in rg's tally (0 bytes, no records).
    if (f.body.len == 0) {
        st.bump(.files_searched);
        return;
    }
    // Binary model (rg parity, mirrors `binary.handleBinary`):
    //   • implicit (walked) line-mode file — rg's "quit" strategy searches
    //     only the committed prefix (`binary.committedPrefix`): the lines
    //     its buffer had consumed before the fill that read the first NUL.
    //     An empty prefix ⇒ one search, zero bytes, zero records.
    //   • implicit slice-model file (`-U` whose pattern can match `\n`) —
    //     the slice searcher sniffs min(len, 64K): a NUL inside quits
    //     before searching anything; beyond it the file is ordinary text
    //     (binary_offset null).
    //   • explicit path arg — searched in full (line model: NUL doubles as
    //     a line terminator below; slice model: byte_count clamps at the
    //     offset), records emitted, `binary_offset` reported.
    //   • `-a/--text` disables detection entirely.
    var eff = f;
    var bin: ?usize = if (o.text) null else std.mem.indexOfScalar(u8, f.body, 0);
    var searched = f.body.len;
    if (bin) |q| {
        if (ml.sliceModel(re, o)) {
            if (!f.explicit and binary.multilineBinary(f.body.len, q)) {
                st.bump(.files_searched);
                return; // sniff quit: nothing searched, no records
            }
            if (!f.explicit) bin = null else searched = q;
        } else if (!f.explicit) {
            const cut = binary.committedPrefix(f.body, q);
            if (cut == 0) {
                st.bump(.files_searched);
                return;
            }
            eff.body = f.body[0..cut];
            searched = cut;
        }
    }
    st.bump(.files_searched);
    st.add(.bytes_searched, emitFile(a, out, re, ss, caps, o, eff, st, bin, searched, needle));
}

fn fileWeight(_: void, f: File) usize {
    return f.body.len;
}

/// The `--json` record stream, data-parallel over files (the highest-traffic
/// agent/FFI output format). `readCandidates` already read every file's bytes in
/// parallel; this fans the per-file span scan + JSON encode across cores too,
/// mirroring the warm FFI's `streamParallel`: shard the files by byte weight
/// (`shardBounds` → `greedyBounds`, so one huge file can't stall a thread), run
/// the SAME `runFiles` core over each contiguous slice into its own arena buffer
/// with its own span scratch + running `Stats`, then concatenate the buffers in
/// file order and SUM the per-shard stats before the single trailing `summary`.
/// Output is byte-identical to `run`: the shards are contiguous file ranges, the
/// records within each are produced by the same encoder, and per-file stats add.
/// Below `min_bytes`, with one usable core, or under `-r` (whose capture VM
/// carries per-thread scratch a shard can't share) it falls straight through to
/// the serial `run`. `a` is a per-query arena; `gpa` backs each shard's own arena
/// (arenas aren't safe for concurrent allocation).
pub fn runParallel(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, files: []const File, needle: ?simd.Gate, elapsed: assay.Duration) Stats {
    // `GIST_NO_PARALLEL` (the parity-gate idiom, via the shared `assay.serialForced`
    // joint) forces the serial emit so `rgsuite/run.py`'s serial engine pass
    // actually exercises the serial `--json` path — not just the walk — closing
    // the same both-engines gap `swarm.eligible` documents. No production caller sets it.
    if (assay.serialForced()) return run(a, out, re, caps, o, files, needle, elapsed);
    // A single large file: fan the record stream across cores over ITS OWN body
    // (line-aligned shards), the parallelism rg can't apply to one file — the
    // `--json` twin of `serial.emitFileSharded`. Restricted to the plain,
    // line-mode case (no `-r`/context/`-v`/`--max-count`/`-U`); a binary body
    // (a NUL, detected in `soloShard`'s parallel base pass) and every other
    // shape fall through to the file-sharded (or serial) path below.
    if (files.len == 1 and caps == null and !ml.sliceModel(re, o) and !o.invert and
        o.before == 0 and o.after == 0 and o.max_per_file == 0 and files[0].body.len >= parallel.min_bytes)
    {
        if (soloShard(gpa, a, out, re, o, files[0], needle)) |st| {
            summary(a, out, st, elapsed);
            return st;
        }
    }
    const bounds = if (caps != null) null else parallel.shardBounds(File, files, {}, fileWeight, parallel.min_bytes, parallel.max_shards, a);
    const b = bounds orelse return run(a, out, re, caps, o, files, needle, elapsed);
    const nthr = b.len - 1;

    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        files: []const File,
        needle: ?simd.Gate,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        // One entry per file, in order: `marks[j]` = buffer length after file j
        // (the boundary the ordered merge truncates on), `stat_marks[j]` = the
        // running tally through file j. A soft-cap cut at file j takes `buf[0..
        // marks[j]]` and `stat_marks[j]`, so the merged stream AND summary are
        // byte-identical to the serial loop's break-before-next-file.
        marks: std.ArrayList(corpus_mod.Mark) = .empty,
        stat_marks: std.ArrayList(Stats) = .empty,
        st: Stats = .{},

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var ss = Matcher.SpanSim.init(sa, sh.re) catch die("engine init failed\n", .{});
            for (sh.files) |f| {
                emitOne(sa, &sh.buf, sh.re, &ss, null, sh.o, f, &sh.st, sh.needle);
                // A record is content to its last byte: `--json` takes no color
                // and refuses every hyperlink posture, so there is no chrome to
                // discount here the way the rg-shaped merge must.
                sh.marks.append(sa, .plain(sh.buf.items.len)) catch oom();
                sh.stat_marks.append(sa, sh.st) catch oom();
            }
        }
    };

    const shards = a.alloc(Shard, nthr) catch oom();
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .files = files[b[i]..b[i + 1]],
        .needle = needle,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    parallel.fanOut(Shard, shards, threads, Shard.run);

    var st = Stats{};
    for (shards) |*sh| {
        const cut = corpus_mod.appendBudgeted(a, out, sh.buf.items, sh.marks.items, !o.quiet) catch oom();
        // On a soft-cap cut the serial loop breaks before the next file, so this
        // shard contributes only its through-cut tally and no later shard runs.
        const sst = if (cut) |j| sh.stat_marks.items[j] else sh.st;
        st.fold(sst);
        if (cut != null) break;
    }
    summary(a, out, st, elapsed);
    return st;
}

/// Line-aligned shard cuts over `body` (`\n`-terminated boundaries, byte-balanced
/// across cores) — the `--json` twin of `serial.lineShardBounds`. `null` below
/// the shard floor or when fewer than two real shards survive.
fn lineCuts(body: []const u8, a: std.mem.Allocator) ?[]const usize {
    if (body.len < parallel.min_bytes) return null;
    const cores = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@min(cores, body.len / parallel.min_bytes), parallel.max_shards);
    if (nthr < 2) return null;
    const cuts = a.alloc(usize, nthr + 1) catch return null;
    cuts[0] = 0;
    var n: usize = 1;
    var i: usize = 1;
    while (i < nthr) : (i += 1) {
        const approx = body.len / nthr * i;
        const nl = simd.memchr(body, approx, '\n') orelse break;
        const start = nl + 1;
        if (start >= body.len) break;
        if (start > cuts[n - 1]) {
            cuts[n] = start;
            n += 1;
        }
    }
    cuts[n] = body.len;
    n += 1;
    if (n < 3) return null;
    return cuts[0..n];
}

/// Single-file `--json` data parallelism (the win rg leaves on one file). Splits
/// `f`'s body into line-aligned shards, classifies + JSON-encodes each shard's
/// records over the SHARED global body on its own core (global `line_number` via
/// each shard's cumulative-newline base, global `absolute_offset` since offsets
/// are body-relative), then wraps the concatenated records in one `begin`/`end`
/// and returns the summed `Stats`. Byte-identical to the serial `emitFile`: same
/// encoder, same line grid, records folded in line order. `null` ⇒ ineligible
/// (below the shard floor), caller falls through to the serial path.
fn soloShard(gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, o: Opts, f: File, needle: ?simd.Gate) ?Stats {
    const cuts = lineCuts(f.body, a) orelse return null;
    const nthr = cuts.len - 1;

    // Phase 0 — one parallel sweep over the chunks yields each chunk's newline
    // count AND whether it holds a NUL, folding the binary sniff and the line
    // base together (rg pays a single scan; this keeps parity to one, fanned).
    // Prefix-summing the counts gives every shard's global line base; a NUL in a
    // non-`--text` body means "binary" — bail so the caller's path reports it.
    const Count = struct {
        body: []const u8,
        lo: usize,
        hi: usize,
        nl: usize = 0,
        nul: bool = false,
        fn run(c: *@This()) void {
            const r = simd.countByteWithFlag(c.body[c.lo..c.hi], '\n', 0);
            c.nl = r.count;
            c.nul = r.seen;
        }
    };
    const counts = a.alloc(Count, nthr) catch return null;
    for (counts, 0..) |*c, i| c.* = .{ .body = f.body, .lo = cuts[i], .hi = cuts[i + 1] };
    const cthreads = a.alloc(std.Thread, nthr) catch oom();
    parallel.fanOut(Count, counts, cthreads, Count.run);
    const base_ln = a.alloc(usize, nthr) catch return null;
    base_ln[0] = 0;
    for (1..nthr) |i| base_ln[i] = base_ln[i - 1] + counts[i - 1].nl;
    if (!o.text) for (counts) |c| if (c.nul) return null; // binary ⇒ caller reports it

    const Shard = struct {
        re: *const Matcher,
        o: Opts,
        f: File,
        needle: ?simd.Gate,
        lo: usize,
        hi: usize,
        base: usize,
        arena: std.heap.ArenaAllocator,
        buf: std.ArrayList(u8) = .empty,
        fml: usize = 0,
        fm: usize = 0,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var ss = Matcher.SpanSim.init(sa, sh.re) catch die("engine init failed\n", .{});
            soloShardRecords(sa, &sh.buf, sh.re, &ss, sh.o, sh.f, sh.lo, sh.hi, sh.base, sh.needle, &sh.fml, &sh.fm);
        }
    };

    const shards = a.alloc(Shard, nthr) catch return null;
    for (shards, 0..) |*sh, i| sh.* = .{
        .re = re,
        .o = o,
        .f = f,
        .needle = needle,
        .lo = cuts[i],
        .hi = cuts[i + 1],
        .base = base_ln[i],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = a.alloc(std.Thread, nthr) catch oom();
    parallel.fanOut(Shard, shards, threads, Shard.run);

    var fml: usize = 0;
    var fm: usize = 0;
    for (shards) |*sh| {
        fml += sh.fml;
        fm += sh.fm;
    }
    var st = Stats{};
    st.bump(.files_searched);
    st.add(.bytes_searched, f.body.len);
    if (fml == 0) return st; // searched, no match: no begin/end, exit via summary
    st.set(.files_with_match, 1);
    st.set(.matched_lines, fml);
    st.set(.matches, fm);
    if (o.quiet) return st; // --quiet: tally only, suppress the record stream
    const pj = pathData(a, f.path);
    const mark = begin(a, out, pj);
    for (shards) |*sh| out.appendSlice(a, sh.buf.items) catch oom();
    endRecord(a, out, pj, &st, mark, f.body.len, fml, fm, null);
    return st;
}

/// One shard's `--json` records for the global lines in `[lo, hi)` (a line-mode,
/// non-binary, no-context slice), tallying matched lines/spans into `fml`/`fm`.
/// `base` is the shard's global line count so `line_number` stays absolute; byte
/// offsets are already global (the scan is over `f.body`). No `begin`/`end` — the
/// driver wraps the merged stream once.
///
/// Line-free, like `output.Emitter.fileLit`: it NEVER materializes the shard's
/// lines. When a required literal (or a caller `needle`) gates the pattern, one
/// candidate-jump sweep (`indexOfAnyPos`/`Gate.find`) lands only on lines that
/// hold a literal — the sole lines that can match — and each hit's bounds come
/// from a reverse/forward `memchr`; `line_number` is counted incrementally over
/// the inter-hit gap (`countByte`). A literal-free pattern falls back to a
/// streaming per-line walk (still no line array). Either way the record head,
/// `view` (CRLF-trimmed), terminator-inclusive `lines.text`, and submatch
/// offsets are byte-identical to the serial `emitFile`'s plain branch.
fn soloShardRecords(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, f: File, lo: usize, hi: usize, base: usize, needle: ?simd.Gate, fml: *usize, fm: *usize) void {
    const body = f.body;
    const lits = re.lits();
    const jump = needle != null or lits.len != 0; // a hit-to-hit prefilter exists
    const pj = pathData(a, f.path); // path object, encoded once per shard
    var lineno: usize = base; // 0-based line index at `counted`; +1 on emit
    var counted: usize = lo;
    var ml_ct: usize = 0;
    var m_ct: usize = 0;
    var pos: usize = lo;
    while (pos < hi) {
        // Next candidate line start: jump to the next literal/needle hit (skipping
        // every provably non-matching line) and walk back to its line start, or —
        // for a literal-free pattern — take the next line as-is.
        var ls: usize = pos;
        if (jump) {
            const p = (if (needle) |g| g.find(body, pos) else simd.indexOfAnyPos(body, pos, lits)) orelse break;
            if (p >= hi) break;
            ls = if (simd.lastIndexOfScalar(body, p, '\n')) |nl| nl + 1 else 0;
        }
        const le = simd.memchr(body, ls, '\n') orelse body.len;
        const content = body[ls..le];
        const view = if (o.crlf) std.mem.trimEnd(u8, content, "\r") else content;
        const spans = matchSpans(a, re, ss, o, view, le < body.len);
        if (spans.len != 0) { // solo path is non-inverted
            if (!o.quiet) {
                lineno += simd.countByte(body[counted..ls], '\n');
                counted = ls;
                const text_end = if (le < body.len) le + 1 else body.len;
                recordOpen(a, out, "match", pj, body[ls..text_end], lineno + 1, ls);
                emitSubmatches(a, out, null, o, view, spans);
                add(a, out, "]}}\n");
            }
            ml_ct += 1;
            m_ct += spans.len;
        }
        if (le >= body.len) break;
        pos = le + 1;
    }
    fml.* = ml_ct;
    fm.* = m_ct;
}

// `spans` are the line's non-overlapping spans, enumerated ONCE at classification
// and reused for both the `matches` tally and `submatches` emission (no second/
// third engine pass per line). An inverted match line has none by construction; a
// `-v` CONTEXT line does carry them, because rg's JSON paints submatches on every
// record it prints, context included.
const Line = struct { off: usize, view: []const u8, text: []const u8, kind: u8 = 0, spans: []const Matcher.Span = &.{} }; // kind: 0 none,1 ctx,2 match

/// Did this line carry a terminator in the file? `text` is the line AS rg reports
/// it (terminator included), so its last byte answers — and `output.Rows` needs
/// the answer to decide whether the zero-width match at the end of the content
/// exists (it sits before the `\n`, so the file's unterminated tail has none).
fn terminatedLine(o: Opts, ln: Line) bool {
    return ln.text.len != 0 and ln.text[ln.text.len - 1] == o.term();
}

/// Returns the bytes this file actually contributed to `bytes_searched` — the
/// whole body, or, when `-m` stopped the walk, only what rg's searcher read
/// before it quit (the same rule `read/stats.zig`'s `fileMatchStats` applies to
/// the text `--stats` block).
fn emitFile(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, f: File, st: *Stats, bin: ?usize, searched: usize, needle: ?simd.Gate) usize {
    if (ml.sliceModel(re, o)) return emitFileMulti(a, out, re, caps, o, f, st, bin, searched);
    // Split into lines, keeping each line's file offset and its raw text (with the
    // trailing terminator, as ripgrep reports it in `lines.text`). In a binary
    // EXPLICIT file rg's converter treats each NUL as a line terminator too —
    // an implicit body was already cut before its first NUL, so "\n\x00" is
    // safe for every `bin != null` path.
    var lines: std.ArrayList(Line) = .empty;
    var pos: usize = 0;
    while (pos < f.body.len) {
        const nl = if (bin == null) std.mem.indexOfScalarPos(u8, f.body, pos, '\n') else std.mem.indexOfAnyPos(u8, f.body, pos, "\n\x00");
        const content_end = nl orelse f.body.len;
        const text_end = if (nl) |n| n + 1 else f.body.len;
        const content = f.body[pos..content_end];
        // rg's converter REPLACES a terminating NUL with the line terminator in
        // `lines.text` (the match text itself is untouched) — mirror that.
        const text = if (nl != null and f.body[nl.?] == 0) blk: {
            const t = a.alloc(u8, content.len + 1) catch oom();
            @memcpy(t[0..content.len], content);
            t[content.len] = '\n';
            break :blk t;
        } else f.body[pos..text_end];
        lines.append(a, .{ .off = pos, .view = if (o.crlf) std.mem.trimEnd(u8, content, "\r") else content, .text = text }) catch oom();
        if (nl == null) break;
        pos = text_end;
    }

    // Classify: a match line (respecting -v), then paint -A/-B/-C context windows.
    // The classification scan over EVERY line is the `--json` serial-engine
    // hotspot — a line that cannot match skips the NFA entirely. Either the
    // pattern's single required literal (`requiredLiteralGate`) or, for a
    // needle-less pure-literal alternation, the whole-buffer multi-literal
    // prefilter (`litCandidates` — one fused sweep marking candidate lines). Both
    // are sound only when non-inverted (a `-v` match LACKS the literals), so
    // `litCandidates` declines under `o.invert` and `needle` is null there too,
    // leaving the `has == o.invert` classification below unchanged. On a hit we
    // enumerate the line's spans ONCE and cache them for the `matches` tally and
    // `submatches` emission below — no redundant re-run of the engine.
    const cand = litCandidates(a, re, needle, o, f.body, lines.items);
    var file_matches: usize = 0;
    // Index of the line that reached `-m`, once one has: rg stops there but still
    // searches that match's after-context window, and a line inside the window
    // that matches is printed as a MATCH (never a context line) — the record-stream
    // twin of `output/grid.zig`'s `capWindow`. The window does not chain.
    var cap_at: ?usize = null;
    // End offset (terminator included) of the last line printed AS a match — the
    // boundary rg reports as `bytes_searched` when the cap stopped the walk.
    var last_hit_end: usize = 0;
    for (lines.items, 0..) |*ln, i| {
        const gate_ok = if (needle) |g| g.in(ln.view) else if (cand) |c| c[i] else true;
        const spans = if (gate_ok) matchSpans(a, re, ss, o, ln.view, terminatedLine(o, ln.*)) else &.{};
        // Kept on EVERY line, not just a match: rg's JSON paints `submatches` on
        // whatever line it prints, so a `-v` context record (which is by
        // definition a line the pattern matched) carries the pattern's spans.
        ln.spans = spans;
        const has = spans.len > 0;
        if (has == o.invert) continue;
        if (cap_at) |last| {
            if (o.after == 0 or i > last + o.after) break;
        }
        file_matches += 1;
        ln.kind = 2;
        last_hit_end = ln.off + ln.text.len;
        if (o.max_per_file != 0 and file_matches >= o.max_per_file and cap_at == null) cap_at = i;
        // A match found INSIDE the cap's window opens no window of its own, so it
        // paints no context (rg's stream ends at the capping match's window).
        if (cap_at) |last| if (last != i) continue;
        var b: usize = 0;
        while (b < o.before and i >= b + 1) : (b += 1) if (lines.items[i - b - 1].kind == 0) {
            lines.items[i - b - 1].kind = 1;
        };
        var af: usize = 1;
        while (af <= o.after and i + af < lines.items.len) : (af += 1) if (lines.items[i + af].kind == 0) {
            lines.items[i + af].kind = 1;
        };
    }
    if (file_matches == 0) return searched;
    // `-m` quits at the Nth match, so only the bytes through the last printed
    // match were read — unless its after-context window ran off EOF, where the
    // searcher reached the end anyway and rg reports the whole body.
    const eff = if (cap_at) |last| blk: {
        if (o.after != 0 and last + o.after >= lines.items.len) break :blk searched;
        break :blk @min(searched, last_hit_end);
    } else searched;

    const fml = countMatched(o, lines.items);
    const fm = countMatches(lines.items);
    st.bump(.files_with_match);
    st.add(.matched_lines, fml);
    st.add(.matches, fm);
    if (o.quiet) return eff; // --quiet: tally stats, suppress the record stream

    const pj = pathData(a, f.path);
    const mark = begin(a, out, pj);

    for (lines.items, 1..) |ln, lineno| {
        if (ln.kind == 0) continue;
        const is_match = ln.kind == 2;
        recordOpen(a, out, if (is_match) "match" else "context", pj, ln.text, lineno, ln.off);
        emitSubmatches(a, out, caps, o, ln.view, ln.spans);
        add(a, out, "]}}\n");
    }

    endRecord(a, out, pj, st, mark, eff, fml, fm, bin);
    return eff;
}

/// The `--json` record stream under `-U`/`--multiline`: one `match` record per
/// line-contiguous BLOCK of whole-buffer matches (its `lines.text` is the full
/// run of physical lines, `absolute_offset`/`line_number` the block's start, and
/// `submatches` carry block-relative offsets — rg's multiline shape), `context`
/// records for `-A/-B/-C` windows, and an `end` with the file's tallies. Empty
/// matches never form a submatch (rg's JSON only reports real spans). Mirrors
/// `output.Emitter.buffer`'s model via `multiline.zig`, so text and JSON agree.
/// Returns the file's `bytes_searched` — the whole body unless `-m` was actually
/// reached, where rg stops at the Nth match's last line (its after-context window
/// does NOT extend the read here, unlike the line model).
fn emitFileMulti(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, f: File, st: *Stats, bin: ?usize, searched: usize) usize {
    const body = f.body;
    const lines = ml.splitLines(a, body, o.term());
    // Non-empty spans only — a submatch is a real, painted span in rg's JSON.
    var spans: std.ArrayList(ml.Span) = .empty;
    for (ml.collect(a, re, o, body)) |sp| if (sp.end > sp.start) spans.append(a, sp) catch oom();

    if (o.invert) {
        emitFileMultiInvert(a, out, o, f, lines, spans.items, st, bin, searched);
        return searched;
    }
    if (spans.items.len == 0) return searched;

    // Coalesce spans into line-contiguous blocks (rg's `--`-free grouping) —
    // the shared `ml.blocks` sink-block model.
    const blocks = ml.blocks(a, lines, spans.items);

    const fml = ml.countMatchedLines(lines, spans.items);
    const fm = spans.items.len;
    const eff = if (o.max_per_file != 0 and fml >= o.max_per_file)
        @min(searched, lines[blocks[blocks.len - 1].last].term_end)
    else
        searched;
    st.bump(.files_with_match);
    st.add(.matched_lines, fml);
    st.add(.matches, fm);
    if (o.quiet) return eff;

    // Per-line record plan: which block starts here, and which lines are `-A/-B/-C`
    // context (never a covered line).
    const starts = a.alloc(?usize, lines.len) catch oom();
    const covered = a.alloc(bool, lines.len) catch oom();
    const ctx = a.alloc(bool, lines.len) catch oom();
    @memset(starts, null);
    @memset(covered, false);
    @memset(ctx, false);
    for (blocks, 0..) |b, bi| {
        starts[b.first] = bi;
        for (b.first..b.last + 1) |k| covered[k] = true;
    }
    for (blocks) |b| {
        var d: usize = 1;
        while (d <= o.before and b.first >= d) : (d += 1) if (!covered[b.first - d]) {
            ctx[b.first - d] = true;
        };
        d = 1;
        while (d <= o.after and b.last + d < lines.len) : (d += 1) if (!covered[b.last + d]) {
            ctx[b.last + d] = true;
        };
    }

    const pj = pathData(a, f.path);
    const mark = begin(a, out, pj);
    var k: usize = 0;
    while (k < lines.len) {
        if (starts[k]) |bi| {
            const b = blocks[bi];
            matchRecord(a, out, caps, o, pj, lines, body, b.first, b.last, spans.items[b.s0..b.s1]);
            k = b.last + 1;
            continue;
        }
        if (ctx[k]) emitLineRecord(a, out, "context", pj, k + 1, lines[k].start, body[lines[k].start..lines[k].term_end]);
        k += 1;
    }
    endRecord(a, out, pj, st, mark, eff, fml, fm, bin);
    return eff;
}

/// `-v` under `-U --json`: a `match` record (empty submatches) for each physical
/// line NOT covered by any match's line span.
fn emitFileMultiInvert(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, f: File, lines: []const ml.Line, spans: []const ml.Span, st: *Stats, bin: ?usize, searched: usize) void {
    const covered = a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    for (spans) |sp| {
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        for (ml.lineIndexAt(lines, sp.start)..l1 + 1) |c| covered[c] = true;
    }
    var printed: usize = 0;
    for (covered) |c| printed += @intFromBool(!c);
    if (printed == 0) return;
    st.bump(.files_with_match);
    st.add(.matched_lines, printed);
    if (o.quiet) return;
    const pj = pathData(a, f.path);
    const mark = begin(a, out, pj);
    for (lines, 0..) |ln, k| {
        if (covered[k]) continue;
        emitLineRecord(a, out, "match", pj, k + 1, ln.start, f.body[ln.start..ln.term_end]);
    }
    endRecord(a, out, pj, st, mark, searched, printed, 0, bin);
}

/// The `{"type":"<kind>","data":{"path":<path_json>` opener every record shares.
/// `path_json` is the file's `pathData`-cached `{"text":…}`/`{"bytes":…}` object,
/// appended verbatim (no per-record re-validate/re-escape of the repeated path).
fn openData(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path_json: []const u8) void {
    add(a, out, "{\"type\":\"");
    add(a, out, kind);
    add(a, out, "\",\"data\":{\"path\":");
    add(a, out, path_json);
}

/// A line-record head through `"submatches":[` — the caller appends the
/// submatch objects (possibly none) and the `]}}\n` close.
fn recordOpen(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path_json: []const u8, text: []const u8, lineno: usize, off: usize) void {
    openData(a, out, kind, path_json);
    add(a, out, ",\"lines\":");
    jsonData(a, out, text);
    add(a, out, ",\"line_number\":");
    writeUint(a, out, lineno);
    add(a, out, ",\"absolute_offset\":");
    writeUint(a, out, off);
    add(a, out, ",\"submatches\":[");
}

/// Opens a file's record run and returns the buffer mark it started at, so the
/// `end` record can report rg's `bytes_printed`: the bytes this file's `begin` +
/// line records occupy, NOT counting the `end` record itself (rg's printer tallies
/// its write count before encoding the summary object that carries it).
fn begin(a: std.mem.Allocator, out: *std.ArrayList(u8), path_json: []const u8) usize {
    const at = out.items.len;
    openData(a, out, "begin", path_json);
    add(a, out, "}}\n");
    return at;
}

/// A whole-BLOCK `match` record: `lines.text` spans every physical line of the
/// block, submatches carry offsets relative to the block's first-line offset.
fn matchRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, path_json: []const u8, lines: []const ml.Line, body: []const u8, first: usize, last: usize, spans: []const ml.Span) void {
    const base = lines[first].start;
    recordOpen(a, out, "match", path_json, body[base..lines[last].term_end], first + 1, base);
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    for (spans, 0..) |sp, n| submatch(a, out, caps, o, body, sp, base, n, slots);
    add(a, out, "]}}\n");
}

/// A single-line record (`match` with empty submatches for invert, or `context`).
fn emitLineRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path_json: []const u8, lineno: usize, off: usize, text: []const u8) void {
    recordOpen(a, out, kind, path_json, text, lineno, off);
    add(a, out, "]}}\n");
}

/// `mark` is the `begin`-time buffer offset; the printed byte count is measured
/// from it and folded into `st` so the trailing `summary` sums the same field.
fn endRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), path_json: []const u8, st: *Stats, mark: usize, bytes: usize, matched_lines: usize, matches: usize, bin: ?usize) void {
    const printed = out.items.len - mark;
    st.add(.bytes_printed, printed);
    openData(a, out, "end", path_json);
    add(a, out, ",\"binary_offset\":");
    if (bin) |q| writeUint(a, out, q) else add(a, out, "null");
    add(a, out, ",\"stats\":{\"elapsed\":{\"secs\":0,\"nanos\":0,\"human\":\"0.000000s\"},\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":");
    writeUint(a, out, bytes);
    add(a, out, ",\"bytes_printed\":");
    writeUint(a, out, printed);
    add(a, out, ",\"matched_lines\":");
    writeUint(a, out, matched_lines);
    add(a, out, ",\"matches\":");
    writeUint(a, out, matches);
    add(a, out, "}}}\n");
}

/// Emit each non-empty (word-valid) match span on `view` as a submatch object;
/// under `-r` include the expanded `replacement`. Returns the count emitted.
fn emitSubmatches(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, view: []const u8, spans: []const Matcher.Span) void {
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    for (spans, 0..) |sp, n| submatch(a, out, caps, o, view, sp, 0, n, slots);
}

/// One submatch object — `{"match":…[,"replacement":…],"start":…,"end":…}`,
/// comma-prefixed after the first (`n != 0`). Offsets rebase against `base`:
/// 0 for the single-line stream, the block's first-line offset under `-U`.
fn submatch(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, src: []const u8, sp: Matcher.Span, base: usize, n: usize, slots: []isize) void {
    if (n != 0) out.append(a, ',') catch oom();
    add(a, out, "{\"match\":");
    jsonData(a, out, src[sp.start..sp.end]);
    if (o.replace) |tmpl| if (caps) |c| {
        _ = c.find(src, sp.start, slots);
        var rep: std.ArrayList(u8) = .empty;
        output.expandInto(a, c, &rep, tmpl, src, slots);
        add(a, out, ",\"replacement\":");
        jsonData(a, out, rep.items);
    };
    add(a, out, ",\"start\":");
    writeUint(a, out, sp.start - base);
    add(a, out, ",\"end\":");
    writeUint(a, out, sp.end - base);
    add(a, out, "}");
}

/// `pub`: the parallel walk engine emits the single trailing `summary` record
/// after every worker has streamed its files and their tallies are summed. The
/// `elapsed`/`elapsed_total` Duration objects now carry the run's real monotonic
/// time (ripgrep's `{secs, subsec_nanos, human}` decomposition); the parity
/// harness still normalizes these two objects away, so this stays byte-safe.
pub fn summary(a: std.mem.Allocator, out: *std.ArrayList(u8), st: Stats, elapsed: assay.Duration) void {
    const total = elapsed.ns();
    const secs: u64 = @intCast(@divFloor(total, std.time.ns_per_s));
    const sub: u64 = @intCast(@mod(total, std.time.ns_per_s));
    const human = @as(f64, @floatFromInt(total)) / 1e9;
    out.print(a, "{{\"data\":{{\"elapsed_total\":{{\"human\":\"{d:.6}s\",\"nanos\":{d},\"secs\":{d}}},\"stats\":{{\"bytes_printed\":{d},\"bytes_searched\":{d},\"elapsed\":{{\"human\":\"{d:.6}s\",\"nanos\":{d},\"secs\":{d}}},\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ human, sub, secs, st.get(.bytes_printed), st.get(.bytes_searched), human, sub, secs, st.get(.matched_lines), st.get(.matches), st.get(.files_searched), st.get(.files_with_match) }) catch oom();
}

// ─────────────────────────── helpers ───────────────────────────

/// A match line's non-overlapping spans (rg's `submatches`), enumerated once.
/// Returns `&.{}` without allocating on a non-match, so the classification scan
/// over context/non-matching lines stays as cheap as a first-span probe — the
/// engine walks each line exactly once and its spans are cached on the `Line`.
/// Per-line candidate mask for a pure-literal pattern — the `--json` twin of
/// `output.Emitter.litCandidates` (see it for the equivalence/superset proof).
/// ONE fused whole-buffer `indexOfAnyPos` sweep over `body` marks only the lines
/// around literal hits (mapped via each `Line.off`, a forward-only two-pointer),
/// so classification skips ~every non-candidate without an NFA run. Null unless
/// sound & profitable: pure literals, no single needle already gating, and not
/// inverted (a `-v` match LACKS the literals).
fn litCandidates(a: std.mem.Allocator, re: *const Matcher, needle: ?simd.Gate, o: Opts, body: []const u8, lines: []const Line) ?[]const bool {
    if (needle != null or o.invert or lines.len == 0) return null;
    const lits = re.lits();
    if (lits.len == 0) return null;
    const cand = a.alloc(bool, lines.len) catch return null;
    @memset(cand, false);
    var lc: usize = 0;
    var from: usize = 0;
    while (simd.indexOfAnyPos(body, from, lits)) |p| {
        while (lc + 1 < lines.len and lines[lc + 1].off <= p) lc += 1;
        cand[lc] = true;
        if (lc + 1 >= lines.len) break;
        from = lines[lc + 1].off;
    }
    return cand;
}

/// One line's match spans for the record stream — `output.Rows`, the same walk
/// `-o` and `--count-matches` print, so a nullable pattern's zero-width matches
/// become `{"match":{"text":""},…}` submatches and make their line a `match`
/// record, exactly as rg's JSON printer does (measured: `--json -e 'x*'` emits a
/// record per line with one empty submatch per column). The old non-empty-only
/// `nextSpan` walk silently dropped both.
fn matchSpans(a: std.mem.Allocator, re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, view: []const u8, terminated: bool) []const Matcher.Span {
    var rows = output.Rows{ .re = re, .ss = ss, .o = o, .mv = view, .terminated = terminated };
    const first = rows.next() orelse return &.{};
    var list: std.ArrayList(Matcher.Span) = .empty;
    list.append(a, first) catch oom();
    while (rows.next()) |sp| list.append(a, sp) catch oom();
    return list.items;
}

/// A `kind == 2` line is exactly a `matchSpans` hit (classification already ran
/// under the same options), so the matched-lines stat is a plain tally — under
/// `-v` too, where rg counts the inverted lines it emitted as `matched_lines`
/// while `matches` stays 0 (measured: `--json -v -e abc` over a 4-line file with
/// one `abc` reports `matched_lines: 3`, `matches: 0`).
fn countMatched(_: Opts, lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| n += @intFromBool(ln.kind == 2);
    return n;
}

/// Sum of cached per-line spans — no engine re-run. Only a `kind == 2` line's
/// spans are `matches`: every line now caches its spans (a `-v` context record
/// prints them), but rg's `matches` counts only what it printed AS a match, which
/// is 0 for an inverted stream because an inverted match line has no span.
fn countMatches(lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| if (ln.kind == 2) {
        n += ln.spans.len;
    };
    return n;
}

// ─────────────── whole-buffer (-U) JSON — byte-identical vs ripgrep ───────────────
//
// Expected record lines captured from `upstream/ripgrep` (`rg -U --json …`); the
// end/summary timing fields are zeroed on both sides by the differential harness.

/// Reuses `output.zig`'s MlHarness (same compile + caps shape); only the
/// runner differs — route through the `--json` record stream, not the Emitter.
fn runJson(h: *output.MlHarness, o: Opts, body: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    const out = try a.create(std.ArrayList(u8));
    out.* = .empty;
    var opts = o;
    opts.multiline = true;
    opts.mode = .json;
    _ = run(a, out, &h.m, if (h.caps) |*c| c else null, opts, &.{.{ .path = "f.txt", .body = body }}, null, @enumFromInt(0));
    return out.items;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "-U --json record-stream parity table (captured from ripgrep)" {
    const cases = [_]struct { pat: []const u8, o: Opts, body: []const u8, needles: []const []const u8 }{
        // -U --json emits one block match record with block-relative submatches
        .{ .pat = "a\\nb", .o = .{}, .body = "a\nb\nc\n", .needles = &.{
            "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"f.txt\"}}}\n",
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"a\\nb\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]}}\n",
            "\"matched_lines\":2,\"matches\":1",
        } },
        // -U --json coalesces contiguous matches into one record with two submatches
        .{ .pat = "x\\ny", .o = .{}, .body = "x\ny\nx\ny\n", .needles = &.{
            "\"lines\":{\"text\":\"x\\ny\\nx\\ny\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"x\\ny\"},\"start\":0,\"end\":3},{\"match\":{\"text\":\"x\\ny\"},\"start\":4,\"end\":7}]",
        } },
        // -U --json separates blocks with a gap into distinct records
        .{ .pat = "a\\nb", .o = .{}, .body = "a\nb\n\na\nb\n", .needles = &.{
            "\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]",
            "\"line_number\":4,\"absolute_offset\":5,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]",
        } },
        // -U --json context records carry original line numbers and empty submatches
        .{ .pat = "a\\nb", .o = .{ .after = 1 }, .body = "a\nb\nc\n", .needles = &.{
            "{\"type\":\"context\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"c\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n",
        } },
        // -U --json invert emits match records for uncovered lines
        .{ .pat = "a\\nb", .o = .{ .invert = true }, .body = "a\nb\nx\n", .needles = &.{
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"x\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n",
        } },
        // -U --json -r attaches replacement to each submatch
        .{ .pat = "a\\nb", .o = .{ .replace = "Z" }, .body = "a\nb\nc\n", .needles = &.{
            "\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"replacement\":{\"text\":\"Z\"},\"start\":0,\"end\":3}]",
        } },
    };
    for (&cases) |c| {
        var h = try output.MlHarness.init(c.pat, .{ .replace = c.o.replace != null });
        defer h.deinit();
        const s = try runJson(&h, c.o, c.body);
        for (c.needles) |needle| try std.testing.expect(contains(s, needle));
    }
}

/// Append a raw record fragment (OOM is fatal — the CLI contract).
fn add(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(a, s) catch oom();
}

/// Append `v` as decimal — the record stream's `line_number`/`absolute_offset`/
/// `start`/`end` are emitted once PER SUBMATCH, so this hand-rolled writer
/// (digits into a stack buffer, one bulk copy) sheds `std.fmt.format`'s writer
/// vtable + branch overhead on the hottest per-record integers. Byte-identical
/// to `{d}`: a plain unsigned base-10 with no padding or sign.
fn writeUint(a: std.mem.Allocator, out: *std.ArrayList(u8), v: usize) void {
    var buf: [20]u8 = undefined; // ceil(log10(2^64)) = 20 digits
    var i: usize = buf.len;
    var n = v;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    add(a, out, buf[i..]);
}

/// The `{"text":…}`/`{"bytes":…}` data object for a path, encoded ONCE per file.
/// A file's `begin`, every `match`/`context`, and its `end` all repeat the same
/// path; re-running `jsonData` (UTF-8 validation + SIMD escape) for each was
/// pure O(records) waste. Callers pass the returned slice as `path_json`.
fn pathData(a: std.mem.Allocator, path: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    jsonData(a, &b, path);
    return b.items;
}

/// All bytes < 0x80 — a SIMD pre-check that proves valid UTF-8 without the full
/// validator (ASCII ⊂ UTF-8). The overwhelming majority of source lines/paths/
/// match spans are ASCII, so this shaves the per-string validation `jsonData`
/// runs on every record; a high byte falls through to `utf8ValidateSlice`.
fn asciiOnly(s: []const u8) bool {
    const vlen = std.simd.suggestVectorLength(u8) orelse 16;
    const Vec = @Vector(vlen, u8);
    const hi: Vec = @splat(0x80);
    var i: usize = 0;
    while (i + vlen <= s.len) : (i += vlen) {
        const blk: Vec = s[i..][0..vlen].*;
        if (@reduce(.Or, blk >= hi)) return false;
    }
    while (i < s.len) : (i += 1) if (s[i] >= 0x80) return false;
    return true;
}

/// Write one rg JSON data object: `{"text":<escaped>}` when the bytes are valid
/// UTF-8, else `{"bytes":"<base64>"}` — ripgrep's `Data::from_bytes` (jsont.rs).
/// Lines, submatch text, replacements, and paths all take this shape, so a
/// latin-1 or binary-adjacent line degrades to base64 instead of mojibake.
fn jsonData(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    if (asciiOnly(s) or std.unicode.utf8ValidateSlice(s)) {
        add(a, out, "{\"text\":");
        jsonstr.write(out, a, s);
        add(a, out, "}");
        return;
    }
    const enc = std.base64.standard.Encoder;
    const buf = a.alloc(u8, enc.calcSize(s.len)) catch oom();
    add(a, out, "{\"bytes\":\"");
    add(a, out, enc.encode(buf, s));
    add(a, out, "\"}");
}
