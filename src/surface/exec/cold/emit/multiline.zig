//! gist `rg -U` — the whole-buffer match MODEL (no output).
//!
//! Under `-U`/`--multiline` the linear engine already matches over a WHOLE
//! buffer (`^`/`$` anchor at `\n` boundaries, `.` crosses `\n` only under
//! dotall — see `kernel/match/regex/linear/matcher.zig`). What the output layer still needs is a
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
const Matcher = @import("../../../../kernel/match/regex/linear/matcher.zig").Matcher;

pub const Span = Matcher.Span;

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
/// Mirrors `grepfile.collectLines`' rg line semantics (a trailing terminator
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

/// The leftmost whole-buffer matches under ripgrep's progress rule, honoring
/// `-w` and `-m`. A non-empty match advances past its end; a zero-width match
/// advances ONE byte and is dropped when it sits adjacent to the previous
/// match's end (rust-regex `find_iter`) or at `body.len` (the terminated
/// phantom — there is no line there). Empty matches are KEPT otherwise, so a
/// nullable pattern (`a*`, `x*`) reproduces rg's per-position empties; every
/// downstream count and frame derives from this one list. Arena-owned.
pub fn collect(a: std.mem.Allocator, re: *const Matcher, o: Opts, body: []const u8) []Span {
    var ss = Matcher.SpanSim.init(a, re) catch return &.{};
    defer ss.deinit();
    var out: std.ArrayList(Span) = .empty;
    var from: usize = 0;
    var last_end: ?usize = null;
    while (from <= body.len) {
        const sp = re.matchSpan(&ss, body, from) orelse break;
        if (o.word and !output.wordOk(o.unicode, body, sp.start, sp.end)) {
            from = if (sp.end > sp.start) sp.end else sp.start + 1;
            continue;
        }
        if (sp.end == sp.start) {
            const adjacent = last_end != null and sp.start == last_end.?;
            if (sp.start == body.len or adjacent) {
                from = sp.start + 1;
                continue;
            }
        }
        out.append(a, sp) catch oom();
        last_end = sp.end;
        from = if (sp.end > sp.start) sp.end else sp.start + 1;
        if (o.max_per_file != 0 and out.items.len >= o.max_per_file) break;
    }
    return out.toOwnedSlice(a) catch oom();
}

/// `--count-matches` (and `-c --only-matching`): total emitted matches, empty
/// ones included — rg's whole-buffer `matches` tally.
pub fn countAll(spans: []const Span) usize {
    return spans.len;
}

/// `-c/--count` under `-U`: the number of DISTINCT physical lines a match
/// STARTS on — rg's multiline "matching lines" (`a\nb` twice ⇒ 2; `a*` over two
/// lines ⇒ 2 even though it yields four matches). Spans are ascending, so a
/// single forward pass counts start-line transitions.
pub fn countStartLines(lines: []const Line, spans: []const Span) usize {
    var n: usize = 0;
    var prev: ?usize = null;
    for (spans) |sp| {
        const li = lineIndexAt(lines, sp.start);
        if (prev == null or prev.? != li) {
            n += 1;
            prev = li;
        }
    }
    return n;
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
const Regex = @import("../../../../kernel/match/regex/linear/core.zig").Regex;

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
    // "aa", empty@3, empty@4 — empty@5 (== len) is dropped.
    try t.expectEqual(@as(usize, 3), spans.len);
    try t.expectEqual(Span{ .start = 4, .end = 4 }, spans[2]);
}

test "collect honors -m/--max-count as a match cap" {
    var fx = try Fixture.init("a\nb");
    defer fx.deinit();
    const spans = collect(fx.a(), &fx.m, .{ .max_per_file = 1 }, "a\nb\na\nb\n");
    try t.expectEqual(@as(usize, 1), spans.len);
}

test "count semantics: start-lines vs all matches vs matched-lines" {
    var fx = try Fixture.init("a*");
    defer fx.deinit();
    const body = "aa\nbb\n";
    const lines = splitLines(fx.a(), body, '\n');
    const spans = collect(fx.a(), &fx.m, .{}, body);
    try t.expectEqual(@as(usize, 4), countAll(spans)); // --count-matches
    try t.expectEqual(@as(usize, 2), countStartLines(lines, spans)); // -c
    try t.expectEqual(@as(usize, 2), countMatchedLines(lines, spans)); // stat
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
