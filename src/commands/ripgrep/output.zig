// MONOLITHIC: one Emitter carries shared match, context, offset, replacement, and stream state across every byte-compatible rg output mode
//! gist `rg` — the match + presentation layer (split from `run.zig`).
//!
//! `run.zig` owns the walk (gather files, apply type/glob scope, stdin); this
//! module owns everything downstream of "here is one file's bytes": line
//! splitting is done by the caller, and the `Emitter` turns matches into
//! ripgrep-shaped output — the default `path:line:text` frame, `-o` only-matching,
//! `-c/--count`, `--count-matches`, `-A/-B/-C` context windows, `-w` word spans,
//! `--column`/`-b`/`--vimgrep` locators, `-r` replacement, and the `--json`
//! record stream. One linear-time RE2-style engine backs all of it (`matchSpan`
//! for spans, `lineMatch` for the boolean path); no second matcher.

const std = @import("std");
const args = @import("args.zig");
const Opts = args.Opts;
const die = args.die;
const palette = @import("color.zig");
const simd = @import("../../scan/simd.zig");
const Regex = @import("../../regex/core.zig").Regex;
const Captures = @import("../../regex/captures.zig").Captures;

pub fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// ripgrep `-w`: a match span `[s,e)` is a word match iff bounded by a non-word
/// byte (or the line edge) on BOTH sides. Unlike `\b(pat)\b` this does not
/// require the match to contain word bytes, so a punctuation match (e.g. `.`
/// matching `.`) is still a valid word match — rg's actual semantics.
pub fn wordOk(line: []const u8, s: usize, e: usize) bool {
    const before = s == 0 or !isWordByte(line[s - 1]);
    const after = e == line.len or !isWordByte(line[e]);
    return before and after;
}

/// Resolve a `-r` group reference: an all-digit name is the numeric index; else
/// a named group looked up in the capture program. Null ⇒ unknown (→ empty).
pub fn groupIndexOf(caps: *const Captures, name: []const u8) ?u32 {
    var all_digits = true;
    for (name) |c| if (c < '0' or c > '9') {
        all_digits = false;
        break;
    };
    if (all_digits) return std.fmt.parseInt(u32, name, 10) catch null;
    return caps.groupByName(name);
}

/// Expand a `-r` replacement template into `buf`: `$1`/`${1}` numeric groups,
/// `$name`/`${name}` named groups (`$0` = whole match), `$$` → literal `$`, an
/// unknown/out-of-range group → empty (ripgrep / rust-regex `Replacer` rules).
/// Shared by the text `Emitter` and the `--json` record stream (`json.zig`).
pub fn expandInto(a: std.mem.Allocator, caps: *const Captures, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] != '$') {
            buf.append(a, tmpl[i]) catch die("oom\n", .{});
            i += 1;
            continue;
        }
        if (i + 1 < tmpl.len and tmpl[i + 1] == '$') {
            buf.append(a, '$') catch die("oom\n", .{});
            i += 2;
            continue;
        }
        i += 1;
        var name: []const u8 = "";
        if (i < tmpl.len and tmpl[i] == '{') {
            const st = i + 1;
            var j = st;
            while (j < tmpl.len and tmpl[j] != '}') j += 1;
            name = tmpl[st..j];
            i = if (j < tmpl.len) j + 1 else j;
        } else {
            const st = i;
            while (i < tmpl.len and isWordByte(tmpl[i])) i += 1;
            name = tmpl[st..i];
        }
        if (name.len == 0) {
            buf.append(a, '$') catch die("oom\n", .{});
            continue;
        }
        const gi = groupIndexOf(caps, name) orelse continue;
        if (2 * gi + 1 >= slots.len) continue; // out-of-range group → empty
        const so = slots[2 * gi];
        const eo = slots[2 * gi + 1];
        if (so >= 0 and eo >= 0) buf.appendSlice(a, line[@intCast(so)..@intCast(eo)]) catch die("oom\n", .{});
    }
}

/// `--max-columns-preview` cut point: the largest byte index ≤ `cols` that lands
/// on a UTF-8 char boundary (ripgrep counts graphemes; byte-accurate for ASCII,
/// and never splits a multi-byte scalar for the rest).
fn previewEnd(s: []const u8, cols: usize) usize {
    var end = @min(cols, s.len);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

pub const Emitter = struct {
    a: std.mem.Allocator,
    re: *const Regex,
    o: Opts,
    show_name: bool,
    out: *std.ArrayList(u8),
    /// Absolute address of the current file's byte-0 (set per file by the caller);
    /// `--byte-offset` reports `@intFromPtr(line.ptr) - base` for each line/match.
    base: usize = 0,
    /// Optional required literal from the compiled regex: every match must
    /// contain these bytes, so lines without them are rejected by SIMD
    /// memmem before any engine run. Purely an accelerator; alternations only
    /// set it when the analyzer proves one literal common to every branch.
    needle: ?[]const u8 = null,
    /// `-r/--replace` capture matcher (group-aware Pike VM), non-null only when a
    /// replacement template is active. Built once per run by the caller.
    caps: ?*Captures = null,
    /// Resolved once per run by `color.zig` (stdout tty + `--color` + env).
    /// Paints path/line-number chrome and highlights match spans when true.
    use_color: bool = false,

    /// `--crlf` match view: a trailing `\r` is treated as part of the terminator
    /// (so `$`/`\b` anchor before it) but is KEPT in the emitted line — ripgrep's
    /// CRLF behavior. Spans computed on this view index the original line 1:1
    /// (it's a prefix), so display bytes are unaffected.
    fn mview(self: *Emitter, line: []const u8) []const u8 {
        return if (self.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    }

    fn lineCanMatch(self: *const Emitter, line: []const u8) bool {
        const needle = self.needle orelse return true;
        return simd.contains(line, needle);
    }

    /// Absolute byte offset of a slice (line or match span) within the file.
    fn offOf(self: *Emitter, slice: []const u8) usize {
        return @intFromPtr(slice.ptr) - self.base;
    }

    /// The inter-field separator: `--field-match-separator` (default `:`) on a
    /// match line, `--field-context-separator` (default `-`) on a context line.
    fn fieldSep(self: *Emitter, is_match: bool) []const u8 {
        return if (is_match) self.o.field_match_sep else self.o.field_ctx_sep;
    }

    /// Wrap `s` in `on` .. `reset` when color is active, else emit it plain.
    fn paint(self: *Emitter, on: []const u8, s: []const u8) void {
        if (!self.use_color) {
            self.out.appendSlice(self.a, s) catch die("oom\n", .{});
            return;
        }
        self.out.appendSlice(self.a, on) catch die("oom\n", .{});
        self.out.appendSlice(self.a, s) catch die("oom\n", .{});
        self.out.appendSlice(self.a, palette.reset) catch die("oom\n", .{});
    }

    /// Write `path` followed by its terminator — NUL under `--null` (ripgrep's
    /// path-terminator), else the field separator. Used by the count/prefix paths.
    fn writePath(self: *Emitter, path: []const u8, is_match: bool) void {
        self.paint(palette.path_on, path);
        if (self.o.null_sep) self.out.append(self.a, 0) catch die("oom\n", .{}) else self.paint(palette.sep_on, self.fieldSep(is_match));
    }

    /// Emit the `path:line:col:byteoff:` locator prefix (fields present per flags,
    /// separators per match/context). `--null` terminates the PATH with NUL; every
    /// other field uses the field separator. `col`/`byteoff` are 1-based / 0-based
    /// like ripgrep; `col` prints only under `--column` on a match line.
    fn prefix(self: *Emitter, path: []const u8, lineno: usize, col: usize, byteoff: usize, is_match: bool) void {
        const sep = self.fieldSep(is_match);
        if (self.show_name) self.writePath(path, is_match);
        if (self.o.line_num) {
            var buf: [20]u8 = undefined;
            self.paint(palette.line_on, std.fmt.bufPrint(&buf, "{d}", .{lineno}) catch die("line number too long\n", .{}));
            self.paint(palette.sep_on, sep);
        }
        if (self.o.column and is_match and col != 0) self.out.print(self.a, "{d}{s}", .{ col, sep }) catch die("oom\n", .{});
        if (self.o.byte_offset) self.out.print(self.a, "{d}{s}", .{ byteoff, sep }) catch die("oom\n", .{});
    }

    /// Append a line's text honoring `--trim` (drop leading blanks) and
    /// `-M/--max-columns`. Over-wide lines become ripgrep's `[Omitted long …]`
    /// placeholder, or — under `--max-columns-preview` — the first `max_cols`
    /// bytes followed by ` [... omitted end of long line]`.
    fn text(self: *Emitter, line: []const u8, is_match: bool) void {
        var s = line;
        // -r/--replace: a match line is emitted with every match span replaced by
        // the expanded template (trim / max-columns then apply to the RESULT — rg's
        // order). `starts` = replacement offsets, the "match granularity" ripgrep's
        // over-long-line placeholders count against. Context lines are untouched.
        var starts: []const usize = &.{};
        if (is_match) if (self.o.replace) |tmpl| {
            const r = self.buildReplaced(tmpl, line);
            s = r.text;
            starts = r.starts;
        };
        if (self.o.trim) s = std.mem.trimStart(u8, s, " \t");
        if (self.o.max_cols != 0 and s.len > self.o.max_cols) {
            self.exceeded(s, is_match, starts);
        } else if (is_match and self.use_color and self.o.replace == null) {
            self.highlightSpans(s);
        } else self.out.appendSlice(self.a, s) catch die("oom\n", .{});
        self.out.append(self.a, self.o.term()) catch die("oom\n", .{});
    }

    /// Paint every match span within `s` (a matching line, post-trim), leaving
    /// non-matching text untouched. `s` is re-scanned independently of the
    /// caller's line-hit check — cheap (one line) and keeps this self-contained
    /// rather than threading span positions through every call site of `text`.
    /// `-r/--replace` output is excluded by the caller (the substituted text
    /// isn't "the match" any more).
    fn highlightSpans(self: *Emitter, s: []const u8) void {
        var ssim = Regex.SpanSim.init(self.a, self.re) catch {
            self.out.appendSlice(self.a, s) catch die("oom\n", .{});
            return;
        };
        defer ssim.deinit();
        const mv = self.mview(s);
        var from: usize = 0;
        var last: usize = 0;
        while (from <= mv.len) {
            const sp = self.re.matchSpan(&ssim, mv, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (self.o.word and !wordOk(mv, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            self.out.appendSlice(self.a, s[last..sp.start]) catch die("oom\n", .{});
            self.paint(palette.match_on, s[sp.start..sp.end]);
            last = sp.end;
            from = sp.end;
        }
        self.out.appendSlice(self.a, s[last..]) catch die("oom\n", .{});
    }

    /// Non-empty, `-w`-filtered match spans of `s` (on its `--crlf` view), leftmost
    /// non-overlapping — the "match granularity" `--color` gives the over-long-line
    /// renderer (rg counts/paints matches once it's highlighting). Same iteration
    /// as `highlightSpans`, materialized so `exceeded` can both paint the shown
    /// preview AND count the matches past the cut in one pass. Arena-owned.
    fn matchSpans(self: *Emitter, s: []const u8) []const Regex.Span {
        var out: std.ArrayList(Regex.Span) = .empty;
        var ssim = Regex.SpanSim.init(self.a, self.re) catch return &.{};
        defer ssim.deinit();
        const mv = self.mview(s);
        var from: usize = 0;
        while (from <= mv.len) {
            const sp = self.re.matchSpan(&ssim, mv, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (self.o.word and !wordOk(mv, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            out.append(self.a, sp) catch die("oom\n", .{});
            from = sp.end;
        }
        return out.toOwnedSlice(self.a) catch &.{};
    }

    /// ripgrep's `--max-columns` over-long-line rendering. Without match granularity
    /// it's the plain `[Omitted long …]` / ` [... omitted end of long line]`; WITH
    /// it (`-r` replacement offsets OR `--color`, which highlights so it counts) it
    /// reports match counts: `[Omitted long line with N matches]` / ` [... N more
    /// match(es)]`. `starts` are `-r` replacement offsets within `s` (empty ⇒ none).
    fn exceeded(self: *Emitter, s: []const u8, is_match: bool, starts: []const usize) void {
        const gran = starts.len != 0 or (self.o.replace != null and is_match);
        if (self.o.max_cols_preview) {
            const cut = previewEnd(s, self.o.max_cols);
            // `--color` (no `-r`): paint matches inside the shown preview and count
            // the ones that begin past the cut — rg's colored-preview behavior.
            if (self.use_color and is_match and self.o.replace == null) {
                var last: usize = 0;
                var remaining: usize = 0;
                for (self.matchSpans(s)) |sp| {
                    if (sp.start >= cut) {
                        remaining += 1;
                        continue;
                    }
                    self.out.appendSlice(self.a, s[last..sp.start]) catch die("oom\n", .{});
                    const e = @min(sp.end, cut);
                    self.paint(palette.match_on, s[sp.start..e]);
                    last = e;
                }
                self.out.appendSlice(self.a, s[last..cut]) catch die("oom\n", .{});
                self.out.print(self.a, " [... {d} more {s}]", .{ remaining, if (remaining == 1) "match" else "matches" }) catch die("oom\n", .{});
                return;
            }
            self.out.appendSlice(self.a, s[0..cut]) catch die("oom\n", .{});
            if (!gran) {
                self.out.appendSlice(self.a, " [... omitted end of long line]") catch die("oom\n", .{});
            } else {
                var remaining: usize = 0;
                for (starts) |st| if (st >= cut) {
                    remaining += 1;
                };
                self.out.print(self.a, " [... {d} more {s}]", .{ remaining, if (remaining == 1) "match" else "matches" }) catch die("oom\n", .{});
            }
            return;
        }
        if (!is_match) {
            self.out.appendSlice(self.a, "[Omitted long context line]") catch die("oom\n", .{});
        } else if (gran and !self.o.only_matching) {
            self.out.print(self.a, "[Omitted long line with {d} matches]", .{starts.len}) catch die("oom\n", .{});
        } else self.out.appendSlice(self.a, "[Omitted long matching line]") catch die("oom\n", .{});
    }

    /// The result of applying a `-r` template to a line: the rewritten text plus
    /// the byte offset (within `text`) where each replacement begins — the match
    /// granularity ripgrep uses for the `--max-columns` "N matches" placeholders.
    const Replaced = struct { text: []const u8, starts: []const usize };

    /// Build `line` with every (leftmost-first, non-overlapping) match span replaced
    /// by the expanded `-r` template. Non-matching text is copied verbatim; under
    /// `-w`, a span that isn't a word match is left in place. An empty match whose
    /// start coincides with the previous match's end is skipped (rust-regex
    /// `find_iter` progress rule), else empties advance one byte. Arena-owned.
    fn buildReplaced(self: *Emitter, tmpl: []const u8, line: []const u8) Replaced {
        const caps = self.caps orelse return .{ .text = line, .starts = &.{} };
        const slots = self.a.alloc(isize, caps.nslots) catch die("oom\n", .{});
        var buf: std.ArrayList(u8) = .empty;
        var starts: std.ArrayList(usize) = .empty;
        var from: usize = 0;
        var last_end: ?usize = null;
        while (from <= line.len and caps.find(line, from, slots)) {
            const s: usize = @intCast(slots[0]);
            const e: usize = @intCast(slots[1]);
            buf.appendSlice(self.a, line[from..s]) catch die("oom\n", .{});
            const empty_adjacent = e == s and last_end != null and s == last_end.?;
            if (empty_adjacent or (self.o.word and !wordOk(line, s, e))) {
                if (s < line.len) buf.append(self.a, line[s]) catch die("oom\n", .{});
                from = s + 1;
                continue;
            }
            starts.append(self.a, buf.items.len) catch die("oom\n", .{});
            self.expand(&buf, tmpl, line, slots);
            last_end = e;
            if (e == s) {
                if (s < line.len) buf.append(self.a, line[s]) catch die("oom\n", .{});
                from = s + 1;
            } else from = e;
        }
        if (from < line.len) buf.appendSlice(self.a, line[from..]) catch die("oom\n", .{});
        return .{ .text = buf.toOwnedSlice(self.a) catch die("oom\n", .{}), .starts = starts.toOwnedSlice(self.a) catch die("oom\n", .{}) };
    }

    fn expand(self: *Emitter, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
        expandInto(self.a, self.caps.?, buf, tmpl, line, slots);
    }

    /// `-o` with `-r`: emit the expanded template (not the raw match) for each match
    /// span across `lines`. Returns the number emitted (respecting `--max-count`).
    fn onlyMatchingRepl(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var emitted: usize = 0;
        for (lines, 0..) |line, k| {
            if (!self.lineCanMatch(self.mview(line))) continue;
            emitted += self.emitLineRepl(path, k + 1, line, emitted);
            if (self.o.max_per_file != 0 and emitted >= self.o.max_per_file) break;
        }
        return emitted;
    }

    /// Emit each match on one line as its expanded `-r` template (the `-o` frame),
    /// `so_far` matches already counted toward `--max-count`. Returns the count on
    /// this line.
    fn emitLineRepl(self: *Emitter, path: []const u8, lineno: usize, line: []const u8, so_far: usize) usize {
        const caps = self.caps.?;
        const tmpl = self.o.replace.?;
        const slots = self.a.alloc(isize, caps.nslots) catch die("oom\n", .{});
        var n: usize = 0;
        var from: usize = 0;
        while (from <= line.len and caps.find(line, from, slots)) {
            const s: usize = @intCast(slots[0]);
            const e: usize = @intCast(slots[1]);
            if (e == s) {
                from = s + 1;
                continue;
            }
            if (self.o.word and !wordOk(line, s, e)) {
                from = e;
                continue;
            }
            self.prefix(path, lineno, s + 1, self.offOf(line) + s, true);
            self.expand(self.out, tmpl, line, slots);
            self.out.append(self.a, self.o.term()) catch die("oom\n", .{});
            n += 1;
            if (self.o.max_per_file != 0 and so_far + n >= self.o.max_per_file) break;
            from = e;
        }
        return n;
    }

    /// 1-based byte column of the first (word-valid, non-empty) match on the line,
    /// or 0 if none — the value ripgrep prints under `--column`.
    fn firstCol(self: *Emitter, ssim: *Regex.SpanSim, line: []const u8) usize {
        var from: usize = 0;
        while (from <= line.len) {
            const sp = self.re.matchSpan(ssim, line, from) orelse return 0;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (self.o.word and !wordOk(line, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            return sp.start + 1;
        }
        return 0;
    }

    pub fn file(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        const o = self.o;
        var sim = Regex.Sim.init(self.a, self.re) catch return 0;
        defer sim.deinit();
        if (o.passthru and !o.invert and !o.count_only and !o.count_matches and !o.files_only) return self.passthru(path, lines);
        if (o.vimgrep and !o.invert) return self.vimgrep(path, lines);
        // `--count --only-matching` counts every match span (like --count-matches),
        // not matching lines — ripgrep's documented override.
        if ((o.count_matches or (o.count_only and o.only_matching)) and !o.invert) return self.countMatches(path, lines);
        if (o.only_matching and !o.invert) return if (o.replace != null) self.onlyMatchingRepl(path, lines) else self.onlyMatching(path, lines);

        // `-w` decides a line via the span predicate; the plain path uses the
        // boolean DFA. Only `-w` pays for the SpanSim scratch.
        var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        var idx: std.ArrayList(usize) = .empty;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            // A required-literal gate (when the caller derived one): a line
            // without the literal bytes cannot match, and a SIMD memmem is an
            // order of magnitude cheaper than an engine run per line.
            const hit = self.lineCanMatch(mv) and
                (if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(&sim, mv));
            if (hit == o.invert) {
                // --stop-on-nonmatch: once matching has begun, the first non-match
                // ends the file (ripgrep stops reading further lines).
                if (o.stop_on_nonmatch and idx.items.len > 0) break;
                continue;
            }
            idx.append(self.a, k) catch die("oom\n", .{});
            if (o.max_per_file != 0 and idx.items.len >= o.max_per_file) break;
        }
        if (idx.items.len == 0) return 0;
        if (o.files_only) {
            self.out.print(self.a, "{s}{c}", .{ path, if (o.null_sep) @as(u8, 0) else '\n' }) catch die("oom\n", .{});
            return idx.items.len;
        }
        if (o.count_only or o.count_matches) {
            if (self.show_name) self.writePath(path, true);
            self.out.print(self.a, "{d}\n", .{idx.items.len}) catch die("oom\n", .{});
            return idx.items.len;
        }
        const is_match = self.a.alloc(bool, lines.len) catch die("oom\n", .{});
        @memset(is_match, false);
        for (idx.items) |m| is_match[m] = true;
        // Column locators need a span scan per match line; only pay for it under
        // --column (or --column implied by --vimgrep, handled separately).
        var css: ?Regex.SpanSim = if (o.column) (Regex.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (css) |*s| s.deinit();
        const B = o.before;
        const A = o.after;
        var prev_end: ?usize = null;
        for (idx.items) |m| {
            const lo = if (m >= B) m - B else 0;
            const hi = @min(m + A, lines.len - 1);
            var start = lo;
            if (prev_end) |pe| {
                if (lo > pe + 1) {
                    if (o.wantsContext()) self.groupSep();
                } else if (hi <= pe) {
                    continue;
                } else start = pe + 1;
            }
            var k = start;
            while (k <= hi) : (k += 1) {
                const is_m = is_match[k];
                const col: usize = if (is_m and css != null) self.firstCol(&css.?, self.mview(lines[k])) else 0;
                self.prefix(path, k + 1, col, self.offOf(lines[k]), is_m);
                self.text(lines[k], is_m);
            }
            prev_end = hi;
        }
        return idx.items.len;
    }

    /// `--passthru`: emit EVERY line of the file (matching lines framed as matches,
    /// the rest as context) — ripgrep's "context of infinity". Returns the count of
    /// matching lines (for the exit code); output is written regardless of matches.
    fn passthru(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        const o = self.o;
        var sim = Regex.Sim.init(self.a, self.re) catch return 0;
        defer sim.deinit();
        var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        var css: ?Regex.SpanSim = if (o.column) (Regex.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (css) |*s| s.deinit();
        var mss: ?Regex.SpanSim = if (o.only_matching) (Regex.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (mss) |*s| s.deinit();
        var matched: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            const is_m = self.lineCanMatch(mv) and
                (if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(&sim, mv));
            if (is_m) matched += 1;
            // --passthru -o: a matching line contributes each match span (only-
            // matching frame), a non-matching line still prints in full (context).
            if (is_m and mss != null) {
                if (self.o.replace != null) _ = self.emitLineRepl(path, k + 1, line, 0) else _ = self.emitMatches(&mss.?, path, k + 1, line, mv);
                continue;
            }
            const col: usize = if (is_m and css != null) self.firstCol(&css.?, mv) else 0;
            self.prefix(path, k + 1, col, self.offOf(line), is_m);
            self.text(line, is_m);
        }
        return matched;
    }

    /// Emit each match span on one line in the only-matching frame (shared by
    /// `-o` and `--passthru -o`). `mv` is the `--crlf` match view of `line`.
    /// Returns the number of spans emitted.
    fn emitMatches(self: *Emitter, ssim: *Regex.SpanSim, path: []const u8, lineno: usize, line: []const u8, mv: []const u8) usize {
        var from: usize = 0;
        var n: usize = 0;
        var last_end: ?usize = null;
        while (from <= mv.len) {
            const span = self.re.matchSpan(ssim, mv, from) orelse break;
            if (span.end == span.start) {
                // rg `find_iter` yields zero-width matches too, but only for a
                // nullable regex (`-o ''`, `a*`) and never one adjacent to the
                // previous match's end (the progress rule) — so a non-nullable
                // pattern's output is byte-identical to before. An empty match
                // prints an empty `-o` line (word-checked under `-w`).
                const adjacent = last_end != null and span.start == last_end.?;
                if (!self.re.nullable or adjacent or (self.o.word and !wordOk(mv, span.start, span.end))) {
                    from = span.start + 1;
                    continue;
                }
                self.prefix(path, lineno, span.start + 1, self.offOf(line) + span.start, true);
                self.out.append(self.a, self.o.term()) catch die("oom\n", .{});
                n += 1;
                last_end = span.end;
                from = span.start + 1;
                continue;
            }
            if (self.o.word and !wordOk(mv, span.start, span.end)) {
                from = span.end;
                continue;
            }
            self.prefix(path, lineno, span.start + 1, self.offOf(line) + span.start, true);
            const end = if (self.o.crlf and span.end == mv.len) line.len else span.end;
            self.paint(palette.match_on, line[span.start..end]);
            self.out.append(self.a, self.o.term()) catch die("oom\n", .{});
            n += 1;
            last_end = span.end;
            from = span.end;
        }
        return n;
    }

    /// The `--`-style separator between non-adjacent context groups, honoring
    /// `--context-separator` (custom string) and `--no-context-separator` (none).
    fn groupSep(self: *Emitter) void {
        if (self.o.ctx_sep) |sep| self.out.print(self.a, "{s}\n", .{sep}) catch die("oom\n", .{});
    }

    /// `--vimgrep`: one `path:line:col:text` row per match (all matches on a line),
    /// line numbers and columns always on. Never groups.
    fn vimgrep(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim = Regex.SpanSim.init(self.a, self.re) catch return 0;
        defer ssim.deinit();
        var emitted: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            var from: usize = 0;
            while (from <= mv.len) {
                const sp = self.re.matchSpan(&ssim, mv, from) orelse break;
                if (sp.end == sp.start) {
                    from = sp.start + 1;
                    continue;
                }
                if (self.o.word and !wordOk(mv, sp.start, sp.end)) {
                    from = sp.end;
                    continue;
                }
                self.prefix(path, k + 1, sp.start + 1, self.offOf(line) + sp.start, true);
                self.text(line, true);
                emitted += 1;
                if (self.o.max_per_file != 0 and emitted >= self.o.max_per_file) return emitted;
                from = sp.end;
            }
        }
        return emitted;
    }

    /// Does any word-bounded match span exist on this line? (`-w` boolean path.)
    pub fn lineHitWord(self: *Emitter, ssim: *Regex.SpanSim, line: []const u8) bool {
        var from: usize = 0;
        while (from <= line.len) {
            const sp = self.re.matchSpan(ssim, line, from) orelse return false;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (wordOk(line, sp.start, sp.end)) return true;
            from = sp.end;
        }
        return false;
    }

    fn onlyMatching(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim = Regex.SpanSim.init(self.a, self.re) catch return 0;
        defer ssim.deinit();
        var emitted: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            emitted += self.emitMatches(&ssim, path, k + 1, line, mv);
            if (self.o.max_per_file != 0 and emitted >= self.o.max_per_file) break;
        }
        return emitted;
    }

    fn countMatches(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim = Regex.SpanSim.init(self.a, self.re) catch return 0;
        defer ssim.deinit();
        var total: usize = 0;
        for (lines) |line| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            var from: usize = 0;
            while (from <= mv.len) {
                const span = self.re.matchSpan(&ssim, mv, from) orelse break;
                if (span.end == span.start) {
                    from = span.start + 1;
                    continue;
                }
                if (self.o.word and !wordOk(mv, span.start, span.end)) {
                    from = span.end;
                    continue;
                }
                total += 1;
                if (self.o.max_per_file != 0 and total >= self.o.max_per_file) break;
                from = span.end;
            }
        }
        if (total == 0) return 0;
        if (self.show_name) self.writePath(path, true);
        self.out.print(self.a, "{d}\n", .{total}) catch die("oom\n", .{});
        return total;
    }
};

test "required literal line gate handles sub-trigram needles" {
    const t = std.testing;
    var re = try Regex.compile(t.allocator, "[0-9a-f]{8}-[0-9a-f]{4}");
    defer re.deinit();
    var out: std.ArrayList(u8) = .empty;
    var em = Emitter{
        .a = t.allocator,
        .re = &re,
        .o = .{},
        .show_name = false,
        .out = &out,
        .needle = re.required,
    };

    try t.expectEqualStrings("-", re.required);
    try t.expect(!em.lineCanMatch("abcdef012345"));
    try t.expect(em.lineCanMatch("deadbeef-cafe"));
}
