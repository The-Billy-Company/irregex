//! The line index over bytes — where a line begins, which one holds an offset,
//! what its number is, and the clamped band of neighbors around it.
//!
//! This package spells that arithmetic seven times, in four shapes that agree on
//! ripgrep's newline rule and disagree on nothing else: content-only slices
//! (`corpus/read/legible.zig`), an offset grid (`exec/cold/emit/multiline.zig`),
//! a warm iterator (`exec/session/facet/stream.zig`), and three count-only
//! scanners (`exec/session/warm/mirror.zig`, `kernel/query/query.zig`,
//! `kernel/scan/classrun.zig`). Four shapes is why nobody collapsed them, so
//! this module is deliberately not a fifth shape: it is the walk, plus the two
//! projections (materialize / tally) and the two locators (offset → line,
//! offset → band) the four shapes are each a slice of.
//!
//! The rule, stated once, since every one of the seven restates it: **`\n`
//! TERMINATES a line.** A trailing terminator therefore yields no phantom empty
//! final line, content after the last terminator is still a line, and an empty
//! buffer holds no lines at all. A CRLF's `\r` stays in the content, which is
//! ripgrep's default without `--crlf` — `Line.shown` is the other view, for a
//! host that prints rather than matches.
//!
//! **Numbers are 1-based**, matching what `-n` prints, what an editor jumps to,
//! and what every other tool a host diffs against says. The 0-based grid index
//! is `number - 1` and is only ever a position in a materialized slice.
//!
//! Pure: bytes in, arithmetic out. No corpus, no I/O, no emit policy, and no
//! opinion about which terminator a file uses — `term` is a parameter, because
//! `-0`/`--null-data` makes it `\x00` and the rule above is identical.

const std = @import("std");

/// The terminator every caller means unless it says otherwise.
pub const newline: u8 = '\n';

/// One physical line's byte ranges within a buffer.
///
/// Three offsets rather than two, because the two questions a host asks want
/// different ends: *what does this line say* stops before the terminator, and
/// *where does the next line start* is past it. Deriving either from the other
/// needs the buffer and the rule, which is exactly the re-derivation this
/// module exists to stop — so both are carried. For an unterminated final line
/// `content_end == term_end == bytes.len`, and `terminated()` is how you tell.
pub const Line = struct {
    start: usize,
    /// One past the last content byte — the terminator excluded.
    content_end: usize,
    /// One past the terminator, so the next line's `start`. Equals `bytes.len`
    /// for a final line with no terminator, which ripgrep still frames.
    term_end: usize,

    /// The line's bytes, terminator excluded. A CRLF's `\r` is KEPT — rg's
    /// default, and what the matching engines here see.
    pub fn content(self: Line, bytes: []const u8) []const u8 {
        return bytes[self.start..self.content_end];
    }

    /// The same bytes with a CRLF's `\r` dropped — the display view. Separate
    /// from `content` rather than replacing it because a matcher and a printer
    /// legitimately disagree here, and collapsing them would silently move
    /// every `$` anchor on a Windows file.
    pub fn shown(self: Line, bytes: []const u8) []const u8 {
        const text = self.content(bytes);
        return if (text.len > 0 and text[text.len - 1] == '\r') text[0 .. text.len - 1] else text;
    }

    /// The line including its terminator — the bytes a verbatim re-emit writes.
    pub fn raw(self: Line, bytes: []const u8) []const u8 {
        return bytes[self.start..self.term_end];
    }

    /// Did this line end with a terminator, or with the file?
    pub fn terminated(self: Line) bool {
        return self.term_end > self.content_end;
    }

    /// Whether byte `off` falls on this line, terminator included. Half-open,
    /// so the position past an unterminated tail is not on it — see `locate`
    /// for the one place that position is nonetheless answerable.
    pub fn holds(self: Line, off: usize) bool {
        return off >= self.start and off < self.term_end;
    }
};

/// A line and its 1-based number.
pub const Located = struct { number: usize, line: Line };

/// The clamped band of lines around a located one — a context window that ran
/// out of file on one or both sides.
///
/// `center` is the whole reason this is a struct rather than a pair of offsets:
/// after a clamp at the top of the file the requested `before` was not
/// delivered, so a host that assumed "the middle row is the hit" would point at
/// the wrong line. It reports where the hit actually landed instead of leaving
/// the caller to re-derive it from a comparison it would have to get right.
pub const Band = struct {
    /// 1-based number of the band's FIRST line. Clamping moves the edges; it
    /// never renumbers, so this is a real line number in the file.
    number: usize,
    /// Byte offset the band starts at.
    start: usize,
    /// One past the band's last line, terminator included.
    end: usize,
    /// How many lines the band holds — at most `before + 1 + after`, fewer
    /// wherever the file ran out.
    len: usize,
    /// 0-based position of the line that held the offset, within the band.
    center: usize,
};

/// Walk `bytes` a line at a time. The iterator shape, so a caller that wants
/// neither a materialized grid nor a bare count pays for neither.
///
/// No `partial` flag, unlike the warm session's hand-rolled twin: an
/// unterminated tail sets `pos` to `bytes.len` through its own `term_end`, so
/// exhaustion is the same test for both endings.
pub const Walk = struct {
    bytes: []const u8,
    term: u8 = newline,
    pos: usize = 0,

    pub inline fn next(self: *Walk) ?Line {
        if (self.pos >= self.bytes.len) return null;
        const line = lineFrom(self.bytes, self.term, self.pos);
        self.pos = line.term_end;
        return line;
    }
};

/// The line beginning at `start`, which the caller must already know is a line
/// boundary. The one place the terminator search is written.
fn lineFrom(bytes: []const u8, term: u8, start: usize) Line {
    const nl = std.mem.indexOfScalarPos(u8, bytes, start, term);
    return .{
        .start = start,
        .content_end = nl orelse bytes.len,
        .term_end = if (nl) |n| n + 1 else bytes.len,
    };
}

/// How many lines `bytes` holds. The tally projection — no offsets, no slices,
/// one pass, and `std.mem.count` is vectorized underneath.
pub fn count(bytes: []const u8, term: u8) usize {
    if (bytes.len == 0) return 0;
    return std.mem.count(u8, bytes, &.{term}) + @intFromBool(bytes[bytes.len - 1] != term);
}

/// The line holding byte `off`, with its 1-based number — or null when no line
/// holds it.
///
/// Null is a real answer three ways, and they are the three every host gets
/// wrong. `off > bytes.len` is out of range. An EMPTY buffer has no lines, so
/// no offset lands on one. And `off == bytes.len` on a buffer that ends with a
/// terminator is ripgrep's phantom position: the terminator already closed the
/// last line and nothing begins after it (`glue.rs`'s `sink_matched` refuses a
/// match there). The one case that DOES answer at `bytes.len` is an
/// unterminated tail, whose real final line runs flush to the end.
///
/// Cost is one pass over `bytes[0..off]` — two vectorized `std` scans, not a
/// byte loop. A caller with many offsets over one buffer wants `collect` +
/// `find` instead, which pays that once for the whole file.
pub fn locate(bytes: []const u8, term: u8, off: usize) ?Located {
    if (off > bytes.len or bytes.len == 0) return null;
    if (off == bytes.len and bytes[bytes.len - 1] == term) return null;
    const before = bytes[0..off];
    // Terminators strictly before `off`: one per line already closed. An `off`
    // landing exactly ON a terminator is excluded by the slice, which is right
    // — that byte belongs to the line it ends, not to the next one.
    const closed = std.mem.count(u8, before, &.{term});
    const start = if (std.mem.lastIndexOfScalar(u8, before, term)) |i| i + 1 else 0;
    return .{ .number = closed + 1, .line = lineFrom(bytes, term, start) };
}

/// The context band of `before` lines above and `after` below the line holding
/// `off`, clamped at both ends of the buffer. Null exactly when `locate` is.
///
/// Clamping is the correctness detail: a request wider than the file must
/// shorten the band, never renumber it and never run off either end. Walking
/// backwards is a terminator search per line rather than a whole-buffer grid,
/// so a three-line window over a megabyte file stays a three-line cost plus the
/// one prefix pass `locate` already owes for the number.
pub fn band(bytes: []const u8, term: u8, off: usize, before: usize, after: usize) ?Band {
    const hit = locate(bytes, term, off) orelse return null;

    var start = hit.line.start;
    var back: usize = 0;
    while (back < before and start > 0) : (back += 1) {
        // `start - 1` is the previous line's terminator; the line before that
        // one begins after ITS terminator, or at byte zero.
        const prev = bytes[0 .. start - 1];
        start = if (std.mem.lastIndexOfScalar(u8, prev, term)) |i| i + 1 else 0;
    }

    var end = hit.line.term_end;
    var fwd: usize = 0;
    // `end == bytes.len` ends the walk whichever way the last line finished, so
    // a trailing terminator never grows a phantom row into the band.
    while (fwd < after and end < bytes.len) : (fwd += 1) end = lineFrom(bytes, term, end).term_end;

    return .{ .number = hit.number - back, .start = start, .end = end, .len = back + 1 + fwd, .center = back };
}

/// Every line of `bytes` as an owned grid — the materialized projection, for a
/// caller with many offsets to resolve against one buffer. Caller frees.
///
/// Pre-sized from one terminator count, so the whole file is a single
/// allocation rather than the list's grow-and-copy doubling.
pub fn collect(gpa: std.mem.Allocator, bytes: []const u8, term: u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacityPrecise(gpa, count(bytes, term));
    var walk = Walk{ .bytes = bytes, .term = term };
    while (walk.next()) |line| out.appendAssumeCapacity(line);
    return out.toOwnedSlice(gpa);
}

/// The 0-based index into a `collect`ed grid of the line holding `off`, or null
/// when none does. Its 1-based number is that index plus one.
///
/// Binary search over the ascending `start` keys, so resolving M offsets
/// against one file is `O(M log N)` after the single build — the reason the
/// grid shape exists at all next to `locate`.
pub fn find(grid: []const Line, off: usize) ?usize {
    if (grid.len == 0) return null;
    const last = grid[grid.len - 1];
    if (off >= last.term_end) {
        // The same phantom rule `locate` keeps, restated at the one position a
        // half-open `holds` cannot express: past the end belongs to an
        // UNTERMINATED tail and to nothing else.
        return if (off == last.term_end and !last.terminated()) grid.len - 1 else null;
    }
    var lo: usize = 0;
    var hi: usize = grid.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (grid[mid].start <= off) lo = mid + 1 else hi = mid;
    }
    return lo - 1; // grid[0].start == 0 <= off, so lo >= 1
}

// ── tests ────────────────────────────────────────────────────────────────────
// Every expectation below is derived from an INDEPENDENT byte-at-a-time oracle
// or hand-written out, never from what this module returned.

const testing = std.testing;

/// The naive scan this module has to agree with: walk one byte at a time,
/// opening a line at position 0 and after every terminator, closing it at the
/// terminator or at the end of the buffer. Deliberately the slowest possible
/// spelling of the rule, sharing no code with the implementation.
fn oracle(gpa: std.mem.Allocator, bytes: []const u8, term: u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(gpa);
    var start: ?usize = if (bytes.len == 0) null else 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != term) continue;
        try out.append(gpa, .{ .start = start.?, .content_end = i, .term_end = i + 1 });
        start = if (i + 1 < bytes.len) i + 1 else null;
    }
    if (start) |s| try out.append(gpa, .{ .start = s, .content_end = bytes.len, .term_end = bytes.len });
    return out.toOwnedSlice(gpa);
}

/// The corpus every shape test runs over: the eight endings that decide whether
/// this primitive is better or worse than the seven copies.
const corpus = [_][]const u8{
    "", // empty file
    "\n", // a file that is one bare terminator
    "\n\n\n", // nothing but terminators
    "a", // one unterminated line
    "a\n", // one terminated line
    "abc\ndef", // an unterminated tail
    "abc\ndef\n", // a terminated tail
    "a\r\nb\r\n", // CRLF throughout
    "a\r\nb", // CRLF with an unterminated tail
    "\nleading", // an empty first line
    "mid\n\nempty\n", // an empty line in the middle
};

test "the walk agrees with a byte-at-a-time oracle on every ending" {
    const gpa = testing.allocator;
    for (corpus) |bytes| {
        const want = try oracle(gpa, bytes, newline);
        defer gpa.free(want);

        var got: std.ArrayList(Line) = .empty;
        defer got.deinit(gpa);
        var walk = Walk{ .bytes = bytes };
        while (walk.next()) |line| try got.append(gpa, line);
        try testing.expectEqualSlices(Line, want, got.items);

        // The other three projections are the same walk, so they must agree
        // with the same oracle rather than with each other.
        try testing.expectEqual(want.len, count(bytes, newline));
        const grid = try collect(gpa, bytes, newline);
        defer gpa.free(grid);
        try testing.expectEqualSlices(Line, want, grid);
    }
}

test "a terminator that is not a newline follows the identical rule" {
    const gpa = testing.allocator;
    // `-0`/`--null-data`: the same four shapes, a different byte. Nothing in
    // the rule is about `\n` specifically, and this is how that stays true.
    for ([_][]const u8{ "", "\x00", "a\x00b", "a\x00b\x00" }) |bytes| {
        const want = try oracle(gpa, bytes, 0);
        defer gpa.free(want);
        const grid = try collect(gpa, bytes, 0);
        defer gpa.free(grid);
        try testing.expectEqualSlices(Line, want, grid);
        try testing.expectEqual(want.len, count(bytes, 0));
        // And a `\n` in a NUL-delimited file is ordinary content.
        if (bytes.len > 0) try testing.expect(grid.len >= 1);
    }
}

test "locate: 1-based numbers, and the four offsets that decide correctness" {
    const bytes = "abc\ndef\nghi";

    // Numbering is 1-based and agrees with what `-n` prints.
    try testing.expectEqual(@as(usize, 1), locate(bytes, newline, 0).?.number);
    try testing.expectEqual(@as(usize, 1), locate(bytes, newline, 2).?.number);
    // An offset landing exactly ON a terminator belongs to the line that
    // terminator ENDS — not to the next one. Byte 3 is line 1's `\n`.
    try testing.expectEqual(@as(usize, 1), locate(bytes, newline, 3).?.number);
    try testing.expectEqual(@as(usize, 2), locate(bytes, newline, 4).?.number);
    try testing.expectEqual(@as(usize, 3), locate(bytes, newline, 8).?.number);

    // The unterminated tail is a real line, and the position one past the end
    // of the buffer is ON it — ripgrep frames that line.
    const tail = locate(bytes, newline, bytes.len).?;
    try testing.expectEqual(@as(usize, 3), tail.number);
    try testing.expectEqualStrings("ghi", tail.line.content(bytes));
    try testing.expect(!tail.line.terminated());

    // Past the buffer entirely is out of range, not the last line.
    try testing.expect(locate(bytes, newline, bytes.len + 1) == null);
}

test "locate: the phantom position, the empty file, and the lone terminator" {
    // A buffer ending in a terminator has nothing after it: the terminator
    // already closed the last line. This is the case a naive `count(\n) + 1`
    // gets wrong, and it would be wrong everywhere if it were wrong here.
    const closed = "abc\n";
    try testing.expectEqual(@as(usize, 1), count(closed, newline));
    try testing.expectEqual(@as(usize, 1), locate(closed, newline, 3).?.number);
    try testing.expect(locate(closed, newline, closed.len) == null);

    // An empty file holds no lines, so no offset — including zero — is on one.
    try testing.expectEqual(@as(usize, 0), count("", newline));
    try testing.expect(locate("", newline, 0) == null);

    // A file that is a single terminator holds exactly ONE empty line.
    const bare = "\n";
    try testing.expectEqual(@as(usize, 1), count(bare, newline));
    const only = locate(bare, newline, 0).?;
    try testing.expectEqual(@as(usize, 1), only.number);
    try testing.expectEqualStrings("", only.line.content(bare));
    try testing.expect(only.line.terminated());
    try testing.expect(locate(bare, newline, 1) == null);
}

test "CRLF: the carriage return is content to a matcher and absent to a printer" {
    const bytes = "alpha\r\nbeta\r\n";
    const first = locate(bytes, newline, 0).?.line;
    // rg's default (no `--crlf`) keeps the `\r` — so `content` must, or every
    // `$` anchor on a Windows file moves by one byte.
    try testing.expectEqualStrings("alpha\r", first.content(bytes));
    try testing.expectEqualStrings("alpha", first.shown(bytes));
    try testing.expectEqualStrings("alpha\r\n", first.raw(bytes));
    try testing.expectEqual(@as(usize, 2), count(bytes, newline));

    // A lone `\r` is NOT a terminator: one line, and `shown` leaves an interior
    // carriage return alone.
    const lone = "a\rb";
    try testing.expectEqual(@as(usize, 1), count(lone, newline));
    try testing.expectEqualStrings("a\rb", locate(lone, newline, 0).?.line.shown(lone));

    // An empty CRLF line is `\r` alone: content one byte, shown zero.
    const blank = "\r\n";
    const only = locate(blank, newline, 0).?.line;
    try testing.expectEqualStrings("\r", only.content(blank));
    try testing.expectEqualStrings("", only.shown(blank));
}

test "locate agrees with the oracle at every offset of every corpus buffer" {
    const gpa = testing.allocator;
    for (corpus) |bytes| {
        const want = try oracle(gpa, bytes, newline);
        defer gpa.free(want);
        // One past the end included, which is where the phantom rule lives.
        for (0..bytes.len + 1) |off| {
            // The oracle's own answer: the first line whose half-open range
            // holds `off`, or the final UNTERMINATED line when `off` is the
            // buffer's end. Written as a linear search over the oracle grid so
            // it shares nothing with `locate`'s arithmetic.
            var expected: ?usize = null;
            for (want, 0..) |line, i| {
                if (off >= line.start and off < line.term_end) expected = i;
            }
            if (expected == null and want.len > 0 and off == bytes.len) {
                const last = want[want.len - 1];
                if (last.content_end == last.term_end) expected = want.len - 1;
            }
            const got = locate(bytes, newline, off);
            if (expected) |idx| {
                try testing.expectEqual(idx + 1, got.?.number);
                try testing.expectEqual(want[idx], got.?.line);
                try testing.expectEqual(idx, find(want, off).?);
            } else {
                try testing.expect(got == null);
                try testing.expect(find(want, off) == null);
            }
        }
        try testing.expect(locate(bytes, newline, bytes.len + 1) == null);
    }
}

test "a band clamps at both ends without renumbering" {
    const bytes = "1\n2\n3\n4\n5\n";

    // Interior: the full window, centered.
    const mid = band(bytes, newline, 4, 1, 1).?; // offset 4 is on line 3
    try testing.expectEqual(@as(usize, 2), mid.number);
    try testing.expectEqual(@as(usize, 3), mid.len);
    try testing.expectEqual(@as(usize, 1), mid.center);
    try testing.expectEqualStrings("2\n3\n4\n", bytes[mid.start..mid.end]);

    // Clamped at the TOP: the band shortens and `center` moves with it. The
    // first line is still numbered 1 — a clamp never renumbers.
    const top = band(bytes, newline, 0, 3, 1).?;
    try testing.expectEqual(@as(usize, 1), top.number);
    try testing.expectEqual(@as(usize, 2), top.len);
    try testing.expectEqual(@as(usize, 0), top.center);
    try testing.expectEqualStrings("1\n2\n", bytes[top.start..top.end]);

    // Clamped at the BOTTOM: the trailing terminator must not grow a phantom
    // sixth row into the band.
    const bottom = band(bytes, newline, 8, 1, 4).?;
    try testing.expectEqual(@as(usize, 4), bottom.number);
    try testing.expectEqual(@as(usize, 2), bottom.len);
    try testing.expectEqual(@as(usize, 1), bottom.center);
    try testing.expectEqualStrings("4\n5\n", bytes[bottom.start..bottom.end]);

    // Wider than the file in BOTH directions: the whole file, once, and the
    // center still names the line that held the offset.
    const all = band(bytes, newline, 4, 99, 99).?;
    try testing.expectEqual(@as(usize, 1), all.number);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqual(@as(usize, 2), all.center);
    try testing.expectEqual(@as(usize, 0), all.start);
    try testing.expectEqual(bytes.len, all.end);

    // A zero-width window is the located line alone.
    const one = band(bytes, newline, 4, 0, 0).?;
    try testing.expectEqual(@as(usize, 3), one.number);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("3\n", bytes[one.start..one.end]);

    // No line, no band — the phantom position and the empty file both.
    try testing.expect(band(bytes, newline, bytes.len, 9, 9) == null);
    try testing.expect(band("", newline, 0, 9, 9) == null);
}

test "a band is exactly the oracle's slice, for every offset and every width" {
    const gpa = testing.allocator;
    for (corpus) |bytes| {
        const want = try oracle(gpa, bytes, newline);
        defer gpa.free(want);
        for (0..bytes.len + 1) |off| {
            const here = locate(bytes, newline, off) orelse {
                for (0..4) |b| for (0..4) |a| try testing.expect(band(bytes, newline, off, b, a) == null);
                continue;
            };
            const idx = here.number - 1;
            for (0..4) |b| for (0..4) |a| {
                // The oracle's band is a saturating slice of the grid — the
                // definition of "clamp", written without any of `band`'s
                // arithmetic.
                const first = idx -| b;
                const last = @min(idx + a, want.len - 1);
                const got = band(bytes, newline, off, b, a).?;
                try testing.expectEqual(first + 1, got.number);
                try testing.expectEqual(last - first + 1, got.len);
                try testing.expectEqual(idx - first, got.center);
                try testing.expectEqual(want[first].start, got.start);
                try testing.expectEqual(want[last].term_end, got.end);
                // And the band is walkable at absolute offsets: `len` lines
                // out of the original buffer, starting at the band's start.
                var walk = Walk{ .bytes = bytes, .pos = got.start };
                for (first..last + 1) |i| try testing.expectEqual(want[i], walk.next().?);
                try testing.expectEqual(got.end, walk.pos);
            };
        }
    }
}

test "the grid serves the offset-grid and content-slice shapes at once" {
    const gpa = testing.allocator;
    const bytes = "alpha\nbeta\ngamma";
    const grid = try collect(gpa, bytes, newline);
    defer gpa.free(grid);

    // The content-slice shape (`legible.collectLines`): the same three strings,
    // and no phantom fourth.
    try testing.expectEqual(@as(usize, 3), grid.len);
    const want = [_][]const u8{ "alpha", "beta", "gamma" };
    for (grid, want) |line, text| try testing.expectEqualStrings(text, line.content(bytes));

    // The offset-grid shape (`multiline.splitLines` + `lineIndexAt`): the same
    // three ranges, and a binary search that lands on the same line the linear
    // locator does.
    try testing.expectEqual(Line{ .start = 6, .content_end = 10, .term_end = 11 }, grid[1]);
    for (0..bytes.len + 1) |off| {
        const linear = locate(bytes, newline, off);
        const searched = find(grid, off);
        if (linear) |hit| {
            try testing.expectEqual(hit.number - 1, searched.?);
        } else try testing.expect(searched == null);
    }
    // An empty buffer has an empty grid, and nothing is found in it.
    const none = try collect(gpa, "", newline);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expect(find(none, 0) == null);
}
