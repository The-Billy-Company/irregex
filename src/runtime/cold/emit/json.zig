//! gist `rg --json` — ripgrep's JSON Lines record stream (ADR-parity output).
//!
//! Split from `run.zig`/`output.zig`: given each file's already-read bytes,
//! this module emits ripgrep's exact `--json` message sequence — one JSON object
//! per line: a `begin` per matched file, a `match`/`context` per emitted line
//! (with byte-accurate `submatches` and, under `-r`, per-match `replacement`),
//! an `end` with that file's stats, and a trailing `summary`. It reuses the one
//! regex engine (`matchSpan` for spans, capture VM for `-r`) and `output`'s
//! shared template expander, so there is no second matcher or replacer.
//!
//! The `stats` timing fields (`elapsed`, `elapsed_total`) and `bytes_printed` are
//! ripgrep-printer-internal / wall-clock and inherently non-reproducible, so we
//! emit fixed placeholders; the differential harness normalizes them on both
//! sides exactly as it already does for `--stats` seconds. Every correctness
//! field (`matches`, `matched_lines`, `searches`, `bytes_searched`, and the whole
//! match/submatch structure) is emitted for real.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const args = @import("../argv/args.zig");
const output = @import("output.zig");
const ml = @import("multiline.zig");
const Opts = args.Opts;
const die = args.die;
const oom = args.oom;
const Regex = @import("../../../search/match/regex/linear/core.zig").Regex;
const Matcher = @import("../../../search/match/regex/linear/matcher.zig").Matcher;
const captures_mod = @import("../../../search/match/regex/compile/captures.zig");
const Caps = captures_mod.Caps;
const Captures = captures_mod.Captures;

pub const File = struct { path: []const u8, body: []const u8 };

const Stats = struct { searches: usize = 0, with_match: usize = 0, matched_lines: usize = 0, matches: usize = 0, bytes_searched: usize = 0 };

/// Emit the full `--json` stream for `files` into `out`. Returns true if any file
/// matched (drives the process exit code).
pub fn run(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, files: []const File) bool {
    var ss = Matcher.SpanSim.init(a, re) catch die("engine init failed\n", .{});
    defer ss.deinit();
    var st = Stats{};
    for (files) |f| {
        // Bound the record buffer at the output ceiling (corpus.zig) before the
        // next file — the JSON stream, like the serial line path, accumulates
        // before a single flush, so this is the OOM guard for `--json`.
        if (!o.quiet and corpus_mod.outputFull(out.items.len)) break;
        const body = f.body;
        if (body.len == 0) continue;
        if (!o.text and corpus_mod.isBinary(body)) continue;
        st.searches += 1;
        st.bytes_searched += body.len;
        emitFile(a, out, re, &ss, caps, o, f, &st);
    }
    summary(a, out, st);
    return st.with_match > 0;
}

const Line = struct { off: usize, view: []const u8, text: []const u8, kind: u8 = 0 }; // kind: 0 none,1 ctx,2 match

fn emitFile(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, f: File, st: *Stats) void {
    if (re.multiline()) return emitFileMulti(a, out, re, caps, o, f, st);
    // Split into lines, keeping each line's file offset and its raw text (with the
    // trailing terminator, as ripgrep reports it in `lines.text`).
    var lines: std.ArrayList(Line) = .empty;
    var pos: usize = 0;
    while (pos < f.body.len) {
        const nl = std.mem.indexOfScalarPos(u8, f.body, pos, '\n');
        const content_end = nl orelse f.body.len;
        const text_end = if (nl) |n| n + 1 else f.body.len;
        const content = f.body[pos..content_end];
        lines.append(a, .{ .off = pos, .view = if (o.crlf) std.mem.trimEnd(u8, content, "\r") else content, .text = f.body[pos..text_end] }) catch oom();
        if (nl == null) break;
        pos = text_end;
    }

    // Classify: a match line (respecting -v), then paint -A/-B/-C context windows.
    var file_matches: usize = 0;
    for (lines.items, 0..) |*ln, i| {
        const has = firstSpan(re, ss, o, ln.view) != null;
        if (has == o.invert) continue;
        if (o.max_per_file != 0 and file_matches >= o.max_per_file) break;
        file_matches += 1;
        ln.kind = 2;
        var b: usize = 0;
        while (b < o.before and i >= b + 1) : (b += 1) if (lines.items[i - b - 1].kind == 0) {
            lines.items[i - b - 1].kind = 1;
        };
        var af: usize = 1;
        while (af <= o.after and i + af < lines.items.len) : (af += 1) if (lines.items[i + af].kind == 0) {
            lines.items[i + af].kind = 1;
        };
    }
    if (file_matches == 0) return;

    const fml = countMatched(re, ss, o, lines.items);
    const fm = countMatches(re, ss, o, lines.items);
    st.with_match += 1;
    st.matched_lines += fml;
    st.matches += fm;
    if (o.quiet) return; // --quiet: tally stats, suppress the record stream

    out.print(a, "{{\"type\":\"begin\",\"data\":{{\"path\":{{\"text\":", .{}) catch oom();
    jsonStr(a, out, f.path);
    add(a, out, "}}}\n");

    for (lines.items) |ln| {
        if (ln.kind == 0) continue;
        const is_match = ln.kind == 2;
        out.print(a, "{{\"type\":\"{s}\",\"data\":{{\"path\":{{\"text\":", .{if (is_match) "match" else "context"}) catch oom();
        jsonStr(a, out, f.path);
        add(a, out, "},\"lines\":{\"text\":");
        jsonStr(a, out, ln.text);
        out.print(a, "}},\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ lineNo(lines.items, ln), ln.off }) catch oom();
        if (is_match and !o.invert) _ = emitSubmatches(a, out, re, ss, caps, o, ln.view);
        add(a, out, "]}}\n");
    }

    out.print(a, "{{\"type\":\"end\",\"data\":{{\"path\":{{\"text\":", .{}) catch oom();
    jsonStr(a, out, f.path);
    out.print(a, "}},\"binary_offset\":null,\"stats\":{{\"elapsed\":{{\"secs\":0,\"nanos\":0,\"human\":\"0.000000s\"}},\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":{d},\"bytes_printed\":0,\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ f.body.len, fml, fm }) catch oom();
}

/// The `--json` record stream under `-U`/`--multiline`: one `match` record per
/// line-contiguous BLOCK of whole-buffer matches (its `lines.text` is the full
/// run of physical lines, `absolute_offset`/`line_number` the block's start, and
/// `submatches` carry block-relative offsets — rg's multiline shape), `context`
/// records for `-A/-B/-C` windows, and an `end` with the file's tallies. Empty
/// matches never form a submatch (rg's JSON only reports real spans). Mirrors
/// `output.Emitter.buffer`'s model via `multiline.zig`, so text and JSON agree.
fn emitFileMulti(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, f: File, st: *Stats) void {
    const body = f.body;
    const lines = ml.splitLines(a, body, o.term());
    // Non-empty spans only — a submatch is a real, painted span in rg's JSON.
    var spans: std.ArrayList(ml.Span) = .empty;
    for (ml.collect(a, re, o, body)) |sp| if (sp.end > sp.start) spans.append(a, sp) catch oom();

    if (o.invert) return emitFileMultiInvert(a, out, o, f, lines, spans.items, st);
    if (spans.items.len == 0) return;

    // Coalesce spans into line-contiguous blocks (rg's `--`-free grouping).
    const Block = struct { first: usize, last: usize, s0: usize, s1: usize };
    var blocks: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < spans.items.len) {
        const first = ml.lineIndexAt(lines, spans.items[i].start);
        var last = ml.lineIndexAt(lines, ml.spanLast(spans.items[i]));
        var j = i + 1;
        while (j < spans.items.len) : (j += 1) {
            const fl = ml.lineIndexAt(lines, spans.items[j].start);
            if (fl > last + 1) break;
            const ll = ml.lineIndexAt(lines, ml.spanLast(spans.items[j]));
            if (ll > last) last = ll;
        }
        blocks.append(a, .{ .first = first, .last = last, .s0 = i, .s1 = j }) catch oom();
        i = j;
    }

    const fml = ml.countMatchedLines(lines, spans.items);
    const fm = spans.items.len;
    st.with_match += 1;
    st.matched_lines += fml;
    st.matches += fm;
    if (o.quiet) return;

    // Per-line record plan: which block starts here, and which lines are `-A/-B/-C`
    // context (never a covered line).
    const starts = a.alloc(?usize, lines.len) catch oom();
    const covered = a.alloc(bool, lines.len) catch oom();
    const ctx = a.alloc(bool, lines.len) catch oom();
    @memset(starts, null);
    @memset(covered, false);
    @memset(ctx, false);
    for (blocks.items, 0..) |b, bi| {
        starts[b.first] = bi;
        for (b.first..b.last + 1) |k| covered[k] = true;
    }
    for (blocks.items) |b| {
        var d: usize = 1;
        while (d <= o.before and b.first >= d) : (d += 1) if (!covered[b.first - d]) {
            ctx[b.first - d] = true;
        };
        d = 1;
        while (d <= o.after and b.last + d < lines.len) : (d += 1) if (!covered[b.last + d]) {
            ctx[b.last + d] = true;
        };
    }

    begin(a, out, f.path);
    var k: usize = 0;
    while (k < lines.len) {
        if (starts[k]) |bi| {
            const b = blocks.items[bi];
            matchRecord(a, out, caps, o, f, lines, body, b.first, b.last, spans.items[b.s0..b.s1]);
            k = b.last + 1;
            continue;
        }
        if (ctx[k]) contextRecord(a, out, f.path, lines, body, k);
        k += 1;
    }
    endRecord(a, out, f.path, body.len, fml, fm);
}

/// `-v` under `-U --json`: a `match` record (empty submatches) for each physical
/// line NOT covered by any match's line span.
fn emitFileMultiInvert(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, f: File, lines: []const ml.Line, spans: []const ml.Span, st: *Stats) void {
    const covered = a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    for (spans) |sp| {
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        for (ml.lineIndexAt(lines, sp.start)..l1 + 1) |c| covered[c] = true;
    }
    var printed: usize = 0;
    for (covered) |c| {
        if (!c) printed += 1;
    }
    if (printed == 0) return;
    st.with_match += 1;
    st.matched_lines += printed;
    if (o.quiet) return;
    begin(a, out, f.path);
    for (lines, 0..) |ln, k| {
        if (covered[k]) continue;
        emitLineRecord(a, out, "match", f.path, k + 1, ln.start, f.body[ln.start..ln.term_end]);
    }
    endRecord(a, out, f.path, f.body.len, printed, 0);
}

fn begin(a: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) void {
    add(a, out, "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":");
    jsonStr(a, out, path);
    add(a, out, "}}}\n");
}

/// A whole-BLOCK `match` record: `lines.text` spans every physical line of the
/// block, submatches carry offsets relative to the block's first-line offset.
fn matchRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, f: File, lines: []const ml.Line, body: []const u8, first: usize, last: usize, spans: []const ml.Span) void {
    const base = lines[first].start;
    add(a, out, "{\"type\":\"match\",\"data\":{\"path\":{\"text\":");
    jsonStr(a, out, f.path);
    add(a, out, "},\"lines\":{\"text\":");
    jsonStr(a, out, body[base..lines[last].term_end]);
    out.print(a, "}},\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ first + 1, base }) catch oom();
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    for (spans, 0..) |sp, n| {
        if (n != 0) out.append(a, ',') catch oom();
        add(a, out, "{\"match\":{\"text\":");
        jsonStr(a, out, body[sp.start..sp.end]);
        add(a, out, "}");
        if (o.replace) |tmpl| if (caps) |c| {
            _ = c.find(body, sp.start, slots);
            var rep: std.ArrayList(u8) = .empty;
            output.expandInto(a, c, &rep, tmpl, body, slots);
            add(a, out, ",\"replacement\":{\"text\":");
            jsonStr(a, out, rep.items);
            add(a, out, "}");
        };
        out.print(a, ",\"start\":{d},\"end\":{d}}}", .{ sp.start - base, sp.end - base }) catch oom();
    }
    add(a, out, "]}}\n");
}

fn contextRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, lines: []const ml.Line, body: []const u8, k: usize) void {
    emitLineRecord(a, out, "context", path, k + 1, lines[k].start, body[lines[k].start..lines[k].term_end]);
}

/// A single-line record (`match` with empty submatches for invert, or `context`).
fn emitLineRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path: []const u8, lineno: usize, off: usize, text: []const u8) void {
    out.print(a, "{{\"type\":\"{s}\",\"data\":{{\"path\":{{\"text\":", .{kind}) catch oom();
    jsonStr(a, out, path);
    add(a, out, "},\"lines\":{\"text\":");
    jsonStr(a, out, text);
    out.print(a, "}},\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[]}}}}\n", .{ lineno, off }) catch oom();
}

fn endRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, bytes: usize, matched_lines: usize, matches: usize) void {
    add(a, out, "{\"type\":\"end\",\"data\":{\"path\":{\"text\":");
    jsonStr(a, out, path);
    out.print(a, "}},\"binary_offset\":null,\"stats\":{{\"elapsed\":{{\"secs\":0,\"nanos\":0,\"human\":\"0.000000s\"}},\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":{d},\"bytes_printed\":0,\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ bytes, matched_lines, matches }) catch oom();
}

fn lineNo(all: []const Line, ln: Line) usize {
    var n: usize = 1;
    for (all) |x| {
        if (x.off == ln.off) return n;
        n += 1;
    }
    return n;
}

/// Emit each non-empty (word-valid) match span on `view` as a submatch object;
/// under `-r` include the expanded `replacement`. Returns the count emitted.
fn emitSubmatches(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, view: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    while (from <= view.len) {
        const sp = re.matchSpan(ss, view, from) orelse break;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (o.word and !output.wordOk(view, sp.start, sp.end)) {
            from = sp.end;
            continue;
        }
        if (n != 0) out.append(a, ',') catch oom();
        add(a, out, "{\"match\":{\"text\":");
        jsonStr(a, out, view[sp.start..sp.end]);
        add(a, out, "}");
        if (o.replace) |tmpl| if (caps) |c| {
            _ = c.find(view, sp.start, slots);
            var rep: std.ArrayList(u8) = .empty;
            output.expandInto(a, c, &rep, tmpl, view, slots);
            add(a, out, ",\"replacement\":{\"text\":");
            jsonStr(a, out, rep.items);
            add(a, out, "}");
        };
        out.print(a, ",\"start\":{d},\"end\":{d}}}", .{ sp.start, sp.end }) catch oom();
        n += 1;
        from = sp.end;
    }
    return n;
}

fn summary(a: std.mem.Allocator, out: *std.ArrayList(u8), st: Stats) void {
    out.print(a, "{{\"data\":{{\"elapsed_total\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"stats\":{{\"bytes_printed\":0,\"bytes_searched\":{d},\"elapsed\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ st.bytes_searched, st.matched_lines, st.matches, st.searches, st.with_match }) catch oom();
}

// ─────────────────────────── helpers ───────────────────────────

fn firstSpan(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, view: []const u8) ?Matcher.Span {
    var from: usize = 0;
    while (from <= view.len) {
        const sp = re.matchSpan(ss, view, from) orelse return null;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (o.word and !output.wordOk(view, sp.start, sp.end)) {
            from = sp.end;
            continue;
        }
        return sp;
    }
    return null;
}

fn countMatched(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| if (ln.kind == 2 and !o.invert and firstSpan(re, ss, o, ln.view) != null) {
        n += 1;
    };
    return n;
}

fn countMatches(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| {
        if (ln.kind != 2 or o.invert) continue;
        var from: usize = 0;
        while (from <= ln.view.len) {
            const sp = re.matchSpan(ss, ln.view, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (o.word and !output.wordOk(ln.view, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            n += 1;
            from = sp.end;
        }
    }
    return n;
}

// ─────────────── whole-buffer (-U) JSON — byte-identical vs ripgrep ───────────────
//
// Expected record lines captured from `upstream/ripgrep` (`rg -U --json …`); the
// end/summary timing fields are zeroed on both sides by the differential harness.

const MlJson = struct {
    arena: std.heap.ArenaAllocator,
    m: Matcher,
    caps: ?Caps = null,

    fn init(pat: []const u8, replace: bool) !MlJson {
        const ta = std.testing.allocator;
        var h = MlJson{
            .arena = std.heap.ArenaAllocator.init(ta),
            .m = .{ .linear = try Regex.compileOpts(ta, pat, .{ .multiline = true }) },
        };
        if (replace) h.caps = .{ .linear = try Captures.compile(ta, pat, false, false) };
        return h;
    }
    fn deinit(self: *MlJson) void {
        self.arena.deinit();
        self.m.deinit();
        if (self.caps) |*c| c.deinit();
    }
    fn run(self: *MlJson, o: Opts, body: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const out = try a.create(std.ArrayList(u8));
        out.* = .empty;
        var opts = o;
        opts.multiline = true;
        opts.json = true;
        _ = @import("json.zig").run(a, out, &self.m, if (self.caps) |*c| c else null, opts, &.{.{ .path = "f.txt", .body = body }});
        return out.items;
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "-U --json emits one block match record with block-relative submatches" {
    var h = try MlJson.init("a\\nb", false);
    defer h.deinit();
    const s = try h.run(.{}, "a\nb\nc\n");
    try std.testing.expect(contains(s, "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"f.txt\"}}}\n"));
    try std.testing.expect(contains(s, "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"a\\nb\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]}}\n"));
    try std.testing.expect(contains(s, "\"matched_lines\":2,\"matches\":1"));
}

test "-U --json coalesces contiguous matches into one record with two submatches" {
    var h = try MlJson.init("x\\ny", false);
    defer h.deinit();
    const s = try h.run(.{}, "x\ny\nx\ny\n");
    try std.testing.expect(contains(s, "\"lines\":{\"text\":\"x\\ny\\nx\\ny\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"x\\ny\"},\"start\":0,\"end\":3},{\"match\":{\"text\":\"x\\ny\"},\"start\":4,\"end\":7}]"));
}

test "-U --json separates blocks with a gap into distinct records" {
    var h = try MlJson.init("a\\nb", false);
    defer h.deinit();
    const s = try h.run(.{}, "a\nb\n\na\nb\n");
    try std.testing.expect(contains(s, "\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]"));
    try std.testing.expect(contains(s, "\"line_number\":4,\"absolute_offset\":5,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]"));
}

test "-U --json context records carry original line numbers and empty submatches" {
    var h = try MlJson.init("a\\nb", false);
    defer h.deinit();
    const s = try h.run(.{ .after = 1 }, "a\nb\nc\n");
    try std.testing.expect(contains(s, "{\"type\":\"context\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"c\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n"));
}

test "-U --json invert emits match records for uncovered lines" {
    var h = try MlJson.init("a\\nb", false);
    defer h.deinit();
    const s = try h.run(.{ .invert = true }, "a\nb\nx\n");
    try std.testing.expect(contains(s, "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"x\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n"));
}

test "-U --json -r attaches replacement to each submatch" {
    var h = try MlJson.init("a\\nb", true);
    defer h.deinit();
    const s = try h.run(.{ .replace = "Z" }, "a\nb\nc\n");
    try std.testing.expect(contains(s, "\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"replacement\":{\"text\":\"Z\"},\"start\":0,\"end\":3}]"));
}

/// Append a raw record fragment (OOM is fatal — the CLI contract).
fn add(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(a, s) catch oom();
}

/// Write a JSON string literal (including the surrounding quotes) with ripgrep's
/// escaping: `"` `\` and C0 controls escaped, `\n`/`\r`/`\t` short forms, the rest
/// as `\u00XX`. (All harness fixtures are UTF-8; the bytes/base64 form rg uses for
/// invalid UTF-8 is out of scope for this text-oriented locator.)
fn jsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(a, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => add(a, out, "\\\""),
        '\\' => add(a, out, "\\\\"),
        '\n' => add(a, out, "\\n"),
        '\r' => add(a, out, "\\r"),
        '\t' => add(a, out, "\\t"),
        else => if (c < 0x20) {
            out.print(a, "\\u{x:0>4}", .{c}) catch oom();
        } else out.append(a, c) catch oom(),
    };
    out.append(a, '"') catch oom();
}
