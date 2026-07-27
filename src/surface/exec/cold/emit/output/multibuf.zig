//! gist `rg` — the whole-buffer (`-U`/`--multiline`) emit path.
//!
//! Split from `output.zig`: the multiline twin of `grid.zig`. A `-U` match may
//! cross `\n`, so there is no "the matching line" — rg prints the whole run of
//! lines a match covers, coalesces line-contiguous matches into one `--`-free
//! block, and measures `-o` columns against that block. `buffer` dispatches to
//! the mode-specific renderer; each `buf*` sibling is one output mode.
//!
//! The pure span/line MODEL (progress rule, block grid, counts) deliberately
//! lives one level up in `../multiline.zig`, shared with the `--json` record
//! stream, so text and JSON cannot drift on what matched.

const std = @import("std");
const args = @import("../../argv/args.zig");
const Opts = args.Opts;
const oom = args.oom;
const palette = @import("../color.zig");
const ml = @import("../multiline.zig");
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
const Regex = @import("../../../../../kernel/match/regex/regex.zig").Regex;
const captures_mod = @import("../../../../../kernel/match/regex/regex.zig");
const Caps = captures_mod.Caps;
const Captures = captures_mod.Captures;
const output = @import("../output.zig");
const Emitter = output.Emitter;
const display = @import("display.zig");
const replace = @import("replace.zig");

/// Whole-buffer (`-U`/`--multiline`) emit path — the multiline twin of
/// `file`. The caller selects it when `self.re.multiline()`; `body` is the
/// file's bytes (BOM already stripped, `base` set to `@intFromPtr(body.ptr)`
/// so offsets read out file-relative). A multiline match may cross `\n`; rg
/// prints the whole run of lines a match covers, coalesces line-contiguous
/// matches into one `--`-free block, and measures `-o` columns against the
/// block. This dispatcher routes to the mode-specific renderer; the pure
/// span/line model (progress rule, block grid, counts) lives in
/// `multiline.zig` so this and `--json` cannot drift on what matches.
///
/// Returns the count that drives the exit code and `-c`: rg's multiline
/// "matching lines" (distinct match-start lines) for the frame modes, the
/// printed-line count for `-v`, the emitted-match count for `-o`, the tally
/// for the count modes. Zero ⇒ no output was written for this file.
pub fn buffer(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    // `-l` needs only "does one kept span exist" — never walk every match
    // in the buffer. When the whole-buffer boolean provably equals the emit
    // model's verdict (`bufBoolExact`), one `bufMatch` run answers (the
    // assertion-free class rides the multiline DFA at O(1)/byte); `-w`
    // reshapes spans and `--crlf` matches a rewritten view, so both keep
    // the span path — capped at the FIRST kept span instead of all of them.
    if (o.mode == .files_with_matches and !o.invert) {
        if (!o.word and !o.crlf and self.re.bufBoolExact()) {
            var local_sim: ?Matcher.Sim = if (self.sim == null) (Matcher.Sim.init(self.a, self.re) catch return 0) else null;
            defer if (local_sim) |*s| s.deinit();
            const sim = self.sim orelse &local_sim.?;
            return if (self.re.bufMatch(sim, body)) self.emitPathOnly(path) else 0;
        }
        var first = o;
        first.max_per_file = 1;
        return if (collectSpans(self, first, body).len == 0) 0 else self.emitPathOnly(path);
    }
    const spans = collectSpans(self, o, body);
    // `--count-matches` tallies every match span, empties included (`-c -o`
    // resolved to this mode back in argv — `answer.Mode.settle`).
    if (o.mode == .count_matches) return self.bufTally(path, ml.countAll(spans));
    // Passthru prints every line, so an inverted run still has a full file to
    // render and the block frames below — which widen a context window around a
    // block that MATCHED — have nothing to widen.
    if (o.invert) return if (o.passthru and o.mode.frames()) bufPassthru(self, path, body) else bufInvert(self, path, body);
    // `--count` (matching lines) is emitted before the empty-spans short
    // circuit so `--include-zero` can still print a `path:0` line.
    if (o.mode == .count) return self.bufTally(path, ml.countStartLines(ml.splitLines(self.a, body, o.term()), spans));
    // The same gap at the other end: with no span there is no block, and the
    // frames below would print nothing where passthru owes the whole file.
    if (spans.len == 0) return if (o.passthru and o.mode.frames()) bufPassthru(self, path, body) else 0;
    const lines = ml.splitLines(self.a, body, o.term());
    if (o.mode == .files_with_matches) return self.emitPathOnly(path);
    if (o.only_matching) return if (o.replace != null) bufOnlyRepl(self, path, lines, spans, body) else bufOnly(self, path, lines, spans, body);
    // `--vimgrep` is a row shape, not a mode, so whichever block frame owns the
    // text applies it and keeps its own context windows and `-m` accounting.
    // Under `-r` that is the REPLACE frame, because rg's rows are measured
    // against the replaced block re-split into lines (rg #1311), not against
    // the original ones — a match spanning three lines collapses its rows onto
    // the one replaced line its substitution lands on.
    if (o.replace != null) return bufReplaceBlocks(self, path, lines, spans, body);
    return bufBlocks(self, path, lines, spans, body);
}

/// Whole-buffer span collection honoring the `--crlf` match view: matching
/// runs against `body` with every `\r` that directly precedes a `\n`
/// removed, so `^`/`$` (and `-w` bounds) anchor at the LOGICAL line ends —
/// rg's CRLF-aware regex (`Sherlock$` must match `…Sherlock\r\n`). Returned
/// spans are remapped to ORIGINAL byte offsets; a span never contains a
/// removed `\r` (it wasn't in the view), so a match ending at a logical
/// line end maps to just before the `\r`. Plain bodies pay nothing.
fn collectSpans(self: *Emitter, o: Opts, body: []const u8) []ml.Span {
    if (!self.o.crlf or body.len > std.math.maxInt(u32) or
        std.mem.indexOf(u8, body, "\r\n") == null)
        return ml.collect(self.a, self.re, o, body);
    const view = self.a.alloc(u8, body.len) catch oom();
    const origin = self.a.alloc(u32, body.len) catch oom();
    var vlen: usize = 0;
    for (body, 0..) |c, i| {
        if (c == '\r' and i + 1 < body.len and body[i + 1] == '\n') continue;
        view[vlen] = c;
        origin[vlen] = @intCast(i);
        vlen += 1;
    }
    const spans = ml.collect(self.a, self.re, o, view[0..vlen]);
    for (spans) |*sp| {
        const s = origin[sp.start];
        sp.end = if (sp.end > sp.start) origin[sp.end - 1] + 1 else s;
        sp.start = s;
    }
    return spans;
}

/// `-v` under `-U`: emit each physical line NOT covered by any match's line
/// span, framed as a match (`:`) with its own line number — rg's multiline
/// invert. Honors `-m` as a cap on printed lines. Returns that count.
fn bufInvert(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    const lines = ml.splitLines(self.a, body, o.term());
    const covered = self.a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    // Coverage needs EVERY match (no `-m` cap); `-m` bounds only the printed
    // inverted lines below. `collect` reads only `-w` from these opts.
    for (collectSpans(self, .{ .word = o.word }, body)) |sp| {
        const l0 = ml.lineIndexAt(lines, sp.start);
        for (l0..ml.lineIndexAt(lines, ml.spanLast(sp)) + 1) |li| covered[li] = true;
    }
    var printed: usize = 0;
    for (lines, 0..) |ln, k| {
        if (covered[k]) continue;
        self.prefix(path, k + 1, 0, ln.start, true);
        display.text(self, body[ln.start..ln.content_end], false);
        printed += 1;
        if (o.max_per_file != 0 and printed >= o.max_per_file) break;
    }
    return printed;
}

/// `--passthru` under `-U`, for the two runs the block frames cannot serve: an
/// INVERTED verdict, and a file with no match at all. Both leave `ml.blocks`
/// empty, and `bufBlocks`/`bufReplaceBlocks` express passthru as a context
/// window of infinite width — which needs a block to widen. Everywhere else
/// passthru already belongs to those frames, and must stay there: they are what
/// knows `-r`, `-o`, and `--vimgrep` under `-U`.
///
/// Every physical line prints, framed as a match when a span touches it — so a
/// match crossing three lines marks all three, where the per-line model can
/// only ever mark one. Returns the matching-line count for the exit code;
/// output is written whether or not anything matched.
fn bufPassthru(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    const lines = ml.splitLines(self.a, body, o.term());
    const covered = self.a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    // What `-m` counts here is LINE BLOCKS — a match widened to whole lines,
    // with any further match landing on a line already covered folded into it.
    // That is the unit rg's multiline searcher reports, and it explains both
    // ends: two matches on one line are one block (`-m2` over `aa` reaches the
    // second matching LINE), while one match crossing two lines is also one
    // block and marks both (`-m1` keeps all of it). Counting raw spans gets the
    // first case wrong; counting marked lines gets the second wrong.
    var kept: usize = 0;
    var last: ?usize = null;
    for (collectSpans(self, .{ .word = o.word }, body)) |sp| {
        const l0 = ml.lineIndexAt(lines, sp.start);
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        if (last == null or l0 > last.?) {
            if (o.max_per_file != 0 and kept >= o.max_per_file) break;
            kept += 1;
        }
        for (l0..l1 + 1) |li| covered[li] = true;
        last = if (last) |lv| @max(lv, l1) else l1;
    }
    var matched: usize = 0;
    for (lines, 0..) |ln, k| {
        const is_m = covered[k] != o.invert;
        if (is_m) matched += 1;
        self.prefix(path, k + 1, 0, ln.start, is_m);
        display.text(self, body[ln.start..ln.content_end], false);
    }
    return matched;
}

/// `-o` under `-U`: for each match, emit its per-line fragment(s). Column and
/// byte offset are the MATCH's start (column measured against its block's
/// first line, offset absolute), repeated on every fragment line — rg's
/// multiline only-matching frame. Two rg parity rules govern which fragments
/// print: a BLANK line covered by a span emits nothing (rg's printer guards
/// its emit loop with `while !line.is_empty()` after trimming the
/// terminator), and a lone zero-width match sitting exactly at a line start
/// emits nothing (rg treats it as a consumed gap — `^` produces no `-o`
/// output). A zero-width match that shares its line with another match, or
/// sits past the line start, still prints its empty fragment (`x?`, `a*`).
fn bufOnly(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const bases = ml.blockBases(self.a, lines, spans);
    for (spans, 0..) |sp, si| {
        const l0 = ml.lineIndexAt(lines, sp.start);
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        const col = 1 + (sp.start - bases[si]);
        // A zero-width span is "lone" on its start line when no sibling span
        // starts there (spans are ascending, so same-line spans are a run).
        const lone = (si == 0 or ml.lineIndexAt(lines, spans[si - 1].start) != l0) and
            (si + 1 == spans.len or ml.lineIndexAt(lines, spans[si + 1].start) != l0);
        for (l0..l1 + 1) |li| {
            const ln = lines[li];
            if (ln.content_end == ln.start) continue; // blank line: rg emits nothing
            var fs = @max(sp.start, ln.start);
            var fe = @min(sp.end, ln.content_end);
            if (fe == fs and fs == ln.start and lone) continue; // lone `^`-style empty at line start
            // --trim: rg trims the LINE's blank prefix before intersecting it
            // with the match, so a fragment starts no earlier than the trimmed
            // line start; a non-empty fragment swallowed whole by the trim
            // emits nothing (rg advances past it). Columns are unaffected.
            if (self.o.trim and fe > fs) {
                const ts = ln.start + display.blankPrefix(body[ln.start..ln.content_end]);
                if (fe <= ts) continue;
                fs = @max(fs, ts);
            }
            // --crlf: every `-o` line below ends with the full `\r\n`
            // terminator, so a fragment reaching a terminated dos line's
            // content end sheds the `\r` it covered (content_end keeps it)
            // instead of doubling it — rg emits `frag\r\n`, never `\r\r\n`.
            if (self.o.crlf and fe == ln.content_end and ln.term_end > ln.content_end and fe > fs and body[fe - 1] == '\r') fe -= 1;
            self.prefix(path, li + 1, col, sp.start, true);
            const frag = body[fs..fe];
            // -M/--max-columns on the fragment. `-o` always has match
            // granularity, and no OTHER match can start inside this
            // fragment's truncated tail (spans are non-overlapping), so the
            // preview placeholder is always ` [... 0 more matches]` and the
            // plain one `[Omitted long matching line]` — pass one span at
            // the fragment start to select that granularity.
            if (self.o.max_cols != 0 and frag.len > self.o.max_cols) {
                display.exceeded(self, frag, true, &.{0});
            } else {
                self.paint(palette.match_on, frag);
            }
            self.add(self.o.outTerm());
        }
    }
    return spans.len;
}

/// `-o -r` under `-U`: emit each match's expanded template ONCE, prefixed
/// with its start line — rg replaces the whole (cross-line) match and prints
/// the substitution as a unit, so the template's own newlines split it.
fn bufOnlyRepl(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const caps = self.caps orelse return 0;
    const tmpl = self.o.replace.?;
    const slots = self.a.alloc(isize, caps.nslots()) catch oom();
    for (spans) |sp| {
        _ = caps.find(body, sp.start, slots);
        const li = ml.lineIndexAt(lines, sp.start);
        self.prefix(path, li + 1, 1 + (sp.start - lines[li].start), sp.start, true);
        replace.expand(self, self.out, tmpl, body, slots);
        self.add(self.o.outTerm()); // expanded text carries no terminator
    }
    return spans.len;
}

/// Where a printed line's `--vimgrep` spans come from under `-U`: the matches
/// that OPEN on it, which is rg's `per_match_one_line` ("vimgrep really only
/// wants one line per match, even when a match spans multiple lines", rg
/// #1866) — a continuation line opens none and so prints nothing at all. An
/// empty span contributes no row (parity with the single-line frame).
/// `display.vimgrepLine` owns the row shape (shared with `grid`'s provenance).
fn vimgrepRows(self: *Emitter, path: []const u8, ln: ml.Line, lineno: usize, run: []const ml.Span, body: []const u8) void {
    var starts: std.ArrayList(usize) = .empty;
    for (run) |sp| if (sp.end != sp.start) starts.append(self.a, sp.start - ln.start) catch oom();
    display.vimgrepLine(self, .{
        .path = path,
        .lineno = lineno,
        .text = body[ln.start..ln.content_end],
        .off = ln.start,
        .starts = starts.items,
        .terminated = ln.term_end > ln.content_end,
        .off_of = .line, // a block sink reports the printed line's offset
    });
}

/// The default `-U` frame: print each line a match covers (once, deduped
/// across overlapping matches), with `-A/-B/-C` context windows and the
/// same `--`-group coalescing as the per-line `file` path. `--passthru`
/// widens every window to the whole file (rg's "context of infinity").
fn bufBlocks(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const o = self.o;
    const n = lines.len;
    const is_match = self.a.alloc(bool, n) catch oom();
    const col = self.a.alloc(usize, n) catch oom();
    @memset(is_match, false);
    @memset(col, 0);
    // Under `--vimgrep` a row belongs to a MATCH, not to a covered line, so the
    // frame also needs the spans that START on each line: `run[k]` is the half-
    // open slice of `spans` opening there (they are start-ordered, so it is
    // contiguous). A continuation line of a multi-line match opens none, which
    // is exactly why it prints nothing at all — not even as context.
    const run = self.a.alloc([2]u32, if (o.vimgrep) n else 0) catch oom();
    @memset(run, .{ 0, 0 });
    for (spans, 0..) |sp, si| {
        const l0 = ml.lineIndexAt(lines, sp.start);
        const c = 1 + (sp.start - lines[l0].start);
        if (o.vimgrep) {
            if (run[l0][1] == run[l0][0]) run[l0][0] = @intCast(si);
            run[l0][1] = @intCast(si + 1);
        }
        for (l0..ml.lineIndexAt(lines, ml.spanLast(sp)) + 1) |li| if (!is_match[li]) {
            is_match[li] = true;
            col[li] = c;
        };
    }
    var idx: std.ArrayList(usize) = .empty;
    for (0..n) |k| if (is_match[k]) idx.append(self.a, k) catch oom();

    const B = if (o.passthru) n else o.before;
    const A = if (o.passthru) n else o.after;
    var prev_end: ?usize = null;
    for (idx.items) |m| {
        const hi = @min(m + A, n - 1);
        var k = self.windowStart(m -| B, hi, &prev_end) orelse continue;
        while (k <= hi) : (k += 1) {
            const is_m = is_match[k];
            if (o.vimgrep and is_m) {
                vimgrepRows(self, path, lines[k], k + 1, spans[run[k][0]..run[k][1]], body);
                continue;
            }
            self.row(path, k + 1, if (is_m) col[k] else 0, lines[k].start, body[lines[k].start..lines[k].content_end], is_m);
        }
    }
    return idx.items.len;
}

/// `-U -r` — rg's actual replacement model (rg #1311): the searcher
/// coalesces matches whose covered lines overlap or are ADJACENT into one
/// sink block; the printer replaces every match within the block while
/// PRESERVING the block's non-matching bytes, then re-splits the REPLACED
/// text into physical lines numbered from the block's first original line.
/// Context lines around a block keep their original text and numbers;
/// `--passthru` widens the window to the whole file. Supersedes a per-span
/// emit that dropped the surrounding text of the matched lines.
fn bufReplaceBlocks(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const o = self.o;
    const caps = self.caps orelse return 0;
    const tmpl = o.replace.?;
    const slots = self.a.alloc(isize, caps.nslots()) catch oom();
    const n = lines.len;
    const B = if (o.passthru) n else o.before;
    const A = if (o.passthru) n else o.after;
    // The searcher blocks: spans whose covered lines overlap or are
    // adjacent join into one sink block (glue.rs `last_match.end() >=
    // line.start()`) — the shared `ml.blocks` grouping.
    const bs = ml.blocks(self.a, lines, spans);
    var covered: usize = 0;
    var prev_end: ?usize = null;
    for (bs, 0..) |b, bi| {
        covered += b.last - b.first + 1;
        // Context window over the ORIGINAL grid. After-context never
        // reaches the next block's first line — the searcher sinks that
        // line as a match, so context stops short of it.
        const lo = b.first -| B;
        var hi = @min(b.last + A, n - 1);
        if (bi + 1 < bs.len) hi = @min(hi, bs[bi + 1].first - 1);
        var start = lo;
        if (prev_end) |pe| {
            if (lo > pe + 1) {
                if (o.wantsContext()) self.groupSep();
            } else start = @max(start, pe + 1);
        }
        self.ctxRows(path, lines, body, start, b.first);
        // Build the replaced block: each span expands its template, every
        // other byte (including the trailing terminator) copies verbatim.
        var buf: std.ArrayList(u8) = .empty;
        var starts: std.ArrayList(usize) = .empty;
        var cursor = lines[b.first].start;
        for (spans[b.s0..b.s1]) |sp| {
            buf.appendSlice(self.a, body[cursor..sp.start]) catch oom();
            starts.append(self.a, buf.items.len) catch oom();
            _ = caps.find(body, sp.start, slots);
            replace.expand(self, &buf, tmpl, body, slots);
            cursor = @max(cursor, sp.end);
        }
        buf.appendSlice(self.a, body[cursor..lines[b.last].term_end]) catch oom();
        emitReplacedBlock(self, path, b.first, lines[b.first].start, buf.items, starts.items);
        self.ctxRows(path, lines, body, b.last + 1, hi + 1);
        prev_end = hi;
    }
    return covered;
}

/// Emit one replaced block's text as physical lines numbered from original
/// line `blo` (0-based). rg's frame: every line is a match line, the column
/// (under `--column`) is the FIRST replacement's block-relative offset on
/// every line, and `--trim`/`-M` apply per emitted line with the
/// replacement `starts` as the match granularity.
///
/// `--vimgrep` re-cuts the same text into one row per replacement instead:
/// a replaced line that no substitution BEGINS on prints nothing at all
/// (rg's per-match rule — the tail lines of a multi-line substitution are
/// not rows of their own, and not context either).
fn emitReplacedBlock(self: *Emitter, path: []const u8, blo: usize, block_off: usize, rep: []const u8, starts: []const usize) void {
    const term = self.o.term();
    const col = if (starts.len > 0) starts[0] + 1 else 0;
    var lineno = blo + 1;
    var pos: usize = 0;
    while (pos < rep.len) {
        const nl = std.mem.indexOfScalarPos(u8, rep, pos, term);
        const end = nl orelse rep.len;
        // Rebase the replacement starts into this line's coordinates; a
        // start on an earlier line clamps to 0 (before any `-M` cut, like
        // rg's block-coordinate comparison), later ones drop off the tail.
        // `--vimgrep` wants the stricter set — the ones OPENING here.
        var line_starts: std.ArrayList(usize) = .empty;
        for (starts) |st| {
            if (st >= end) break;
            if (!self.o.vimgrep or st >= pos) line_starts.append(self.a, st -| pos) catch oom();
        }
        if (self.o.vimgrep) {
            display.vimgrepLine(self, .{
                .path = path,
                .lineno = lineno,
                .text = rep[pos..end],
                .off = block_off + pos,
                .starts = line_starts.items,
                .terminated = nl != null,
                .off_of = .line,
            });
        } else {
            self.prefix(path, lineno, col, block_off + pos, true);
            // A split found a term byte ⇒ this physical line was terminated in
            // the (replaced) block; only the final unsplit tail can lack one.
            display.emitBody(self, rep[pos..end], true, line_starts.items, nl != null);
        }
        if (nl == null) break;
        pos = end + 1;
        lineno += 1;
    }
}

/// The `-U` parity harness: compile a pattern in multiline mode (plus the
/// optional capture program `-r` needs) and run the whole-buffer emit over a
/// body, returning the exact bytes. `pub` across two file boundaries —
/// `multibuf_test.zig` drives the ripgrep parity table with it, and
/// `json.zig`'s `-U --json` parity test reuses the same compile + caps shape
/// rather than re-deriving one that could disagree.
pub const MlHarness = struct {
    arena: std.heap.ArenaAllocator,
    m: Matcher,
    caps: ?Caps = null,

    pub fn init(pat: []const u8, o: struct { dotall: bool = false, replace: bool = false }) !MlHarness {
        const ta = std.testing.allocator;
        var h = MlHarness{
            .arena = std.heap.ArenaAllocator.init(ta),
            .m = .{ .linear = try Regex.compileOpts(ta, pat, .{ .multiline = true, .dotall = o.dotall }) },
        };
        if (o.replace) h.caps = .{ .linear = try Captures.compile(ta, pat, false, false) };
        return h;
    }
    pub fn deinit(self: *MlHarness) void {
        self.arena.deinit();
        self.m.deinit();
        if (self.caps) |*c| c.deinit();
    }
    /// Run the whole-buffer emit path with the given options and return the bytes.
    pub fn run(self: *MlHarness, o: Opts, body: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const out = try a.create(std.ArrayList(u8));
        out.* = .empty;
        var em = Emitter{
            .a = a,
            .re = &self.m,
            .o = o,
            .show_name = false,
            .out = out,
            .base = @intFromPtr(body.ptr),
            .caps = if (self.caps) |*c| c else null,
        };
        _ = em.buffer("f.txt", body);
        return out.items;
    }
};
