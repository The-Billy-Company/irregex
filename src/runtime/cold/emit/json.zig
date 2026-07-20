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
const grepfile = @import("../read/grepfile.zig");
const args = @import("../argv/args.zig");
const output = @import("output.zig");
const jsonstr = @import("jsonstr.zig");
const ml = @import("multiline.zig");
const Opts = args.Opts;
const die = args.die;
const oom = args.oom;
const Matcher = @import("../../../search/match/regex/linear/matcher.zig").Matcher;
const Caps = @import("../../../search/match/regex/compile/captures.zig").Caps;

pub const File = struct { path: []const u8, body: []const u8, explicit: bool = false };

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
        // An empty file is still a search in rg's tally (0 bytes, no records).
        if (f.body.len == 0) {
            st.searches += 1;
            continue;
        }
        // Binary model (rg parity, mirrors `grepfile.handleBinary`):
        //   • implicit (walked) line-mode file — rg's "quit" strategy searches
        //     only the committed prefix (`grepfile.committedPrefix`): the lines
        //     its buffer had consumed before the fill that read the first NUL.
        //     An empty prefix ⇒ one search, zero bytes, zero records.
        //   • implicit slice-model file (`-U` whose pattern can match `\n`) —
        //     the slice searcher sniffs min(len, 64K): a NUL inside quits
        //     before searching anything; beyond it the file is ordinary text
        //     (binary_offset null).
        //   • explicit path arg — searched in full (line model: NUL doubles as
        //     a line terminator below; slice model: byte_count clamps at the
        //     offset), records emitted, `binary_offset` reported.
        //   • `-a/--text` disables detection entirely.
        var eff = f;
        var bin: ?usize = if (o.text) null else std.mem.indexOfScalar(u8, f.body, 0);
        var searched = f.body.len;
        if (bin) |q| {
            if (re.multiline() and re.canMatchNewline()) {
                if (!f.explicit and grepfile.multilineBinary(f.body.len, q)) {
                    st.searches += 1;
                    continue; // sniff quit: nothing searched, no records
                }
                if (!f.explicit) bin = null else searched = q;
            } else if (!f.explicit) {
                const cut = grepfile.committedPrefix(f.body, q);
                if (cut == 0) {
                    st.searches += 1;
                    continue;
                }
                eff.body = f.body[0..cut];
                searched = cut;
            }
        }
        st.searches += 1;
        st.bytes_searched += searched;
        emitFile(a, out, re, &ss, caps, o, eff, &st, bin, searched);
    }
    summary(a, out, st);
    return st.with_match > 0;
}

const Line = struct { off: usize, view: []const u8, text: []const u8, kind: u8 = 0 }; // kind: 0 none,1 ctx,2 match

fn emitFile(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, f: File, st: *Stats, bin: ?usize, searched: usize) void {
    if (re.multiline()) return emitFileMulti(a, out, re, caps, o, f, st, bin, searched);
    // Split into lines, keeping each line's file offset and its raw text (with the
    // trailing terminator, as ripgrep reports it in `lines.text`). In a binary
    // EXPLICIT file rg's converter treats each NUL as a line terminator too —
    // an implicit body was already cut before its first NUL, so "\n\x00" is
    // safe for every `bin != null` path.
    var lines: std.ArrayList(Line) = .empty;
    var pos: usize = 0;
    while (pos < f.body.len) {
        const nl = if (bin == null) std.mem.indexOfScalarPos(u8, f.body, pos, '\n') else std.mem.indexOfAnyPos(u8, f.body, pos, "\n\x00");
        const content_end = nl orelse f.body.len;
        const text_end = if (nl) |n| n + 1 else f.body.len;
        const content = f.body[pos..content_end];
        // rg's converter REPLACES a terminating NUL with the line terminator in
        // `lines.text` (the match text itself is untouched) — mirror that.
        const text = if (nl != null and f.body[nl.?] == 0) blk: {
            const t = a.alloc(u8, content.len + 1) catch oom();
            @memcpy(t[0..content.len], content);
            t[content.len] = '\n';
            break :blk t;
        } else f.body[pos..text_end];
        lines.append(a, .{ .off = pos, .view = if (o.crlf) std.mem.trimEnd(u8, content, "\r") else content, .text = text }) catch oom();
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

    const fml = countMatched(o, lines.items);
    const fm = countMatches(re, ss, o, lines.items);
    st.with_match += 1;
    st.matched_lines += fml;
    st.matches += fm;
    if (o.quiet) return; // --quiet: tally stats, suppress the record stream

    begin(a, out, f.path);

    for (lines.items, 1..) |ln, lineno| {
        if (ln.kind == 0) continue;
        const is_match = ln.kind == 2;
        recordOpen(a, out, if (is_match) "match" else "context", f.path, ln.text, lineno, ln.off);
        if (is_match and !o.invert) _ = emitSubmatches(a, out, re, ss, caps, o, ln.view);
        add(a, out, "]}}\n");
    }

    endRecord(a, out, f.path, searched, fml, fm, bin);
}

/// The `--json` record stream under `-U`/`--multiline`: one `match` record per
/// line-contiguous BLOCK of whole-buffer matches (its `lines.text` is the full
/// run of physical lines, `absolute_offset`/`line_number` the block's start, and
/// `submatches` carry block-relative offsets — rg's multiline shape), `context`
/// records for `-A/-B/-C` windows, and an `end` with the file's tallies. Empty
/// matches never form a submatch (rg's JSON only reports real spans). Mirrors
/// `output.Emitter.buffer`'s model via `multiline.zig`, so text and JSON agree.
fn emitFileMulti(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, caps: ?*Caps, o: Opts, f: File, st: *Stats, bin: ?usize, searched: usize) void {
    const body = f.body;
    const lines = ml.splitLines(a, body, o.term());
    // Non-empty spans only — a submatch is a real, painted span in rg's JSON.
    var spans: std.ArrayList(ml.Span) = .empty;
    for (ml.collect(a, re, o, body)) |sp| if (sp.end > sp.start) spans.append(a, sp) catch oom();

    if (o.invert) return emitFileMultiInvert(a, out, o, f, lines, spans.items, st, bin, searched);
    if (spans.items.len == 0) return;

    // Coalesce spans into line-contiguous blocks (rg's `--`-free grouping) —
    // the shared `ml.blocks` sink-block model.
    const blocks = ml.blocks(a, lines, spans.items);

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
    for (blocks, 0..) |b, bi| {
        starts[b.first] = bi;
        for (b.first..b.last + 1) |k| covered[k] = true;
    }
    for (blocks) |b| {
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
            const b = blocks[bi];
            matchRecord(a, out, caps, o, f, lines, body, b.first, b.last, spans.items[b.s0..b.s1]);
            k = b.last + 1;
            continue;
        }
        if (ctx[k]) emitLineRecord(a, out, "context", f.path, k + 1, lines[k].start, body[lines[k].start..lines[k].term_end]);
        k += 1;
    }
    endRecord(a, out, f.path, searched, fml, fm, bin);
}

/// `-v` under `-U --json`: a `match` record (empty submatches) for each physical
/// line NOT covered by any match's line span.
fn emitFileMultiInvert(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, f: File, lines: []const ml.Line, spans: []const ml.Span, st: *Stats, bin: ?usize, searched: usize) void {
    const covered = a.alloc(bool, lines.len) catch oom();
    @memset(covered, false);
    for (spans) |sp| {
        const l1 = ml.lineIndexAt(lines, ml.spanLast(sp));
        for (ml.lineIndexAt(lines, sp.start)..l1 + 1) |c| covered[c] = true;
    }
    var printed: usize = 0;
    for (covered) |c| printed += @intFromBool(!c);
    if (printed == 0) return;
    st.with_match += 1;
    st.matched_lines += printed;
    if (o.quiet) return;
    begin(a, out, f.path);
    for (lines, 0..) |ln, k| {
        if (covered[k]) continue;
        emitLineRecord(a, out, "match", f.path, k + 1, ln.start, f.body[ln.start..ln.term_end]);
    }
    endRecord(a, out, f.path, searched, printed, 0, bin);
}

/// The `{"type":"<kind>","data":{"path":<path>` opener every record shares.
fn openData(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path: []const u8) void {
    out.print(a, "{{\"type\":\"{s}\",\"data\":{{\"path\":", .{kind}) catch oom();
    jsonData(a, out, path);
}

/// A line-record head through `"submatches":[` — the caller appends the
/// submatch objects (possibly none) and the `]}}\n` close.
fn recordOpen(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path: []const u8, text: []const u8, lineno: usize, off: usize) void {
    openData(a, out, kind, path);
    add(a, out, ",\"lines\":");
    jsonData(a, out, text);
    out.print(a, ",\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ lineno, off }) catch oom();
}

fn begin(a: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) void {
    openData(a, out, "begin", path);
    add(a, out, "}}\n");
}

/// A whole-BLOCK `match` record: `lines.text` spans every physical line of the
/// block, submatches carry offsets relative to the block's first-line offset.
fn matchRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, f: File, lines: []const ml.Line, body: []const u8, first: usize, last: usize, spans: []const ml.Span) void {
    const base = lines[first].start;
    recordOpen(a, out, "match", f.path, body[base..lines[last].term_end], first + 1, base);
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    for (spans, 0..) |sp, n| submatch(a, out, caps, o, body, sp, base, n, slots);
    add(a, out, "]}}\n");
}

/// A single-line record (`match` with empty submatches for invert, or `context`).
fn emitLineRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, path: []const u8, lineno: usize, off: usize, text: []const u8) void {
    recordOpen(a, out, kind, path, text, lineno, off);
    add(a, out, "]}}\n");
}

fn endRecord(a: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, bytes: usize, matched_lines: usize, matches: usize, bin: ?usize) void {
    openData(a, out, "end", path);
    add(a, out, ",\"binary_offset\":");
    if (bin) |q| out.print(a, "{d}", .{q}) catch oom() else add(a, out, "null");
    out.print(a, ",\"stats\":{{\"elapsed\":{{\"secs\":0,\"nanos\":0,\"human\":\"0.000000s\"}},\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":{d},\"bytes_printed\":0,\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ bytes, matched_lines, matches }) catch oom();
}

/// Emit each non-empty (word-valid) match span on `view` as a submatch object;
/// under `-r` include the expanded `replacement`. Returns the count emitted.
fn emitSubmatches(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Matcher, ss: *Matcher.SpanSim, caps: ?*Caps, o: Opts, view: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots()) catch oom() else &.{};
    while (output.nextSpan(re, ss, o, view, &from)) |sp| {
        submatch(a, out, caps, o, view, sp, 0, n, slots);
        n += 1;
    }
    return n;
}

/// One submatch object — `{"match":…[,"replacement":…],"start":…,"end":…}`,
/// comma-prefixed after the first (`n != 0`). Offsets rebase against `base`:
/// 0 for the single-line stream, the block's first-line offset under `-U`.
fn submatch(a: std.mem.Allocator, out: *std.ArrayList(u8), caps: ?*Caps, o: Opts, src: []const u8, sp: Matcher.Span, base: usize, n: usize, slots: []isize) void {
    if (n != 0) out.append(a, ',') catch oom();
    add(a, out, "{\"match\":");
    jsonData(a, out, src[sp.start..sp.end]);
    if (o.replace) |tmpl| if (caps) |c| {
        _ = c.find(src, sp.start, slots);
        var rep: std.ArrayList(u8) = .empty;
        output.expandInto(a, c, &rep, tmpl, src, slots);
        add(a, out, ",\"replacement\":");
        jsonData(a, out, rep.items);
    };
    out.print(a, ",\"start\":{d},\"end\":{d}}}", .{ sp.start - base, sp.end - base }) catch oom();
}

fn summary(a: std.mem.Allocator, out: *std.ArrayList(u8), st: Stats) void {
    out.print(a, "{{\"data\":{{\"elapsed_total\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"stats\":{{\"bytes_printed\":0,\"bytes_searched\":{d},\"elapsed\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ st.bytes_searched, st.matched_lines, st.matches, st.searches, st.with_match }) catch oom();
}

// ─────────────────────────── helpers ───────────────────────────

fn firstSpan(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, view: []const u8) ?Matcher.Span {
    var from: usize = 0;
    return output.nextSpan(re, ss, o, view, &from);
}

/// A `kind == 2` line is exactly a `firstSpan` hit (classification already ran
/// under the same options), so the matched-lines stat is a plain tally — and 0
/// under `-v`, rg's stat shape for the inverted single-line stream.
fn countMatched(o: Opts, lines: []const Line) usize {
    if (o.invert) return 0;
    var n: usize = 0;
    for (lines) |ln| n += @intFromBool(ln.kind == 2);
    return n;
}

fn countMatches(re: *const Matcher, ss: *Matcher.SpanSim, o: Opts, lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| {
        if (ln.kind != 2 or o.invert) continue;
        var from: usize = 0;
        while (output.nextSpan(re, ss, o, ln.view, &from)) |_| n += 1;
    }
    return n;
}

// ─────────────── whole-buffer (-U) JSON — byte-identical vs ripgrep ───────────────
//
// Expected record lines captured from `upstream/ripgrep` (`rg -U --json …`); the
// end/summary timing fields are zeroed on both sides by the differential harness.

/// Reuses `output.zig`'s MlHarness (same compile + caps shape); only the
/// runner differs — route through the `--json` record stream, not the Emitter.
fn runJson(h: *output.MlHarness, o: Opts, body: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    const out = try a.create(std.ArrayList(u8));
    out.* = .empty;
    var opts = o;
    opts.multiline = true;
    opts.json = true;
    _ = run(a, out, &h.m, if (h.caps) |*c| c else null, opts, &.{.{ .path = "f.txt", .body = body }});
    return out.items;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "-U --json record-stream parity table (captured from ripgrep)" {
    const cases = [_]struct { pat: []const u8, o: Opts, body: []const u8, needles: []const []const u8 }{
        // -U --json emits one block match record with block-relative submatches
        .{ .pat = "a\\nb", .o = .{}, .body = "a\nb\nc\n", .needles = &.{
            "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"f.txt\"}}}\n",
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"a\\nb\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]}}\n",
            "\"matched_lines\":2,\"matches\":1",
        } },
        // -U --json coalesces contiguous matches into one record with two submatches
        .{ .pat = "x\\ny", .o = .{}, .body = "x\ny\nx\ny\n", .needles = &.{
            "\"lines\":{\"text\":\"x\\ny\\nx\\ny\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"x\\ny\"},\"start\":0,\"end\":3},{\"match\":{\"text\":\"x\\ny\"},\"start\":4,\"end\":7}]",
        } },
        // -U --json separates blocks with a gap into distinct records
        .{ .pat = "a\\nb", .o = .{}, .body = "a\nb\n\na\nb\n", .needles = &.{
            "\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]",
            "\"line_number\":4,\"absolute_offset\":5,\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"start\":0,\"end\":3}]",
        } },
        // -U --json context records carry original line numbers and empty submatches
        .{ .pat = "a\\nb", .o = .{ .after = 1 }, .body = "a\nb\nc\n", .needles = &.{
            "{\"type\":\"context\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"c\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n",
        } },
        // -U --json invert emits match records for uncovered lines
        .{ .pat = "a\\nb", .o = .{ .invert = true }, .body = "a\nb\nx\n", .needles = &.{
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"f.txt\"},\"lines\":{\"text\":\"x\\n\"},\"line_number\":3,\"absolute_offset\":4,\"submatches\":[]}}\n",
        } },
        // -U --json -r attaches replacement to each submatch
        .{ .pat = "a\\nb", .o = .{ .replace = "Z" }, .body = "a\nb\nc\n", .needles = &.{
            "\"submatches\":[{\"match\":{\"text\":\"a\\nb\"},\"replacement\":{\"text\":\"Z\"},\"start\":0,\"end\":3}]",
        } },
    };
    for (&cases) |c| {
        var h = try output.MlHarness.init(c.pat, .{ .replace = c.o.replace != null });
        defer h.deinit();
        const s = try runJson(&h, c.o, c.body);
        for (c.needles) |needle| try std.testing.expect(contains(s, needle));
    }
}

/// Append a raw record fragment (OOM is fatal — the CLI contract).
fn add(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(a, s) catch oom();
}

/// Write one rg JSON data object: `{"text":<escaped>}` when the bytes are valid
/// UTF-8, else `{"bytes":"<base64>"}` — ripgrep's `Data::from_bytes` (jsont.rs).
/// Lines, submatch text, replacements, and paths all take this shape, so a
/// latin-1 or binary-adjacent line degrades to base64 instead of mojibake.
fn jsonData(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    if (std.unicode.utf8ValidateSlice(s)) {
        add(a, out, "{\"text\":");
        jsonstr.write(out, a, s);
        add(a, out, "}");
        return;
    }
    const enc = std.base64.standard.Encoder;
    const buf = a.alloc(u8, enc.calcSize(s.len)) catch oom();
    add(a, out, "{\"bytes\":\"");
    add(a, out, enc.encode(buf, s));
    add(a, out, "\"}");
}
