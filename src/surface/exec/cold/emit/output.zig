//! gist `rg` — the match + presentation layer (split from `run.zig`).
//!
//! `run.zig` owns the walk (gather files, apply type/glob scope, stdin); this
//! module owns everything downstream of "here is one file's bytes". It is the
//! **facade** over the `output/` folder: the `Emitter` struct — the per-file
//! state every rg output mode shares (match base, body end, literal gate,
//! capture program, color, scratch simulators) — plus the small writer
//! vocabulary they all frame output with, plus the span and itoa primitives.
//!
//! The mode implementations live in siblings, each free functions over
//! `*Emitter`, exactly like `render.zig` next door:
//!
//!   - `output/display.zig`  what a chosen line looks like: `--trim`,
//!                           `-M/--max-columns`, `--color`, the terminator
//!                           model, and the two shared row shapes (`-o`
//!                           only-matching, `--vimgrep` per-match)
//!   - `output/replace.zig`  `-r` template expansion (`expandInto` is shared
//!                           verbatim with the `--json` stream)
//!   - `output/grid.zig`     the physical-line-grid modes: the default frame,
//!                           `-v`, `--passthru`, `-o`, `-c`
//!   - `output/skim.zig`     the line-free literal searcher loop (`fileLit`)
//!   - `output/multibuf.zig` the whole-buffer `-U` emit
//!
//! One linear-time RE2-style engine backs all of it (`matchSpan` for spans,
//! `lineMatch` for the boolean path); no second matcher.

const std = @import("std");
const args = @import("../argv/args.zig");
const Opts = args.Opts;
const oom = args.oom;
const palette = @import("color.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");
const ml = @import("multiline.zig");
const Regex = @import("../../../../kernel/match/regex/regex.zig").Regex;
const Matcher = @import("../../../../kernel/match/regex/regex.zig").Matcher;
const Caps = @import("../../../../kernel/match/regex/regex.zig").Caps;
const word = @import("../../../../kernel/match/regex/regex.zig").word;

const display = @import("output/display.zig");
const replace = @import("output/replace.zig");
const grid = @import("output/grid.zig");
const skim = @import("output/skim.zig");
const multibuf = @import("output/multibuf.zig");

/// The `-r` template expander, re-exported so `json.zig` and the bench lab
/// keep reaching it at `emit.expandInto` — one expander, two record streams.
pub const expandInto = replace.expandInto;
/// The `-U` parity harness, re-exported for `json.zig`'s `-U --json` test.
pub const MlHarness = multibuf.MlHarness;

pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The "00".."99" two-digit table `writeDecimal` writes a pair at a time (the
/// classic Andrei Alexandrescu / rust-`itoa` scheme) — built once at comptime.
const dec2: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        t[i * 2] = '0' + @as(u8, i / 10);
        t[i * 2 + 1] = '0' + @as(u8, i % 10);
    }
    break :blk t;
};

/// Unsigned integer → base-10 ASCII, into the tail of `buf`, returning the
/// written slice. Byte-identical to `std.fmt.bufPrint("{d}", .{v})` (plain
/// decimal, no sign, no leading zero) but specialized: two digits per iteration
/// off a comptime table, so it halves the divisions std's generic `formatInt`
/// pays and skips its base/case/fill machinery. This is the `-n` (and
/// `--column`/`-b`) hot path — one call per emitted line. `buf` must be ≥ 20
/// bytes (the widest u64 is 20 digits); the emitter's locators pass a `[20]u8`.
pub fn writeDecimal(buf: []u8, v: u64) []u8 {
    var n = v;
    var i: usize = buf.len;
    while (n >= 100) : (n /= 100) {
        const r = (n % 100) * 2;
        i -= 2;
        buf[i] = dec2[r];
        buf[i + 1] = dec2[r + 1];
    }
    if (n < 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n));
    } else {
        const r = n * 2;
        i -= 2;
        buf[i] = dec2[@intCast(r)];
        buf[i + 1] = dec2[@intCast(r + 1)];
    }
    return buf[i..];
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

pub const Emitter = struct {
    a: std.mem.Allocator,
    re: *const Matcher,
    o: Opts,
    show_name: bool,
    out: *std.ArrayList(u8),
    /// Absolute address of the current file's byte-0 (set per file by the caller);
    /// `--byte-offset` reports `@intFromPtr(line.ptr) - base` for each line/match.
    base: usize = 0,
    /// Optional required-literal gate from the compiled regex: every match
    /// must contain these bytes (in some ASCII case spelling when `.ci`), so
    /// lines without them are rejected by the SIMD kernels before any engine
    /// run. Purely an accelerator; alternations only set it when the analyzer
    /// proves one literal common to every branch.
    needle: ?simd.Gate = null,
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

    // ──────────────────────────── the verb set ────────────────────────────
    // What a caller outside this folder asks an Emitter to do: answer one file
    // in the mode the flags selected. Each delegates to the driver that owns
    // that match model; the eligibility predicates let a scheduler pick the
    // cheapest one before committing to a line split.

    /// Answer one file from its already-split lines — the default frame plus
    /// every per-line mode. Returns the mode's tally (see `grid.zig`).
    pub fn file(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
        return grid.file(self, path, lines);
    }

    /// Answer one file from its whole buffer — the `-U`/`--multiline` frame.
    pub fn buffer(self: *Emitter, path: []const u8, body: []const u8) usize {
        return multibuf.buffer(self, path, body);
    }

    /// Answer one file (or one line-aligned shard of it) without ever building
    /// a line array — the pure-literal searcher loop.
    pub fn fileLit(self: *Emitter, path: []const u8, body: []const u8, lo: usize, hi: usize, base_lineno: usize, tally: bool) usize {
        return skim.fileLit(self, path, body, lo, hi, base_lineno, tally);
    }

    /// Is `fileLit` sound and profitable for this run?
    pub fn litFastEligible(self: *const Emitter) bool {
        return skim.litFastEligible(self);
    }

    /// Will `file` answer from the whole buffer, so the caller can skip
    /// splitting lines entirely?
    pub fn fusedFileEligible(self: *const Emitter) bool {
        return grid.fusedFileEligible(self);
    }

    /// `-c`/`--count-matches`: emit a `[path:]N` count line, returning `n` for
    /// the caller. A zero count normally emits nothing; `--include-zero` prints
    /// the `path:0` line anyway (the return stays `n`, so a zero count still
    /// reads as "no match" for the exit code — rg exits 1 while printing the
    /// zero lines).
    pub fn bufTally(self: *Emitter, path: []const u8, n: usize) usize {
        if (n == 0 and !self.o.include_zero) return 0;
        if (self.show_name) self.writePath(path, true);
        // The `-c`/`--count-matches` count emit (one per counted file): the
        // specialized itoa + a raw append, not a `"{d}{s}"` format parse.
        var buf: [20]u8 = undefined;
        self.add(writeDecimal(&buf, n));
        self.add(self.o.outTerm());
        return n;
    }

    /// Does any word-bounded match span exist on this line? (`-w` boolean path
    /// — every caller holds `o.word`, so `nextSpan` applies the word filter.)
    pub fn lineHitWord(self: *Emitter, ssim: *Matcher.SpanSim, line: []const u8) bool {
        return self.firstCol(ssim, line) != 0;
    }

    // ─────────────────── the shared writer vocabulary ────────────────────
    // Folder-internal, not a public API: Zig has no `pub(folder)`, so the
    // primitives the `output/` drivers frame their bytes with are `pub` here.
    // Everything below is an implementation detail of this folder — a caller
    // outside it wants the verb set above.

    /// `--crlf` match view: a trailing `\r` is treated as part of the terminator
    /// (so `$`/`\b` anchor before it) but is KEPT in the emitted line — ripgrep's
    /// CRLF behavior. Spans computed on this view index the original line 1:1
    /// (it's a prefix), so display bytes are unaffected.
    pub fn mview(self: *const Emitter, line: []const u8) []const u8 {
        return if (self.o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
    }

    /// Was this raw line slice terminated in the file? The split drops the
    /// terminator byte, so only the slice ending exactly at `body_end` (when
    /// known) is the file's unterminated tail. rg writes a terminated line
    /// verbatim (dos keeps `\r\n`, unix keeps `\n` even under `--crlf`) but
    /// appends the full output terminator to an unterminated one.
    pub fn lineTerminated(self: *const Emitter, line: []const u8) bool {
        return self.body_end == 0 or @intFromPtr(line.ptr) + line.len != self.body_end;
    }

    pub fn lineCanMatch(self: *const Emitter, line: []const u8) bool {
        const needle = self.needle orelse return true;
        return needle.in(line);
    }

    /// Per-line candidate mask for a pure-literal pattern — rg's Teddy prefilter
    /// at line grain. ONE fused whole-buffer `indexOfAnyPos` sweep marks only the
    /// lines around literal hits, jumping non-matching regions at SIMD speed, so
    /// the per-line classify below skips ~every non-candidate without an engine
    /// run — the win a needle-less alternation (`function|const|…`) otherwise
    /// can't get (no single required literal to gate on). `re.lits` is a match
    /// EQUIVALENCE (a line matches ⟺ it holds one literal — `analysis.pureLiterals`,
    /// empty under `-i`/`-w`/`-U`), so the mask is a SUPERSET of the true match set
    /// (a hit landing in a line's trailing `\r`/terminator maps to that line —
    /// harmless: the caller still confirms each candidate with the engine) and
    /// never a subset, keeping output byte-identical. Returns null (caller keeps
    /// its per-line path) unless the shortcut is sound & profitable: pure literals,
    /// no single needle already gating, not inverted (a `-v` match LACKS the
    /// literals), not `--stop-on-nonmatch` (which acts on non-matches mid-stream),
    /// and a materialized body.
    pub fn litCandidates(self: *Emitter, lines: []const []const u8) ?[]const bool {
        if (self.needle != null or self.o.invert or self.o.stop_on_nonmatch) return null;
        if (lines.len == 0 or self.body_end <= self.base) return null;
        const lits = self.re.lits();
        if (lits.len == 0) return null;
        const body = @as([*]const u8, @ptrFromInt(self.base))[0 .. self.body_end - self.base];
        const cand = self.a.alloc(bool, lines.len) catch return null;
        @memset(cand, false);
        var lc: usize = 0;
        var from: usize = 0;
        // Hits and lines are both sorted by offset, so the line cursor only
        // advances — O(lines + hits) total. A literal carries no newline, so a
        // hit `p` lands within one line's span; map it, mark it, then resume at
        // the next line's start (skipping the rest of the hit's line).
        while (simd.indexOfAnyPos(body, from, lits)) |p| {
            while (lc + 1 < lines.len and @intFromPtr(lines[lc + 1].ptr) - self.base <= p) lc += 1;
            cand[lc] = true;
            if (lc + 1 >= lines.len) break;
            from = @intFromPtr(lines[lc + 1].ptr) - self.base;
        }
        return cand;
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

    /// Append raw bytes to the render buffer (OOM is fatal — the CLI contract).
    pub fn add(self: *Emitter, s: []const u8) void {
        self.out.appendSlice(self.a, s) catch oom();
    }

    /// Wrap `s` in `on` .. `reset` when color is active, else emit it plain.
    pub fn paint(self: *Emitter, on: []const u8, s: []const u8) void {
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
    pub fn prefix(self: *Emitter, path: []const u8, lineno: usize, col: usize, byteoff: usize, is_match: bool) void {
        const sep = self.fieldSep(is_match);
        if (self.show_name) self.writePath(path, is_match);
        var buf: [20]u8 = undefined;
        if (self.o.line_num) {
            self.paint(palette.line_on, writeDecimal(&buf, lineno));
            self.paint(palette.sep_on, sep);
        }
        if (self.o.column and is_match and col != 0) {
            self.add(writeDecimal(&buf, col));
            self.add(sep);
        }
        if (self.o.byte_offset) {
            self.add(writeDecimal(&buf, byteoff));
            self.add(sep);
        }
    }

    /// 1-based byte column of the first (word-valid, non-empty) match on the line,
    /// or 0 if none — the value ripgrep prints under `--column`.
    pub fn firstCol(self: *Emitter, ssim: *Matcher.SpanSim, line: []const u8) usize {
        var from: usize = 0;
        const sp = nextSpan(self.re, ssim, self.o, line, &from) orelse return 0;
        return sp.start + 1;
    }

    /// One framed output row: the locator prefix followed by the line body.
    pub fn row(self: *Emitter, path: []const u8, lineno: usize, col: usize, off: usize, body: []const u8, is_match: bool) void {
        self.prefix(path, lineno, col, off, is_match);
        display.text(self, body, is_match);
    }

    /// Emit lines `[lo, hi_ex)` of the physical grid as context rows.
    pub fn ctxRows(self: *Emitter, path: []const u8, lines: []const ml.Line, body: []const u8, lo: usize, hi_ex: usize) void {
        for (lo..hi_ex) |k| self.row(path, k + 1, 0, lines[k].start, body[lines[k].start..lines[k].content_end], false);
    }

    /// The `--`-style separator between non-adjacent context groups, honoring
    /// `--context-separator` (custom string) and `--no-context-separator` (none).
    pub fn groupSep(self: *Emitter) void {
        if (self.o.ctx_sep) |sep| self.out.print(self.a, "{s}{s}", .{ sep, self.o.outTerm() }) catch oom();
    }

    /// Resolve one `-A/-B` window `[lo,hi]` against the previous group: prints
    /// the `--` separator across a gap, clamps the start past any overlap, and
    /// returns the first line to emit — null when the window is swallowed
    /// entirely. Shared by the per-line and whole-buffer block frames.
    pub fn windowStart(self: *Emitter, lo: usize, hi: usize, prev_end: *?usize) ?usize {
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

    /// `-l`: emit the path once, NUL-terminated under `--null` (rg's
    /// path-terminator), else the output terminator. Returns 1 for the tally.
    /// The one emit per matching file — two raw appends beat routing a bare
    /// `"{s}{s}"` through the format machinery (byte-identical to it).
    pub fn emitPathOnly(self: *Emitter, path: []const u8) usize {
        self.add(path);
        self.add(if (self.o.null_sep) "\x00" else self.o.outTerm());
        return 1;
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
        .needle = .{ .bytes = m.required() },
    };

    try t.expectEqualStrings("-", m.required());
    try t.expect(!em.lineCanMatch("abcdef012345"));
    try t.expect(em.lineCanMatch("deadbeef-cafe"));
}
