//! gist `rg` — the search tally.
//!
//! One counter schema behind rg's `--stats` block, the `--json` summary record
//! (`emit/json.zig`), and the `GIST_TRACE=query` stderr diagnostic, plus the
//! per-file count that feeds them. Both walk engines fold into the same
//! `Stats`, so a parallel run's reported numbers cannot drift from a serial
//! one's — the difference between the two engines is scheduling, never
//! arithmetic.

const std = @import("std");
const args = @import("../argv/args.zig");
const Opts = args.Opts;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const assay = @import("../../../assay/assay.zig");
const multiline = @import("../emit/multiline.zig");
const output = @import("../emit/output.zig");
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const simd = @import("../../../kernel/scan/simd.zig");

/// Unified search-stats counter set — one `assay.Tally` schema shared by rg's
/// `--stats` block (below) and the `--json` summary record (`emit/json.zig`),
/// collapsing what were two near-identical hand-rolled structs. Timing fields
/// are intentionally omitted: they are non-deterministic and the differential
/// harness normalizes the two `seconds` lines away (ripgrep's own tests only
/// `contains`-check them). Named by rg's `--stats` vocabulary; the JSON emitter
/// renders `files_searched`→`searches` and `files_with_match`→`searches_with_match`.
/// `bytes_printed` is set once by whoever owns the final output buffer — a worker
/// never accumulates it, so per-worker folds use `foldExcept(.., &.{.bytes_printed})`;
/// the JSON summary always reports it as 0.
pub const StatField = enum {
    matches,
    matched_lines,
    files_with_match,
    files_searched,
    bytes_printed,
    bytes_searched,
};
pub const Stats = assay.Tally(StatField);

pub const FileStat = struct { matches: usize, lines: usize, bytes: usize };

/// `N bytes printed` for a finished run, given what the run actually wrote.
///
/// ripgrep tallies that counter inside its STANDARD printer alone, so every
/// summary shape — `-l`, `--files-without-match`, `-c`, `--count-matches` —
/// reports `0 bytes printed` however many path or tally bytes it emitted, and so
/// does `-q`, which emits nothing. gist used to report its own output buffer's
/// length in those modes (`14 bytes printed` where rg said `0`); the divergence
/// was caught differentially by `bench/rgsuite/fuzz.py`. Both walk engines route
/// through here so the two cannot answer it differently.
pub fn bytesPrinted(o: Opts, written: usize) usize {
    return if (o.quiet or o.mode.enumerates()) 0 else written;
}

test "bytes printed is the standard printer's counter only" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 26), bytesPrinted(.{}, 26));
    try t.expectEqual(@as(usize, 26), bytesPrinted(.{ .mode = .json }, 26));
    try t.expectEqual(@as(usize, 0), bytesPrinted(.{ .quiet = true }, 26));
    inline for (.{ .files_with_matches, .files_without_match, .count, .count_matches, .files }) |m|
        try t.expectEqual(@as(usize, 0), bytesPrinted(.{ .mode = m }, 26));
}

/// Count total match spans and matching lines in one file (for `--stats`),
/// honoring `-w` word bounds and the `--crlf` match view. Empty spans don't
/// count (ripgrep counts non-empty matches). Under `-m/--max-count`, ripgrep
/// stops reading after the Nth matching line, so `bytes` reports only the bytes
/// actually searched (ADR-parity with rg's `r2944` regression) rather than the
/// whole file.
pub fn fileMatchStats(re: *const Matcher, a: std.mem.Allocator, o: Opts, body: []const u8, lines: []const []const u8, needle: ?simd.Gate) FileStat {
    // The required-literal gate is sound for the tally exactly as it is for
    // emission: a body/line without the literal every match must contain holds
    // zero matches, so it contributes (0 matches, 0 lines) and only its bytes to
    // `bytes_searched`. This replaces a full NFA sweep of every line with one
    // SIMD `contains` — the same scan `--stats` used to skip. `bytes` still
    // reports the whole body (rg counts non-matching bytes as searched).
    // Under `-v` the gate proves the OPPOSITE: a body without the required
    // literal has no matching line, so EVERY line is an inverted match — the
    // shortcut would report zero where rg reports the whole file.
    if (!o.invert) if (needle) |g| if (!g.in(body)) return .{ .matches = 0, .lines = 0, .bytes = body.len };
    // `-U`: the tally is over whole-buffer spans, not split lines. `matches`
    // counts non-empty spans; `lines` the union of lines they cover (rg's
    // `matched lines`). `-m` already capped the span list, and rg reports the
    // whole body as searched here (no line-wise early stop).
    if (multiline.sliceModel(re, o)) {
        const grid = multiline.splitLines(a, body, o.term());
        var real: std.ArrayList(multiline.Span) = .empty;
        for (multiline.collect(a, re, o, body)) |sp| if (sp.end > sp.start) real.append(a, sp) catch return .{ .matches = 0, .lines = 0, .bytes = body.len };
        return .{ .matches = real.items.len, .lines = multiline.countMatchedLines(grid, real.items), .bytes = body.len };
    }
    var ss = Matcher.SpanSim.init(a, re) catch return .{ .matches = 0, .lines = 0, .bytes = body.len };
    defer ss.deinit();
    var m: usize = 0;
    var l: usize = 0;
    // `-m` stops rg after the Nth matching line — but not before it searches
    // that match's after-context window, and a matching line inside the window
    // still counts (measured: `-m 1 -A 2` over `fn a / xxx / fn c` reports 2
    // matches, 14 bytes searched). The window does not chain: a match inside it
    // opens no window of its own. `bytes` then reports through the last
    // MATCHING line, never the last line the window reached.
    var last_hit_end: usize = 0;
    var window_end: ?usize = null;
    for (lines, 0..) |line, i| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        // `-v` counts the lines the pattern does NOT match, so it only needs to
        // know whether ONE span exists (cap 1) and inverts the answer; the plain
        // case counts every span on the line.
        const term = lineTerminated(body, line);
        const hits = if (o.invert) @intFromBool(countSpans(re, &ss, o, needle, mv, term, 1) == 0) else countSpans(re, &ss, o, needle, mv, term, 0);
        if (hits != 0) {
            l += 1;
            // rg's `matches` counter under `-v` depends on which printer runs:
            // the standard printer reports `0 matches` (an inverted line carries
            // no span to count) while every summary printer — `-c`,
            // `--count-matches`, `-l`, `--files-without-match` — reports one per
            // inverted line. Both measured against live rg;
            // `bench/rgsuite/fuzz.py` is the oracle.
            m += if (o.invert) @intFromBool(o.mode.enumerates()) else hits;
            last_hit_end = lineEnd(body, line);
        }
        if (window_end) |w| {
            if (i >= w) break;
            continue;
        }
        if (hits != 0 and o.max_per_file != 0 and l >= o.max_per_file) {
            if (o.after == 0) return .{ .matches = m, .lines = l, .bytes = last_hit_end };
            window_end = i + o.after;
        }
    }
    // A window that ran off the end of the file means the searcher reached EOF
    // rather than stopping at the cap, and rg then reports the whole body as
    // searched (measured: `-m 1 -A 3` over a 3-line file reports all 13 bytes,
    // where `-A 2` — the window ending exactly on the last line — reports 5).
    const stopped_short = if (window_end) |w| w < lines.len else false;
    return .{ .matches = m, .lines = l, .bytes = if (stopped_short) last_hit_end else body.len };
}

/// One line's end offset within its body, rg's terminator included when one
/// follows — the boundary `bytes searched` reports when a cap stops the walk.
fn lineEnd(body: []const u8, line: []const u8) usize {
    const end = (@intFromPtr(line.ptr) - @intFromPtr(body.ptr)) + line.len;
    return if (end < body.len) end + 1 else end;
}

/// Did this line carry a terminator in the body — `lineEnd`'s own predicate,
/// named, because `output.Rows` needs it to decide whether the zero-width match
/// at the end of the content exists (it sits before the `\n`, so an unterminated
/// tail has no such position).
fn lineTerminated(body: []const u8, line: []const u8) bool {
    return (@intFromPtr(line.ptr) - @intFromPtr(body.ptr)) + line.len < body.len;
}

/// Countable spans on one line — rg's `--stats` `matches` is the count of spans
/// its printer would yield, zero-width ones included (measured: `--stats -e 'a|'`
/// over a 4-line file reports 11 matches / 4 matched lines, the same 11 rows `-o`
/// prints). So this walks `output.Rows`, the one span iteration `-o` and
/// `--count-matches` already share, rather than a second non-empty-only loop that
/// silently undercounted every nullable pattern (the fuzzer's `\b*` / `[a-z]*`
/// / `pat|` divergences).
/// `cap` cuts the walk short — `-v` only needs to know whether ONE exists, so it
/// asks for 1 rather than paying for the whole line.
fn countSpans(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, needle: ?simd.Gate, mv: []const u8, terminated: bool, cap: usize) usize {
    if (needle) |g| if (!g.in(mv)) return 0;
    var rows = output.Rows{ .re = re, .ss = ss, .o = o, .mv = mv, .terminated = terminated };
    var n: usize = 0;
    while (rows.next() != null) {
        n += 1;
        if (n == cap) break;
    }
    return n;
}

/// Emit ripgrep's `--stats` block (leading blank line, one field per line). The
/// two `seconds` lines now carry the run's real monotonic `elapsed` (formatted
/// `{d:.6}`, ripgrep's precision); the differential harness still normalizes
/// both wall-clock lines away, so this is byte-parity-safe and rg-faithful.
pub fn emitStats(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Stats, elapsed: assay.Duration) void {
    const secs = @as(f64, @floatFromInt(elapsed.ns())) / 1e9;
    out.print(a,
        \\
        \\{d} matches
        \\{d} matched lines
        \\{d} files contained matches
        \\{d} files searched
        \\{d} bytes printed
        \\{d} bytes searched
        \\{d:.6} seconds spent searching
        \\{d:.6} seconds total
        \\
    , .{ s.get(.matches), s.get(.matched_lines), s.get(.files_with_match), s.get(.files_searched), s.get(.bytes_printed), s.get(.bytes_searched), secs, secs }) catch oom();
}

/// Lens-gated machine-readable diagnostic for a completed search — the stderr
/// peer of the stdout `--stats`/`--json` summary, emitted ONLY under
/// `GIST_TRACE=query` (default runs emit nothing here, preserving byte parity).
/// It renders as one NDJSON record on a `--json` run (or `GIST_TRACE_FORMAT=
/// json`) and as one text line otherwise, routed through the assay sink — so a
/// warm daemon query carries it back to the client's stderr like every other
/// diagnostic. Shared by both walk engines so their reported counts can't drift.
pub fn diagSearch(gpa: std.mem.Allocator, json: bool, s: Stats, elapsed: assay.Duration) void {
    if (!assay.lit(.query)) return;
    assay.summary(gpa, json, "gist: {d} files searched · {d} with match · {d} matches · {d} matched lines · {d} bytes searched · {d:.1} ms\n", .{ s.get(.files_searched), s.get(.files_with_match), s.get(.matches), s.get(.matched_lines), s.get(.bytes_searched), elapsed.ms() }, .{
        .{ "verb", "s", "search" },
        .{ "files_searched", "d", s.get(.files_searched) },
        .{ "files_with_match", "d", s.get(.files_with_match) },
        .{ "matches", "d", s.get(.matches) },
        .{ "matched_lines", "d", s.get(.matched_lines) },
        .{ "bytes_searched", "d", s.get(.bytes_searched) },
        .{ "ms", "d:.1", elapsed.ms() },
    });
}

test "multiline --stats tallies spans and covered lines over the whole buffer" {
    const Regex = @import("../../../kernel/regex/regex.zig").Regex;
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Matcher{ .linear = try Regex.compileOpts(a, "a\\nb", .{ .multiline = true }) };
    defer m.deinit();
    const body = "a\nb\nx\na\nb\n";
    const fs = fileMatchStats(&m, a, .{ .multiline = true }, body, &.{}, null);
    try t.expectEqual(@as(usize, 2), fs.matches); // two cross-line matches
    try t.expectEqual(@as(usize, 4), fs.lines); // they cover four physical lines
    try t.expectEqual(body.len, fs.bytes);
}
