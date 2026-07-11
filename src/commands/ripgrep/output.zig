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
const substitute = @import("substitute.zig");
const modes = @import("modes.zig");
const Regex = @import("../../regex/core.zig").Regex;
const Captures = @import("../../regex/captures.zig").Captures;

// Word-boundary semantics + the `-r` template engine live in `substitute.zig`
// (shared with `json.zig`/`grepfile.zig`); re-exported so `output.wordOk` /
// `output.expandInto` call sites are unchanged.
pub const isWordByte = substitute.isWordByte;
pub const wordOk = substitute.wordOk;
pub const groupIndexOf = substitute.groupIndexOf;
pub const expandInto = substitute.expandInto;

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
    /// Optional required-literal (from `literalGate`): every match must
    /// contain these bytes, so lines without them are rejected by SIMD
    /// memmem before any engine run. Purely an accelerator — never set for
    /// caseless/inverted/multi-pattern runs (the gate derivation refuses).
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
    pub fn mview(self: *Emitter, line: []const u8) []const u8 {
        return if (self.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    }

    /// Absolute byte offset of a slice (line or match span) within the file.
    pub fn offOf(self: *Emitter, slice: []const u8) usize {
        return @intFromPtr(slice.ptr) - self.base;
    }

    /// The inter-field separator: `--field-match-separator` (default `:`) on a
    /// match line, `--field-context-separator` (default `-`) on a context line.
    fn fieldSep(self: *Emitter, is_match: bool) []const u8 {
        return if (is_match) self.o.field_match_sep else self.o.field_ctx_sep;
    }

    /// Wrap `s` in `on` .. `reset` when color is active, else emit it plain.
    pub fn paint(self: *Emitter, on: []const u8, s: []const u8) void {
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
    pub fn writePath(self: *Emitter, path: []const u8, is_match: bool) void {
        self.paint(palette.path_on, path);
        if (self.o.null_sep) self.out.append(self.a, 0) catch die("oom\n", .{}) else self.paint(palette.sep_on, self.fieldSep(is_match));
    }

    /// Emit the `path:line:col:byteoff:` locator prefix (fields present per flags,
    /// separators per match/context). `--null` terminates the PATH with NUL; every
    /// other field uses the field separator. `col`/`byteoff` are 1-based / 0-based
    /// like ripgrep; `col` prints only under `--column` on a match line.
    pub fn prefix(self: *Emitter, path: []const u8, lineno: usize, col: usize, byteoff: usize, is_match: bool) void {
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
    pub fn text(self: *Emitter, line: []const u8, is_match: bool) void {
        var s = line;
        // -r/--replace: a match line is emitted with every match span replaced by
        // the expanded template (trim / max-columns then apply to the RESULT — rg's
        // order). `starts` = replacement offsets, the "match granularity" ripgrep's
        // over-long-line placeholders count against. Context lines are untouched.
        var starts: []const usize = &.{};
        if (is_match) if (self.o.replace) |tmpl| {
            const r = substitute.buildReplaced(self.a, self.caps, self.o.word, tmpl, line);
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

    pub fn file(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        const o = self.o;
        var sim = Regex.Sim.init(self.a, self.re) catch return 0;
        defer sim.deinit();
        if (o.passthru and !o.invert and !o.count_only and !o.count_matches and !o.files_only) return modes.passthru(self, path, lines);
        if (o.vimgrep and !o.invert) return modes.vimgrep(self, path, lines);
        // `--count --only-matching` counts every match span (like --count-matches),
        // not matching lines — ripgrep's documented override.
        if ((o.count_matches or (o.count_only and o.only_matching)) and !o.invert) return modes.countMatches(self, path, lines);
        if (o.only_matching and !o.invert) return if (o.replace != null) modes.onlyMatchingRepl(self, path, lines) else modes.onlyMatching(self, path, lines);

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
            const hit = if (self.needle != null and std.mem.find(u8, mv, self.needle.?) == null)
                false
            else if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(&sim, mv);
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
                const col: usize = if (is_m and css != null) modes.firstCol(self, &css.?, self.mview(lines[k])) else 0;
                self.prefix(path, k + 1, col, self.offOf(lines[k]), is_m);
                self.text(lines[k], is_m);
            }
            prev_end = hi;
        }
        return idx.items.len;
    }

    /// The `--`-style separator between non-adjacent context groups, honoring
    /// `--context-separator` (custom string) and `--no-context-separator` (none).
    fn groupSep(self: *Emitter) void {
        if (self.o.ctx_sep) |sep| self.out.print(self.a, "{s}\n", .{sep}) catch die("oom\n", .{});
    }

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
};
