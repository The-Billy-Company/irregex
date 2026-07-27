//! gist `rg -U` — the whole-buffer match MODEL (no output).
//!
//! Under `-U`/`--multiline` the linear engine already matches over a WHOLE
//! buffer (`^`/`$` anchor at `\n` boundaries, `.` crosses `\n` only under
//! dotall — see `kernel/match/regex/linear/ladder/matcher.zig`). What the output layer still needs is a
//! faithful, byte-index model of THAT: the leftmost run of matches under
//! ripgrep's progress rule, the physical-line grid they land on, the way rg
//! coalesces contiguous matches into one block, and the three multiline count
//! semantics. This module is exactly that model and nothing else — it never
//! writes a byte. `output.zig`'s `Emitter.buffer` renders it into rg's text
//! frame and `json.zig` renders it into the `--json` record stream, so the two
//! surfaces cannot drift on WHICH spans exist or WHERE they sit.
//!
//! The one seam it touches is `Matcher.matchSpan` over the whole body; `-w`
//! word bounds are checked against the whole buffer (rg's cross-line `-w`).

const std = @import("std");
const args = @import("../argv/args.zig");
const output = @import("output.zig");
const Opts = args.Opts;
const die = args.die;
const oom = args.oom;
const Matcher = @import("../../../../kernel/match/regex/regex.zig").Matcher;

pub const Span = Matcher.Span;

/// Does this run search with rg's whole-buffer searcher, or its line searcher?
/// `-U` alone is not the answer. rg engages the multi-line searcher only when
/// the line terminator belongs to the pattern
/// (`Searcher::multi_line_with_matcher` asks whether `\n` is outside the
/// matcher's non-matching bytes — `Matcher.claimsNewline`), because a pattern
/// that cannot touch a `\n` cannot cross one — and because a pattern anchored
/// to the HAYSTACK would have that anchor re-offered at every line. So
/// `rg -U alpha` is byte-for-byte `rg alpha` — same columns, same `-b` offsets
/// (the MATCH's, not the printed line's), same `-c` line counting, same `-m`
/// cap — while `rg -U 'a\nb'`, `rg -U 'alpha$'`, and `rg -U '\Aa'` get the
/// block model. Every place that picks a model asks this, so no two can answer
/// differently for one run.
pub fn sliceModel(re: *const Matcher, o: Opts) bool {
    return o.multiline and re.claimsNewline();
}

/// A physical line's byte ranges within the buffer. `content` (`[start,
/// content_end)`) excludes the terminator; `term_end` includes it (== body.len
/// for a final unterminated line — rg still frames that line).
pub const Line = struct { start: usize, content_end: usize, term_end: usize };

/// The last byte a span occupies (for locating its final line). An empty span
/// occupies its start position; a non-empty span's last byte is `end - 1`.
pub fn spanLast(sp: Span) usize {
    return if (sp.end > sp.start) sp.end - 1 else sp.start;
}

/// Split `body` into physical lines on `term`, keeping each line's byte ranges.
/// Mirrors `legible.collectLines`' rg line semantics (a trailing terminator
/// yields no phantom empty line) but retains offsets the multiline locators need.
/// Pre-sized from one terminator count so the split is a single allocation.
pub fn splitLines(a: std.mem.Allocator, body: []const u8, term: u8) []Line {
    var out: std.ArrayList(Line) = .empty;
    out.ensureUnusedCapacity(a, std.mem.count(u8, body, &.{term}) + 1) catch oom();
    var pos: usize = 0;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, term);
        const ce = nl orelse body.len;
        out.appendAssumeCapacity(.{ .start = pos, .content_end = ce, .term_end = if (nl) |n| n + 1 else body.len });
        if (nl == null) break;
        pos = ce + 1;
    }
    return out.toOwnedSlice(a) catch oom();
}

/// 0-based index of the physical line containing byte `off` (`off` in
/// `[0, body.len)`; kept spans never start at `body.len`). Binary search over
/// the ascending `start` keys — the locators call it per span, not per byte.
pub fn lineIndexAt(lines: []const Line, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].start <= off) lo = mid + 1 else hi = mid;
    }
    return lo - 1; // lines[0].start == 0 ≤ off, so lo ≥ 1
}

/// The phantom position past the end of `body`: a match landing exactly there
/// claims no line, so rg refuses to report it and stops the search
/// (glue.rs `sink_matched`: "the only way we can produce an empty line for a
/// match is if we match the position immediately following the last byte that
/// we search, and where that last byte is also the line terminator"). Both
/// halves of that sentence matter. An UNTERMINATED tail has a real last line
/// flush against `body.len`, and rg frames it — `rg -U '\z'` prints `aaa` over
/// `aaa` and nothing over `aaa\n`. An empty body has no line at all.
fn phantomEnd(body: []const u8, term: u8, at: usize) bool {
    return at == body.len and (body.len == 0 or body[body.len - 1] == term);
}

/// The leftmost whole-buffer matches under ripgrep's progress rule, honoring
/// `-w`, and stopping after `o.max_per_file` spans. That stop is a CEILING for
/// a caller that needs no more (the `-l` boolean asks for one), NOT `-m`'s
/// meaning — under the slice model `-m` bounds a line region, which is
/// `capRegion`'s job over the complete list. A non-empty match advances past
/// its end; a zero-width match
/// advances ONE byte and is dropped when it sits adjacent to the previous
/// match's end (rust-regex `find_iter`) or on the phantom past a terminated
/// body (`phantomEnd`). Empty matches are KEPT otherwise, so a
/// nullable pattern (`a*`, `x*`) reproduces rg's per-position empties; every
/// downstream count and frame derives from this one list. Arena-owned.
pub fn collect(a: std.mem.Allocator, re: *const Matcher, o: Opts, body: []const u8) []Span {
    var ss = Matcher.SpanSim.init(a, re) catch return &.{};
    defer ss.deinit();
    var out: std.ArrayList(Span) = .empty;
    var w: Walk = .{ .re = re, .ss = &ss, .o = o, .body = body };
    while (w.next()) |sp| {
        out.append(a, sp) catch oom();
        if (o.max_per_file != 0 and out.items.len >= o.max_per_file) break;
    }
    return out.toOwnedSlice(a) catch oom();
}

/// The same walk as a cursor, so a consumer that needs HOW MANY never pays for a
/// list of WHICH. The rules live here once and `collect` reads them through this
/// too — a second implementation of the progress rule would be a second thing to
/// keep true.
pub const Walk = struct {
    re: *const Matcher,
    ss: *Matcher.SpanSim,
    o: Opts,
    body: []const u8,
    from: usize = 0,
    last_end: ?usize = null,

    pub fn next(self: *Walk) ?Span {
        // rg's multiline loop is `while !slice[pos..].is_empty()` — it never opens
        // a search AT the end, so `body.len` is a place a match may LAND (found
        // from an earlier resume, as `\z` is) but never a place one is looked
        // for. An empty body is therefore searched zero times, not once.
        while (self.from < self.body.len) {
            const sp = self.re.matchSpan(self.ss, self.body, self.from) orelse return null;
            if (self.o.word and !output.wordOk(self.o.unicode, self.body, sp.start, sp.end)) {
                // One byte on, not past the candidate's end — rg's `-w` is
                // compiled into the pattern, so a rejected candidate never
                // consumes the region it covered (see `output.nextSpan`).
                self.from = sp.start + 1;
                continue;
            }
            if (sp.end == sp.start) {
                const adjacent = self.last_end != null and sp.start == self.last_end.?;
                if (phantomEnd(self.body, self.o.term(), sp.start) or adjacent) {
                    self.from = sp.start + 1;
                    continue;
                }
            }
            self.last_end = sp.end;
            self.from = if (sp.end > sp.start) sp.end else sp.start + 1;
            return sp;
        }
        return null;
    }
};

/// How many matches the walk yields — which is `--count-matches` AND `-c/--count`
/// under the slice model: total emitted matches, empty ones included, rg's
/// whole-buffer `matches` tally. The two count modes are one question here, which
/// is rg's documented contract: "when multiline mode is enabled and the
/// pattern(s) given can match over multiple lines, -c/--count is equivalent to
/// --count-matches" (`rg --help count`). There is no line tally to give: a match
/// owns a line RANGE, not a line.
///
/// Do not re-derive this from a probe like `rg -U -c 'a*'`: a pattern that cannot
/// read `\n` never enters the slice model at all (`sliceModel`), so such a probe
/// measures rg's LINE counter and reports lines. Force the same shape across the
/// boundary (`a*|q\nq`) and `-c` answers with the match tally.
///
/// `-U -c` used to route through `collect`, then read `.len` off a list it threw
/// away: 33.5 M lazy matches on one 64 MiB line cost ~800 MiB of spans nobody
/// looked at (measured by the robustness lane, which is also how the ceiling
/// came to be near). Counting through the cursor is O(1) in memory, and the
/// answer is the same walk's answer by construction.
pub fn count(a: std.mem.Allocator, re: *const Matcher, o: Opts, body: []const u8) usize {
    var ss = Matcher.SpanSim.init(a, re) catch return 0;
    defer ss.deinit();
    var w: Walk = .{ .re = re, .ss = &ss, .o = o, .body = body };
    var n: usize = 0;
    while (w.next()) |_| {
        n += 1;
        if (o.max_per_file != 0 and n >= o.max_per_file) break;
    }
    return n;
}

/// `-v` under the slice model: which physical lines a match CLAIMED, as a mask
/// over `lines` (`true` ⇒ suppressed, so `-v` prints the rest).
///
/// rg does not invert the union of every match's line span. Its inverted
/// searcher (glue.rs `sink_matched_inverted`) walks the buffer once and resumes
/// each search from the END of the line span it just claimed — not from the
/// match's end, which is what `collect` does. A second match beginning on an
/// already-claimed line is therefore never found, and the lines only IT would
/// have claimed still print. Over `AA one / middle / end two BB one / middle2 /
/// end two CC`, `one[\s\S]*?two` claims lines 1-3, resumes at line 4, finds
/// nothing there, and the last two lines print — where a union of the two
/// matches would have swallowed the file whole.
///
/// `-w` word bounds are honored as in `collect`. `-m N` caps the matches this
/// walk may CONSUME, not the lines the caller prints: rg's `core.find` simply
/// stops answering once N matches were found, so everything past the Nth
/// claim is one unclaimed region and prints in full. `rg -U -v -m1` over a
/// two-match file therefore prints MORE than `-m2` would, not fewer lines.
pub fn claimed(a: std.mem.Allocator, re: *const Matcher, o: Opts, body: []const u8, lines: []const Line) []const bool {
    const out = a.alloc(bool, lines.len) catch oom();
    @memset(out, false);
    if (lines.len == 0) return out;
    var ss = Matcher.SpanSim.init(a, re) catch return out;
    defer ss.deinit();
    var pos: usize = 0;
    var found: usize = 0;
    while (pos < body.len) {
        if (o.max_per_file != 0 and found >= o.max_per_file) break;
        const sp = re.matchSpan(&ss, body, pos) orelse break;
        if (phantomEnd(body, o.term(), sp.start)) break; // claims no line
        if (o.word and !output.wordOk(o.unicode, body, sp.start, sp.end)) {
            pos = sp.start + 1; // see `output.nextSpan`: `-w` narrows, never consumes
            continue;
        }
        found += 1;
        const last = lineIndexAt(lines, spanLast(sp));
        for (lineIndexAt(lines, sp.start)..last + 1) |li| out[li] = true;
        pos = @max(lines[last].term_end, pos + 1);
    }
    return out;
}

/// `-m N` under the slice model: the spans that still RENDER, clipped to the
/// region rg admits. `--max-count` bounds the SINK EVENTS rg's multiline
/// searcher reports, and each event hands the printer one match's whole line
/// range — so `-m` draws a line boundary, not a match cap. Every match that
/// STARTS at or before that boundary still prints, truncated to it: `-m1` where
/// the first match covers lines 1-3 prints all four matches those lines hold,
/// and a later match reaching line 5 shows only its line-3 head. Clipping the
/// span list (rather than teaching each frame a limit) is what lets the block,
/// `-o`, and `--vimgrep` frames stay unaware of `-m` entirely. Counts ignore
/// `-m`, so callers tally BEFORE clipping. `max == 0` ⇒ unbounded.
pub fn capRegion(a: std.mem.Allocator, lines: []const Line, spans: []const Span, max: usize) []const Span {
    if (max == 0 or spans.len <= max) return spans;
    var last: usize = 0;
    for (spans[0..max]) |sp| last = @max(last, lineIndexAt(lines, spanLast(sp)));
    const edge = lines[last].content_end;
    var out: std.ArrayList(Span) = .empty;
    for (spans) |sp| {
        if (lineIndexAt(lines, sp.start) > last) break;
        out.append(a, .{ .start = sp.start, .end = @min(sp.end, edge) }) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

/// The number of physical lines covered by the union of every match's line span
/// — rg's `matched_lines` stat (a match over two lines contributes both; an
/// overlap is counted once). Spans are ascending in `start`.
pub fn countMatchedLines(lines: []const Line, spans: []const Span) usize {
    var n: usize = 0;
    var covered: ?usize = null; // highest line index already counted
    for (spans) |sp| {
        var s = lineIndexAt(lines, sp.start);
        const e = lineIndexAt(lines, spanLast(sp));
        if (covered) |c| if (s <= c) {
            s = c + 1;
        };
        if (e >= s) n += e - s + 1;
        if (covered == null or e > covered.?) covered = e;
    }
    return n;
}

/// Whether a span physically crosses a line boundary (covers >1 physical line).
pub fn spansLines(lines: []const Line, sp: Span) bool {
    return lineIndexAt(lines, spanLast(sp)) > lineIndexAt(lines, sp.start);
}

/// A maximal line-contiguous group of ascending spans — rg's multiline
/// searcher's sink block: consecutive spans join when the next span's first
/// line overlaps OR is exactly adjacent to the block's last covered line
/// (glue.rs `last_match.end() >= line.start()`). `s0..s1` index the member
/// spans. Shared by `-U -r` (output.zig) and the `--json` record stream.
pub const Block = struct { first: usize, last: usize, s0: usize, s1: usize };

/// The one grouping walk behind `blocks` and `blockBases`. `bridged` selects
/// the stricter `-o` column-base rule (see `blockBases`): an exactly-adjacent
/// pair joins only when one of the two bridging spans itself crosses a line.
fn blocksWith(a: std.mem.Allocator, lines: []const Line, spans: []const Span, bridged: bool) []Block {
    var out: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < spans.len) {
        const first = lineIndexAt(lines, spans[i].start);
        var last = lineIndexAt(lines, spanLast(spans[i]));
        var j = i + 1;
        while (j < spans.len) : (j += 1) {
            const fl = lineIndexAt(lines, spans[j].start);
            if (fl > last + 1) break;
            if (bridged and fl == last + 1 and
                !spansLines(lines, spans[j]) and !spansLines(lines, spans[j - 1])) break;
            last = @max(last, lineIndexAt(lines, spanLast(spans[j])));
        }
        out.append(a, .{ .first = first, .last = last, .s0 = i, .s1 = j }) catch oom();
        i = j;
    }
    return out.toOwnedSlice(a) catch oom();
}

pub fn blocks(a: std.mem.Allocator, lines: []const Line, spans: []const Span) []Block {
    return blocksWith(a, lines, spans, false);
}

/// For each span, the byte offset of its BLOCK's first matched line — the base
/// ripgrep measures `-o` columns against (a match's `-o` column is `1 + (start -
/// block_base)`, repeated on every line the match spans). A block is a maximal
/// run of matches ripgrep's multiline searcher groups into one sink region:
/// consecutive matches join when their lines OVERLAP (`next.first_line ≤
/// cur.last_line`) or are exactly ADJACENT (`== cur.last_line + 1`) AND the
/// bridging pair includes a match that itself spans lines. Two single-line
/// matches on adjacent lines do NOT join — rg gives each its own line-relative
/// column (`x?` over `a\nb` ⇒ cols 1,2,1,2), while a genuine cross-line run
/// stays block-relative (`a\nb|b\nc` ⇒ 1,1,5,5). Arena-owned, one per span.
pub fn blockBases(a: std.mem.Allocator, lines: []const Line, spans: []const Span) []usize {
    const bases = a.alloc(usize, spans.len) catch oom();
    for (blocksWith(a, lines, spans, true)) |b| {
        const base = lines[b.first].start;
        for (b.s0..b.s1) |j| bases[j] = base;
    }
    return bases;
}

// ─────────────────────────────── tests ───────────────────────────────

const t = std.testing;
const Regex = @import("../../../../kernel/match/regex/regex.zig").Regex;

/// Test scaffold: an arena for the model's `[]…` allocations (mirrors the
/// per-run arena the CLI hands the emitter, so nothing leaks) plus a compiled
/// multiline matcher freed on scope exit.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    m: Matcher,
    fn init(pat: []const u8) !Fixture {
        return .{
            .arena = std.heap.ArenaAllocator.init(t.allocator),
            .m = .{ .linear = try Regex.compileOpts(t.allocator, pat, .{ .multiline = true }) },
        };
    }
    fn a(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.m.deinit();
    }
};

test "a haystack anchor picks the slice model even though it eats no newline" {
    // `\Aa` never touches a `\n`, but the line searcher would hand it a fresh
    // haystack per line — every line start a buffer start, `\A` decayed into
    // `^`. rg claims the terminator for it rather than allow that; so does this.
    var anchored = try Fixture.init("\\Aa");
    defer anchored.deinit();
    try t.expect(anchored.m.claimsNewline());
    try t.expect(sliceModel(&anchored.m, .{ .multiline = true }));
    // …and only under `-U`. Per-line, `\A` IS `^` (the line is the haystack).
    try t.expect(!sliceModel(&anchored.m, .{}));

    // The complement: `\b` claims nothing, so it stays on rg's line searcher.
    var plain = try Fixture.init("\\ba");
    defer plain.deinit();
    try t.expect(!plain.m.claimsNewline());
    try t.expect(!sliceModel(&plain.m, .{ .multiline = true }));
}

test "the slice model reads \\A/\\z against the buffer, not each line" {
    var fx = try Fixture.init("\\Aa");
    defer fx.deinit();
    // "a\nabc\n": the line model would claim both lines; only offset 0 is BOF.
    const spans = collect(fx.a(), &fx.m, .{}, "a\nabc\n");
    try t.expectEqual(@as(usize, 1), spans.len);
    try t.expectEqual(Span{ .start = 0, .end = 1 }, spans[0]);

    // `\z` is the byte after the final terminator, so a `\n`-terminated file
    // has no line ending flush against it — `rg -U 'abc\z'` finds nothing.
    var tail = try Fixture.init("abc\\z");
    defer tail.deinit();
    try t.expectEqual(@as(usize, 0), collect(tail.a(), &tail.m, .{}, "a\nabc\n").len);
    try t.expectEqual(@as(usize, 1), collect(tail.a(), &tail.m, .{}, "a\nabc").len);
}

test "splitLines keeps offsets and drops the trailing phantom line" {
    var fx = try Fixture.init("x");
    defer fx.deinit();
    const lines = splitLines(fx.a(), "a\nbb\nc", '\n');
    try t.expectEqual(@as(usize, 3), lines.len);
    try t.expectEqual(Line{ .start = 0, .content_end = 1, .term_end = 2 }, lines[0]);
    try t.expectEqual(Line{ .start = 2, .content_end = 4, .term_end = 5 }, lines[1]);
    try t.expectEqual(Line{ .start = 5, .content_end = 6, .term_end = 6 }, lines[2]);

    try t.expectEqual(@as(usize, 2), splitLines(fx.a(), "a\nb\n", '\n').len); // no phantom line
}

test "lineIndexAt binary-searches the physical grid" {
    var fx = try Fixture.init("x");
    defer fx.deinit();
    const lines = splitLines(fx.a(), "a\nbb\nc\n", '\n');
    try t.expectEqual(@as(usize, 0), lineIndexAt(lines, 0));
    try t.expectEqual(@as(usize, 0), lineIndexAt(lines, 1)); // the \n belongs to line 0
    try t.expectEqual(@as(usize, 1), lineIndexAt(lines, 2));
    try t.expectEqual(@as(usize, 1), lineIndexAt(lines, 4));
    try t.expectEqual(@as(usize, 2), lineIndexAt(lines, 5));
}

test "collect yields cross-line spans left to right" {
    var fx = try Fixture.init("a\nb");
    defer fx.deinit();
    const spans = collect(fx.a(), &fx.m, .{}, "a\nb\nx\na\nb\n");
    try t.expectEqual(@as(usize, 2), spans.len);
    try t.expectEqual(Span{ .start = 0, .end = 3 }, spans[0]);
    try t.expectEqual(Span{ .start = 6, .end = 9 }, spans[1]);
}

test "collect empty-match progress rule (a* over two lines)" {
    var fx = try Fixture.init("a*");
    defer fx.deinit();
    // "aa\nbb\n": "aa" then empties at 3,4,5 (2 is adjacent to "aa" end; 6 is the phantom).
    const spans = collect(fx.a(), &fx.m, .{}, "aa\nbb\n");
    try t.expectEqual(@as(usize, 4), spans.len);
    try t.expectEqual(Span{ .start = 0, .end = 2 }, spans[0]);
    try t.expectEqual(Span{ .start = 3, .end = 3 }, spans[1]);
    try t.expectEqual(Span{ .start = 4, .end = 4 }, spans[2]);
    try t.expectEqual(Span{ .start = 5, .end = 5 }, spans[3]);
}

test "collect drops the empty match at an unterminated buffer end" {
    var fx = try Fixture.init("a*");
    defer fx.deinit();
    const spans = collect(fx.a(), &fx.m, .{}, "aa\nbb"); // no trailing \n
    // "aa", empty@3, empty@4 — the walk never resumes at 5 (== len) to look
    // for a sixth, so the nullable pattern stops with the last real byte.
    try t.expectEqual(@as(usize, 3), spans.len);
    try t.expectEqual(Span{ .start = 4, .end = 4 }, spans[2]);
}

test "the end-of-buffer phantom exists only behind a terminator" {
    var fx = try Fixture.init("\\z");
    defer fx.deinit();
    // Terminated: `\z` sits past the final `\n`, on a line that does not exist.
    // rg refuses to frame it — `rg -U '\z'` over "aaa\n" reports nothing.
    try t.expectEqual(@as(usize, 0), collect(fx.a(), &fx.m, .{}, "aaa\n").len);
    try t.expectEqual(@as(usize, 0), collect(fx.a(), &fx.m, .{}, "").len);

    // Unterminated: the last line runs flush to `\z`, so the match claims it
    // and rg prints `aaa`. The span is empty but its LINE range is not.
    const kept = collect(fx.a(), &fx.m, .{}, "aaa");
    try t.expectEqual(@as(usize, 1), kept.len);
    try t.expectEqual(Span{ .start = 3, .end = 3 }, kept[0]);
    try t.expectEqual(@as(usize, 0), lineIndexAt(splitLines(fx.a(), "aaa", '\n'), spanLast(kept[0])));

    // `--null-data` moves the terminator, and the phantom moves with it.
    try t.expectEqual(@as(usize, 1), collect(fx.a(), &fx.m, .{ .null_data = true }, "aaa\n").len);
    try t.expectEqual(@as(usize, 0), collect(fx.a(), &fx.m, .{ .null_data = true }, "aaa\x00").len);
}

test "collect stops at the caller's span ceiling" {
    var fx = try Fixture.init("a\nb");
    defer fx.deinit();
    const spans = collect(fx.a(), &fx.m, .{ .max_per_file = 1 }, "a\nb\na\nb\n");
    try t.expectEqual(@as(usize, 1), spans.len);
}

test "count semantics: both count modes tally spans; --stats tallies lines" {
    var fx = try Fixture.init("a*|q\nq");
    defer fx.deinit();
    const body = "aa\nbb\n";
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    // The alternation is what puts this in the slice model, where `-c` and
    // `--count-matches` are one number — `rg -U -c 'a*|q\nq'` over this body
    // answers 4, the same as `--count-matches`, not the 2 lines `rg -c 'a*'`
    // reports from the line model. One "aa" plus three empties on line 2.
    // Cursor and list are the same walk: `count` answers without materializing
    // the spans, and must agree with the list `collect` builds from it.
    try t.expectEqual(@as(usize, 4), count(fx.a(), &fx.m, .{}, body));
    try t.expectEqual(@as(usize, 4), spans.len);
    try t.expectEqual(@as(usize, 2), countMatchedLines(lines, spans)); // --stats: covered lines
}

test "capRegion bounds the printed LINES, not the match count" {
    var fx = try Fixture.init("one[\\s\\S]*?two|B");
    defer fx.deinit();
    //             L1........L2.......L3................L4.........L5
    const body = "AA one\nmiddle\nend two BB one\nmiddle2\nend two CC\n";
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    try t.expectEqual(@as(usize, 4), spans.len); // L1-3, B, B, L3-5

    // `-m1` admits the first match's whole range (lines 1-3), so all FOUR
    // matches still render — the last one clipped to its line-3 head.
    const one = capRegion(fx.a(), lines, spans, 1);
    try t.expectEqual(@as(usize, 4), one.len);
    try t.expectEqual(lines[2].content_end, one[3].end);
    try t.expectEqual(spans[3].start, one[3].start);

    // `-m4` admits every match, so nothing is clipped at all.
    try t.expectEqual(spans[3].end, capRegion(fx.a(), lines, spans, 4)[3].end);
}

test "capRegion drops a match that opens past the region" {
    var fx = try Fixture.init("x");
    defer fx.deinit();
    const body = "x\n\nx\n"; // two matches, a blank line apart
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    try t.expectEqual(@as(usize, 2), spans.len);
    try t.expectEqual(@as(usize, 1), capRegion(fx.a(), lines, spans, 1).len);
}

test "blockBases coalesces contiguous matches to one base" {
    var fx = try Fixture.init("x\ny");
    defer fx.deinit();
    const body = "x\ny\nx\ny\n"; // two matches on adjacent line pairs → one block
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    const bases = blockBases(fx.a(), lines, spans);
    try t.expectEqual(@as(usize, 2), spans.len);
    try t.expectEqual(@as(usize, 0), bases[0]);
    try t.expectEqual(@as(usize, 0), bases[1]); // same block base ⇒ rg's -o columns 1 and 5
}

test "blockBases splits blocks separated by a gap line" {
    var fx = try Fixture.init("a\nb");
    defer fx.deinit();
    const body = "a\nb\n\na\nb\n"; // blank line between the two matches
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    const bases = blockBases(fx.a(), lines, spans);
    try t.expectEqual(@as(usize, 0), bases[0]);
    try t.expectEqual(@as(usize, 5), bases[1]); // second block starts at its own line
}

test "blockBases keeps adjacent SINGLE-line matches in separate blocks" {
    var fx = try Fixture.init("x?");
    defer fx.deinit();
    const body = "a\nb\n"; // empties at 0,1 (line 0) and 2,3 (line 1); none cross a line
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    const bases = blockBases(fx.a(), lines, spans);
    try t.expectEqual(@as(usize, 4), spans.len);
    try t.expectEqual(@as(usize, 0), bases[0]); // line 0 block
    try t.expectEqual(@as(usize, 0), bases[1]);
    try t.expectEqual(@as(usize, 2), bases[2]); // line 1 resets its own base (rg's line-relative cols)
    try t.expectEqual(@as(usize, 2), bases[3]);
}
