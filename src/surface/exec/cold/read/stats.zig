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
const oom = args.oom;
const assay = @import("../../../../assay/assay.zig");
const multiline = @import("../emit/multiline.zig");
const output = @import("../emit/output.zig");
const Matcher = @import("../../../../kernel/match/regex/regex.zig").Matcher;
const simd = @import("../../../../kernel/match/scan/simd.zig");

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
    if (needle) |g| if (!g.in(body)) return .{ .matches = 0, .lines = 0, .bytes = body.len };
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
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        if (needle) |g| if (!g.in(mv)) continue;
        var from: usize = 0;
        var line_hit = false;
        while (from <= mv.len) {
            const sp = re.matchSpan(&ss, mv, from) orelse break;
            from = if (sp.end == sp.start) sp.start + 1 else sp.end;
            if (sp.end == sp.start) continue;
            if (o.word and !output.wordOk(o.unicode, mv, sp.start, sp.end)) continue;
            m += 1;
            line_hit = true;
        }
        if (line_hit) l += 1;
        if (o.max_per_file != 0 and l >= o.max_per_file) {
            // rg stops after the Nth matching line; bytes searched = end of that
            // line (its terminator included when one follows).
            var end = (@intFromPtr(line.ptr) - @intFromPtr(body.ptr)) + line.len;
            if (end < body.len) end += 1;
            return .{ .matches = m, .lines = l, .bytes = end };
        }
    }
    return .{ .matches = m, .lines = l, .bytes = body.len };
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
    const Regex = @import("../../../../kernel/match/regex/regex.zig").Regex;
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
