//! The `rg` face — the physical-line-grid emit modes.
//!
//! Everything that answers a file by walking its already-split lines.
//! `file` is the dispatcher and the default `path:line:text`
//! shape (with `-A/-B/-C` windows); the rest are its mode siblings — `-v`
//! without a window, `--passthru`, `-o`, and the count modes. `--vimgrep` is
//! deliberately NOT among them: it is a row shape the frames apply, not a mode,
//! so it lives in `display.zig` and only its span provenance is local here.
//!
//! Two other drivers answer a file without this grid: `skim.zig` never builds
//! the line array at all for a pure-literal pattern, and `multibuf.zig` works
//! off whole-buffer `-U` spans. All three emit through the same `Emitter`
//! vocabulary and `display.zig` frame, which is what keeps their bytes identical.

const std = @import("std");
const Matcher = @import("../../../../kernel/regex/regex.zig").Matcher;
const Regex = @import("../../../../kernel/regex/regex.zig").Regex;
const output = @import("../output.zig");
const Emitter = output.Emitter;
const oom = @import("../../../../surface/cli/outcome.zig").oom;
const display = @import("display.zig");
const replace = @import("replace.zig");

/// Will `file()` answer its mode from the whole buffer without reading
/// `lines`? The render drivers consult this to skip `collectLines`
/// entirely — the fused `-c`/`-l` paths below never touch the line grid.
/// Callers must have `base`/`body_end` set (they do: both drivers set the
/// pair right before dispatch). Mirrors `file()`'s own gating exactly.
pub fn fusedFileEligible(self: *const Emitter) bool {
    const o = self.o;
    // `--vimgrep` is absent from this list on purpose: the only two modes below
    // that qualify are `-l` and `-c`, and both now override it in `file()`, so a
    // vimgrep row is never the thing the fused pass would have had to emit.
    if (o.invert or o.word or o.crlf or o.null_data or o.stop_on_nonmatch or
        o.passthru or o.only_matching) return false;
    return switch (o.mode) {
        .files_with_matches => self.re.docMatchFused(),
        .count => self.re.countRunFused(),
        else => false,
    };
}

pub fn file(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
    const o = self.o;
    if (o.passthru and o.mode.frames()) return passthru(self, path, lines);
    // Span modes (`-o`, `--count-matches`): a fused whole-buffer MISS (one
    // class-run/DFA doc pass) proves zero spans, sparing the per-line span
    // walk entirely — the miss-heavy regime rg's lazy-DFA doc scan used to
    // win. A hit still takes the per-line loop (spans need positions).
    // `--crlf`/`--null-data` change the line view an anchored DFA pattern
    // judges against, so they keep the plain path (same fence as the
    // fused `-c`/`-l` gates below).
    if ((o.only_matching or o.mode == .count_matches) and !o.invert and !o.crlf and
        !o.null_data and !o.stop_on_nonmatch and self.body_end > self.base and
        self.re.docMatchFused())
    {
        const body = @as([*]const u8, @ptrFromInt(self.base))[0 .. self.body_end - self.base];
        var s: ?Matcher.Sim = Matcher.Sim.init(self.a, self.re) catch null;
        defer if (s) |*ss| ss.deinit();
        if (s != null and !self.re.docMatch(&s.?, body))
            return if (o.mode.counting()) self.bufTally(path, 0) else 0;
    }
    // `-c -o` already resolved to `.count_matches` in argv (`answer.Mode.settle`
    // — ripgrep's documented override that a count of *matches* beats a count
    // of lines), so this asks about the mode and not about `-o` a second time.
    if (o.mode == .count_matches and !o.invert) return countMatches(self, path, lines);
    // `-o` is a row SHAPE, not an output mode — the same distinction
    // `--vimgrep` draws below. With a context window asked for, its rows
    // belong inside the general frame so `-A/-B/-C` and the `--` separators
    // still apply (rg prints the context around an `-o` match in full); only
    // the far more common windowless case can take the flat loop.
    if (o.only_matching and !o.invert and !o.wantsContext()) return onlyMatching(self, path, lines);

    // The plain-flag whole-buffer regime: the per-line loop below computes
    // exactly "which lines match" under rg's `\n` line model, so when no
    // flag changes the line view (`--crlf` trims `\r`, `--null-data`
    // re-terminates) or the predicate (`-v`/`-w`/--stop-on-nonmatch) and
    // the file body is addressable, a fused whole-buffer machine may
    // answer the mode outright. The gates (needle/lits) are skipped —
    // they only ever accelerate the same verdicts.
    const whole_buf = !o.invert and !o.word and !o.crlf and !o.null_data and
        !o.stop_on_nonmatch and self.body_end > self.base;

    // `-c` fused fast path: the class-run kernel counts matching lines in
    // one hit-jumping pass over the body — no line split consumed, no
    // per-line dispatch (the overhead rg's fused count never paid).
    // `countRunLines` is non-null only when that pass is exact.
    // A cap with an after-context window can count PAST the cap (`capWindow`),
    // which the whole-buffer tally can't see, so that pair takes the line loop.
    if (whole_buf and o.mode == .count and !(o.max_per_file != 0 and o.after > 0)) {
        const body = @as([*]const u8, @ptrFromInt(self.base))[0 .. self.body_end - self.base];
        if (self.re.countRunLines(body)) |n| {
            const capped = if (o.max_per_file != 0) @min(n, o.max_per_file) else n;
            return self.bufTally(path, @intCast(capped));
        }
    }

    // Borrow the caller-threaded scratch when present; else pay a file-local.
    var local_sim: ?Matcher.Sim = if (self.sim == null) (Matcher.Sim.init(self.a, self.re) catch return 0) else null;
    defer if (local_sim) |*s| s.deinit();
    const sim = self.sim orelse &local_sim.?;

    // `-l` fused fast path: one whole-buffer boolean (`docMatch` — the
    // class-run scan or the DFA's fused doc pass) answers "any line
    // matches", replacing the per-line loop the serial single-file `-l`
    // otherwise pays. Only when `docMatch` really is that machine
    // (`docMatchFused`) — the Pike fallback would forfeit the gates.
    if (whole_buf and o.mode == .files_with_matches and self.re.docMatchFused()) {
        const body = @as([*]const u8, @ptrFromInt(self.base))[0 .. self.body_end - self.base];
        return if (self.re.docMatch(sim, body)) self.emitPathOnly(path) else 0;
    }
    // `-w` decides a line via the span predicate; the plain path uses the
    // boolean DFA. Only `-w` pays for the SpanSim scratch.
    var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    // `-v` with no context/count/files-only degenerates to "emit every line
    // the gate+engine rejects, in order, col 0" — the whole two-pass machinery
    // below (idx list, a lines.len bool grid + memset, the windowStart re-walk,
    // the always-0 firstCol) collapses to one streamed pass. Byte-identical
    // (self-checked in flagbench + the rg parity suite); the excluded flags keep
    // their existing branches untouched.
    if (o.invert and o.before == 0 and o.after == 0 and o.mode.frames() and
        !o.stop_on_nonmatch and !o.passthru)
        return invertPlain(self, path, lines, sim, &wss);
    // Whole-buffer literal prefilter (see `litCandidates`): a non-candidate
    // line provably cannot match, so skip it before `mview`/the engine.
    // `--stop-on-nonmatch` disables the mask, so a non-candidate here is a
    // plain non-match (never mid-stream stop bookkeeping).
    const cand = self.litCandidates(lines);
    var idx: std.ArrayList(usize) = .empty;
    var capped_at: ?usize = null;
    for (lines, 0..) |line, k| {
        if (cand) |c| if (!c[k]) continue;
        if (!lineHit(self, sim, &wss, line)) {
            // --stop-on-nonmatch: once matching has begun, the first non-match
            // ends the file (ripgrep stops reading further lines).
            if (o.stop_on_nonmatch and idx.items.len > 0) break;
            continue;
        }
        // `-l` asks only whether this file has any matching line. Emit on
        // the first proof instead of scanning the rest of the file and
        // accumulating line indexes that no output mode will consume.
        if (o.mode == .files_with_matches) return self.emitPathOnly(path);
        idx.append(self.a, k) catch oom();
        if (o.max_per_file != 0 and idx.items.len >= o.max_per_file) {
            capped_at = k;
            break;
        }
    }
    if (o.mode.counting()) {
        const extra = if (capped_at) |last| capWindow(self, lines, cand, sim, &wss, last, null) else 0;
        return self.bufTally(path, idx.items.len + extra);
    }
    if (idx.items.len == 0) return 0;
    const is_match = self.a.alloc(bool, lines.len) catch oom();
    @memset(is_match, false);
    for (idx.items) |m| is_match[m] = true;
    if (capped_at) |last| _ = capWindow(self, lines, cand, sim, &wss, last, is_match);
    // Column locators need a span scan per match line: `--column` wants the
    // first span, `--vimgrep` wants every one of them — and still needs the
    // scan when a later `--no-column` suppressed the column it would print.
    var css: ?Matcher.SpanSim = if (o.column or o.vimgrep) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
    defer if (css) |*s| s.deinit();
    // Only reachable with a context window (the windowless `-o` took the flat
    // loop above), where a matching line contributes its spans and the lines
    // around it print in full as context.
    var mss: ?Matcher.SpanSim = if (o.only_matching) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
    defer if (mss) |*s| s.deinit();
    var prev_end: ?usize = null;
    for (idx.items) |m| {
        const hi = @min(m + o.after, lines.len - 1);
        var k = self.windowStart(m -| o.before, hi, &prev_end) orelse continue;
        while (k <= hi) : (k += 1) {
            const is_m = is_match[k];
            // Spans belong to the line the PATTERN hit, which `is_match` only
            // names when `-v` is off — inverted, the printed match line is the
            // one the pattern MISSED and has no spans at all, while the context
            // line is the hit and carries a row per span (framed `-`, with its
            // column). Gating on `is_m` alone printed the context line and
            // dropped every inverted match line: `rg -o -v -C1 -e bbb` over
            // "aaa\nxbbbx\nccc" is `1:aaa`, `2-2-bbb`, `3:ccc` — we emitted
            // only `2-2-xbbbx`. The `--vimgrep` rows below already invert this
            // way; `-o` did not. (Found by the differential fuzzer.)
            const pattern_hit = is_m != o.invert;
            if (pattern_hit and mss != null) {
                if (o.replace != null)
                    _ = replace.emitLineRepl(self, path, k + 1, lines[k], is_m)
                else
                    _ = display.emitMatches(self, &mss.?, path, k + 1, lines[k], self.mview(lines[k]), is_m);
                continue;
            }
            // rg's vimgrep printer emits one row per match found in the line it
            // is printing — match or context, and framed accordingly. Under `-v`
            // that inverts which side has spans: a printed (inverted) match line
            // has none and prints ONE column-less row, while a CONTEXT line is
            // one the pattern hit and carries a row per span. Measured:
            // `rg --vimgrep -C1 -v -e aa` over "aa x aa\nno" prints
            // `-1-1-`, `-1-6-`, then `:2:`. Gating on `is_m` alone printed
            // nothing at all under `-v` (found by the differential fuzzer).
            if (o.vimgrep) if (css) |*s| {
                if (vimgrepRows(self, s, path, k + 1, lines[k], is_m) != 0) continue;
            };
            // Same rule as the vimgrep rows above: the column describes where the
            // PATTERN hit the line being printed, which under `-v` is the context
            // line (`rg --column -C1 -v -e aa` ⇒ `1-1-aa x`). An ordinary context
            // line has no match, so `firstCol` answers 0 and nothing prints.
            const col: usize = if (css != null) self.firstCol(&css.?, self.mview(lines[k])) else 0;
            self.row(path, k + 1, col, self.offOf(lines[k]), lines[k], is_m);
        }
    }
    return idx.items.len;
}

/// The post-cap after-context window. `-m` caps how many matches ANCHOR a
/// window; it neither demotes nor hides the lines inside the last one. rg still
/// searches those `--after-context` lines, prints a matching one as a match
/// (`:`, not `-`) and counts it: `-m 1 -A 2` over `fn a / xxx / fn c` prints two
/// `:` rows and `-c -m 2 -A 2` over four matching lines reports 4. The window
/// does not chain — a match inside it opens no window of its own. Marks each
/// matching line into `marks` when given; returns how many matched.
/// (`--passthru`, whose post-cap lines rg *does* demote to context, has its own
/// path and must not come through here.)
fn capWindow(self: *Emitter, lines: []const []const u8, cand: ?[]const bool, sim: *Matcher.Sim, wss: *?Matcher.SpanSim, last: usize, marks: ?[]bool) usize {
    if (self.o.after == 0 or last + 1 >= lines.len) return 0;
    const hi = @min(last + self.o.after, lines.len - 1);
    var n: usize = 0;
    for (lines[last + 1 .. hi + 1], last + 1..) |line, k| {
        if (cand) |c| if (!c[k]) continue;
        if (!lineHit(self, sim, wss, line)) continue;
        n += 1;
        if (marks) |mk| mk[k] = true;
    }
    return n;
}

/// Does this line count as a match? The required-literal gate first (a line
/// without the literal bytes provably cannot match, and a SIMD memmem is an
/// order of magnitude cheaper than an engine run per line), then the engine —
/// `-w` through the span predicate — with `-v` flipping the verdict.
fn lineHit(self: *Emitter, sim: *Matcher.Sim, wss: *?Matcher.SpanSim, line: []const u8) bool {
    const mv = self.mview(line);
    const hit = self.lineCanMatch(mv) and
        (if (wss.*) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(sim, mv));
    return hit != self.o.invert;
}

/// `-v` with no context window (`-A/-B/-C`), count, or `-l`: the one-pass
/// invert emit. A line the required-literal gate or the engine REJECTS is a
/// non-match, so under invert it prints — framed as a match (`:`) with its
/// own line number and column 0 (a non-matching line has no span, so the
/// two-pass path's `firstCol` is always 0 here). `-m` caps printed lines.
/// Returns that count. Byte-identical to the general `file` invert branch,
/// without its per-file `idx` list and `lines.len` bool grid.
fn invertPlain(self: *Emitter, path: []const u8, lines: []const []const u8, sim: *Matcher.Sim, wss: *?Matcher.SpanSim) usize {
    const o = self.o;
    var printed: usize = 0;
    for (lines, 0..) |line, k| {
        if (!lineHit(self, sim, wss, line)) continue; // invert: a matching line is excluded
        self.row(path, k + 1, 0, self.offOf(line), line, true);
        printed += 1;
        if (o.max_per_file != 0 and printed >= o.max_per_file) break;
    }
    return printed;
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
    var css: ?Matcher.SpanSim = if (o.column or o.vimgrep) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
    defer if (css) |*s| s.deinit();
    var mss: ?Matcher.SpanSim = if (o.only_matching) (Matcher.SpanSim.init(self.a, self.re) catch null) else null;
    defer if (mss) |*s| s.deinit();
    // `--passthru` prints every line, so the prefilter can't skip lines — but
    // a non-candidate is a proven non-match, so it still spares the engine.
    const cand = self.litCandidates(lines);
    var matched: usize = 0;
    for (lines, 0..) |line, k| {
        const mv = self.mview(line);
        const raw = (if (cand) |c| c[k] else self.lineCanMatch(mv)) and
            (if (wss) |*s| self.lineHitWord(s, mv) else self.re.lineMatch(sim, mv));
        // Under passthru, `-v` and `-m` decide how a line is MARKED, never
        // whether it prints — every line prints, that being the whole point of
        // the flag. `-v` flips which lines count as matches; `-m` stops
        // marking once the per-file limit is reached and the rest fall through
        // as context. Filtering on either instead dropped lines rg keeps.
        const capped = o.max_per_file != 0 and matched >= o.max_per_file;
        const is_m = (raw != o.invert) and !capped;
        if (is_m) matched += 1;
        // The span frames below describe where the PATTERN hit, which an
        // inverted line has nothing to say about.
        const spans_apply = is_m and !o.invert;
        // --passthru -o: a matching line contributes each match span (only-
        // matching frame), a non-matching line still prints in full (context).
        if (spans_apply and mss != null) {
            if (self.o.replace != null) _ = replace.emitLineRepl(self, path, k + 1, line, is_m) else _ = display.emitMatches(self, &mss.?, path, k + 1, line, mv, is_m);
            continue;
        }
        // --passthru --vimgrep: a matching line still contributes one row per
        // match; the non-matching lines around it stay context, as ever.
        if (o.vimgrep) if (css) |*s| {
            if (vimgrepRows(self, s, path, k + 1, line, is_m) != 0) continue;
        };
        const col: usize = if (css != null) self.firstCol(&css.?, mv) else 0;
        self.row(path, k + 1, col, self.offOf(line), line, is_m);
    }
    return matched;
}

/// Where a matching line's `--vimgrep` spans come from on the physical grid:
/// the reused span simulator, walked over the `--crlf` match view. `-r` is the
/// exception — rg recomputes vimgrep columns against the REPLACED text, so the
/// rewrite's replacement offsets ARE the row starts. `display.vimgrepLine` owns
/// the row shape itself (shared with `multibuf`'s `-U` provenance).
fn vimgrepRows(self: *Emitter, ss: *Matcher.SpanSim, path: []const u8, lineno: usize, line: []const u8, is_match: bool) usize {
    var v: display.Vimgrep = .{
        .path = path,
        .lineno = lineno,
        .text = line,
        .off = self.offOf(line),
        .starts = &.{},
        .terminated = self.lineTerminated(line),
        .is_match = is_match,
    };
    if (self.o.replace) |tmpl| {
        const r = replace.buildReplaced(self, tmpl, line);
        v.text = r.text;
        v.starts = r.starts;
        display.vimgrepLine(self, v);
        return r.starts.len;
    }
    const mv = self.mview(line);
    var starts: std.ArrayList(usize) = .empty;
    // `--vimgrep` is one row per match rg's printer YIELDS, which for a nullable
    // pattern includes the zero-width ones (measured: `--vimgrep -e 'x*'` prints
    // a row at every column of every line). So it walks `output.Rows` — the same
    // iteration `-o`/`--count-matches` use — not the non-empty-only `nextSpan`,
    // which dropped every row of an all-empty line (the fuzzer's `\b*` case).
    var rows = output.Rows{ .re = self.re, .ss = ss, .o = self.o, .mv = mv, .terminated = self.lineTerminated(line) };
    while (rows.next()) |sp| starts.append(self.a, sp.start) catch oom();
    v.starts = starts.items;
    display.vimgrepLine(self, v);
    return starts.items.len;
}

/// `-o` frame across `lines`: each match span as its raw bytes, or — with
/// `-r` — the expanded template (not the raw match) per span. Returns the
/// number emitted (respecting `--max-count`).
fn onlyMatching(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var ssim: ?Matcher.SpanSim = if (self.o.replace == null) Matcher.SpanSim.init(self.a, self.re) catch return 0 else null;
    defer if (ssim) |*s| s.deinit();
    const cand = self.litCandidates(lines);
    var emitted: usize = 0;
    var hit_lines: usize = 0;
    for (lines, 0..) |line, k| {
        if (cand) |c| if (!c[k]) continue;
        const mv = self.mview(line);
        if (!self.lineCanMatch(mv)) continue;
        // The windowless `-o` frame is only reached with `-v` off (see the
        // dispatch above), so every row it prints frames as a match.
        const n = if (ssim) |*s| display.emitMatches(self, s, path, k + 1, line, mv, true) else replace.emitLineRepl(self, path, k + 1, line, true);
        emitted += n;
        if (n == 0) continue;
        // `-m` limits matched LINES, so a line emits all of its spans and the
        // limit is tested between lines — `-o -m2` is two lines' worth of
        // matches, not the first two matches.
        hit_lines += 1;
        if (self.o.max_per_file != 0 and hit_lines >= self.o.max_per_file) break;
    }
    return emitted;
}

fn countMatches(self: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var ssim = Matcher.SpanSim.init(self.a, self.re) catch return 0;
    defer ssim.deinit();
    const cand = self.litCandidates(lines);
    var total: usize = 0;
    var hit_lines: usize = 0;
    // The post-cap after-context window (see `capWindow`): rg keeps counting the
    // spans of a matching line inside it, so the walk runs to the window's last
    // line instead of stopping on the cap.
    var window_end: ?usize = null;
    for (lines, 0..) |line, k| {
        if (window_end) |w| if (k > w) break;
        if (cand) |c| if (!c[k]) continue;
        const mv = self.mview(line);
        if (!self.lineCanMatch(mv)) continue;
        // Counted through the walk `-o` prints from, so `--count-matches` is
        // literally "how many `-o` rows" — rg's own identity. Counting
        // non-empty spans instead lost every zero-width match a nullable
        // pattern makes (`--count-matches 'a*'` over "aa\nbb" reported 1, rg 4).
        var rows = output.Rows{ .re = self.re, .ss = &ssim, .o = self.o, .mv = mv, .terminated = self.lineTerminated(line) };
        const on_line = rows.tally();
        if (on_line == 0) continue;
        total += on_line;
        // `-m` limits matched LINES, not spans — the same unit it limits
        // everywhere else — so the last admitted line contributes every span
        // it holds. `rg --count-matches -m1` over a line with two matches
        // reports 2; capping the span loop reported 1.
        hit_lines += 1;
        if (window_end == null and self.o.max_per_file != 0 and hit_lines >= self.o.max_per_file) {
            if (self.o.after == 0) break;
            window_end = k + self.o.after;
        }
    }
    return self.bufTally(path, total);
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
        .o = .{ .mode = .files_with_matches },
        .show_name = true,
        .out = &out,
        .needle = .of(m.required()),
    };

    try t.expectEqual(@as(usize, 1), em.file("fixture.txt", &.{ "needle first", "needle second" }));
    try t.expectEqualStrings("fixture.txt\n", out.items);
}

// `--count-matches` is defined as the number of rows `-o` prints, so the two
// modes are asked the same question over the same lines and must agree. A
// nullable pattern is the only place they can disagree — it is the one shape
// whose matches are mostly zero-width — and counting non-empty spans used to
// report 1 where rg (and this file's own `-o`) say 4.
test "--count-matches counts exactly the rows -o prints, empty matches included" {
    const t = std.testing;
    // Captured from ripgrep 15.2.0 over "aa\nbb\n":
    //   rg -o 'a*' ⇒ aa / <empty> ×3     rg --count-matches 'a*' ⇒ 4
    //   rg -o 'x?' ⇒ <empty> ×6          rg --count-matches 'x?' ⇒ 6
    //   rg -o 'a'  ⇒ a ×2                rg --count-matches 'a'  ⇒ 2
    const cases = [_]struct { pat: []const u8, want: usize }{
        .{ .pat = "a*", .want = 4 },
        .{ .pat = "x?", .want = 6 },
        .{ .pat = "a", .want = 2 },
    };
    const lines: []const []const u8 = &.{ "aa", "bb" };
    for (&cases) |c| {
        var m = Matcher{ .linear = try Regex.compile(t.allocator, c.pat) };
        defer m.deinit();

        var counted: std.ArrayList(u8) = .empty;
        defer counted.deinit(t.allocator);
        var ce = Emitter{ .a = t.allocator, .re = &m, .o = .{ .mode = .count_matches }, .show_name = false, .out = &counted };
        try t.expectEqual(c.want, ce.file("fixture.txt", lines));

        // The same question through the printer: one row per match.
        var printed: std.ArrayList(u8) = .empty;
        defer printed.deinit(t.allocator);
        var pe = Emitter{ .a = t.allocator, .re = &m, .o = .{ .only_matching = true }, .show_name = false, .out = &printed };
        try t.expectEqual(c.want, pe.file("fixture.txt", lines));
        try t.expectEqual(c.want, std.mem.count(u8, printed.items, "\n"));
    }
}
