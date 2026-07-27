//! gist `rg` — file-content ingest transforms: the byte pipeline that turns one
//! file's raw on-disk bytes into the bytes actually searched, honoring the three
//! rg flags that reshape content before matching:
//!
//!   • `-z`/`--search-zip`  — transparently decompress a compressed file by its
//!     extension. gist decodes the common web/source formats (gzip, zlib, zstd,
//!     xz) IN-PROCESS via Zig's `std.compress` — no `gzip -dc` fork per file,
//!     the single biggest speed edge over ripgrep, which shells an external
//!     decompressor for every format. The long-tail formats (bzip2, lz4, brotli,
//!     lzma, `.Z`) fall back to the standard external tool, path-in / stdout-out.
//!   • `--pre` (+ `--pre-glob`) — run an arbitrary preprocessor command over each
//!     file and search its stdout. As in ripgrep, the command receives the path
//!     as `argv[1]` AND the file's bytes on stdin (the open file is wired straight
//!     to the child's stdin fd, so a stdin-reading preprocessor works and there is
//!     no pipe to deadlock). `--pre` overrides `-z` entirely (rg parity);
//!     `--pre-glob` scopes WHICH files are fed through it.
//!   • `-E`/`--encoding` — transcode the (post-decompress / post-pre) bytes from a
//!     named source encoding to UTF-8 so a UTF-8 pattern matches. `auto` (default)
//!     is BOM sniffing (shared with the untransformed fast path); `none` disables
//!     it; explicit labels (`utf-16`, `shift_jis`, `gbk`, …) force a transcode. The
//!     legacy-code-page decoders live in `encoding.zig`; `applyEncoding` keeps only
//!     the UTF fast paths and delegates the rest.
//!
//! This is a deep module: one entry point, `apply`, owns the whole
//! decompress → preprocess → transcode ordering and every failure mode, so the
//! two walk engines never re-implement it. The parallel pipeline declines any
//! transforming invocation (`Config.active`) back to the serial engine, so
//! `apply` only ever runs single-threaded — which is also why the external
//! subprocess path (`std.process.run`, one `io` handle) is safe here.

const std = @import("std");
const args = @import("../argv/args.zig");
const encoding = @import("encoding.zig");
const glob = @import("../../../../corpus/scope/glob.zig");
const legible = @import("legible.zig");
const assay = @import("../../../../assay/assay.zig");
const flate = std.compress.flate;
const zstd = std.compress.zstd;
const xz = std.compress.xz;
/// The transform configuration for one run, assembled once by `run.zig` from the
/// parsed `Opts` (plus the shared preprocessor-failure latch and the `io` handle
/// the external subprocess path needs). Copyable by value — every field is a
/// slice, scalar, or the small `io` vtable pair.
pub const Config = struct {
    io: std.Io,
    search_zip: bool = false,
    pre: ?[]const u8 = null,
    pre_globs: []const []const u8 = &.{}, // --pre-glob includes (empty ⇒ every file)
    pre_excludes: []const []const u8 = &.{}, // --pre-glob '!…'
    encoding: args.Encoding = .auto,
    // A failed `--pre` invocation is an error, not a silent no-match: it prints to
    // stderr and forces exit 2 (rg parity). The latch is threaded by pointer so a
    // parallel read shard — if the reads ever run parallel again — folds in; today
    // `active()` routes transforming runs single-threaded, so it's a plain flag.
    pre_error: ?*std.atomic.Value(bool) = null,

    /// Does any flag change the CONTENT (vs the on-disk bytes)? True disables
    /// index read-elision and whole-file trigram prefilters, since the persisted
    /// index is built over raw on-disk bytes, not decompressed / preprocessed
    /// output — a candidate's needle lives only in the transformed stream.
    pub fn contentActive(self: Config) bool {
        return self.search_zip or self.pre != null;
    }
    /// Is ANY transform in play (content OR a non-default encoding)? A non-default
    /// encoding also breaks index elision (the index holds the source-encoding
    /// bytes, the pattern is UTF-8), so it too forces the plain live read.
    pub fn active(self: Config) bool {
        return self.contentActive() or self.encoding != .auto;
    }
};

/// Transform one file's raw bytes into the bytes to search, or null to DROP the
/// file (an errored `--pre` — the latch already carries the exit-2 signal).
/// `disk` is the openable path (`--pre` argv / decompressor input); `rel` is the
/// display path `--pre-glob` matches against. Ordering is rg's: preprocess (which
/// wholly overrides `-z`) OR decompress, then transcode the result.
pub fn apply(a: std.mem.Allocator, cfg: *const Config, disk: []const u8, rel: []const u8, raw: []const u8) ?[]const u8 {
    var bytes = raw;
    if (cfg.pre) |pre| {
        // `--pre` overrides `-z` entirely (rg): a file the glob selects is fed
        // through the command; one it doesn't is searched raw (never decompressed).
        if (preSelects(cfg, rel)) bytes = spawnPre(a, cfg, &.{ pre, disk }, disk) orelse return null;
    } else if (cfg.search_zip) {
        if (decompress(a, cfg, disk, raw)) |d| bytes = d; // else: passthru raw
    }
    return applyEncoding(a, cfg.encoding, bytes);
}

// ─────────────────────────── encoding ───────────────────────────

/// Transcode `buf` from the requested source encoding to UTF-8. The `auto`/`none`/
/// UTF families are handled inline here: `auto` is the default BOM-sniff (shared
/// verbatim with the untransformed read path via `legible.decodeBom`); `none`
/// passes bytes through untouched; `utf8` strips a UTF-8 BOM and replaces any
/// ill-formed subpart with U+FFFD (an explicit label is a decode, not a
/// passthrough — `legible.utf8Lossy`); the UTF-16 variants
/// transcode (a bare `utf16` without an explicit endianness picks it from a
/// leading BOM, else little-endian — encoding_rs's default). Every other WHATWG
/// legacy encoding (the single-byte pages + the CJK multi-byte pages) routes to
/// `encoding.decode`.
pub fn applyEncoding(a: std.mem.Allocator, enc: args.Encoding, buf: []const u8) []const u8 {
    return switch (enc) {
        .auto => legible.decodeBom(a, buf),
        .none => buf,
        .utf8 => legible.utf8Lossy(a, legible.stripBom(buf)),
        .utf16le => legible.utf16ToUtf8(a, dropUtf16Bom(buf, .little), .little),
        .utf16be => legible.utf16ToUtf8(a, dropUtf16Bom(buf, .big), .big),
        .utf16 => blk: {
            const e: std.builtin.Endian = if (buf.len >= 2 and buf[0] == 0xFE and buf[1] == 0xFF) .big else .little;
            break :blk legible.utf16ToUtf8(a, dropUtf16Bom(buf, e), e);
        },
        else => encoding.decode(a, enc, buf),
    };
}

/// The body a *printer* sees. `--encoding none` is a byte passthrough end to
/// end — rg sniffs no BOM under it, so a leading BOM belongs to the line it
/// prints (measured: `rg -E none fn bom.txt` emits the three BOM bytes, the
/// default sniff does not). Under every other encoding `applyEncoding` already
/// consumed the BOM and a second strip is a no-op, so every emitter can route
/// its bytes through this instead of stripping unconditionally.
pub fn visibleBody(enc: args.Encoding, buf: []const u8) []const u8 {
    return if (enc == .none) buf else legible.stripBom(buf);
}

/// Drop a UTF-16 BOM matching `endian` so the transcoder never emits a leading
/// U+FEFF (which would keep `^` from anchoring the first real character).
fn dropUtf16Bom(buf: []const u8, endian: std.builtin.Endian) []const u8 {
    const bom: []const u8 = if (endian == .little) "\xFF\xFE" else "\xFE\xFF";
    return if (std.mem.startsWith(u8, buf, bom)) buf[2..] else buf;
}

// ─────────────────────────── decompression ───────────────────────────

/// A compressed container recognized by file extension. The first four are
/// decoded in-process via `std.compress` (no fork); the rest shell the standard
/// external tool (path in, stdout out).
const Codec = enum { gzip, zlib, zstd, xz, bzip2, lz4, brotli, lzma, dot_z };

/// Map a path's extension to its codec, or null when nothing matches (`-z` then
/// searches the file verbatim — rg's passthru for an unrecognized extension).
/// The `.tXX` aliases decompress the OUTER layer only (a `.tgz` yields tar bytes),
/// exactly as ripgrep's own extension table does.
fn codecFor(path: []const u8) ?Codec {
    const has = std.ascii.endsWithIgnoreCase;
    if (has(path, ".gz") or has(path, ".tgz") or has(path, ".taz")) return .gzip;
    if (has(path, ".zst") or has(path, ".zstd") or has(path, ".tzst")) return .zstd;
    if (has(path, ".xz") or has(path, ".txz")) return .xz;
    if (has(path, ".lzma") or has(path, ".tlz")) return .lzma;
    if (has(path, ".bz2") or has(path, ".tbz2") or has(path, ".tbz")) return .bzip2;
    if (has(path, ".lz4")) return .lz4;
    if (has(path, ".br")) return .brotli;
    if (has(path, ".zz")) return .zlib;
    if (has(path, ".Z")) return .dot_z;
    return null;
}

/// Decompress `raw` per the path's extension, or null to leave it verbatim (no
/// recognized extension, or a decode/tool failure — a passthru that degrades to
/// "search the compressed bytes", never a fabricated match or a dead run).
fn decompress(a: std.mem.Allocator, cfg: *const Config, disk: []const u8, raw: []const u8) ?[]const u8 {
    const codec = codecFor(disk) orelse return null;
    return switch (codec) {
        .gzip, .zlib, .zstd, .xz => native(a, codec, raw),
        // The long tail: the standard tool, path in, stdout captured, no fork of a
        // decompressor gist can already do in-process.
        .bzip2 => spawnCapture(a, cfg, &.{ "bzip2", "-d", "-c", disk }),
        .lz4 => spawnCapture(a, cfg, &.{ "lz4", "-d", "-c", disk }),
        .brotli => spawnCapture(a, cfg, &.{ "brotli", "-d", "-c", disk }),
        .lzma => spawnCapture(a, cfg, &.{ "xz", "-d", "-c", disk }),
        .dot_z => spawnCapture(a, cfg, &.{ "gzip", "-d", "-c", disk }),
    };
}

/// In-process decode via `std.compress`; any malformed-stream error degrades to
/// passthru (null). Windows: the DEFLATE family's (gzip/zlib) 64 KiB window is
/// the format maximum, so a stack buffer is exact and allocation-free; zstd's is
/// heap-sized to its recommended default (streams above it can't be decoded —
/// rare for source artifacts) and lives in the arena; `xz.Decompress` owns and
/// grows its own LZMA2 dictionary buffer via `a` as blocks demand, and its magic
/// check makes a non-XZ `.xz` degrade to passthru rather than error.
fn native(a: std.mem.Allocator, codec: Codec, raw: []const u8) ?[]const u8 {
    var in: std.Io.Reader = .fixed(raw);
    var out: std.Io.Writer.Allocating = .init(a);
    switch (codec) {
        .gzip, .zlib => {
            var win: [flate.max_window_len]u8 = undefined;
            var d = flate.Decompress.init(&in, if (codec == .gzip) .gzip else .zlib, &win);
            _ = d.reader.streamRemaining(&out.writer) catch return null;
        },
        .zstd => {
            const win = a.alloc(u8, zstd.default_window_len) catch return null;
            var d = zstd.Decompress.init(&in, win, .{});
            _ = d.reader.streamRemaining(&out.writer) catch return null;
        },
        .xz => {
            const scratch = a.alloc(u8, 1 << 16) catch return null;
            var d = xz.Decompress.init(&in, a, scratch) catch return null;
            _ = d.reader.streamRemaining(&out.writer) catch return null;
        },
        else => unreachable,
    }
    return out.toOwnedSlice() catch null;
}

// ─────────────────────────── preprocessor ───────────────────────────

/// Does `--pre-glob` select this path for preprocessing? An empty include set
/// means every file (rg default); a `--pre-glob '!…'` exclude vetoes.
fn preSelects(cfg: *const Config, rel: []const u8) bool {
    for (cfg.pre_excludes) |g| if (glob.globApplies(g, rel)) return false;
    if (cfg.pre_globs.len == 0) return true;
    for (cfg.pre_globs) |g| if (glob.globApplies(g, rel)) return true;
    return false;
}

/// Latch the exit-2 preprocessor error and name the offending file on stderr,
/// echoing the tool's own stderr when it produced any. Returns null (drop file).
///
/// The latch is unconditional and the message is not: failing to read a file
/// through `--pre` is one of ripgrep's file messages, so `--no-messages` quiets
/// the line while the run still exits 2 — the same split every walk-error site
/// makes (`quarry/notice.zig`).
fn preFail(cfg: *const Config, disk: []const u8, tool_stderr: []const u8) ?[]const u8 {
    if (cfg.pre_error) |e| e.store(true, .seq_cst);
    if (tool_stderr.len > 0) {
        assay.note(.corpus, "gist: {s}: preprocessor command failed: {s}\n", .{ disk, std.mem.trimEnd(u8, tool_stderr, "\n") });
    } else {
        assay.note(.corpus, "gist: {s}: preprocessor command failed\n", .{disk});
    }
    return null;
}

/// Run an external decompressor (`bzip2 -dc "$1"`, …), capture stdout, and
/// return it, or null on spawn failure / non-zero exit. A decompressor reads the
/// file via its path argument, so stdin is `.ignore` (the `std.process.run`
/// default) and a failure degrades SILENTLY to passthru — searching the raw
/// compressed bytes, never a fabricated match or a dead run. stderr is bounded;
/// the arena reclaims every allocation at run teardown.
fn spawnCapture(a: std.mem.Allocator, cfg: *const Config, argv: []const []const u8) ?[]const u8 {
    const res = std.process.run(a, cfg.io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    switch (res.term) {
        .exited => |code| if (code == 0) return res.stdout,
        else => {},
    }
    return null;
}

/// Run a `--pre` preprocessor over `disk` and capture its stdout, or null (an
/// ERROR that latches exit 2 via `preFail`, rg parity) on open / spawn / drain
/// failure or a non-zero exit. Unlike a decompressor, the command receives the
/// file's bytes on stdin AS WELL AS the path as `argv[1]` (ripgrep's contract):
/// the open file is handed to the child as its stdin fd, so a stdin-reading
/// preprocessor works and — because a regular file, not a pipe, backs stdin —
/// there is nothing to deadlock, no feeder thread, and no double read into this
/// process. stdout is drained unbounded and stderr is capped, both concurrently
/// (`MultiReader`), the same shape `std.process.run` uses.
fn spawnPre(a: std.mem.Allocator, cfg: *const Config, argv: []const []const u8, disk: []const u8) ?[]const u8 {
    const io = cfg.io;
    const stdin_file = std.Io.Dir.cwd().openFile(io, disk, .{}) catch return preFail(cfg, disk, "");
    defer stdin_file.close(io);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = stdin_file },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return preFail(cfg, disk, "");
    defer child.kill(io);

    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const stderr_reader = mr.reader(1);

    while (mr.fill(64, .none)) |_| {
        if (stderr_reader.buffered().len > 64 * 1024) return preFail(cfg, disk, "");
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return preFail(cfg, disk, ""),
    }
    mr.checkAnyError() catch return preFail(cfg, disk, "");

    const term = child.wait(io) catch return preFail(cfg, disk, "");
    const stderr_bytes = mr.toOwnedSlice(1) catch "";
    switch (term) {
        .exited => |code| if (code == 0) return mr.toOwnedSlice(0) catch return preFail(cfg, disk, stderr_bytes),
        else => {},
    }
    return preFail(cfg, disk, stderr_bytes);
}

test "codecFor maps extensions (case-insensitive), null otherwise" {
    const t = std.testing;
    try t.expectEqual(Codec.gzip, codecFor("a/b.tar.gz").?);
    try t.expectEqual(Codec.gzip, codecFor("X.TGZ").?);
    try t.expectEqual(Codec.zstd, codecFor("log.zst").?);
    try t.expectEqual(Codec.xz, codecFor("core.xz").?);
    try t.expectEqual(Codec.bzip2, codecFor("d.bz2").?);
    try t.expectEqual(Codec.lz4, codecFor("s.lz4").?);
    try t.expectEqual(Codec.brotli, codecFor("w.br").?);
    try t.expectEqual(Codec.dot_z, codecFor("old.Z").?);
    try t.expectEqual(@as(?Codec, null), codecFor("plain.txt"));
    try t.expectEqual(@as(?Codec, null), codecFor("no-ext"));
}

test "latin1 (→ windows-1252) transcode: ASCII aliases, high bytes become 2-byte UTF-8" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pure ASCII returns the same backing slice (no copy) via encoding.decode's fast path.
    const ascii = "func main()";
    try t.expectEqual(ascii.ptr, applyEncoding(a, .windows_1252, ascii).ptr);
    // 0xE9 (é, identical in Latin-1 and windows-1252) → U+00E9 → 0xC3 0xA9.
    try t.expectEqualStrings("caf\xC3\xA9", applyEncoding(a, .windows_1252, "caf\xE9"));
}

test "gzip decodes in-process to the original bytes" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `printf 'the needle is here\nand on another line\n' | gzip -nc` — a real
    // gzip container (deterministic, no mtime) so the test exercises the actual
    // std.compress DEFLATE decode, not a self-consistent encode/decode pair.
    const gz = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 43, 201, 72, 85, 200, 75, 77, 77, 201, 73, 85, 200, 44, 86, 200, 72, 45, 74, 229, 74, 204, 75, 81, 200, 207, 83, 72, 204, 203, 47, 1, 242, 21, 114, 50, 243, 82, 185, 0, 254, 190, 232, 205, 39, 0, 0, 0 };
    const round = native(a, .gzip, &gz).?;
    try t.expectEqualStrings("the needle is here\nand on another line\n", round);
    // A non-gzip blob degrades to passthru (null), never a crash.
    try t.expectEqual(@as(?[]const u8, null), native(a, .gzip, "not compressed at all"));
}

test "applyEncoding: auto BOM-sniffs, none is identity, utf16le transcodes" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // auto strips a UTF-8 BOM (shared with the fast path).
    try t.expectEqualStrings("hi", applyEncoding(a, .auto, "\xEF\xBB\xBFhi"));
    // none leaves the BOM bytes untouched.
    try t.expectEqualStrings("\xEF\xBB\xBFhi", applyEncoding(a, .none, "\xEF\xBB\xBFhi"));
    // utf16le with a BOM: "Hi" → transcoded, BOM dropped.
    try t.expectEqualStrings("Hi", applyEncoding(a, .utf16le, "\xFF\xFEH\x00i\x00"));
    // bare utf16 defaults to LE when there's no BOM.
    try t.expectEqualStrings("Hi", applyEncoding(a, .utf16, "H\x00i\x00"));
}

test "applyEncoding utf8: one U+FFFD per ill-formed maximal subpart" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const FFFD = "\u{FFFD}";
    // Every expectation below was captured from live `rg -E utf8` on the same
    // bytes (see the `-E utf-8` lane of bench/rgsuite/fuzz.py) — not derived
    // from this implementation. An explicit label decodes; it never passes
    // invalid bytes through.
    try t.expectEqualStrings("hi", applyEncoding(a, .utf8, "\xEF\xBB\xBFhi")); // BOM still stripped
    try t.expectEqualStrings("h\u{E9}llo", applyEncoding(a, .utf8, "h\u{E9}llo")); // valid: borrowed
    // Bare continuations stand alone; each is its own subpart.
    try t.expectEqualStrings(FFFD ++ FFFD ++ " x", applyEncoding(a, .utf8, "\x80\x81 x"));
    // Truncated multi-byte leads: the whole valid prefix is ONE subpart.
    try t.expectEqualStrings(FFFD ++ " x", applyEncoding(a, .utf8, "\xE6\x97 x"));
    try t.expectEqualStrings(FFFD ++ " x", applyEncoding(a, .utf8, "\xF0\x9F\x98 x"));
    // An out-of-range second byte ends the subpart at the lead, so the tail
    // bytes are re-examined rather than swallowed: overlong and surrogate
    // encodings each yield one U+FFFD per byte.
    try t.expectEqualStrings(FFFD ++ FFFD ++ FFFD ++ " x", applyEncoding(a, .utf8, "\xE0\x80\x80 x"));
    try t.expectEqualStrings(FFFD ++ FFFD ++ FFFD ++ " x", applyEncoding(a, .utf8, "\xED\xA0\x80 x"));
    try t.expectEqualStrings(FFFD ++ FFFD ++ " x", applyEncoding(a, .utf8, "\xC0\xAF x"));
    // 0xF5.. is past U+10FFFF and cannot lead at all.
    try t.expectEqualStrings(FFFD ++ FFFD, applyEncoding(a, .utf8, "\xFE\xFF"));
}
