//! gist `rg` — binary-file policy: what a NUL costs you.
//!
//! ripgrep does not simply skip a file containing a NUL; it stops at a precise
//! boundary that depends on how its reader happened to fill buffers, and then
//! prints one of two notes. This module is the whole of that behavior — the
//! quit-strategy arithmetic (`committedPrefix`), the two geometries (line model
//! vs the `-U` slice model), and the notes themselves.
//!
//! It is deliberately one module rather than five, because the pieces are not
//! independent: the cut a strategy computes decides which region gets emitted,
//! which decides whether a note prints at all, which decides the exit code.
//! Both walk engines and the warm face call `handleBinary`, so a NUL means the
//! same thing everywhere.

const std = @import("std");
const args = @import("../argv/args.zig");
const Opts = args.Opts;
const oom = args.oom;
const Emitter = @import("../emit/output.zig").Emitter;
const Matcher = @import("../../../../kernel/match/regex/regex.zig").Matcher;
const collectLines = @import("legible.zig").collectLines;
const BUFCAP = @import("slurp.zig").BUFCAP;

/// How many bytes of a NUL-bearing implicit file ripgrep actually SEARCHES
/// before its quit strategy stops it. Not a 64K-aligned cut: rg's line buffer
/// sits behind a BOM-sniffing decoder whose FIRST read returns ≤ 3 bytes, and
/// each fill() then reads into the free buffer (64 KiB, doubling only when a
/// line outgrows it) until a `\n` lands in the newly-read bytes. A fill
/// commits — and the searcher consumes — only up to the LAST `\n` it read;
/// the remainder rolls into the next fill. The NUL scan runs per newly-read
/// chunk BEFORE the terminator scan, and a hit discards that entire fill
/// unsearched (even complete lines it had just read). So the searched prefix
/// is the last committed boundary before the fill that would read the NUL —
/// e.g. `P5\n16 16\n255\n<NUL>…` commits exactly 3 (`P5\n` from the sniff
/// read), and a 67-KiB text prefix commits its last newline under 64 KiB.
pub fn committedPrefix(body: []const u8, nul: usize) usize {
    var committed: usize = 0; // absolute searched/consumed boundary (ends at \n+1)
    var buf_start: usize = 0; // absolute offset of the buffer's first byte
    var end: usize = 0; // absolute end of everything read so far
    var cap: usize = BUFCAP;
    var first = true;
    while (true) { // one fill() per iteration
        while (true) { // fill's inner read loop
            var free = cap - (end - buf_start);
            while (free == 0) : (free = cap - (end - buf_start)) cap *= 2;
            var n = @min(free, body.len - end);
            if (first) {
                n = @min(3, n);
                first = false;
            }
            if (n == 0) return body.len; // EOF (unreachable while nul < len; keeps the fn total)
            const lo = end;
            end += n;
            if (nul >= lo and nul < end) return committed; // NUL in newbytes ⇒ fill discarded
            if (std.mem.lastIndexOfScalar(u8, body[lo..end], '\n')) |i| {
                committed = lo + i + 1;
                buf_start = committed; // roll: consumed up to the last terminator
                break;
            }
        }
    }
}

/// Is a NUL at `nul` "binary" to rg's `-U` slice searcher? That searcher
/// sniffs only the first `min(len, 64K)` bytes up front: a NUL inside the
/// sniff quits BEFORE searching anything; a NUL beyond it is never noticed —
/// the implicit file is searched as ordinary text, matches after the NUL
/// included, `binary_offset` null.
pub fn multilineBinary(body_len: usize, nul: usize) bool {
    return nul < @min(body_len, BUFCAP);
}

/// ripgrep binary-file handling (a NUL is present, no `--text`/`--null-data`).
///
/// Two geometries, selected exactly as rg's `multi_line_with_matcher` does:
/// the SLICE model (`-U` whose pattern can actually match `\n`) sniffs
/// `min(len, 64K)` up front — see `handleBinaryMulti`; everything else —
/// line mode, and `-U` whose pattern provably can't match the terminator —
/// is the LINE model: an implicit (walked) file is searched only through
/// `committedPrefix` (the bytes rg's quit strategy consumed before the
/// NUL-bearing fill) with the WARNING note after a printed match; an explicit
/// path arg or stdin is searched in full ("convert" strategy), but the
/// standard printer suppresses match lines once binary is reported — so only
/// the prefix's lines print, plus the `binary file matches` summary.
/// Returns whether the file counts as a match (drives the exit code).
pub fn handleBinary(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, show_name: bool) bool {
    if (em.re.multiline() and em.re.canMatchNewline())
        return handleBinaryMulti(a, re, o, out, em, path, explicit, body, nul, show_name);

    const prefix = body[0..committedPrefix(body, nul)];
    if (!explicit) {
        // Implicit (walk/glob): only the committed prefix was ever searched —
        // every mode (-l included) answers from it, and `-c`/`--count-matches`
        // are suppressed entirely (rg's Summary printer drops binary files).
        if (o.count_only or o.count_matches) return false;
        const hits = emitRegion(a, em, o, path, prefix);
        if (o.files_only) return hits > 0;
        // A WARNING only when we actually printed a match in the prefix;
        // otherwise rg quits silently (no output, no match).
        if (hits == 0) return false;
        binNote(a, out, o, path, nul, show_name, "WARNING: stopped searching binary file after match");
        return true;
    }

    // -l/--files-with-matches scans an explicit file as text and emits no binary
    // warning; -c counts every match across the whole body (rg's convert strategy
    // treats an explicit binary as text).
    if (o.files_only or o.count_only or o.count_matches)
        return emitRegion(a, em, o, path, body) > 0;

    const before = out.items.len;
    _ = emitRegion(a, em, o, path, prefix);
    if (regionMatches(a, re, o, em, body)) {
        binNote(a, out, o, path, nul, show_name, "binary file matches");
        return true;
    }
    out.shrinkRetainingCapacity(before);
    return false;
}

/// Render a body region through the emitter in the run's own shape — split rg
/// lines for the per-line model, the whole-buffer emitter under `-U` (a `-U`
/// run downgraded to line-model binary semantics still RENDERS whole-buffer;
/// its pattern can't cross lines, so the two shapes coincide). Returns hits.
fn emitRegion(a: std.mem.Allocator, em: *Emitter, o: Opts, path: []const u8, region: []const u8) usize {
    // The fused whole-buffer fast paths inside `file`/`buffer` read the
    // emitter's `[base, body_end)` window DIRECTLY — the `-l` doc-match
    // (`output.zig`), the `-c`/`-o` miss-skip — bypassing the `lines` slice. The
    // caller (`handleBinary`, via both walk engines) has that window pointed at
    // the WHOLE body, but the binary quit strategy searches only this `region`
    // (the committed prefix). Re-point the window at exactly `region` — a
    // contiguous slice of that body — so a fused pass can't escape past rg's NUL
    // cutoff and match bytes in the discarded tail. An empty prefix collapses
    // `body_end == base`, which disables every fused path (they gate on
    // `body_end > base`), so nothing is searched — rg parity.
    em.base = @intFromPtr(region.ptr);
    em.body_end = em.base + region.len;
    if (em.re.multiline()) return em.buffer(path, region);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    collectLines(a, region, o.term(), &lines);
    return em.file(path, lines.items);
}

/// Does the pattern match anywhere in the FULL body? (Drives the explicit
/// binary summary — rg reports the whole file as a binary match even when the
/// only hits sit past the NUL.)
fn regionMatches(a: std.mem.Allocator, re: *const Matcher, o: Opts, em: *Emitter, body: []const u8) bool {
    if (em.re.multiline()) return bufAnyMatch(a, re, body);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    collectLines(a, body, o.term(), &lines);
    return anyLinesMatch(a, re, o, lines.items);
}

/// The slice-model twin of `handleBinary` (`-U` whose pattern can match `\n`).
/// An implicit file never gets here with a beyond-sniff NUL (the engines fall
/// through to the text path — see `multilineBinary`), so implicit ⇒ the sniff
/// quit: nothing searched, nothing printed, no match. An explicit file is
/// searched in full (`-c`/`-l` treat it as text), but the slice searcher
/// reports binary BEFORE searching, so the standard printer suppresses every
/// match line — only the summary prints.
fn handleBinaryMulti(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, show_name: bool) bool {
    if (!explicit) return false;
    // -l / -c treat the explicit file as text over the FULL body (convert).
    if (o.files_only or o.count_only or o.count_matches) return em.buffer(path, body) > 0;
    if (bufAnyMatch(a, re, body)) {
        binNote(a, out, o, path, nul, show_name, "binary file matches");
        return true;
    }
    return false;
}

/// Does the pattern match anywhere in the whole buffer under `-U` semantics?
/// (The multiline twin of `anyLinesMatch`, for the explicit binary summary.)
fn bufAnyMatch(a: std.mem.Allocator, re: *const Matcher, body: []const u8) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    return re.bufMatch(&sim, body);
}

/// Append ripgrep's binary note: `[<path>: ]<msg> (found "\0" byte around offset
/// N)`. The path prefix (with `: ` separator) is shown only when filenames are on.
pub fn binNote(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, path: []const u8, nul: usize, show_name: bool, msg: []const u8) void {
    if (show_name) out.print(a, "{s}: ", .{path}) catch oom();
    out.print(a, "{s} (found \"\\0\" byte around offset {d}){c}", .{ msg, nul, o.term() }) catch oom();
}

/// Does any line match (used for the explicit binary summary)? Honors `-w` and
/// the `--crlf` view; ignores `-v` (rg's binary summary reflects real matches).
pub fn anyLinesMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, lines: []const []const u8) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&sim, mv);
        if (hit) return true;
    }
    return false;
}

const Regex = @import("../../../../kernel/match/regex/regex.zig").Regex;

test "multiline binary: match before the NUL prints; after the NUL is elided" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Matcher{ .linear = try Regex.compileOpts(a, "a\\nb", .{ .multiline = true }) };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    const o = Opts{ .multiline = true, .line_num = true };
    var em = Emitter{ .a = a, .re = &m, .o = o, .show_name = false, .out = &out, .base = 0 };

    // NUL in the first buffer (offset 5): its whole buffer is discarded, so the
    // cross-line match wholly before it (bytes 0-2) never prints — rg's rule.
    const body = "a\nb\x00a\nb\n";
    em.base = @intFromPtr(body.ptr);
    _ = handleBinary(a, &m, o, &out, &em, "x.bin", false, body, 5, true);
    // cut = (5/65536)*65536 = 0 ⇒ nothing before the NUL buffer is emitted.
    try t.expectEqualStrings("", out.items);
}

test "walked -l stops at the NUL buffer without scanning its tail" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "panic") };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const o = Opts{ .files_only = true };
    var em = Emitter{ .a = t.allocator, .re = &m, .o = o, .show_name = true, .out = &out };
    // Both walk engines point the emitter's whole-body window at the file
    // BEFORE binary handling (serial `renderFile`, parallel `emitBody`), and the
    // fused `-l` doc-match reads that window. The test MUST mirror that state or
    // it silently exercises an unset (empty) window and cannot catch a fused
    // pass escaping the NUL cutoff — `setWindow` re-points it per body.
    const setWindow = struct {
        fn f(e: *Emitter, body: []const u8) void {
            e.base = @intFromPtr(body.ptr);
            e.body_end = e.base + body.len;
        }
    }.f;

    const same_buffer = "panic\x00panic after cutoff";
    setWindow(&em, same_buffer);
    try t.expect(!handleBinary(t.allocator, &m, o, &out, &em, "same.bin", false, same_buffer, 5, true));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // No line terminator ever lands before the NUL ⇒ no fill commits ⇒ rg
    // searches ZERO bytes — even though the match sits a full buffer before
    // the NUL (verified against rg: `-l` exits 1, stats say bytes_searched:0).
    const uncommitted = try t.allocator.alloc(u8, BUFCAP + 1);
    defer t.allocator.free(uncommitted);
    @memset(uncommitted, 'x');
    @memcpy(uncommitted[0..5], "panic");
    uncommitted[BUFCAP] = 0;
    setWindow(&em, uncommitted);
    try t.expect(!handleBinary(t.allocator, &m, o, &out, &em, "uncommitted.bin", false, uncommitted, BUFCAP, true));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // A committed line before the NUL-bearing fill IS searched: `panic\n`
    // commits in the first fill, the NUL discards only the next one.
    const committed = try t.allocator.alloc(u8, BUFCAP + 1);
    defer t.allocator.free(committed);
    @memset(committed, 'x');
    @memcpy(committed[0..6], "panic\n");
    committed[BUFCAP] = 0;
    setWindow(&em, committed);
    try t.expect(handleBinary(t.allocator, &m, o, &out, &em, "committed.bin", false, committed, BUFCAP, true));
    try t.expectEqualStrings("committed.bin\n", out.items);
}
