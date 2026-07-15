//! gist `rg` — the per-FILE search machinery, shared by the two walk engines.
//!
//! Split from `run.zig` when the parallel pipeline (`pipeline.zig`) landed:
//! everything here answers "given one file's bytes, produce ripgrep-shaped
//! output for it" with no dependence on HOW the file was discovered or which
//! thread is asking — byte ingest (BOM decode / UTF-16 transcode), rg line
//! semantics, binary-file handling, and the `--stats` tally. `run.zig` (the
//! serial engine that keeps the full exotic flag surface) and `pipeline.zig`
//! (the work-stealing parallel engine behind the common recursive-walk case)
//! both call these, so the two engines cannot drift on per-file semantics.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const args = @import("args.zig");
const output = @import("output.zig");
const Opts = args.Opts;
const die = args.die;
const multiline = @import("multiline.zig");
const Emitter = output.Emitter;
const Regex = @import("../../regex/core.zig").Regex;
const Matcher = @import("../../regex/matcher.zig").Matcher;

/// ripgrep's default read-buffer capacity. Binary detection scans buffer-sized
/// reads for a NUL; a match in the buffer that first contains the NUL is NOT
/// printed (rg has already scanned ahead), so the emission cutoff is the start
/// of that buffer — `(nul_offset / BUFCAP) * BUFCAP`.
pub const BUFCAP: usize = 65536;

/// Strip a leading UTF-8 BOM (ripgrep transparently skips it so `^` anchors to
/// the first real byte). Downstream of `decodeBom` this is a no-op for files (the
/// BOM is already gone); it still guards the stdin path, which isn't BOM-decoded.
pub fn stripBom(buf: []const u8) []const u8 {
    if (buf.len >= 3 and buf[0] == 0xEF and buf[1] == 0xBB and buf[2] == 0xBF) return buf[3..];
    return buf;
}

/// BOM-driven encoding auto-detection, applied once per file at ingest — ripgrep's
/// default (`--encoding auto`) behavior. A UTF-8 BOM is stripped; a UTF-16 LE/BE
/// BOM transcodes the whole file to UTF-8 so the (UTF-8) pattern matches and the
/// UTF-16 NULs never trip binary detection. BOM-less UTF-16 is NOT sniffed (rg
/// needs explicit `-E utf-16` for that, which stays NA); anything else is bytes.
pub fn decodeBom(a: std.mem.Allocator, buf: []const u8) []const u8 {
    if (buf.len >= 3 and buf[0] == 0xEF and buf[1] == 0xBB and buf[2] == 0xBF) return buf[3..];
    if (buf.len >= 2 and buf[0] == 0xFF and buf[1] == 0xFE) return utf16ToUtf8(a, buf[2..], .little);
    if (buf.len >= 2 and buf[0] == 0xFE and buf[1] == 0xFF) return utf16ToUtf8(a, buf[2..], .big);
    return buf;
}

/// Transcode UTF-16 (BOM already consumed) to UTF-8, resolving surrogate pairs;
/// a lone/invalid surrogate or trailing odd byte becomes U+FFFD (rust-encoding's
/// lossy behavior, which ripgrep uses).
pub fn utf16ToUtf8(a: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, bytes[i..][0..2], endian);
        if (cp >= 0xD800 and cp <= 0xDBFF) { // high surrogate → need a low one
            if (i + 3 < bytes.len) {
                const lo: u16 = std.mem.readInt(u16, bytes[i + 2 ..][0..2], endian);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 2;
                } else cp = 0xFFFD;
            } else cp = 0xFFFD;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD; // stray low surrogate
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch blk: {
            // U+FFFD REPLACEMENT CHARACTER — its UTF-8 encoding is a fixed 3 bytes.
            enc[0..3].* = .{ 0xEF, 0xBF, 0xBD };
            break :blk 3;
        };
        out.appendSlice(a, enc[0..n]) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// rg line semantics: `\n` terminates; trailing `\n` yields no phantom empty
/// line; content after the last `\n` is still a line. `\r` is KEPT (ripgrep's
/// default without `--crlf`). Pre-sized from one `\n` count pass (same idiom
/// as `persist.zig`'s NUL-count split) so appending a file's lines is a single
/// allocation instead of the list's usual grow-and-copy doubling — the search
/// loop calls this once per candidate file, so the saved reallocations
/// scale with the corpus, not just one file.
pub fn collectLines(a: std.mem.Allocator, buf: []const u8, term: u8, out: *std.ArrayList([]const u8)) void {
    out.ensureUnusedCapacity(a, std.mem.count(u8, buf, &.{term}) + 1) catch die("oom\n", .{});
    var rest = buf;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, term);
        const end = nl orelse rest.len;
        if (nl != null or end > 0) out.appendAssumeCapacity(rest[0..end]);
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
}

/// ripgrep binary-file handling (a NUL is present, no `--text`/`--null-data`).
/// Emits matching lines that start before the NUL-containing buffer, then either
/// the implicit WARNING (files reached via the walk / glob) or the explicit
/// `binary file matches` summary (an explicit path arg or stdin). Returns whether
/// the file counts as a match (drives the process exit code).
pub fn handleBinary(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, show_name: bool) bool {
    const cut = (nul / BUFCAP) * BUFCAP; // start of the buffer that holds the NUL
    // Under `-U` the emitter renders whole byte ranges, not split lines — route
    // to the buffer path with the same NUL cutoff so binary handling stays
    // engine-neutral while the proven per-line path below is untouched.
    if (em.re.multiline()) return handleBinaryMulti(a, re, o, out, em, path, explicit, body, nul, cut, show_name);

    // `-l` can observe only complete buffers before the one that revealed the
    // first NUL. Do not split/scan the discarded tail (often a multi-megabyte
    // image, font, audio clip, or model artifact).
    if (o.files_only and !explicit) {
        var visible: std.ArrayList([]const u8) = .empty;
        collectLines(a, body[0..cut], o.term(), &visible);
        return em.file(path, visible.items) > 0;
    }

    var lines: std.ArrayList([]const u8) = .empty;
    collectLines(a, body, o.term(), &lines);
    var cutoff: usize = lines.items.len;
    for (lines.items, 0..) |line, k| {
        if (@intFromPtr(line.ptr) - @intFromPtr(body.ptr) >= cut) {
            cutoff = k;
            break;
        }
    }
    const head = lines.items[0..cutoff];

    // -l/--files-with-matches scans an explicit file as text and emits no binary
    // warning. Walked files returned through the bounded fast path above.
    if (o.files_only) return em.file(path, lines.items) > 0;

    // -c/--count: implicit files are suppressed entirely (rg scans fully, detects
    // binary, drops the count); an explicit file counts every match across the
    // whole body (rg treats an explicit binary as text for counting).
    if (o.count_only or o.count_matches) {
        if (!explicit) return false;
        return em.file(path, lines.items) > 0;
    }

    const before = out.items.len;
    const hits = em.file(path, head);
    if (explicit) {
        // Explicit path / stdin: the summary fires if the file matches anywhere
        // (including after the NUL — rg reports the whole file as a binary match).
        if (anyLinesMatch(a, re, o, lines.items)) {
            binNote(a, out, o, path, nul, show_name, "binary file matches");
            return true;
        }
        out.shrinkRetainingCapacity(before);
        return false;
    }
    // Implicit (walk/glob): a WARNING only when we actually printed a match before
    // the NUL buffer; otherwise rg quits silently (no output, no match).
    if (hits > 0) {
        binNote(a, out, o, path, nul, show_name, "WARNING: stopped searching binary file after match");
        return true;
    }
    return false;
}

/// The `-U` twin of `handleBinary`: same NUL-cutoff policy over whole byte
/// ranges (the multiline emitter owns line splitting). Matches emitted only for
/// the head before the NUL buffer; the explicit summary reflects a whole-buffer
/// match. `-c`/`-l` mirror the line path (implicit files suppressed, explicit
/// treated as text).
fn handleBinaryMulti(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, cut: usize, show_name: bool) bool {
    if (o.files_only) return em.buffer(path, if (explicit) body else body[0..cut]) > 0;
    if (o.count_only or o.count_matches) return if (explicit) em.buffer(path, body) > 0 else false;

    const before = out.items.len;
    const hits = em.buffer(path, body[0..cut]);
    if (explicit) {
        if (bufAnyMatch(a, re, body)) {
            binNote(a, out, o, path, nul, show_name, "binary file matches");
            return true;
        }
        out.shrinkRetainingCapacity(before);
        return false;
    }
    if (hits > 0) {
        binNote(a, out, o, path, nul, show_name, "WARNING: stopped searching binary file after match");
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
    if (show_name) out.print(a, "{s}: ", .{path}) catch die("oom\n", .{});
    out.print(a, "{s} (found \"\\0\" byte around offset {d}){c}", .{ msg, nul, o.term() }) catch die("oom\n", .{});
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

/// `--stats` tally (ripgrep's summary). Timing fields are intentionally omitted:
/// they are non-deterministic and the differential harness normalizes the two
/// `seconds` lines away (ripgrep's own tests only `contains`-check them).
pub const Stats = struct {
    matches: usize = 0,
    matched_lines: usize = 0,
    files_with_match: usize = 0,
    files_searched: usize = 0,
    bytes_printed: usize = 0,
    bytes_searched: usize = 0,

    /// Fold another tally into this one (the parallel engine sums its per-worker
    /// tallies; the count fields are all additive, `bytes_printed` is set last
    /// by whoever owns the final output buffer).
    pub fn add(self: *Stats, other: Stats) void {
        self.matches += other.matches;
        self.matched_lines += other.matched_lines;
        self.files_with_match += other.files_with_match;
        self.files_searched += other.files_searched;
        self.bytes_searched += other.bytes_searched;
    }
};

pub const FileStat = struct { matches: usize, lines: usize, bytes: usize };

/// Count total match spans and matching lines in one file (for `--stats`),
/// honoring `-w` word bounds and the `--crlf` match view. Empty spans don't
/// count (ripgrep counts non-empty matches). Under `-m/--max-count`, ripgrep
/// stops reading after the Nth matching line, so `bytes` reports only the bytes
/// actually searched (ADR-parity with rg's `r2944` regression) rather than the
/// whole file.
pub fn fileMatchStats(re: *const Matcher, a: std.mem.Allocator, o: Opts, body: []const u8, lines: []const []const u8) FileStat {
    // `-U`: the tally is over whole-buffer spans, not split lines. `matches`
    // counts non-empty spans; `lines` the union of lines they cover (rg's
    // `matched lines`). `-m` already capped the span list, and rg reports the
    // whole body as searched here (no line-wise early stop).
    if (re.multiline()) {
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
        var from: usize = 0;
        var line_hit = false;
        while (from <= mv.len) {
            const sp = re.matchSpan(&ss, mv, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (o.word and !output.wordOk(mv, sp.start, sp.end)) {
                from = sp.end;
                continue;
            }
            m += 1;
            line_hit = true;
            from = sp.end;
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
/// two `seconds` lines carry zeros — the harness normalizes them (see `Stats`).
pub fn emitStats(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Stats) void {
    out.print(a,
        \\
        \\{d} matches
        \\{d} matched lines
        \\{d} files contained matches
        \\{d} files searched
        \\{d} bytes printed
        \\{d} bytes searched
        \\0.000000 seconds spent searching
        \\0.000000 seconds total
        \\
    , .{ s.matches, s.matched_lines, s.files_with_match, s.files_searched, s.bytes_printed, s.bytes_searched }) catch die("oom\n", .{});
}

/// ripgrep's `<bin>: <path>: <errno phrase>` note for a path that can't be
/// opened/descended — an explicit PATH arg or an unreadable directory hit
/// mid-walk. Shared by both engines (`run.zig`'s serial walk + explicit-PATH
/// probe, `pipeline.zig`'s parallel `processDir`) so a walk-error message
/// can't drift between them. The differential harness keys only on the errno
/// phrase and the exit class (never the `rg:`/`gist:` prefix or the exact
/// number — see `bench/rgsuite/run.py`), so the common cases carry rg's own
/// wording and anything rarer falls back to the Zig error name.
pub fn pathErrNote(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied => "Permission denied (os error 13)",
        error.NotDir => "Not a directory (os error 20)",
        error.SymLinkLoop => "Too many levels of symbolic links (os error 62)",
        error.NameTooLong => "File name too long (os error 63)",
        else => @errorName(err),
    };
}

/// One candidate's raw bytes: POSIX open/read/close into the caller's reused
/// `scratch` (sized `corpus.per_file_cap`); a file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger), so `readTail` keeps
/// reading past it into a growable `a`-owned buffer instead of silently
/// truncating (ripgrep has no default max file size). Returns null when the
/// file can't be opened — the walk's truth degrades to "found nothing here",
/// never an invented match. The returned slice may alias `scratch`: consume it
/// before the next call.
pub fn readFileRaw(a: std.mem.Allocator, scratch: []u8, disk: []const u8) ?[]const u8 {
    const sf = StagedFile.open(scratch, std.posix.AT.FDCWD, disk) orelse return null;
    defer sf.close();
    return sf.readRest(a, scratch);
}

/// A candidate opened and read in TWO stages: the first `BUFCAP` bytes now, the
/// tail only if the caller still needs it. ripgrep's streaming reader decides
/// most files from its first 64 KiB buffer — binary triage (a NUL in buffer 0
/// makes an implicit file contribute nothing) and the `-l` first-match exit
/// both fire there — and on this corpus 86% of all bytes are tails of >64 KiB
/// files, so NOT reading them is the single biggest IO saving available.
///
/// Opens relative to `dirfd`: the parallel walk holds each directory open
/// while searching its files, so the kernel resolves ONE path component
/// instead of re-walking the full `dir/sub/…/name` chain per file (namei is
/// the dominant per-file open cost on a deep monorepo tree; ~21k opens/scan).
pub const StagedFile = struct {
    fd: std.posix.fd_t,
    prefix: []const u8, // first ≤BUFCAP bytes, in the caller's scratch
    more: bool, // the prefix filled BUFCAP exactly ⇒ a tail may exist

    pub fn open(scratch: []u8, dirfd: std.posix.fd_t, name: []const u8) ?StagedFile {
        const fd = std.posix.openat(dirfd, name, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        const cap = @min(scratch.len, BUFCAP);
        const n = drain(fd, scratch[0..cap]);
        return .{ .fd = fd, .prefix = scratch[0..n], .more = n == cap };
    }

    /// The whole body: the prefix plus whatever remains on `fd`, contiguous in
    /// `scratch` (spilling to `readTail` past the scratch cap). Call at most once.
    pub fn readRest(self: *const StagedFile, a: std.mem.Allocator, scratch: []u8) ?[]const u8 {
        if (!self.more) return self.prefix;
        const n = self.prefix.len + drain(self.fd, scratch[self.prefix.len..]);
        if (n == scratch.len) return readTail(a, self.fd, scratch);
        return scratch[0..n];
    }

    pub fn close(self: *const StagedFile) void {
        _ = std.posix.system.close(self.fd);
    }

    /// Fill `buf` from `fd`; returns bytes read. A short read on a regular
    /// local file means EOF (the walk only yields regular files, and gist's
    /// corpus model is a local filesystem — see `corpus/README.md`), so the
    /// common sub-cap file costs ONE read syscall, not read-then-read-zero.
    fn drain(fd: std.posix.fd_t, buf: []u8) usize {
        var n: usize = 0;
        while (n < buf.len) {
            const want = buf.len - n;
            const r = std.posix.read(fd, buf[n..]) catch break;
            n += r;
            if (r < want) break;
        }
        return n;
    }
};

/// `scratch` (already full) plus whatever remains on `fd`, copied into one
/// `a`-owned buffer — the uncommon path for a file at/above `per_file_cap`,
/// kept out of the hot common-case function above.
pub fn readTail(a: std.mem.Allocator, fd: std.posix.fd_t, scratch: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, scratch) catch return null;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const r = std.posix.read(fd, &tmp) catch break;
        if (r == 0) break;
        out.appendSlice(a, tmp[0..r]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

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

test "multiline --stats tallies spans and covered lines over the whole buffer" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Matcher{ .linear = try Regex.compileOpts(a, "a\\nb", .{ .multiline = true }) };
    defer m.deinit();
    const body = "a\nb\nx\na\nb\n";
    const fs = fileMatchStats(&m, a, .{ .multiline = true }, body, &.{});
    try t.expectEqual(@as(usize, 2), fs.matches); // two cross-line matches
    try t.expectEqual(@as(usize, 4), fs.lines); // they cover four physical lines
    try t.expectEqual(body.len, fs.bytes);
}

test "walked -l stops at the NUL buffer without scanning its tail" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "panic") };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const o = Opts{ .files_only = true };
    var em = Emitter{
        .a = t.allocator,
        .re = &m,
        .o = o,
        .show_name = true,
        .out = &out,
    };

    const same_buffer = "panic\x00panic after cutoff";
    try t.expect(!handleBinary(t.allocator, &m, o, &out, &em, "same.bin", false, same_buffer, 5, true));
    try t.expectEqual(@as(usize, 0), out.items.len);

    const prior_buffer = try t.allocator.alloc(u8, BUFCAP + 1);
    defer t.allocator.free(prior_buffer);
    @memset(prior_buffer, 'x');
    @memcpy(prior_buffer[0..5], "panic");
    prior_buffer[BUFCAP] = 0;
    try t.expect(handleBinary(t.allocator, &m, o, &out, &em, "prior.bin", false, prior_buffer, BUFCAP, true));
    try t.expectEqualStrings("prior.bin\n", out.items);
}
