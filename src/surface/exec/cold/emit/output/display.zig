//! gist `rg` — what a selected line LOOKS like on the way out.
//!
//! Split from `output.zig`: the mode drivers decide *which* lines print, this
//! module decides what their bytes are. `--trim` drops the blank prefix,
//! `-M/--max-columns` swaps an over-wide line for ripgrep's placeholder (or a
//! `--max-columns-preview` cut), `--color` paints the match spans, and the
//! terminator model picks between reconstructing a line's original bytes and
//! appending the full output terminator.
//!
//! It also owns the two row SHAPES more than one driver emits — the `-o`
//! only-matching frame (`grid` per-line, `skim` line-free literal) and the
//! `--vimgrep` per-match row (`grid` and `multibuf`) — because one
//! implementation is what keeps their bytes from drifting.

const std = @import("std");
const args = @import("../../argv/args.zig");
const oom = args.oom;
const palette = @import("../color.zig");
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
const Regex = @import("../../../../../kernel/match/regex/regex.zig").Regex;
const output = @import("../output.zig");
const Emitter = output.Emitter;
const replace = @import("replace.zig");

/// Byte length of a line's `--trim`-able blank prefix (spaces and tabs).
/// `pub`: `multibuf` intersects it with a match span to trim `-U -o` fragments.
pub fn blankPrefix(s: []const u8) usize {
    return s.len - std.mem.trimStart(u8, s, " \t").len;
}

/// `--max-columns-preview` cut point: the largest byte index ≤ `cols` that lands
/// on a UTF-8 char boundary (ripgrep counts graphemes; byte-accurate for ASCII,
/// and never splits a multi-byte scalar for the rest).
fn previewEnd(s: []const u8, cols: usize) usize {
    var end = @min(cols, s.len);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

/// Append a line's text honoring `--trim` (drop leading blanks) and
/// `-M/--max-columns`. Over-wide lines become ripgrep's `[Omitted long …]`
/// placeholder, or — under `--max-columns-preview` — the first `max_cols`
/// bytes followed by ` [... omitted end of long line]`.
pub fn text(self: *Emitter, line: []const u8, is_match: bool) void {
    var s = line;
    // -r/--replace: a match line is emitted with every match span replaced by
    // the expanded template (trim / max-columns then apply to the RESULT — rg's
    // order). `starts` = replacement offsets, the "match granularity" ripgrep's
    // over-long-line placeholders count against. Context lines are untouched.
    var starts: []const usize = &.{};
    // Terminator provenance reads off the RAW slice (a rewritten `-r` body
    // is not file-backed, but rg keys the append off the original line).
    const terminated = self.lineTerminated(line);
    if (is_match) if (self.o.replace) |tmpl| {
        const r = replace.buildReplaced(self, tmpl, line);
        s = r.text;
        starts = r.starts;
    };
    emitBody(self, s, is_match, starts, terminated, .{});
}

/// The two knobs rg's `-U` per-match sink answers differently from every other
/// "print this line body" path. Defaults are the line sink's answers.
pub const Body = struct {
    /// Measure the `-M/--max-columns` width WITHOUT the line terminator.
    /// rg's per-match multiline printer strips it before the width test
    /// (`standard.rs` `sink_slow_multi_per_match`), so `rg -U --vimgrep -M9`
    /// still prints a nine-byte line where the line sink omits it.
    bare_width: bool = false,
    /// How many matches the `-M` placeholder reports; 0 ⇒ `starts.len`. rg
    /// counts the SINK EVENT's matches, and a `-U` event is a whole block, so
    /// one row of a four-match block says "with 4 matches" even though the row
    /// carries one.
    tally: usize = 0,
};

/// The presentation tail shared by every "print this line body" path:
/// `--trim`, then `-M/--max-columns` placeholders (with `starts` as the
/// match granularity), then color, then the terminator. `starts` are
/// replacement offsets within `s_in`; trimming rebases them (an offset
/// inside the trimmed whitespace clamps to 0 — before any cut, like rg's
/// block-coordinate comparison).
pub fn emitBody(self: *Emitter, s_in: []const u8, is_match: bool, starts_in: []const usize, terminated: bool, b: Body) void {
    var s = s_in;
    var starts = starts_in;
    if (self.o.trim) {
        const trimmed = std.mem.trimStart(u8, s, " \t");
        const n = s.len - trimmed.len;
        if (n != 0 and starts.len != 0) {
            const adj = self.a.alloc(usize, starts.len) catch oom();
            for (starts, 0..) |st, i| adj[i] = st -| n;
            starts = adj;
        }
        s = trimmed;
    }
    // Terminator model (rg parity): a REWRITTEN body (`-M` placeholder /
    // preview, colored line) lost its `\r`, so rg appends the full output
    // terminator; a verbatim body reconstructs its original bytes — the
    // split `\n`/NUL for a terminated line (any `\r` is still in `s`), the
    // full terminator for the file's unterminated tail.
    //
    // `-M` measures the line WITH its terminator byte (rg slices lines
    // terminator-inclusive, and appends the terminator to a `-r` rewrite
    // before the width check) — an unterminated tail measures bare, and
    // `-o` fragments (bufOnly) measure bare too.
    const width = s.len + @intFromBool(terminated and !b.bare_width);
    const term = if (self.o.max_cols != 0 and width > self.o.max_cols) blk: {
        exceeded(self, s, is_match, starts, b.tally);
        break :blk self.o.outTerm();
    } else if (is_match and self.use_color and self.o.replace == null) blk: {
        // rg's colored writer trims the terminator (incl. `\r`) and
        // re-appends it, normalizing even a unix line to `\r\n` under
        // `--crlf` — mirror that exactly.
        highlightSpans(self, self.mview(s));
        break :blk self.o.outTerm();
    } else blk: {
        self.add(s);
        break :blk if (terminated) self.o.termStr() else self.o.outTerm();
    };
    // `--hyperlink` scope `row` holds the anchor open across the body, so the
    // click target is the whole result line; the terminator stays outside it.
    // A no-op in every other scope (the locator already closed its own).
    self.linkClose();
    self.add(term);
}

/// Paint every match span within `s` (a matching line, post-trim), leaving
/// non-matching text untouched. `s` is re-scanned independently of the
/// caller's line-hit check — cheap (one line) and keeps this self-contained
/// rather than threading span positions through every call site of `text`.
/// `-r/--replace` output is excluded by the caller (the substituted text
/// isn't "the match" any more). Spans step through `nextSpan` over the
/// `--crlf` view (a prefix of `s`, so indexes carry over 1:1); if the span
/// simulator can't be built (engine without span support) the line emits
/// unpainted (`matchSpans` returns no spans).
fn highlightSpans(self: *Emitter, s: []const u8) void {
    var last: usize = 0;
    for (matchSpans(self, s)) |sp| {
        self.add(s[last..sp.start]);
        self.paint(palette.match_on, s[sp.start..sp.end]);
        last = sp.end;
    }
    self.add(s[last..]);
}

/// The same span walk materialized, so `exceeded` can both paint the shown
/// preview AND count the matches past the cut in one pass — the "match
/// granularity" `--color` gives the over-long-line renderer. Arena-owned;
/// empty when the span simulator can't be built.
fn matchSpans(self: *Emitter, s: []const u8) []const Matcher.Span {
    var out: std.ArrayList(Matcher.Span) = .empty;
    var ss = Matcher.SpanSim.init(self.a, self.re) catch return &.{};
    defer ss.deinit();
    const mv = self.mview(s);
    var from: usize = 0;
    while (output.nextSpan(self.re, &ss, self.o, mv, &from)) |sp| out.append(self.a, sp) catch oom();
    return out.toOwnedSlice(self.a) catch &.{};
}

/// ripgrep's `--max-columns` over-long-line rendering. Without match granularity
/// it's the plain `[Omitted long …]` / ` [... omitted end of long line]`; WITH
/// it (`-r` replacement offsets OR `--color`, which highlights so it counts) it
/// reports match counts: `[Omitted long line with N matches]` / ` [... N more
/// match(es)]`. `starts` are `-r` replacement offsets within `s` (empty ⇒ none).
/// `tally` overrides the reported count (0 ⇒ `starts.len`) for a sink whose
/// event holds more matches than the row does; the preview's "N more" always
/// counts `starts`, since rg asks it of the row's own matches.
pub fn exceeded(self: *Emitter, s: []const u8, is_match: bool, starts: []const usize, tally: usize) void {
    const gran = starts.len != 0 or (self.o.replace != null and is_match);
    if (self.o.max_cols_preview) {
        const cut = previewEnd(s, self.o.max_cols);
        var remaining: usize = 0;
        // `--color` (no `-r`): paint matches inside the shown preview and count
        // the ones that begin past the cut — rg's colored-preview behavior.
        if (self.use_color and is_match and self.o.replace == null) {
            var last: usize = 0;
            for (matchSpans(self, s)) |sp| {
                if (sp.start >= cut) {
                    remaining += 1;
                    continue;
                }
                self.add(s[last..sp.start]);
                const e = @min(sp.end, cut);
                self.paint(palette.match_on, s[sp.start..e]);
                last = e;
            }
            self.add(s[last..cut]);
        } else {
            self.add(s[0..cut]);
            if (!gran) return self.add(" [... omitted end of long line]");
            for (starts) |st| remaining += @intFromBool(st >= cut);
        }
        return self.out.print(self.a, " [... {d} more {s}]", .{ remaining, if (remaining == 1) "match" else "matches" }) catch oom();
    }
    if (!is_match) {
        self.add("[Omitted long context line]");
    } else if (gran and !self.o.only_matching) {
        self.out.print(self.a, "[Omitted long line with {d} matches]", .{if (tally != 0) tally else starts.len}) catch oom();
    } else self.add("[Omitted long matching line]");
}

/// One line's worth of `--vimgrep` rows, as its driver resolved them. The
/// fields are the span PROVENANCE a caller owns; `vimgrepLine` owns the shape.
pub const Vimgrep = struct {
    path: []const u8,
    lineno: usize,
    /// The row body — the whole line, already the `-r` rewrite when there is one.
    text: []const u8,
    /// Byte offset of `text`'s line within the file.
    off: usize,
    /// Each match's start within `text`, in order. Drives the columns, and the
    /// `-M` match granularity.
    starts: []const usize,
    /// Did the line carry a terminator in the file (`emitBody`'s bytes model)?
    terminated: bool,
    /// Which of ripgrep's two sinks produced this row. They are two printer
    /// functions with three separately-drifting answers, so naming the sink
    /// once settles all three:
    ///
    /// - **`--byte-offset`** — `line` reports the MATCH's offset, `block` the
    ///   printed LINE's. `rg -U --vimgrep -b 'one[\s\S]*?two|B'` over
    ///   `one\nmid\ntwo B` prints the second row at line 3's start, neither
    ///   the match's offset nor the block's.
    /// - **`-M` width** — `block` measures the line bare (see `Body`).
    /// - **`-M` tally** — `block` reports `tally`, the whole event's matches.
    ///
    /// A `block` row carries exactly ONE match: rg's multiline printer walks
    /// per match, not per line.
    sink: enum { line, block } = .line,
    /// The event's match count, for a `block` row's `-M` placeholder.
    tally: usize = 0,
};

/// `--vimgrep`: the rows ONE selected line contributes — a `path:line:col:text`
/// row per match opening on it, each carrying the whole line.
///
/// A row SHAPE, not an output mode, which is why it lives here and not in a
/// mode driver: `grid` (physical lines) and `multibuf` (`-U` spans) swap it in
/// for their `row()` call and keep their own context windows, `--` separators,
/// and `-m` accounting — how `--vimgrep` composes with `-A/-B/-C` and
/// `--passthru` exactly as rg's does (`-m` therefore caps matching LINES, so
/// `-m1` still prints every match on the first one). The modes that replace the
/// rows outright — `-l`, `-c`, `--count-matches`, `-o` — return before any frame.
///
/// Holding it in one place is what keeps the two drivers' bytes together: the
/// column, the `--byte-offset`, and the `-M/--max-columns` granularity (rg's
/// per-match printer counts the line's matches — `[Omitted long line with N
/// matches]` — where the plain frame says `[Omitted long matching line]`) are
/// decided once here instead of twice, which is how they drifted before.
pub fn vimgrepLine(self: *Emitter, v: Vimgrep) void {
    const block = v.sink == .block;
    for (v.starts) |st| {
        self.prefix(v.path, v.lineno, st + 1, v.off + if (block) 0 else st, true);
        emitBody(self, v.text, true, v.starts, v.terminated, .{ .bare_width = block, .tally = v.tally });
    }
}

/// Emit each match span on one line in the only-matching frame (shared by
/// `-o` and `--passthru -o`). `mv` is the `--crlf` match view of `line`.
/// Returns the number of spans emitted.
pub fn emitMatches(self: *Emitter, ssim: *Matcher.SpanSim, path: []const u8, lineno: usize, line: []const u8, mv: []const u8) usize {
    var from: usize = 0;
    var n: usize = 0;
    var last_end: ?usize = null;
    while (from <= mv.len) {
        const span = self.re.matchSpan(ssim, mv, from) orelse break;
        const empty = span.end == span.start;
        from = if (empty) span.start + 1 else span.end;
        // rg `find_iter` yields zero-width matches too, but only for a
        // nullable regex (`-o ''`, `a*`) and never one adjacent to the
        // previous match's end (the progress rule) — so a non-nullable
        // pattern's output is byte-identical to before. An empty match
        // prints an empty `-o` line (word-checked under `-w`).
        const adjacent = empty and last_end != null and span.start == last_end.?;
        if ((empty and !self.re.nullable()) or adjacent or
            (self.o.word and !output.wordOk(self.o.unicode, mv, span.start, span.end))) continue;
        self.prefix(path, lineno, span.start + 1, self.offOf(line) + span.start, true);
        // `-o` emits bare match bytes + the full output terminator (rg's
        // printer): under `--crlf` every fragment ends `\r\n`, so a match
        // reaching the logical line end needs no `\r`-reattachment.
        if (!empty) self.paint(palette.match_on, line[span.start..span.end]);
        self.linkClose(); // scope `row`: the fragment is part of the click target
        self.add(self.o.outTerm());
        n += 1;
        last_end = span.end;
    }
    return n;
}

/// The `--vimgrep` row shape's own harness: no engine is consulted (the caller
/// resolved the spans), so a bare `Matcher` suffices to hold the `Emitter`.
fn vimgrepBytes(a: std.mem.Allocator, out: *std.ArrayList(u8), o: args.Opts, v: Vimgrep) !void {
    var m = Matcher{ .linear = try Regex.compile(a, "x") };
    defer m.deinit();
    var em = Emitter{ .a = a, .re = &m, .o = o, .show_name = true, .out = out };
    vimgrepLine(&em, v);
}

test "one row per match, each with its own column" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try vimgrepBytes(t.allocator, &out, .{ .line_num = true, .column = true }, .{
        .path = "a.txt",
        .lineno = 1,
        .text = "alpha beta alpha",
        .off = 0,
        .starts = &.{ 0, 11 },
        .terminated = true,
    });
    try t.expectEqualStrings(
        \\a.txt:1:1:alpha beta alpha
        \\a.txt:1:12:alpha beta alpha
        \\
    , out.items);
}

test "--byte-offset follows the sink: the match's, or the printed line's" {
    const t = std.testing;
    const o: args.Opts = .{ .line_num = true, .column = true, .byte_offset = true };
    const v: Vimgrep = .{ .path = "a.txt", .lineno = 3, .text = "zzz alpha zzz", .off = 23, .starts = &.{ 4, 10 }, .terminated = true };

    var block_sink: std.ArrayList(u8) = .empty;
    defer block_sink.deinit(t.allocator);
    var v_block = v;
    v_block.sink = .block;
    try vimgrepBytes(t.allocator, &block_sink, o, v_block);
    // `-U` block sink: every row reports the LINE's offset (rg 14.x).
    try t.expectEqualStrings("a.txt:3:5:23:zzz alpha zzz\na.txt:3:11:23:zzz alpha zzz\n", block_sink.items);

    var line_sink: std.ArrayList(u8) = .empty;
    defer line_sink.deinit(t.allocator);
    try vimgrepBytes(t.allocator, &line_sink, o, v); // default `.line`
    try t.expectEqualStrings("a.txt:3:5:27:zzz alpha zzz\na.txt:3:11:33:zzz alpha zzz\n", line_sink.items);
}

test "-M: the block sink measures bare and reports its whole event's tally" {
    const t = std.testing;
    const o: args.Opts = .{ .line_num = true, .column = true, .max_cols = 8 };
    const v: Vimgrep = .{ .path = "w.txt", .lineno = 1, .text = "start one", .off = 0, .starts = &.{6}, .terminated = true, .sink = .block, .tally = 4 };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try vimgrepBytes(t.allocator, &out, o, v);
    // Nine bare bytes over a limit of eight: omitted, counting the event.
    try t.expectEqualStrings("w.txt:1:7:[Omitted long line with 4 matches]\n", out.items);

    var fits: std.ArrayList(u8) = .empty;
    defer fits.deinit(t.allocator);
    var wide = o;
    wide.max_cols = 9;
    try vimgrepBytes(t.allocator, &fits, wide, v);
    // The terminator is not part of the width here, so nine bytes still fit —
    // the line sink would have measured ten and omitted this row.
    try t.expectEqualStrings("w.txt:1:7:start one\n", fits.items);
}

test "-M reports the line's match count, not the plain placeholder" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    // rg's per-match printer has match granularity, so an over-wide vimgrep
    // line says "with N matches" where the plain frame says "long matching line".
    try vimgrepBytes(t.allocator, &out, .{ .line_num = true, .column = true, .max_cols = 4 }, .{
        .path = "w.txt",
        .lineno = 1,
        .text = "aaXbbXcc",
        .off = 0,
        .starts = &.{ 2, 5 },
        .terminated = true,
    });
    try t.expectEqualStrings(
        \\w.txt:1:3:[Omitted long line with 2 matches]
        \\w.txt:1:6:[Omitted long line with 2 matches]
        \\
    , out.items);
}
