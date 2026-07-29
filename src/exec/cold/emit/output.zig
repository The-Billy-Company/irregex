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
const oom = @import("../../../surface/cli/outcome.zig").oom;
const beacon = @import("../../../surface/cli/beacon.zig");
const palette = @import("color.zig");
const simd = @import("../../../kernel/scan/simd.zig");
const ml = @import("multiline.zig");
const Regex = @import("../../../kernel/regex/regex.zig").Regex;
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Caps = @import("../../../kernel/regex/regex.zig").Caps;
const word = @import("../../../kernel/regex/regex.zig").word;
const corpus_mod = @import("../../../corpus/tree/corpus.zig");

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
        // `% 100 * 2` is < 200, so narrowing to the index type is exact on every
        // address width (the `else` arm below already casts for the same reason).
        const r: usize = @intCast((n % 100) * 2);
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

/// ripgrep `-w` — the engines' own rule (`syntax/word.zig`), re-exported so the
/// emit path names it where the span filters read. Defined there because the
/// `\W`-consumes-a-codepoint distinction it turns on is Unicode-decode
/// knowledge, and the warm query path (`kernel/query/word.zig`) needs the
/// identical verdict; one definition is why they cannot drift.
pub const wordOk = word.wordOk;

/// Next non-empty (and, under `-w`, word-valid) match span at/after `from.*`,
/// advancing `from` past it: a zero-width span skips one byte (the progress
/// rule), a word-rejected span RETRIES one byte past its start. THE
/// span-iteration loop — the text emitter and the `--json` stream both step
/// through it, so the two can never drift on which spans count as "a match".
///
/// Retrying at `start + 1` rather than resuming at `end` is what makes `-w` a
/// constraint on the search instead of a veto on one candidate. rg compiles the
/// word rule INTO the pattern (`(?:^|\W)(pat)(?:$|\W)`, reporting the capture),
/// so a rejected candidate does not consume the region it covered: `rg -w -o
/// '\s?ς'` over "final ς here" prints `ς`, having shifted the match past the
/// space its greedy `\s?` would have taken. Skipping to `end` made gist answer
/// "no match" for that line (found by the differential fuzzer).
pub fn nextSpan(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, s: []const u8, from: *usize) ?Matcher.Span {
    while (from.* <= s.len) {
        const sp = re.matchSpan(ss, s, from.*) orelse return null;
        if (sp.end == sp.start) {
            from.* = sp.start + 1;
            continue;
        }
        if (o.word and !wordOk(o.unicode, s, sp.start, sp.end)) {
            from.* = sp.start + 1;
            continue;
        }
        from.* = sp.end;
        return sp;
    }
    return null;
}

/// The spans rg's `-o` printer yields over one line: `find_iter` widened to
/// zero-width matches, which `nextSpan` above drops because its consumers
/// (`-w`, `--column`, highlighting) all need bytes to point at.
///
/// A zero-width match is yielded only for a nullable pattern, and never one
/// sitting exactly at the previous match's end — rg's progress rule, which is
/// why `a*` over "aa" is one row and not two. A non-nullable pattern therefore
/// walks identically to `nextSpan`.
///
/// `--count-matches` is defined as how many of these rg would print, so it and
/// `-o` step through this one walk instead of each deriving the rule; that is
/// the whole reason it is a type and not a loop inside the printer.
pub const Rows = struct {
    re: *const Matcher,
    ss: *Matcher.SpanSim,
    o: Opts,
    /// The match view of one line (`--crlf`-trimmed where that applies).
    mv: []const u8,
    /// Did this line carry a terminator in the file? rg searches each line WITH
    /// its terminator, so the zero-width match at the end of the content is real
    /// for a terminated line (it sits before the `\n`) and does NOT exist on a
    /// file's unterminated tail — measured: `--count-matches 'x*'` reports 3 over
    /// "ab\n" and 2 over "ab". Callers that know their line's provenance pass
    /// `Emitter.lineTerminated`; the default is the common case.
    terminated: bool = true,
    from: usize = 0,
    last_end: ?usize = null,

    pub fn next(self: *Rows) ?Matcher.Span {
        while (self.from <= self.mv.len) {
            const sp = self.re.matchSpan(self.ss, self.mv, self.from) orelse return null;
            const empty = sp.end == sp.start;
            // A word-rejected candidate retries one byte on, never consuming the
            // region it covered — see `nextSpan` for why rg's compiled-in `-w`
            // makes that the faithful advance.
            const word_bad = self.o.word and !wordOk(self.o.unicode, self.mv, sp.start, sp.end);
            self.from = if (empty or word_bad) sp.start + 1 else sp.end;
            const adjacent = empty and self.last_end != null and sp.start == self.last_end.?;
            if ((empty and !self.re.nullable()) or adjacent or
                (empty and !self.terminated and sp.start == self.mv.len) or word_bad) continue;
            self.last_end = sp.end;
            return sp;
        }
        return null;
    }

    /// How many rows the line holds, for the count modes that print none.
    pub fn tally(self: *Rows) usize {
        var n: usize = 0;
        while (self.next()) |_| n += 1;
        return n;
    }
};

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
    /// Span scratch, built on first use and then reused for this Emitter's
    /// lifetime. Span walks are per LINE (`--color` highlighting, the
    /// `--max-columns` preview), and the engines behind them are memoizing —
    /// the caliper determinizes on demand and only gets cheap once its cache is
    /// warm — so a simulator built per line would throw away the very memo that
    /// makes spans affordable, and pay a fresh allocation for the privilege.
    /// Owned by this Emitter's allocator for its lifetime, like `way` below.
    spans: ?Matcher.SpanSim = null,
    /// This file's OSC-8 destination, built on first use and memoized by the
    /// path slice's identity — one build per file, never per line. Null until
    /// the first locator of a file, and always null when the run has no beacon.
    way: ?beacon.Waypoint = null,
    /// Is a hyperlink frame currently open? Only `--hyperlink` scope `row`
    /// leaves one open past the locator, so the body writers close it.
    linked: bool = false,
    /// Bytes appended so far that the reader never sees — color escapes and
    /// OSC-8 frames. The output budget bounds what someone reads, so it counts
    /// `out.items.len - chrome`: a colored or clickable run must return the
    /// same rows as a plain one, not fewer. Cumulative over this Emitter's
    /// whole life (the serial loop's run; one shard's file range).
    chrome: usize = 0,
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

    /// This Emitter's span scratch, built on demand. Null only when it cannot be
    /// allocated at all, which every caller degrades to "no spans" on.
    pub fn spanSim(self: *Emitter) ?*Matcher.SpanSim {
        if (self.spans == null) self.spans = Matcher.SpanSim.init(self.a, self.re) catch return null;
        return &self.spans.?;
    }

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
        if (self.show_name) _ = self.writePath(path, summary_sep);
        // The `-c`/`--count-matches` count emit (one per counted file): the
        // specialized itoa + a raw append, not a `"{d}{s}"` format parse.
        var buf: [20]u8 = undefined;
        self.add(writeDecimal(&buf, n));
        self.add(self.o.outTerm());
        return n;
    }

    /// Has this run's output ceiling already been spent, counting what this
    /// Emitter still holds unwritten?
    ///
    /// Polled at ROW boundaries by the drivers whose row count is bounded by the
    /// input's SIZE rather than by its line count. `--vimgrep` prints one row per
    /// match and every row carries the whole line, so a 5 MiB single line with
    /// 5 M matches is 12.5 TB of intended output — ripgrep streams exactly that
    /// at ~92 MiB of RSS, while a renderer that buffers a file has to stop
    /// somewhere or it stops being a tool (measured before this poll existed:
    /// 52 GiB of RSS and still climbing when the robustness lane killed it).
    /// The cut lands BETWEEN rows, never inside one, and trips the same
    /// truncation notice a file-boundary cut does.
    pub fn full(self: *const Emitter) bool {
        return corpus_mod.outputFull(self.out.items.len -| self.chrome);
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

    /// The literal set a whole-buffer candidate sweep may mark lines with, ranked
    /// exactly as the engine's own literal tier ranks it (`lower.zig::literalEngine`):
    /// the pure-literal EQUIVALENCE set (`analysis.pureLiterals`, empty under
    /// `-i`/`-w`/`-U`) when the pattern has one, else the per-branch alternation
    /// COVER (`foo|bar` ⇒ {foo,bar}).
    ///
    /// The cover is only a NECESSARY condition, which is all a candidate mask needs
    /// — every caller ANDs the mark with a real engine run, so a superset costs
    /// nothing but a confirmed line. Taking it here is what gives a class-led
    /// alternation (`[A-Z]+_TYPE|[a-z]+_kind`, no literal common to every match) the
    /// same ONE fused buffer sweep a pure-literal alternation gets; without it the
    /// mask declines, and `verdict.zig::lineMatch` re-scans for those same literals
    /// once PER LINE — the identical filter at millions of times the setup.
    ///
    /// Withheld where a match need not contain the cover bytes verbatim, since the
    /// sweep compares raw bytes: `-i` (a match may hold a case variant the cover
    /// does not spell) and `-U` (a match may cross `\n`, so marking the line that
    /// holds a literal proves nothing about where a match starts).
    pub fn maskLiterals(o: Opts, re: *const Matcher) []const []const u8 {
        const lits = re.lits();
        if (lits.len > 0) return lits;
        return if (o.caseless or o.multiline) &.{} else re.alts();
    }

    /// Per-line candidate mask for a literal-bearing pattern — rg's Teddy
    /// prefilter at line grain. ONE fused whole-buffer `indexOfAnyPos` sweep marks
    /// only the lines around literal hits, jumping non-matching regions at SIMD
    /// speed, so the per-line classify below skips ~every non-candidate without an
    /// engine run — the win a needle-less alternation (`function|const|…`)
    /// otherwise can't get (no single required literal to gate on). The mask is a
    /// SUPERSET of the true match set for either literal set `maskLiterals` ranks
    /// (a hit landing in a line's trailing `\r`/terminator maps to that line —
    /// harmless: the caller still confirms each candidate with the engine) and
    /// never a subset, keeping output byte-identical. Returns null (caller keeps
    /// its per-line path) unless the shortcut is sound & profitable: a usable
    /// literal set, no single needle already gating, not inverted (a `-v` match
    /// LACKS the literals), not `--stop-on-nonmatch` (which acts on non-matches
    /// mid-stream), and a materialized body.
    pub fn litCandidates(self: *Emitter, lines: []const []const u8) ?[]const bool {
        if (self.needle != null or self.o.invert or self.o.stop_on_nonmatch) return null;
        if (lines.len == 0 or self.body_end <= self.base) return null;
        const lits = maskLiterals(self.o, self.re);
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

    /// `path:count` in `-c` / `--count-matches` output. Fixed, and deliberately
    /// NOT `--field-match-separator`: rg documents that flag as "only used when
    /// printing matching lines", and a count is a summary, not a matching line —
    /// its own printer carries a separator no flag reaches. Differentially
    /// confirmed against live rg (`bench/rgsuite/fuzz.py`, which is how the leak
    /// was found: gist was rendering `path|1` under `--field-match-separator '|'`).
    const summary_sep = ":";

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
        // An empty prefix is an element with nothing set — `--colors match:none`,
        // or a column number, which gist has never painted. Emitting the reset
        // anyway would spend chrome to change nothing.
        if (!self.use_color or on.len == 0) return self.add(s);
        self.add(on);
        self.add(s);
        self.add(palette.reset);
        self.chrome += on.len + palette.reset.len;
    }

    // ───────────────────────── OSC-8 click targets ─────────────────────────
    // A hyperlink is framing, not content: `linkOpen`/`linkClose` bracket text
    // the row was going to print anyway, and every one of them is a no-op when
    // the run resolved no beacon — so the non-linking path pays one null check
    // per locator and the output stays byte-identical. See `beacon.zig`.

    /// Open a frame pointing at `path` (at `lineno`:`col` when the destination
    /// asks for them). Idempotent-safe: a frame already open is left alone, so
    /// `writePath` nests harmlessly inside the wider anchor `prefix` opens.
    ///
    /// `anchors_path` says whether the filename itself will be printed inside
    /// this frame; when it is and the name carries a control byte, no frame
    /// opens at all (`beacon.tears`). A locator made only of digits is immune,
    /// which is why the caller answers rather than this function guessing.
    fn linkOpen(self: *Emitter, path: []const u8, lineno: usize, col: usize, anchors_path: bool) void {
        if (self.linked) return;
        const b = beacon.current() orelse return;
        const w = if (self.way) |w| (if (w.path.ptr == path.ptr and w.path.len == path.len) w else b.waypoint(self.a, path)) else b.waypoint(self.a, path);
        self.way = w;
        if (anchors_path and w.torn) return;
        const before = self.out.items.len;
        var buf: [20]u8 = undefined;
        for (w.slots, 0..) |slot, i| {
            self.add(w.chunks[i]);
            self.add(writeDecimal(&buf, @max(1, if (slot == .line) lineno else col)));
        }
        self.add(w.chunks[w.slots.len]);
        self.chrome += self.out.items.len - before;
        self.linked = true;
    }

    /// Close the open frame, if any. Idempotent — the body writers call it
    /// unconditionally so scope `row` needs no branch of its own out there.
    pub fn linkClose(self: *Emitter) void {
        if (!self.linked) return;
        self.linked = false;
        self.add(beacon.close);
        self.chrome += beacon.close.len;
    }

    /// Close a frame that ended earlier in the buffer — used to keep the
    /// trailing field separator OUTSIDE the anchor (ripgrep's exact placement)
    /// without making the eagerly-written separators lazy. The tail being
    /// stepped over is one separator, so the memmove is a few bytes.
    fn linkCloseAt(self: *Emitter, pos: usize) void {
        if (!self.linked) return;
        self.linked = false;
        self.out.insertSlice(self.a, pos, beacon.close) catch oom();
        self.chrome += beacon.close.len;
    }

    /// Write `path` followed by its terminator — NUL under `--null` (ripgrep's
    /// path-terminator), else the field separator. Used by the count/prefix paths.
    /// The path is always inside a link when one is active: its own when it is
    /// the whole anchor, the caller's wider one when `prefix` opened it first.
    /// Returns the offset just past the path — where a wider anchor would end
    /// if the path turns out to be the last field.
    fn writePath(self: *Emitter, path: []const u8, sep: []const u8) usize {
        const mine = !self.linked;
        if (mine) self.linkOpen(path, 0, 0, true);
        self.paint(self.o.palette.path, path);
        if (mine) self.linkClose();
        const end = self.out.items.len;
        if (self.o.null_sep) self.out.append(self.a, 0) catch oom() else self.paint(self.o.palette.sep, sep);
        return end;
    }

    /// Emit the `path:line:col:byteoff:` locator prefix (fields present per flags,
    /// separators per match/context). `--null` terminates the PATH with NUL; every
    /// other field uses the field separator. `col`/`byteoff` are 1-based / 0-based
    /// like ripgrep; `col` prints only under `--column` on a match line.
    ///
    /// The locator is also the click target: under the default `prefix` scope the
    /// anchor spans every field written here and stops before the trailing
    /// separator, so selecting a result still yields clean text.
    pub fn prefix(self: *Emitter, path: []const u8, lineno: usize, col: usize, byteoff: usize, is_match: bool) void {
        const sep = self.fieldSep(is_match);
        const b = beacon.current();
        const wide = if (b) |bb| bb.scope != .path and (self.show_name or self.o.line_num or self.o.byte_offset) else false;
        if (wide) self.linkOpen(path, lineno, col, self.show_name);
        // Where the anchor ends: after the last field's VALUE, before its
        // separator. Re-read after each field so the last one wins.
        var anchor = self.out.items.len;
        if (self.show_name) anchor = self.writePath(path, sep);
        var buf: [20]u8 = undefined;
        if (self.o.line_num) {
            self.paint(self.o.palette.line, writeDecimal(&buf, lineno));
            anchor = self.out.items.len;
            self.paint(self.o.palette.sep, sep);
        }
        // The column prints whenever the caller HAS one, match or context: rg's
        // vimgrep printer gives a context line a column too, which is visible
        // under `-v` where the context line is the one the pattern hit
        // (`rg --vimgrep -C1 -v -e aa` ⇒ `t.txt-1-1-aa x`). Every ordinary
        // context row passes 0 and so still prints none.
        if (self.o.column and col != 0) {
            self.paint(self.o.palette.column, writeDecimal(&buf, col));
            anchor = self.out.items.len;
            self.add(sep);
        }
        if (self.o.byte_offset) {
            self.add(writeDecimal(&buf, byteoff));
            anchor = self.out.items.len;
            self.add(sep);
        }
        if (wide and b.?.scope == .prefix) self.linkCloseAt(anchor);
    }

    /// The `--heading` group title: the path on its own line, and — when links
    /// are on — the click target for the whole group beneath it.
    ///
    /// Painted with the same `path` element `writePath` uses for the row
    /// prefix, because it is the same path in a different position: rg colors a
    /// heading and an `-l` row exactly as it colors the `path:` a row carries.
    /// Leaving it bare made the one line a reader scans for stand out least.
    pub fn heading(self: *Emitter, path: []const u8) void {
        self.linkOpen(path, 0, 0, true);
        self.paint(self.o.palette.path, path);
        self.linkClose();
        self.add(if (self.o.null_sep) "\x00" else self.o.outTerm());
    }

    /// 1-based byte column of the first match ripgrep reports on the line, or 0
    /// if it reports none — the value printed under `--column`, and (via
    /// `lineHitWord`) the `-w` verdict for the whole line.
    ///
    /// Walked with `Rows`, so a zero-width match counts: rg prints column 1 for
    /// `--column 'x?'` on any line, and selects a line under `-w` whose only
    /// word-valid match is empty (`-w 'x?'` matches ". ." and skips "zz").
    /// Reading the first NON-EMPTY span instead silently answered 0 for both —
    /// dropping the column from the row, and the line from `-c -w` entirely.
    /// For a non-nullable pattern the two walks agree, which is why this went
    /// unseen: every ordinary pattern makes no empty spans to disagree about.
    pub fn firstCol(self: *Emitter, ssim: *Matcher.SpanSim, line: []const u8) usize {
        var rows = Rows{ .re = self.re, .ss = ssim, .o = self.o, .mv = line, .terminated = self.lineTerminated(line) };
        const sp = rows.next() orelse return 0;
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
        if (self.o.groupSep()) |s| self.out.print(self.a, "{s}{s}", .{ s[0], s[1] }) catch oom();
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
    /// `"{s}{s}"` through the format machinery (byte-identical to it), and the
    /// link frame around them is exactly the heading's (under `--null` there is
    /// none: that list is bound for `xargs -0`, so no posture can link it).
    pub fn emitPathOnly(self: *Emitter, path: []const u8) usize {
        self.heading(path);
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
