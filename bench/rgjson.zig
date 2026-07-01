//! gist `rg --json` — ripgrep's JSON Lines record stream (ADR-parity output).
//!
//! Split from `rgcompat.zig`/`rgemit.zig`: given each file's already-read bytes,
//! this module emits ripgrep's exact `--json` message sequence — one JSON object
//! per line: a `begin` per matched file, a `match`/`context` per emitted line
//! (with byte-accurate `submatches` and, under `-r`, per-match `replacement`),
//! an `end` with that file's stats, and a trailing `summary`. It reuses the one
//! regex engine (`matchSpan` for spans, capture VM for `-r`) and `rgemit`'s
//! shared template expander, so there is no second matcher or replacer.
//!
//! The `stats` timing fields (`elapsed`, `elapsed_total`) and `bytes_printed` are
//! ripgrep-printer-internal / wall-clock and inherently non-reproducible, so we
//! emit fixed placeholders; the differential harness normalizes them on both
//! sides exactly as it already does for `--stats` seconds. Every correctness
//! field (`matches`, `matched_lines`, `searches`, `bytes_searched`, and the whole
//! match/submatch structure) is emitted for real.

const std = @import("std");
const gist = @import("gist");
const corpus_mod = @import("corpus.zig");
const rgargs = @import("rgargs.zig");
const rgemit = @import("rgemit.zig");
const Opts = rgargs.Opts;
const die = rgargs.die;
const Regex = gist.regex.Regex;
const Captures = gist.regex_captures.Captures;

pub const File = struct { path: []const u8, body: []const u8 };

const Stats = struct { searches: usize = 0, with_match: usize = 0, matched_lines: usize = 0, matches: usize = 0, bytes_searched: usize = 0 };

/// Emit the full `--json` stream for `files` into `out`. Returns true if any file
/// matched (drives the process exit code).
pub fn run(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Regex, caps: ?*Captures, o: Opts, files: []const File) bool {
    var ss = Regex.SpanSim.init(a, re) catch die("engine init failed\n", .{});
    defer ss.deinit();
    var st = Stats{};
    for (files) |f| {
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

fn emitFile(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Regex, ss: *Regex.SpanSim, caps: ?*Captures, o: Opts, f: File, st: *Stats) void {
    // Split into lines, keeping each line's file offset and its raw text (with the
    // trailing terminator, as ripgrep reports it in `lines.text`).
    var lines: std.ArrayList(Line) = .empty;
    var pos: usize = 0;
    while (pos < f.body.len) {
        const nl = std.mem.indexOfScalarPos(u8, f.body, pos, '\n');
        const content_end = nl orelse f.body.len;
        const text_end = if (nl) |n| n + 1 else f.body.len;
        const content = f.body[pos..content_end];
        lines.append(a, .{ .off = pos, .view = if (o.crlf) std.mem.trimEnd(u8, content, "\r") else content, .text = f.body[pos..text_end] }) catch die("oom\n", .{});
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

    out.print(a, "{{\"type\":\"begin\",\"data\":{{\"path\":{{\"text\":", .{}) catch die("oom\n", .{});
    jsonStr(a, out, f.path);
    out.appendSlice(a, "}}}\n") catch die("oom\n", .{});

    for (lines.items) |ln| {
        if (ln.kind == 0) continue;
        const is_match = ln.kind == 2;
        out.print(a, "{{\"type\":\"{s}\",\"data\":{{\"path\":{{\"text\":", .{if (is_match) "match" else "context"}) catch die("oom\n", .{});
        jsonStr(a, out, f.path);
        out.appendSlice(a, "},\"lines\":{\"text\":") catch die("oom\n", .{});
        jsonStr(a, out, ln.text);
        out.print(a, "}},\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ lineNo(lines.items, ln), ln.off }) catch die("oom\n", .{});
        if (is_match and !o.invert) _ = emitSubmatches(a, out, re, ss, caps, o, ln.view);
        out.appendSlice(a, "]}}\n") catch die("oom\n", .{});
    }

    out.print(a, "{{\"type\":\"end\",\"data\":{{\"path\":{{\"text\":", .{}) catch die("oom\n", .{});
    jsonStr(a, out, f.path);
    out.print(a, "}},\"binary_offset\":null,\"stats\":{{\"elapsed\":{{\"secs\":0,\"nanos\":0,\"human\":\"0.000000s\"}},\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":{d},\"bytes_printed\":0,\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ f.body.len, fml, fm }) catch die("oom\n", .{});
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
fn emitSubmatches(a: std.mem.Allocator, out: *std.ArrayList(u8), re: *const Regex, ss: *Regex.SpanSim, caps: ?*Captures, o: Opts, view: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    const slots: []isize = if (caps) |c| a.alloc(isize, c.nslots) catch die("oom\n", .{}) else &.{};
    while (from <= view.len) {
        const sp = re.matchSpan(ss, view, from) orelse break;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (o.word and !rgemit.wordOk(view, sp.start, sp.end)) {
            from = sp.end;
            continue;
        }
        if (n != 0) out.append(a, ',') catch die("oom\n", .{});
        out.appendSlice(a, "{\"match\":{\"text\":") catch die("oom\n", .{});
        jsonStr(a, out, view[sp.start..sp.end]);
        out.appendSlice(a, "}") catch die("oom\n", .{});
        if (o.replace) |tmpl| if (caps) |c| {
            _ = c.find(view, sp.start, slots);
            var rep: std.ArrayList(u8) = .empty;
            rgemit.expandInto(a, c, &rep, tmpl, view, slots);
            out.appendSlice(a, ",\"replacement\":{\"text\":") catch die("oom\n", .{});
            jsonStr(a, out, rep.items);
            out.appendSlice(a, "}") catch die("oom\n", .{});
        };
        out.print(a, ",\"start\":{d},\"end\":{d}}}", .{ sp.start, sp.end }) catch die("oom\n", .{});
        n += 1;
        from = sp.end;
    }
    return n;
}

fn summary(a: std.mem.Allocator, out: *std.ArrayList(u8), st: Stats) void {
    out.print(a, "{{\"data\":{{\"elapsed_total\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"stats\":{{\"bytes_printed\":0,\"bytes_searched\":{d},\"elapsed\":{{\"human\":\"0.000000s\",\"nanos\":0,\"secs\":0}},\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ st.bytes_searched, st.matched_lines, st.matches, st.searches, st.with_match }) catch die("oom\n", .{});
}

// ─────────────────────────── helpers ───────────────────────────

fn firstSpan(re: *const Regex, ss: *Regex.SpanSim, o: Opts, view: []const u8) ?Regex.Span {
    var from: usize = 0;
    while (from <= view.len) {
        const sp = re.matchSpan(ss, view, from) orelse return null;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (o.word and !rgemit.wordOk(view, sp.start, sp.end)) {
            from = sp.end;
            continue;
        }
        return sp;
    }
    return null;
}

fn countMatched(re: *const Regex, ss: *Regex.SpanSim, o: Opts, lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |ln| if (ln.kind == 2 and !o.invert and firstSpan(re, ss, o, ln.view) != null) {
        n += 1;
    };
    return n;
}

fn countMatches(re: *const Regex, ss: *Regex.SpanSim, o: Opts, lines: []const Line) usize {
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
            if (o.word and !rgemit.wordOk(ln.view, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            n += 1;
            from = sp.end;
        }
    }
    return n;
}

/// Write a JSON string literal (including the surrounding quotes) with ripgrep's
/// escaping: `"` `\` and C0 controls escaped, `\n`/`\r`/`\t` short forms, the rest
/// as `\u00XX`. (All harness fixtures are UTF-8; the bytes/base64 form rg uses for
/// invalid UTF-8 is out of scope for this text-oriented locator.)
fn jsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.append(a, '"') catch die("oom\n", .{});
    for (s) |c| switch (c) {
        '"' => out.appendSlice(a, "\\\"") catch die("oom\n", .{}),
        '\\' => out.appendSlice(a, "\\\\") catch die("oom\n", .{}),
        '\n' => out.appendSlice(a, "\\n") catch die("oom\n", .{}),
        '\r' => out.appendSlice(a, "\\r") catch die("oom\n", .{}),
        '\t' => out.appendSlice(a, "\\t") catch die("oom\n", .{}),
        else => if (c < 0x20) {
            out.print(a, "\\u{x:0>4}", .{c}) catch die("oom\n", .{});
        } else out.append(a, c) catch die("oom\n", .{}),
    };
    out.append(a, '"') catch die("oom\n", .{});
}
