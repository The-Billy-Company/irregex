//! gist `rg` — what a selected line LOOKS like on the way out.
//!
//! Split from `output.zig`: the mode drivers decide *which* lines print, this
//! module decides what their bytes are. `--trim` drops the blank prefix,
//! `-M/--max-columns` swaps an over-wide line for ripgrep's placeholder (or a
//! `--max-columns-preview` cut), `--color` paints the match spans, and the
//! terminator model picks between reconstructing a line's original bytes and
//! appending the full output terminator.
//!
//! It also owns the `-o` only-matching frame, because `grid` (per-line) and
//! `skim` (line-free literal) both emit it — one implementation is what keeps
//! their fragment bytes from drifting.

const std = @import("std");
const args = @import("../../argv/args.zig");
const oom = args.oom;
const palette = @import("../color.zig");
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
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
    emitBody(self, s, is_match, starts, terminated);
}

/// The presentation tail shared by every "print this line body" path:
/// `--trim`, then `-M/--max-columns` placeholders (with `starts` as the
/// match granularity), then color, then the terminator. `starts` are
/// replacement offsets within `s_in`; trimming rebases them (an offset
/// inside the trimmed whitespace clamps to 0 — before any cut, like rg's
/// block-coordinate comparison).
pub fn emitBody(self: *Emitter, s_in: []const u8, is_match: bool, starts_in: []const usize, terminated: bool) void {
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
    const width = s.len + @intFromBool(terminated);
    if (self.o.max_cols != 0 and width > self.o.max_cols) {
        exceeded(self, s, is_match, starts);
        self.add(self.o.outTerm());
    } else if (is_match and self.use_color and self.o.replace == null) {
        // rg's colored writer trims the terminator (incl. `\r`) and
        // re-appends it, normalizing even a unix line to `\r\n` under
        // `--crlf` — mirror that exactly.
        highlightSpans(self, self.mview(s));
        self.add(self.o.outTerm());
    } else {
        self.add(s);
        self.add(if (terminated) self.o.termStr() else self.o.outTerm());
    }
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
pub fn exceeded(self: *Emitter, s: []const u8, is_match: bool, starts: []const usize) void {
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
        self.out.print(self.a, "[Omitted long line with {d} matches]", .{starts.len}) catch oom();
    } else self.add("[Omitted long matching line]");
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
        self.add(self.o.outTerm());
        n += 1;
        last_end = span.end;
    }
    return n;
}
