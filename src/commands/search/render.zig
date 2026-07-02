//! gist search — output rendering: how a matched span becomes output bytes.
//!
//! Split from the line engine (`emit.zig`) so that loop stays a lean
//! candidate-read + line-walk, while the two presentation concerns that bloat it
//! live here on their own:
//!   • the `-o`/--only-matching + `-r`/--replace SPAN rewrite (leftmost-first
//!     non-overlapping spans from the Pike VM, whole-match template expansion);
//!   • the `--json` record shape (one JSON object per row) — gist's structured
//!     output, the one format the fixed `path:line:text` model couldn't emit.
//!
//! Every function is Shard-free (takes `gpa`/`re`/`opts` explicitly) so it never
//! reaches back into the engine — the dependency points one way, emit → render.

const std = @import("std");
const args = @import("args.zig");
const Options = args.Options;
const Regex = @import("../../regex/core.zig").Regex;

// ─────────────────────────── JSON ───────────────────────────

/// Append `s` as a JSON string body (no surrounding quotes) into `body`,
/// escaping the characters JSON forbids raw: `"` `\` and the C0 controls. A
/// non-UTF-8 byte is passed through verbatim (gist is byte-oriented; the bytes
/// on disk are the truth), matching how the text emitter treats the line.
pub fn jsonStr(gpa: std.mem.Allocator, body: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try body.appendSlice(gpa, "\\\""),
        '\\' => try body.appendSlice(gpa, "\\\\"),
        '\n' => try body.appendSlice(gpa, "\\n"),
        '\r' => try body.appendSlice(gpa, "\\r"),
        '\t' => try body.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...31 => try body.print(gpa, "\\u{x:0>4}", .{c}),
        else => try body.append(gpa, c),
    };
}

/// A `{"path":…}` JSON line (files-with-matches under `--json`).
pub fn jsonFileRow(gpa: std.mem.Allocator, body: *std.ArrayList(u8), path: []const u8) !void {
    try body.appendSlice(gpa, "{\"path\":\"");
    try jsonStr(gpa, body, path);
    try body.appendSlice(gpa, "\"}\n");
}

/// A `{"path":…,"count":N}` JSON line (counts under `--json`).
pub fn jsonCountRow(gpa: std.mem.Allocator, body: *std.ArrayList(u8), path: []const u8, count: usize) !void {
    try body.appendSlice(gpa, "{\"path\":\"");
    try jsonStr(gpa, body, path);
    try body.print(gpa, "\",\"count\":{d}}}\n", .{count});
}

/// A `{"path":…,"line":N,"kind":"match|context","text":…}` JSON line.
pub fn jsonLineRow(gpa: std.mem.Allocator, body: *std.ArrayList(u8), path: []const u8, line: usize, is_match: bool, text: []const u8) !void {
    try body.appendSlice(gpa, "{\"path\":\"");
    try jsonStr(gpa, body, path);
    try body.print(gpa, "\",\"line\":{d},\"kind\":\"{s}\",\"text\":\"", .{ line, if (is_match) "match" else "context" });
    try jsonStr(gpa, body, text);
    try body.appendSlice(gpa, "\"}\n");
}

// ─────────────────────── -r / --replace expansion ───────────────────────

/// Expand a `-r` template's whole-match references into `body` against the
/// matched text `m`: `$0` / `${0}` / `$&` → `m`, `$$` → a literal `$`, everything
/// else verbatim. The parser (`args.validReplaceTemplate`) has already rejected
/// any capture-group ref gist's span engine can't honor, so only these forms
/// reach here — this stays a pure, allocation-free byte copy.
pub fn appendReplacement(gpa: std.mem.Allocator, body: *std.ArrayList(u8), tmpl: []const u8, m: []const u8) !void {
    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] != '$') {
            try body.append(gpa, tmpl[i]);
            continue;
        }
        if (i + 1 >= tmpl.len) {
            try body.append(gpa, '$');
            break;
        }
        switch (tmpl[i + 1]) {
            '$' => {
                try body.append(gpa, '$');
                i += 1;
            },
            '&', '0' => {
                try body.appendSlice(gpa, m);
                i += 1;
            },
            '{' => { // `${0}` — the only braced form the parser admits
                try body.appendSlice(gpa, m);
                i = std.mem.indexOfScalarPos(u8, tmpl, i + 2, '}').?;
            },
            else => try body.append(gpa, '$'), // unreachable given validation
        }
    }
}

/// Append `line`, with each non-overlapping match rewritten by the `-r` template
/// (`tmpl`). Mirrors rg's line-mode `--replace`: text between matches is copied
/// verbatim, a zero-width match is stepped over (never rewritten), and the tail
/// after the last match is copied. Used only when a replacement is set.
pub fn appendReplacedLine(gpa: std.mem.Allocator, re: *const Regex, ssim: *Regex.SpanSim, tmpl: []const u8, line: []const u8, body: *std.ArrayList(u8)) !void {
    var from: usize = 0;
    var cursor: usize = 0;
    while (from <= line.len) {
        const span = re.matchSpan(ssim, line, from) orelse break;
        if (span.end == span.start) {
            from = span.start + 1;
            continue;
        }
        try body.appendSlice(gpa, line[cursor..span.start]);
        try appendReplacement(gpa, body, tmpl, line[span.start..span.end]);
        cursor = span.end;
        from = span.end;
    }
    try body.appendSlice(gpa, line[cursor..]);
}

// ─────────────────────── -o / --only-matching ───────────────────────

/// `-o`/--only-matching: emit each non-overlapping match's TEXT alone (not the
/// whole line), one row per match `path:line:text` (or the JSON object under
/// `--json`), exactly as ripgrep does. Leftmost-first spans come from the Pike
/// VM (`matchSpan`); after a match at `[s,e)` the next search resumes at `e`
/// (non-overlapping), and a zero-width match advances one byte so a nullable
/// pattern can't loop. `-o -r <tmpl>` emits the rewritten match. Returns the row
/// count (0 ⇒ caller drops the file).
pub fn emitOnlyMatching(gpa: std.mem.Allocator, re: *const Regex, opts: Options, path: []const u8, lines: []const []const u8, body: *std.ArrayList(u8)) !usize {
    var ssim = Regex.SpanSim.init(gpa, re) catch return 0;
    defer ssim.deinit();
    var emitted: usize = 0;
    for (lines, 0..) |line, idx| {
        var from: usize = 0;
        while (from <= line.len) {
            const span = re.matchSpan(&ssim, line, from) orelse break;
            if (span.end == span.start) { // zero-width: don't emit, step past to avoid a loop
                from = span.start + 1;
                continue;
            }
            const raw = line[span.start..span.end];
            if (opts.json) {
                // `-o -r`: the JSON `text` carries the rewritten match too.
                if (opts.replace) |t| {
                    var tmp: std.ArrayList(u8) = .empty;
                    defer tmp.deinit(gpa);
                    try appendReplacement(gpa, &tmp, t, raw);
                    try jsonLineRow(gpa, body, path, idx + 1, true, tmp.items);
                } else try jsonLineRow(gpa, body, path, idx + 1, true, raw);
            } else {
                if (opts.no_line_num)
                    try body.print(gpa, "{s}:", .{path})
                else
                    try body.print(gpa, "{s}:{d}:", .{ path, idx + 1 });
                if (opts.replace) |t| try appendReplacement(gpa, body, t, raw) else try body.appendSlice(gpa, raw);
                try body.append(gpa, '\n');
            }
            emitted += 1;
            if (opts.max_per_file != 0 and emitted >= opts.max_per_file) return emitted;
            from = span.end;
        }
    }
    return emitted;
}
