//! gist `rg` — the specialized output modes (split from `output.zig`).
//!
//! The `Emitter` (`output.zig`) owns the default `path:line:text` framed engine
//! and the rendering primitives (`prefix`/`text`/`paint`/`offOf`/`mview`). This
//! module holds the distinct rg output SHAPES that ride those primitives:
//! `--passthru`, `--vimgrep`, `-o` only-matching (raw + `-r` replacement),
//! `--count-matches`, and the `--column` first-column locator. Each is a free
//! function over `*Emitter` so it reuses the same render primitives without
//! fragmenting the struct's state; `Emitter.file` dispatches into them.

const std = @import("std");
const Emitter = @import("output.zig").Emitter;
const substitute = @import("substitute.zig");
const wordOk = substitute.wordOk;
const palette = @import("color.zig");
const Regex = @import("../../regex/core.zig").Regex;
const die = @import("args.zig").die;

/// `--passthru`: emit EVERY line of the file (matching lines framed as matches,
/// the rest as context) — ripgrep's "context of infinity". Returns the count of
/// matching lines (for the exit code); output is written regardless of matches.
pub fn passthru(e: *Emitter, path: []const u8, lines: []const []const u8) usize {
    const o = e.o;
    var sim = Regex.Sim.init(e.a, e.re) catch return 0;
    defer sim.deinit();
    var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(e.a, e.re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var css: ?Regex.SpanSim = if (o.column) (Regex.SpanSim.init(e.a, e.re) catch null) else null;
    defer if (css) |*s| s.deinit();
    var mss: ?Regex.SpanSim = if (o.only_matching) (Regex.SpanSim.init(e.a, e.re) catch null) else null;
    defer if (mss) |*s| s.deinit();
    var matched: usize = 0;
    for (lines, 0..) |line, k| {
        const mv = e.mview(line);
        const is_m = if (wss) |*s| e.lineHitWord(s, mv) else e.re.lineMatch(&sim, mv);
        if (is_m) matched += 1;
        // --passthru -o: a matching line contributes each match span (only-
        // matching frame), a non-matching line still prints in full (context).
        if (is_m and mss != null) {
            if (o.replace != null) _ = emitLineRepl(e, path, k + 1, line, 0) else _ = emitMatches(e, &mss.?, path, k + 1, line, mv);
            continue;
        }
        const col: usize = if (is_m and css != null) firstCol(e, &css.?, mv) else 0;
        e.prefix(path, k + 1, col, e.offOf(line), is_m);
        e.text(line, is_m);
    }
    return matched;
}

/// Emit each match span on one line in the only-matching frame (shared by
/// `-o` and `--passthru -o`). `mv` is the `--crlf` match view of `line`.
/// Returns the number of spans emitted.
pub fn emitMatches(e: *Emitter, ssim: *Regex.SpanSim, path: []const u8, lineno: usize, line: []const u8, mv: []const u8) usize {
    var from: usize = 0;
    var n: usize = 0;
    var last_end: ?usize = null;
    while (from <= mv.len) {
        const span = e.re.matchSpan(ssim, mv, from) orelse break;
        if (span.end == span.start) {
            // rg `find_iter` yields zero-width matches too, but only for a
            // nullable regex (`-o ''`, `a*`) and never one adjacent to the
            // previous match's end (the progress rule) — so a non-nullable
            // pattern's output is byte-identical to before. An empty match
            // prints an empty `-o` line (word-checked under `-w`).
            const adjacent = last_end != null and span.start == last_end.?;
            if (!e.re.nullable or adjacent or (e.o.word and !wordOk(mv, span.start, span.end))) {
                from = span.start + 1;
                continue;
            }
            e.prefix(path, lineno, span.start + 1, e.offOf(line) + span.start, true);
            e.out.append(e.a, e.o.term()) catch die("oom\n", .{});
            n += 1;
            last_end = span.end;
            from = span.start + 1;
            continue;
        }
        if (e.o.word and !wordOk(mv, span.start, span.end)) {
            from = span.end;
            continue;
        }
        e.prefix(path, lineno, span.start + 1, e.offOf(line) + span.start, true);
        const end = if (e.o.crlf and span.end == mv.len) line.len else span.end;
        e.paint(palette.match_on, line[span.start..end]);
        e.out.append(e.a, e.o.term()) catch die("oom\n", .{});
        n += 1;
        last_end = span.end;
        from = span.end;
    }
    return n;
}

pub fn onlyMatching(e: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var ssim = Regex.SpanSim.init(e.a, e.re) catch return 0;
    defer ssim.deinit();
    var emitted: usize = 0;
    for (lines, 0..) |line, k| {
        emitted += emitMatches(e, &ssim, path, k + 1, line, e.mview(line));
        if (e.o.max_per_file != 0 and emitted >= e.o.max_per_file) break;
    }
    return emitted;
}

/// `-o` with `-r`: emit the expanded template (not the raw match) for each match
/// span across `lines`. Returns the number emitted (respecting `--max-count`).
pub fn onlyMatchingRepl(e: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var emitted: usize = 0;
    for (lines, 0..) |line, k| {
        emitted += emitLineRepl(e, path, k + 1, line, emitted);
        if (e.o.max_per_file != 0 and emitted >= e.o.max_per_file) break;
    }
    return emitted;
}

/// Emit each match on one line as its expanded `-r` template (the `-o` frame),
/// `so_far` matches already counted toward `--max-count`. Returns the count on
/// this line.
pub fn emitLineRepl(e: *Emitter, path: []const u8, lineno: usize, line: []const u8, so_far: usize) usize {
    const caps = e.caps.?;
    const tmpl = e.o.replace.?;
    const slots = e.a.alloc(isize, caps.nslots) catch die("oom\n", .{});
    var n: usize = 0;
    var from: usize = 0;
    while (from <= line.len and caps.find(line, from, slots)) {
        const s: usize = @intCast(slots[0]);
        const en: usize = @intCast(slots[1]);
        if (en == s) {
            from = s + 1;
            continue;
        }
        if (e.o.word and !wordOk(line, s, en)) {
            from = en;
            continue;
        }
        e.prefix(path, lineno, s + 1, e.offOf(line) + s, true);
        substitute.expandInto(e.a, caps, e.out, tmpl, line, slots);
        e.out.append(e.a, e.o.term()) catch die("oom\n", .{});
        n += 1;
        if (e.o.max_per_file != 0 and so_far + n >= e.o.max_per_file) break;
        from = en;
    }
    return n;
}

/// 1-based byte column of the first (word-valid, non-empty) match on the line,
/// or 0 if none — the value ripgrep prints under `--column`.
pub fn firstCol(e: *Emitter, ssim: *Regex.SpanSim, line: []const u8) usize {
    var from: usize = 0;
    while (from <= line.len) {
        const sp = e.re.matchSpan(ssim, line, from) orelse return 0;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        if (e.o.word and !wordOk(line, sp.start, sp.end)) {
            from = sp.end;
            continue;
        }
        return sp.start + 1;
    }
    return 0;
}

/// `--vimgrep`: one `path:line:col:text` row per match (all matches on a line),
/// line numbers and columns always on. Never groups.
pub fn vimgrep(e: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var ssim = Regex.SpanSim.init(e.a, e.re) catch return 0;
    defer ssim.deinit();
    var emitted: usize = 0;
    for (lines, 0..) |line, k| {
        const mv = e.mview(line);
        var from: usize = 0;
        while (from <= mv.len) {
            const sp = e.re.matchSpan(&ssim, mv, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (e.o.word and !wordOk(mv, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            e.prefix(path, k + 1, sp.start + 1, e.offOf(line) + sp.start, true);
            e.text(line, true);
            emitted += 1;
            if (e.o.max_per_file != 0 and emitted >= e.o.max_per_file) return emitted;
            from = sp.end;
        }
    }
    return emitted;
}

pub fn countMatches(e: *Emitter, path: []const u8, lines: []const []const u8) usize {
    var ssim = Regex.SpanSim.init(e.a, e.re) catch return 0;
    defer ssim.deinit();
    var total: usize = 0;
    for (lines) |line| {
        const mv = e.mview(line);
        var from: usize = 0;
        while (from <= mv.len) {
            const span = e.re.matchSpan(&ssim, mv, from) orelse break;
            if (span.end == span.start) {
                from = span.start + 1;
                continue;
            }
            if (e.o.word and !wordOk(mv, span.start, span.end)) {
                from = span.end;
                continue;
            }
            total += 1;
            if (e.o.max_per_file != 0 and total >= e.o.max_per_file) break;
            from = span.end;
        }
    }
    if (total == 0) return 0;
    if (e.show_name) e.writePath(path, true);
    e.out.print(e.a, "{d}\n", .{total}) catch die("oom\n", .{});
    return total;
}
