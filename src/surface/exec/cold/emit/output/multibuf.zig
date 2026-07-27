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
const regex = @import("../../../../../kernel/match/regex/regex.zig");
const Matcher = regex.Matcher;
const Regex = regex.Regex;
const Caps = regex.Caps;
const Captures = regex.Captures;
const output = @import("../output.zig");
const Emitter = output.Emitter;
const display = @import("display.zig");
const replace = @import("replace.zig");

/// Whole-buffer (`-U`/`--multiline`) emit path, selected only when
/// `ml.sliceModel` says a pattern may cross `\n`. `body` is BOM-stripped and
/// `base` makes its offsets file-relative. rg prints each match's line run,
/// coalesces touching runs, and measures `-o` columns against that block.
/// Mode renderers live here; `multiline.zig` owns the shared span/line model so
/// text and `--json` cannot drift.
///
/// Returns the exit-driving count: printed lines for frames/`-v`, matches for
/// `-o`, and `ml.count` for both count modes. Passthru may print with zero.
pub fn buffer(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    // `-l` needs one kept span. When `bufBoolExact` proves boolean/emit parity,
    // one O(1)/byte `bufMatch` answers; `-w` and `--crlf` reshape spans, so
    // their span path stops after its first kept result.
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
    // `-v` reads no span list: its claim walk resumes past whole LINES, not
    // past match ends, so it runs its own scan. Both count modes come here too
    // — an inverted event has no matches to tally, only lines. Inverted
    // passthru owes the full file, and has no matched block to widen.
    if (o.invert) return if (o.passthru and o.mode.frames()) bufPassthru(self, path, body) else bufInvert(self, path, body);
    // `-m` caps the printed `ml.capRegion`, not spans; count modes ignore it
    // (`rg -U -m1 -c` reports every match), so consumers bound a complete list.
    var uncapped = o;
    uncapped.max_per_file = 0;
    // Both count modes want a NUMBER, so they walk the cursor and never build the
    // list: `-U -c 'a[\s\S]*?a'` over a 64 MiB line yields 33.5 M matches, and
    // materializing them cost ~800 MiB of spans nobody read. `--count-matches`
    // includes empty spans (argv settles `-c -o` into it), and counting happens
    // before any empty-span return so `--include-zero` can still emit `path:0`.
    if (o.mode == .count or o.mode == .count_matches) {
        const v = View.of(self, body);
        return self.bufTally(path, ml.count(self.a, self.re, uncapped, v.text));
    }
    const spans = collectSpans(self, uncapped, body);
    // No span means no block for passthru's infinite context to widen.
    if (spans.len == 0) return if (o.passthru and o.mode.frames()) bufPassthru(self, path, body) else 0;
    const lines = ml.splitLines(self.a, body, o.term());
    // Every frame below receives the already-capped `-m` region.
    const kept = ml.capRegion(self.a, lines, spans, o.max_per_file);
    if (o.mode == .files_with_matches) return self.emitPathOnly(path);
    if (o.only_matching) return if (o.replace != null) bufOnlyRepl(self, path, lines, kept, body) else bufOnly(self, path, lines, kept, body);
    // `--vimgrep` is a row shape applied by the owning block frame. With `-r`,
    // rg measures rows against the re-split replacement (rg #1311), so a
    // three-line match may collapse onto its substitution's one line.
    if (o.replace != null) return bufReplaceBlocks(self, path, lines, kept, body);
    if (o.vimgrep) return bufVimgrep(self, path, lines, kept, body);
    return bufBlocks(self, path, lines, kept, body);
}

/// The bytes spans are matched against. Under `--crlf` that is a copy with the
/// CR before every LF removed — so anchors and `-w` see logical line ends, and
/// a match reaching one maps back before the CR — with `origin` as the map
/// home. A plain body is matched in place and allocates nothing. Either way the
/// view holds the SAME lines in the same order, so a per-LINE answer (`-v`'s
/// claim mask) carries over by index and needs no map at all.
const View = struct {
    text: []const u8,
    origin: ?[]const u32 = null,

    fn of(self: *Emitter, body: []const u8) View {
        if (!self.o.crlf or body.len > std.math.maxInt(u32) or
            std.mem.indexOf(u8, body, "\r\n") == null) return .{ .text = body };
        const text = self.a.alloc(u8, body.len) catch oom();
        const origin = self.a.alloc(u32, body.len) catch oom();
        var n: usize = 0;
        for (body, 0..) |c, i| {
            if (c == '\r' and i + 1 < body.len and body[i + 1] == '\n') continue;
            text[n] = c;
            origin[n] = @intCast(i);
            n += 1;
        }
        return .{ .text = text[0..n], .origin = origin };
    }
};

/// Collect spans against the match view, mapped back to original offsets.
fn collectSpans(self: *Emitter, o: Opts, body: []const u8) []ml.Span {
    const v = View.of(self, body);
    const spans = ml.collect(self.a, self.re, o, v.text);
    if (v.origin) |origin| for (spans) |*sp| {
        const s = origin[sp.start];
        sp.end = if (sp.end > sp.start) origin[sp.end - 1] + 1 else s;
        sp.start = s;
    };
    return spans;
}

/// `-v -U`: the lines no match's sink claimed become the selected lines, and
/// the claimed ones around them become their `-A/-B/-C` context — rg sinks an
/// inverted region through the same context machinery as a matched one.
///
/// Both count modes report the selected lines here (`rg -U -v -c` and
/// `-v --count-matches` agree), because an inverted event carries no matches to
/// tally instead.
fn bufInvert(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    const lines = ml.splitLines(self.a, body, o.term());
    const view = View.of(self, body);
    // `ml.claimed` answers per LINE, and the match view holds the same lines,
    // so its mask carries over by index without the offset map.
    const claimed = ml.claimed(
        self.a,
        self.re,
        .{ .word = o.word, .max_per_file = o.max_per_file },
        view.text,
        if (view.origin == null) lines else ml.splitLines(self.a, view.text, o.term()),
    );
    const selected = self.a.alloc(bool, lines.len) catch oom();
    var n: usize = 0;
    for (claimed, selected) |c, *s| {
        s.* = !c;
        n += @intFromBool(s.*);
    }
    if (o.mode.counting()) return self.bufTally(path, n);
    // An inverted line is not a match, so it carries no `--column`.
    const col = self.a.alloc(usize, lines.len) catch oom();
    @memset(col, 0);
    return frameLines(self, path, lines, body, selected, col);
}

/// `--passthru -U` for inverted or matchless runs, where `ml.blocks` is empty
/// and no block exists for the regular frames' infinite context to widen.
/// Other passthru runs stay in those frames because they own `-r`, `-o`, and
/// `--vimgrep`.
///
/// Every physical line prints; spans mark every line they touch. Returns the
/// matching-line count although output exists even when nothing matched.
fn bufPassthru(self: *Emitter, path: []const u8, body: []const u8) usize {
    const o = self.o;
    const lines = ml.splitLines(self.a, body, o.term());
    const covered = self.a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    // `-m` counts line blocks: two matches on one line form one block, while
    // one match crossing two lines is also one block and keeps both. Counting
    // spans breaks the first case; counting covered lines breaks the second.
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

/// `-o -U`: emit each match's per-line fragments, repeating its absolute
/// offset and block-relative start column. Covered blank lines and lone empty
/// matches at line starts emit nothing; shared or later empties still do.
fn bufOnly(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const o = self.o;
    const bases = ml.blockBases(self.a, lines, spans);
    for (spans, 0..) |sp, si| {
        const l0 = ml.lineIndexAt(lines, sp.start);
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        const col = 1 + (sp.start - bases[si]);
        // A zero-width span is lone when no adjacent start-ordered span shares its line.
        const lone = (si == 0 or ml.lineIndexAt(lines, spans[si - 1].start) != l0) and
            (si + 1 == spans.len or ml.lineIndexAt(lines, spans[si + 1].start) != l0);
        for (l0..l1 + 1) |li| {
            const ln = lines[li];
            if (ln.content_end == ln.start) continue; // blank line: rg emits nothing
            var fs = @max(sp.start, ln.start);
            var fe = @min(sp.end, ln.content_end);
            if (fe == fs and fs == ln.start and lone) continue; // lone `^`-style empty at line start
            // `--trim` intersects against the trimmed line; swallowed fragments vanish.
            if (o.trim and fe > fs) {
                const ts = ln.start + display.blankPrefix(body[ln.start..ln.content_end]);
                if (fe <= ts) continue;
                fs = @max(fs, ts);
            }
            // Avoid doubling a covered CR when the output appends the full CRLF.
            if (o.crlf and fe == ln.content_end and ln.term_end > ln.content_end and fe > fs and body[fe - 1] == '\r') fe -= 1;
            self.prefix(path, li + 1, col, sp.start, true);
            const frag = body[fs..fe];
            // `-M` has match granularity; one synthetic start selects its placeholder.
            if (o.max_cols != 0 and frag.len > o.max_cols) {
                display.exceeded(self, frag, true, &.{0}, 0);
            } else {
                self.paint(self.o.palette.match, frag);
            }
            self.add(o.outTerm());
        }
    }
    return spans.len;
}

/// `-o -r -U`: expand each whole match once at its start line; template
/// newlines split the emitted substitution.
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

/// `--vimgrep -U`: one row per MATCH, on the first line of that match this
/// frame can actually print — rg's `sink_slow_multi_per_match`.
///
/// The walk is per match, not per line, and that ordering is observable: rg
/// finishes a match's rows before starting the next match's, so two matches
/// whose omitted heads overlap interleave differently than a line walk would.
/// Normally a match yields exactly one row, on the line it opens (rg #1866
/// — vimgrep wants one line per match even when the match spans several).
/// `-M/--max-columns` is the exception: an omitted line `continue`s rather than
/// ending the match, so an over-wide head prints its placeholder AND the walk
/// carries on to the match's next line, stopping at the first that fits.
///
/// Context and `--` separators stay on the original grid, block by block, as
/// in every other `-U` frame. Returns the covered line count.
fn bufVimgrep(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const o = self.o;
    const n = lines.len;
    const before = if (o.passthru) n else o.before;
    const after = if (o.passthru) n else o.after;
    const blocks = ml.blocks(self.a, lines, spans);
    var covered: usize = 0;
    var prev_end: ?usize = null;
    for (blocks, 0..) |b, bi| {
        covered += b.last - b.first + 1;
        var hi = @min(b.last + after, n - 1);
        if (bi + 1 < blocks.len) hi = @min(hi, blocks[bi + 1].first - 1);
        const start = self.windowStart(b.first -| before, hi, &prev_end) orelse continue;
        self.ctxRows(path, lines, body, start, b.first);
        // Every row of this block reports the block's own match tally when `-M`
        // omits it, because one block is one sink event.
        const tally = b.s1 - b.s0;
        for (spans[b.s0..b.s1]) |sp| {
            if (sp.end == sp.start) continue; // an empty match owns no row
            const last = ml.lineIndexAt(lines, ml.spanLast(sp));
            for (ml.lineIndexAt(lines, sp.start)..last + 1) |li| {
                const ln = lines[li];
                const text = body[ln.start..ln.content_end];
                display.vimgrepLine(self, .{
                    .path = path,
                    .lineno = li + 1,
                    .text = text,
                    .off = ln.start,
                    .starts = &.{sp.start -| ln.start},
                    .terminated = ln.term_end > ln.content_end,
                    .sink = .block,
                    .tally = tally,
                });
                if (o.max_cols == 0 or text.len <= o.max_cols) break;
            }
        }
        self.ctxRows(path, lines, body, b.last + 1, hi + 1);
        prev_end = hi;
    }
    return covered;
}

/// Default `-U` frame: print each covered line once with coalesced context;
/// `--passthru` widens each window to the whole file. `--vimgrep` is its own
/// frame (`bufVimgrep`) because rg prints that one per match, not per line.
fn bufBlocks(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const n = lines.len;
    const is_match = self.a.alloc(bool, n) catch oom();
    const col = self.a.alloc(usize, n) catch oom();
    @memset(is_match, false);
    @memset(col, 0);
    // `--column` repeats the block's first match column on every covered line;
    // contiguous block ranges are their exact coverage.
    for (ml.blocks(self.a, lines, spans)) |b| {
        const c = 1 + (spans[b.s0].start - lines[b.first].start);
        for (b.first..b.last + 1) |li| {
            is_match[li] = true;
            col[li] = c;
        }
    }
    return frameLines(self, path, lines, body, is_match, col);
}

/// The line frame both `-U` selections print through: every selected line once,
/// widened into its `-A/-B/-C` window, overlapping windows coalesced into one
/// run and separated runs divided by `--`. `col` is each selected line's
/// `--column` (zero where the selection has none, as `-v` does). Returns the
/// selected-line count — the caller's exit-driving tally.
///
/// Sharing it is what keeps `-v` framed like a match: rg sinks an inverted
/// region through the same context machinery, so the claimed lines around one
/// show up as its context.
fn frameLines(self: *Emitter, path: []const u8, lines: []const ml.Line, body: []const u8, is_match: []const bool, col: []const usize) usize {
    const o = self.o;
    const n = lines.len;
    const before = if (o.passthru) n else o.before;
    const after = if (o.passthru) n else o.after;
    var prev_end: ?usize = null;
    var selected: usize = 0;
    for (is_match, 0..) |matched, m| {
        if (!matched) continue;
        selected += 1;
        const hi = @min(m + after, n - 1);
        var k = self.windowStart(m -| before, hi, &prev_end) orelse continue;
        while (k <= hi) : (k += 1) {
            const is_m = is_match[k];
            self.row(path, k + 1, if (is_m) col[k] else 0, lines[k].start, body[lines[k].start..lines[k].content_end], is_m);
        }
    }
    return selected;
}

/// `-U -r` (rg #1311): coalesce matches on overlapping/adjacent lines, replace
/// within each block while preserving unmatched bytes, then re-split from the
/// first original line number. Context remains original; passthru widens it.
fn bufReplaceBlocks(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
    const o = self.o;
    const caps = self.caps orelse return 0;
    const tmpl = o.replace.?;
    const slots = self.a.alloc(isize, caps.nslots()) catch oom();
    const n = lines.len;
    const before = if (o.passthru) n else o.before;
    const after = if (o.passthru) n else o.after;
    // `ml.blocks` mirrors glue.rs: overlapping or adjacent covered lines join.
    const blocks = ml.blocks(self.a, lines, spans);
    var covered: usize = 0;
    var prev_end: ?usize = null;
    for (blocks, 0..) |b, bi| {
        covered += b.last - b.first + 1;
        // Original-grid after-context stops before the next block's match line.
        const lo = b.first -| before;
        var hi = @min(b.last + after, n - 1);
        if (bi + 1 < blocks.len) hi = @min(hi, blocks[bi + 1].first - 1);
        var start = lo;
        if (prev_end) |pe| {
            if (lo > pe + 1) {
                if (o.wantsContext()) self.groupSep();
            } else start = @max(start, pe + 1);
        }
        self.ctxRows(path, lines, body, start, b.first);
        // Expand each span and copy every other byte, including the terminator.
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

/// Emit a replacement block as physical lines from original 0-based `blo`.
/// Every row is a match with the first replacement's block-relative column;
/// `--trim`/`-M` apply per line at replacement-start granularity.
///
/// `--vimgrep` instead emits one row per replacement start; continuation lines
/// of multiline substitutions are neither rows nor context.
fn emitReplacedBlock(self: *Emitter, path: []const u8, blo: usize, block_off: usize, rep: []const u8, starts: []const usize) void {
    const term = self.o.term();
    const col = if (starts.len != 0) starts[0] + 1 else 0;
    var lineno = blo + 1;
    var pos: usize = 0;
    while (pos < rep.len) {
        const nl = std.mem.indexOfScalarPos(u8, rep, pos, term);
        const end = nl orelse rep.len;
        // Rebase starts onto this line: prior ones clamp to 0, later ones drop;
        // vimgrep keeps only starts opening here.
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
                .sink = .block,
                .tally = starts.len,
            });
        } else {
            self.prefix(path, lineno, col, block_off + pos, true);
            // Only the final unsplit tail can lack a terminator.
            display.emitBody(self, rep[pos..end], true, line_starts.items, nl != null, .{});
        }
        if (nl == null) break;
        pos = end + 1;
        lineno += 1;
    }
}

/// `-U` parity harness: compile multiline regex/captures and return exact emit
/// bytes. `multibuf_test.zig` and `json.zig` share it to prevent fixture drift.
pub const MlHarness = struct {
    arena: std.heap.ArenaAllocator,
    m: Matcher,
    caps: ?Caps = null,

    pub fn init(pat: []const u8, o: struct { dotall: bool = false, replace: bool = false }) !MlHarness {
        const ta = std.testing.allocator;
        var h: MlHarness = .{
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
