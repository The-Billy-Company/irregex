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
const args = @import("../argv/args.zig");
const Opts = args.Opts;
const die = args.die;
const oom = args.oom;
const palette = @import("color.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");
const ml = @import("multiline.zig");
const Regex = @import("../../../../kernel/match/regex/linear/core.zig").Regex;
const Matcher = @import("../../../../kernel/match/regex/linear/matcher.zig").Matcher;
const captures_mod = @import("../../../../kernel/match/regex/compile/captures.zig");
const Caps = captures_mod.Caps;
const Captures = captures_mod.Captures;
const word = @import("../../../../kernel/match/regex/syntax/word.zig");

pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// ripgrep `-w`: a match span `[s,e)` is a word match iff bounded by a non-word
/// CODEPOINT (or the line edge) on BOTH sides. Unlike `\b(pat)\b` this does not
/// require the match to contain word chars, so a punctuation match (e.g. `.`
/// matching `.`) is still a valid word match — rg's actual semantics. The word
/// test is the engines' shared `\b` oracle (`syntax/word.zig`): Unicode-aware
/// by default (`中`/`é`/Cyrillic beside a match kill it, exactly as rg), the
/// ASCII byte class under `--no-unicode` — caught by the multi-corpus sweep
/// (linux/subtitles/typescript `-w` counts all diverged on non-ASCII text).
pub fn wordOk(unicode: bool, line: []const u8, s: usize, e: usize) bool {
    return !word.wordBefore(unicode, line, s) and !word.wordAt(unicode, line, e);
}

/// Next non-empty (and, under `-w`, word-valid) match span at/after `from.*`,
/// advancing `from` past it: a zero-width span skips one byte (the progress
/// rule), a word-rejected span advances to its end. THE span-iteration loop —
/// the text emitter and the `--json` stream both step through it, so the two
/// can never drift on which spans count as "a match".
pub fn nextSpan(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, s: []const u8, from: *usize) ?Matcher.Span {
    while (from.* <= s.len) {
        const sp = re.matchSpan(ss, s, from.*) orelse return null;
        if (sp.end == sp.start) {
            from.* = sp.start + 1;
            continue;
        }
        from.* = sp.end;
        if (o.word and !wordOk(o.unicode, s, sp.start, sp.end)) continue;
        return sp;
    }
    return null;
}

/// Resolve a `-r` group reference: an all-digit name is the numeric index; else
/// a named group looked up in the capture program. Null ⇒ unknown (→ empty).
pub fn groupIndexOf(caps: *const Caps, name: []const u8) ?u32 {
    for (name) |c| if (!std.ascii.isDigit(c)) return caps.groupByName(name);
    return std.fmt.parseInt(u32, name, 10) catch null;
}

/// Expand a `-r` replacement template into `buf`: `$1`/`${1}` numeric groups,
/// `$name`/`${name}` named groups (`$0` = whole match), `$$` → literal `$`, an
/// unknown/out-of-range group → empty (ripgrep / rust-regex `Replacer` rules).
/// Shared by the text `Emitter` and the `--json` record stream (`json.zig`).
pub fn expandInto(a: std.mem.Allocator, caps: *const Caps, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] != '$') {
            buf.append(a, tmpl[i]) catch oom();
            i += 1;
            continue;
        }
        if (i + 1 < tmpl.len and tmpl[i + 1] == '$') {
            buf.append(a, '$') catch oom();
            i += 2;
            continue;
        }
        i += 1;
        const name = if (i < tmpl.len and tmpl[i] == '{') blk: {
            const st = i + 1;
            const j = std.mem.indexOfScalarPos(u8, tmpl, st, '}') orelse tmpl.len;
            i = @min(j + 1, tmpl.len);
            break :blk tmpl[st..j];
        } else blk: {
            const st = i;
            while (i < tmpl.len and isWordByte(tmpl[i])) i += 1;
            break :blk tmpl[st..i];
        };
        if (name.len == 0) {
            buf.append(a, '$') catch oom();
            continue;
        }
        const gi = groupIndexOf(caps, name) orelse continue;
        if (2 * gi + 1 >= slots.len) continue; // out-of-range group → empty
        const so = slots[2 * gi];
        const eo = slots[2 * gi + 1];
        if (so >= 0 and eo >= 0) buf.appendSlice(a, line[@intCast(so)..@intCast(eo)]) catch oom();
    }
}

/// `--max-columns-preview` cut point: the largest byte index ≤ `cols` that lands
/// on a UTF-8 char boundary (ripgrep counts graphemes; byte-accurate for ASCII,
/// and never splits a multi-byte scalar for the rest).
/// Byte length of a line's `--trim`-able blank prefix (spaces and tabs).
fn blankPrefix(s: []const u8) usize {
    return s.len - std.mem.trimStart(u8, s, " \t").len;
}

fn previewEnd(s: []const u8, cols: usize) usize {
    var end = @min(cols, s.len);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

pub const Emitter = struct {
    a: std.mem.Allocator,
    re: *const Matcher,
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
    /// `-r/--replace` capture matcher (linear Pike VM or PCRE2), non-null only
    /// when a replacement template is active. Built once per run by the caller.
    caps: ?*Caps = null,
    /// Resolved once per run by `color.zig` (stdout tty + `--color` + env).
    /// Paints path/line-number chrome and highlights match spans when true.
    use_color: bool = false,
    /// Caller-owned reusable boolean-match scratch (`Matcher.Sim` is
    /// generation-counted and file-agnostic by design), threaded in per-worker
    /// by the parallel engine and per-run by the serial one so its three
    /// n_states allocations amortize across every file this Emitter emits.
    /// Null ⇒ the per-file paths build (and free) a local one, as before.
    sim: ?*Matcher.Sim = null,
    /// Absolute address one past the current file's last byte (set with `base`).
    /// A raw line slice ending exactly here is the file's UNTERMINATED tail —
    /// a terminated final line's slice stops before its terminator byte — and
    /// rg appends the full output terminator (`\r\n` under `--crlf`) to such a
    /// line instead of reconstructing a bare `\n`. 0 ⇒ unknown (never a tail).
    body_end: usize = 0,

    /// `--crlf` match view: a trailing `\r` is treated as part of the terminator
    /// (so `$`/`\b` anchor before it) but is KEPT in the emitted line — ripgrep's
    /// CRLF behavior. Spans computed on this view index the original line 1:1
    /// (it's a prefix), so display bytes are unaffected.
    fn mview(self: *const Emitter, line: []const u8) []const u8 {
        return if (self.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    }

    /// Was this raw line slice terminated in the file? The split drops the
    /// terminator byte, so only the slice ending exactly at `body_end` (when
    /// known) is the file's unterminated tail. rg writes a terminated line
    /// verbatim (dos keeps `\r\n`, unix keeps `\n` even under `--crlf`) but
    /// appends the full output terminator to an unterminated one.
    fn lineTerminated(self: *const Emitter, line: []const u8) bool {
        return self.body_end == 0 or @intFromPtr(line.ptr) + line.len != self.body_end;
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

    /// Append raw bytes to the render buffer (OOM is fatal — the CLI contract).
    fn add(self: *Emitter, s: []const u8) void {
        self.out.appendSlice(self.a, s) catch oom();
    }

    /// Wrap `s` in `on` .. `reset` when color is active, else emit it plain.
    fn paint(self: *Emitter, on: []const u8, s: []const u8) void {
        if (!self.use_color) return self.add(s);
        self.add(on);
        self.add(s);
        self.add(palette.reset);
    }

    /// Write `path` followed by its terminator — NUL under `--null` (ripgrep's
    /// path-terminator), else the field separator. Used by the count/prefix paths.
    fn writePath(self: *Emitter, path: []const u8, is_match: bool) void {
        self.paint(palette.path_on, path);
        if (self.o.null_sep) self.out.append(self.a, 0) catch oom() else self.paint(palette.sep_on, self.fieldSep(is_match));
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
        if (self.o.column and is_match and col != 0) self.out.print(self.a, "{d}{s}", .{ col, sep }) catch oom();
        if (self.o.byte_offset) self.out.print(self.a, "{d}{s}", .{ byteoff, sep }) catch oom();
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
        // Terminator provenance reads off the RAW slice (a rewritten `-r` body
        // is not file-backed, but rg keys the append off the original line).
        const terminated = self.lineTerminated(line);
        if (is_match) if (self.o.replace) |tmpl| {
            const r = self.buildReplaced(tmpl, line);
            s = r.text;
            starts = r.starts;
        };
        self.emitBody(s, is_match, starts, terminated);
    }

    /// The presentation tail shared by every "print this line body" path:
    /// `--trim`, then `-M/--max-columns` placeholders (with `starts` as the
    /// match granularity), then color, then the terminator. `starts` are
    /// replacement offsets within `s_in`; trimming rebases them (an offset
    /// inside the trimmed whitespace clamps to 0 — before any cut, like rg's
    /// block-coordinate comparison).
    fn emitBody(self: *Emitter, s_in: []const u8, is_match: bool, starts_in: []const usize, terminated: bool) void {
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
            self.exceeded(s, is_match, starts);
            self.add(self.o.outTerm());
        } else if (is_match and self.use_color and self.o.replace == null) {
            // rg's colored writer trims the terminator (incl. `\r`) and
            // re-appends it, normalizing even a unix line to `\r\n` under
            // `--crlf` — mirror that exactly.
            self.highlightSpans(self.mview(s));
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
        for (self.matchSpans(s)) |sp| {
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
        while (nextSpan(self.re, &ss, self.o, mv, &from)) |sp| out.append(self.a, sp) catch oom();
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
            var remaining: usize = 0;
            // `--color` (no `-r`): paint matches inside the shown preview and count
            // the ones that begin past the cut — rg's colored-preview behavior.
            if (self.use_color and is_match and self.o.replace == null) {
                var last: usize = 0;
                for (self.matchSpans(s)) |sp| {
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
        const slots = self.a.alloc(isize, caps.nslots()) catch oom();
        var buf: std.ArrayList(u8) = .empty;
        var starts: std.ArrayList(usize) = .empty;
        var from: usize = 0;
        var last_end: ?usize = null;
        while (from <= line.len and caps.find(line, from, slots)) {
            const s: usize = @intCast(slots[0]);
            const e: usize = @intCast(slots[1]);
            buf.appendSlice(self.a, line[from..s]) catch oom();
            const empty_adjacent = e == s and last_end != null and s == last_end.?;
            const rejected = empty_adjacent or (self.o.word and !wordOk(self.o.unicode, line, s, e));
            if (!rejected) {
                starts.append(self.a, buf.items.len) catch oom();
                self.expand(&buf, tmpl, line, slots);
                last_end = e;
            }
            // A rejected or empty span keeps/advances past one source byte;
            // an accepted non-empty span resumes after its end.
            if (rejected or e == s) {
                if (s < line.len) buf.append(self.a, line[s]) catch oom();
                from = s + 1;
            } else from = e;
        }
        if (from < line.len) buf.appendSlice(self.a, line[from..]) catch oom();
        return .{ .text = buf.toOwnedSlice(self.a) catch oom(), .starts = starts.toOwnedSlice(self.a) catch oom() };
    }

    fn expand(self: *Emitter, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
        expandInto(self.a, self.caps.?, buf, tmpl, line, slots);
    }

    /// Emit each match on one line as its expanded `-r` template (the `-o` frame),
    /// `so_far` matches already counted toward `--max-count`. Returns the count on
    /// this line.
    fn emitLineRepl(self: *Emitter, path: []const u8, lineno: usize, line: []const u8, so_far: usize) usize {
        const caps = self.caps.?;
        const tmpl = self.o.replace.?;
        const slots = self.a.alloc(isize, caps.nslots()) catch oom();
        var n: usize = 0;
        var from: usize = 0;
        while (from <= line.len and caps.find(line, from, slots)) {
            const s: usize = @intCast(slots[0]);
            const e: usize = @intCast(slots[1]);
            if (e == s or (self.o.word and !wordOk(self.o.unicode, line, s, e))) {
                from = if (e == s) s + 1 else e;
                continue;
            }
            self.prefix(path, lineno, s + 1, self.offOf(line) + s, true);
            self.expand(self.out, tmpl, line, slots);
            self.add(self.o.outTerm()); // expanded text carries no terminator — rg appends the full one
            n += 1;
            if (self.o.max_per_file != 0 and so_far + n >= self.o.max_per_file) break;
            from = e;
        }
        return n;
    }

    /// 1-based byte column of the first (word-valid, non-empty) match on the line,
    /// or 0 if none — the value ripgrep prints under `--column`.
    fn firstCol(self: *Emitter, ssim: *Matcher.SpanSim, line: []const u8) usize {
        var from: usize = 0;
        const sp = nextSpan(self.re, ssim, self.o, line, &from) orelse return 0;
        return sp.start + 1;
    }

    /// One framed output row: the locator prefix followed by the line body.
    fn row(self: *Emitter, path: []const u8, lineno: usize, col: usize, off: usize, body: []const u8, is_match: bool) void {
        self.prefix(path, lineno, col, off, is_match);
        self.text(body, is_match);
    }

    /// Emit lines `[lo, hi_ex)` of the physical grid as context rows.
    fn ctxRows(self: *Emitter, path: []const u8, lines: []const ml.Line, body: []const u8, lo: usize, hi_ex: usize) void {
        for (lo..hi_ex) |k| self.row(path, k + 1, 0, lines[k].start, body[lines[k].start..lines[k].content_end], false);
    }

    pub fn file(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        const o = self.o;
        if (o.passthru and !o.invert and !o.count_only and !o.count_matches and !o.files_only) return self.passthru(path, lines);
        if (o.vimgrep and !o.invert) return self.vimgrep(path, lines);
        // `--count --only-matching` counts every match span (like --count-matches),
        // not matching lines — ripgrep's documented override.
        if ((o.count_matches or (o.count_only and o.only_matching)) and !o.invert) return self.countMatches(path, lines);
        if (o.only_matching and !o.invert) return self.onlyMatching(path, lines);

        // Borrow the caller-threaded scratch when present; else pay a file-local.
        var local_sim: ?Matcher.Sim = if (self.sim == null) (Matcher.Sim.init(self.a, self.re) catch return 0) else null;
        defer if (local_sim) |*s| s.deinit();
        const sim = self.sim orelse &local_sim.?;
        // `-w` decides a line via the span predicate; the plain path uses the
        // boolean DFA. Only `-w` pays for the SpanSim scratch.
        var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        var idx: std.ArrayList(usize) = .empty;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            // A required-literal gate (when the caller derived one): a line
            // without the literal bytes cannot match, and a SIMD memmem is an
            // order of magnitude cheaper than an engine run per line.
            const hit = self.lineCanMatch(mv) and
                (if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(sim, mv));
            if (hit == o.invert) {
                // --stop-on-nonmatch: once matching has begun, the first non-match
                // ends the file (ripgrep stops reading further lines).
                if (o.stop_on_nonmatch and idx.items.len > 0) break;
                continue;
            }
            // `-l` asks only whether this file has any matching line. Emit on
            // the first proof instead of scanning the rest of the file and
            // accumulating line indexes that no output mode will consume.
            if (o.files_only) return self.emitPathOnly(path);
            idx.append(self.a, k) catch oom();
            if (o.max_per_file != 0 and idx.items.len >= o.max_per_file) break;
        }
        if (o.count_only or o.count_matches) return self.bufTally(path, idx.items.len);
        if (idx.items.len == 0) return 0;
        const is_match = self.a.alloc(bool, lines.len) catch oom();
        @memset(is_match, false);
        for (idx.items) |m| is_match[m] = true;
        // Column locators need a span scan per match line; only pay for it under
        // --column (or --column implied by --vimgrep, handled separately).
        var css: ?Matcher.SpanSim = if (o.column) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (css) |*s| s.deinit();
        var prev_end: ?usize = null;
        for (idx.items) |m| {
            const hi = @min(m + o.after, lines.len - 1);
            var k = self.windowStart(m -| o.before, hi, &prev_end) orelse continue;
            while (k <= hi) : (k += 1) {
                const is_m = is_match[k];
                const col: usize = if (is_m and css != null) self.firstCol(&css.?, self.mview(lines[k])) else 0;
                self.row(path, k + 1, col, self.offOf(lines[k]), lines[k], is_m);
            }
        }
        return idx.items.len;
    }

    /// `--passthru`: emit EVERY line of the file (matching lines framed as matches,
    /// the rest as context) — ripgrep's "context of infinity". Returns the count of
    /// matching lines (for the exit code); output is written regardless of matches.
    fn passthru(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        const o = self.o;
        // Same lease as `file`: borrowed caller scratch, or a file-local build.
        var local_sim: ?Matcher.Sim = if (self.sim == null) (Matcher.Sim.init(self.a, self.re) catch return 0) else null;
        defer if (local_sim) |*s| s.deinit();
        const sim = self.sim orelse &local_sim.?;
        var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        var css: ?Matcher.SpanSim = if (o.column) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (css) |*s| s.deinit();
        var mss: ?Matcher.SpanSim = if (o.only_matching) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
        defer if (mss) |*s| s.deinit();
        var matched: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            const is_m = self.lineCanMatch(mv) and
                (if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(sim, mv));
            if (is_m) matched += 1;
            // --passthru -o: a matching line contributes each match span (only-
            // matching frame), a non-matching line still prints in full (context).
            if (is_m and mss != null) {
                if (self.o.replace != null) _ = self.emitLineRepl(path, k + 1, line, 0) else _ = self.emitMatches(&mss.?, path, k + 1, line, mv);
                continue;
            }
            const col: usize = if (is_m and css != null) self.firstCol(&css.?, mv) else 0;
            self.row(path, k + 1, col, self.offOf(line), line, is_m);
        }
        return matched;
    }

    /// Emit each match span on one line in the only-matching frame (shared by
    /// `-o` and `--passthru -o`). `mv` is the `--crlf` match view of `line`.
    /// Returns the number of spans emitted.
    fn emitMatches(self: *Emitter, ssim: *Matcher.SpanSim, path: []const u8, lineno: usize, line: []const u8, mv: []const u8) usize {
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
                (self.o.word and !wordOk(self.o.unicode, mv, span.start, span.end))) continue;
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

    /// The `--`-style separator between non-adjacent context groups, honoring
    /// `--context-separator` (custom string) and `--no-context-separator` (none).
    fn groupSep(self: *Emitter) void {
        if (self.o.ctx_sep) |sep| self.out.print(self.a, "{s}{s}", .{ sep, self.o.outTerm() }) catch oom();
    }

    /// Resolve one `-A/-B` window `[lo,hi]` against the previous group: prints
    /// the `--` separator across a gap, clamps the start past any overlap, and
    /// returns the first line to emit — null when the window is swallowed
    /// entirely. Shared by the per-line and whole-buffer block frames.
    fn windowStart(self: *Emitter, lo: usize, hi: usize, prev_end: *?usize) ?usize {
        var start = lo;
        if (prev_end.*) |pe| {
            if (lo > pe + 1) {
                if (self.o.wantsContext()) self.groupSep();
            } else if (hi <= pe) {
                return null;
            } else start = pe + 1;
        }
        prev_end.* = hi;
        return start;
    }

    /// `--vimgrep`: one `path:line:col:text` row per match (all matches on a line),
    /// line numbers and columns always on. Never groups.
    fn vimgrep(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim = Matcher.SpanSim.init(self.a, self.re) catch return 0;
        defer ssim.deinit();
        var emitted: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            var from: usize = 0;
            while (nextSpan(self.re, &ssim, self.o, mv, &from)) |sp| {
                self.row(path, k + 1, sp.start + 1, self.offOf(line) + sp.start, line, true);
                emitted += 1;
                if (self.o.max_per_file != 0 and emitted >= self.o.max_per_file) return emitted;
            }
        }
        return emitted;
    }

    /// Does any word-bounded match span exist on this line? (`-w` boolean path
    /// — every caller holds `o.word`, so `nextSpan` applies the word filter.)
    pub fn lineHitWord(self: *Emitter, ssim: *Matcher.SpanSim, line: []const u8) bool {
        return self.firstCol(ssim, line) != 0;
    }

    /// `-o` frame across `lines`: each match span as its raw bytes, or — with
    /// `-r` — the expanded template (not the raw match) per span. Returns the
    /// number emitted (respecting `--max-count`).
    fn onlyMatching(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim: ?Matcher.SpanSim = if (self.o.replace == null) Matcher.SpanSim.init(self.a, self.re) catch return 0 else null;
        defer if (ssim) |*s| s.deinit();
        var emitted: usize = 0;
        for (lines, 0..) |line, k| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            emitted += if (ssim) |*s| self.emitMatches(s, path, k + 1, line, mv) else self.emitLineRepl(path, k + 1, line, emitted);
            if (self.o.max_per_file != 0 and emitted >= self.o.max_per_file) break;
        }
        return emitted;
    }

    fn countMatches(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        var ssim = Matcher.SpanSim.init(self.a, self.re) catch return 0;
        defer ssim.deinit();
        var total: usize = 0;
        for (lines) |line| {
            const mv = self.mview(line);
            if (!self.lineCanMatch(mv)) continue;
            var from: usize = 0;
            while (nextSpan(self.re, &ssim, self.o, mv, &from)) |_| {
                total += 1;
                if (self.o.max_per_file != 0 and total >= self.o.max_per_file) break;
            }
        }
        return self.bufTally(path, total);
    }

    // ─────────────────────── whole-buffer (-U) emit ───────────────────────

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
        const spans = self.collectSpans(o, body);
        // `--count-matches` and `-c -o` tally every match span (empties included).
        if (o.count_matches or (o.count_only and o.only_matching)) return self.bufTally(path, ml.countAll(spans));
        if (o.invert) return self.bufInvert(path, body);
        // `--count` (matching lines) is emitted before the empty-spans short
        // circuit so `--include-zero` can still print a `path:0` line.
        if (o.count_only) return self.bufTally(path, ml.countStartLines(ml.splitLines(self.a, body, o.term()), spans));
        if (spans.len == 0) return 0;
        const lines = ml.splitLines(self.a, body, o.term());
        if (o.files_only) return self.emitPathOnly(path);
        if (o.only_matching) return if (o.replace != null) self.bufOnlyRepl(path, lines, spans, body) else self.bufOnly(path, lines, spans, body);
        if (o.vimgrep) return self.bufVimgrep(path, lines, spans, body);
        if (o.replace != null) return self.bufReplaceBlocks(path, lines, spans, body);
        return self.bufBlocks(path, lines, spans, body);
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

    /// `-l`: emit the path once, NUL-terminated under `--null` (rg's
    /// path-terminator), else the output terminator. Returns 1 for the tally.
    fn emitPathOnly(self: *Emitter, path: []const u8) usize {
        self.out.print(self.a, "{s}{s}", .{ path, if (self.o.null_sep) "\x00" else self.o.outTerm() }) catch oom();
        return 1;
    }

    /// Emit a `[path:]N` count line, returning `n` for the caller. A zero count
    /// normally emits nothing; `--include-zero` prints the `path:0` line anyway
    /// (the return stays `n`, so a zero count still reads as "no match" for the
    /// exit code — rg exits 1 while printing the zero lines).
    fn bufTally(self: *Emitter, path: []const u8, n: usize) usize {
        if (n == 0 and !self.o.include_zero) return 0;
        if (self.show_name) self.writePath(path, true);
        self.out.print(self.a, "{d}{s}", .{ n, self.o.outTerm() }) catch oom();
        return n;
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
        for (self.collectSpans(.{ .word = o.word }, body)) |sp| {
            const l0 = ml.lineIndexAt(lines, sp.start);
            for (l0..ml.lineIndexAt(lines, ml.spanLast(sp)) + 1) |li| covered[li] = true;
        }
        var printed: usize = 0;
        for (lines, 0..) |ln, k| {
            if (covered[k]) continue;
            self.prefix(path, k + 1, 0, ln.start, true);
            self.text(body[ln.start..ln.content_end], false);
            printed += 1;
            if (o.max_per_file != 0 and printed >= o.max_per_file) break;
        }
        return printed;
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
                    const ts = ln.start + blankPrefix(body[ln.start..ln.content_end]);
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
                    self.exceeded(frag, true, &.{0});
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
            self.expand(self.out, tmpl, body, slots);
            self.add(self.o.outTerm()); // expanded text carries no terminator
        }
        return spans.len;
    }

    /// `--vimgrep` under `-U`: one row per MATCH, showing only the FIRST line
    /// the match covers — rg's `per_match_one_line` ("vimgrep really only wants
    /// one line per match, even when a match spans multiple lines", rg #1866).
    /// The column is the match's start within that line (1-based) and the row
    /// carries the FULL line text (`--trim`/`-M` applied), not just the match.
    /// Empty spans are skipped (parity with the single-line vimgrep frame).
    fn bufVimgrep(self: *Emitter, path: []const u8, lines: []const ml.Line, spans: []const ml.Span, body: []const u8) usize {
        var emitted: usize = 0;
        for (spans) |sp| {
            if (sp.end == sp.start) continue;
            const li = ml.lineIndexAt(lines, sp.start);
            const ln = lines[li];
            self.prefix(path, li + 1, 1 + (sp.start - ln.start), ln.start, true);
            self.emitBody(body[ln.start..ln.content_end], true, &.{sp.start - ln.start}, ln.term_end > ln.content_end);
            emitted += 1;
        }
        return emitted;
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
        for (spans) |sp| {
            const l0 = ml.lineIndexAt(lines, sp.start);
            const c = 1 + (sp.start - lines[l0].start);
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
                self.expand(&buf, tmpl, body, slots);
                cursor = @max(cursor, sp.end);
            }
            buf.appendSlice(self.a, body[cursor..lines[b.last].term_end]) catch oom();
            self.emitReplacedBlock(path, b.first, lines[b.first].start, buf.items, starts.items);
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
            var line_starts: std.ArrayList(usize) = .empty;
            for (starts) |st| {
                if (st >= end) break;
                line_starts.append(self.a, st -| pos) catch oom();
            }
            self.prefix(path, lineno, col, block_off + pos, true);
            // A split found a term byte ⇒ this physical line was terminated in
            // the (replaced) block; only the final unsplit tail can lack one.
            self.emitBody(rep[pos..end], true, line_starts.items, nl != null);
            if (nl == null) break;
            pos = end + 1;
            lineno += 1;
        }
    }
};

test "required literal line gate handles sub-trigram needles" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "[0-9a-f]{8}-[0-9a-f]{4}") };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    var em = Emitter{
        .a = t.allocator,
        .re = &m,
        .o = .{},
        .show_name = false,
        .out = &out,
        .needle = m.required(),
    };

    try t.expectEqualStrings("-", m.required());
    try t.expect(!em.lineCanMatch("abcdef012345"));
    try t.expect(em.lineCanMatch("deadbeef-cafe"));
}

test "files-only emits once and stops after the first matching line" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "needle") };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    var em = Emitter{
        .a = t.allocator,
        .re = &m,
        .o = .{ .files_only = true },
        .show_name = true,
        .out = &out,
        .needle = m.required(),
    };

    try t.expectEqual(@as(usize, 1), em.file("fixture.txt", &.{ "needle first", "needle second" }));
    try t.expectEqualStrings("fixture.txt\n", out.items);
}

// ─────────────── whole-buffer (-U) emit — byte-identical vs ripgrep ───────────────
//
// Every expected string below was captured from `upstream/ripgrep` (`rg -U …`) on the
// same input, so these are ripgrep-parity assertions, not self-consistency checks.

pub const MlHarness = struct {
    arena: std.heap.ArenaAllocator,
    m: Matcher,
    caps: ?Caps = null,

    fn init(pat: []const u8, o: struct { dotall: bool = false, replace: bool = false }) !MlHarness {
        const ta = std.testing.allocator;
        var h = MlHarness{
            .arena = std.heap.ArenaAllocator.init(ta),
            .m = .{ .linear = try Regex.compileOpts(ta, pat, .{ .multiline = true, .dotall = o.dotall }) },
        };
        if (o.replace) h.caps = .{ .linear = try Captures.compile(ta, pat, false, false) };
        return h;
    }
    fn deinit(self: *MlHarness) void {
        self.arena.deinit();
        self.m.deinit();
        if (self.caps) |*c| c.deinit();
    }
    /// Run the whole-buffer emit path with the given options and return the bytes.
    fn run(self: *MlHarness, o: Opts, body: []const u8) ![]const u8 {
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

/// One parity row: rg's captured output for a pattern + option set over a
/// body. Harness knobs derive from the options (`dotall` from
/// `multiline_dotall`, capture compilation from `-r`).
const MlCase = struct { pat: []const u8, o: Opts, body: []const u8, want: []const u8 };

test "-U whole-buffer emit parity table (captured from ripgrep)" {
    const cases = [_]MlCase{
        // -U cross-line span prints the full run of lines
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\nc\n", .want = "1:a\n2:b\n" },
        // -U match ending exactly at EOF with no trailing newline
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb", .want = "1:a\n2:b\n" },
        // -U -o emits each line fragment of the match
        .{ .pat = "x\\ny", .o = .{ .multiline = true, .line_num = true, .only_matching = true }, .body = "x\ny\nx\ny\n", .want = "1:x\n2:y\n3:x\n4:y\n" },
        // -U -o --column -b: match-start col (block-relative) + abs offset per fragment
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true, .byte_offset = true }, .body = "abYZcd\nef\n", .want = "1:3:2:YZcd\n2:3:2:ef\n" },
        // -U -o --column: block-relative columns across coalesced matches
        // block base = line 1; match2 starts at buffer byte 4 ⇒ column 5.
        .{ .pat = "a\\nb|b\\nc", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\nb\nc\n", .want = "1:1:a\n2:1:b\n3:5:b\n4:5:c\n" },
        // -U non-o --column repeats the match-start column on every line
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .column = true }, .body = "abYZcd\nef\n", .want = "1:3:abYZcd\n2:3:ef\n" },
        // -U non-o -b reports each printed line's own offset
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .byte_offset = true }, .body = "abYZcd\nef\n", .want = "1:0:abYZcd\n2:7:ef\n" },
        // -U -C1 context frames the multiline match
        .{ .pat = "c\\nd", .o = .{ .multiline = true, .line_num = true, .before = 1, .after = 1 }, .body = "a\nb\nc\nd\ne\nf\ng\n", .want = "2-b\n3:c\n4:d\n5-e\n" },
        // -U -A1 separates non-adjacent blocks with --
        .{ .pat = "a\\nb|e\\nf", .o = .{ .multiline = true, .line_num = true, .after = 1 }, .body = "a\nb\nc\nd\ne\nf\ng\n", .want = "1:a\n2:b\n3-c\n--\n5:e\n6:f\n7-g\n" },
        // -U -c counts distinct match-start lines; --count-matches counts spans
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .count_only = true }, .body = "a\nb\nx\na\nb\n", .want = "2\n" },
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .count_matches = true }, .body = "a\nb\nx\na\nb\n", .want = "2\n" },
        // -U -c with a nullable pattern counts start-lines, not all empties
        .{ .pat = "a*", .o = .{ .multiline = true, .count_only = true }, .body = "aa\nbb\n", .want = "2\n" },
        .{ .pat = "a*", .o = .{ .multiline = true, .count_matches = true }, .body = "aa\nbb\n", .want = "4\n" },
        // -U -v prints lines outside every match's span
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .invert = true }, .body = "a\nb\nx\na\nb\n", .want = "3:x\n" },
        // -U -m caps the number of matches
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .max_per_file = 2 }, .body = "a\nb\na\nb\na\nb\n", .want = "1:a\n2:b\n3:a\n4:b\n" },
        // -U -w rejects a span not on word boundaries
        // 'b' is preceded by 'a' (a word byte) ⇒ not a word match ⇒ no output.
        .{ .pat = "b\\nc", .o = .{ .multiline = true, .line_num = true, .word = true }, .body = "ab\ncd\n", .want = "" },
        // Isolated: 'b' at line start, 'c' at line end ⇒ word match.
        .{ .pat = "b\\nc", .o = .{ .multiline = true, .line_num = true, .word = true }, .body = "b\nc\n", .want = "1:b\n2:c\n" },
        // -U -x (line-anchored pattern) matches whole lines only
        .{ .pat = "^(?:a\\nb)$", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\nc\n", .want = "1:a\n2:b\n" },
        // -U --multiline-dotall lets . cross newlines
        .{ .pat = "a.b", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true }, .body = "a\nb\n", .want = "1:a\n2:b\n" },
        // -U without dotall: . does not cross a newline
        .{ .pat = "a.b", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\n", .want = "" },
        // -U match spanning many lines prints them all once
        .{ .pat = "a.*e", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true }, .body = "a\nb\nc\nd\ne\n", .want = "1:a\n2:b\n3:c\n4:d\n5:e\n" },
        // -U -o zero-width matches follow rg's progress rule
        // "aa" then three empties on line 2 (offsets 3,4,5); the phantom at EOF is dropped.
        // rg: `rg -U -o -n 'a*'` ⇒ 1:aa / 2: / 2: / 2: (empties emit — not lone on line 2).
        .{ .pat = "a*", .o = .{ .multiline = true, .line_num = true, .only_matching = true }, .body = "aa\nbb\n", .want = "1:aa\n2:\n2:\n2:\n" },
        // -U -o empties on line 2 take line-relative columns (not block-absolute)
        // rg `-U -o -n --column 'a*'` ⇒ 1:1:aa / 2:1: / 2:2: / 2:3: — the line-2 block
        // resets its column base to line 2, so the empties read 1,2,3 (not 4,5,6).
        .{ .pat = "a*", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "aa\nbb\n", .want = "1:1:aa\n2:1:\n2:2:\n2:3:\n" },
        // -U -o skips a blank line covered by a cross-line span
        // rg `-U --multiline-dotall -o -n 'a.*b'` over "a\n\nb\n" ⇒ 1:a / 3:b — the blank
        // middle line emits nothing, and the line number jumps 1→3.
        .{ .pat = "a.*b", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true, .only_matching = true }, .body = "a\n\nb\n", .want = "1:a\n3:b\n" },
        // -U -o lone ^ zero-width at line start emits nothing
        // rg `-U -o -n --column '^'` over "a\nb\n" ⇒ (empty). Each ^ is the only match
        // on its (non-blank) line and sits at the line start ⇒ rg emits nothing.
        .{ .pat = "^", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\n", .want = "" },
        // -U -o separate empties on adjacent lines are line-relative, not one block
        // rg `-U -o -n --column 'x?'` over "a\nb\n" ⇒ 1:1: / 1:2: / 2:1: / 2:2: — two empties
        // per line; because neither span crosses a line, the two lines are separate blocks,
        // so line 2's columns reset (1,2) rather than continuing (3,4).
        .{ .pat = "x?", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\n", .want = "1:1:\n1:2:\n2:1:\n2:2:\n" },
        // -U --crlf keeps the carriage return in the emitted line
        .{ .pat = "a\\r?\\nb", .o = .{ .multiline = true, .line_num = true, .crlf = true }, .body = "a\r\nb\r\nc\r\n", .want = "1:a\r\n2:b\r\n" },
        // -U --null-data uses NUL as the line terminator
        .{ .pat = "a", .o = .{ .multiline = true, .line_num = true, .null_data = true }, .body = "a\x00b\x00", .want = "1:a\x00" },
        // -U -o -r emits the expanded template once per match
        .{ .pat = "(a)\\n(b)", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .replace = "<$1>" }, .body = "a\nb\n", .want = "1:<a>\n" },
        // -U -r replaces the cross-line match and re-splits the result
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .replace = "Z" }, .body = "a\nb\nc\n", .want = "1:Z\n" },
        .{ .pat = "(a\\nb)", .o = .{ .multiline = true, .line_num = true, .replace = "P${1}Q" }, .body = "a\nb\nc\n", .want = "1:Pa\n2:bQ\n" },
        // -U -r keeps context line numbers original after a collapsing replace
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .after = 1, .replace = "Z" }, .body = "a\nb\nc\n", .want = "1:Z\n3-c\n" },
        // -U empty buffer and no-match produce no output
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "", .want = "" },
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "x\ny\nz\n", .want = "" },
    };
    for (&cases) |c| {
        var h = try MlHarness.init(c.pat, .{ .dotall = c.o.multiline_dotall, .replace = c.o.replace != null });
        defer h.deinit();
        try std.testing.expectEqualStrings(c.want, try h.run(c.o, c.body));
    }
}
