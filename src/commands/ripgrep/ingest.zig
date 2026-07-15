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
//!     file (the path as `argv[1]`) and search its stdout. `--pre` overrides `-z`
//!     entirely (rg parity); `--pre-glob` scopes WHICH files are fed through it.
//!   • `-E`/`--encoding` — transcode the (post-decompress / post-pre) bytes from a
//!     named source encoding to UTF-8 so a UTF-8 pattern matches. `auto` (default)
//!     is BOM sniffing (shared with the untransformed fast path); `none` disables
//!     it; explicit labels (`utf-16`, `latin1`, …) force a transcode.
//!
//! This is a deep module: one entry point, `apply`, owns the whole
//! decompress → preprocess → transcode ordering and every failure mode, so the
//! two walk engines never re-implement it. The parallel pipeline declines any
//! transforming invocation (`Config.active`) back to the serial engine, so
//! `apply` only ever runs single-threaded — which is also why the external
//! subprocess path (`std.process.run`, one `io` handle) is safe here.

const std = @import("std");
const args = @import("args.zig");
const glob = @import("../scope/glob.zig");
const grepfile = @import("grepfile.zig");
const flate = std.compress.flate;
const zstd = std.compress.zstd;
const xz = std.compress.xz;
const die = args.die;

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
        if (preSelects(cfg, rel)) bytes = runPre(a, cfg, pre, disk) orelse return null;
    } else if (cfg.search_zip) {
        if (decompress(a, cfg, disk, raw)) |d| bytes = d; // else: passthru raw
    }
    return applyEncoding(a, cfg.encoding, bytes);
}

// ─────────────────────────── encoding ───────────────────────────

/// Transcode `buf` from the requested source encoding to UTF-8. `auto` is the
/// default BOM-sniff (shared verbatim with the untransformed read path via
/// `grepfile.decodeBom`); `none` passes bytes through untouched; the explicit
/// labels force a transcode regardless of any BOM. UTF-16 without an explicit
/// endianness picks it from a leading BOM (else little-endian, encoding_rs's
/// default). Latin-1 maps each byte 1:1 to its U+00xx code point.
pub fn applyEncoding(a: std.mem.Allocator, enc: args.Encoding, buf: []const u8) []const u8 {
    return switch (enc) {
        .auto => grepfile.decodeBom(a, buf),
        .none => buf,
        .utf8 => grepfile.stripBom(buf),
        .utf16le => grepfile.utf16ToUtf8(a, dropUtf16Bom(buf, .little), .little),
        .utf16be => grepfile.utf16ToUtf8(a, dropUtf16Bom(buf, .big), .big),
        .utf16 => blk: {
            const e: std.builtin.Endian = if (buf.len >= 2 and buf[0] == 0xFE and buf[1] == 0xFF) .big else .little;
            break :blk grepfile.utf16ToUtf8(a, dropUtf16Bom(buf, e), e);
        },
        .latin1 => latin1ToUtf8(a, buf),
    };
}

/// Drop a UTF-16 BOM matching `endian` so the transcoder never emits a leading
/// U+FEFF (which would keep `^` from anchoring the first real character).
fn dropUtf16Bom(buf: []const u8, endian: std.builtin.Endian) []const u8 {
    if (buf.len < 2) return buf;
    const le = buf[0] == 0xFF and buf[1] == 0xFE;
    const be = buf[0] == 0xFE and buf[1] == 0xFF;
    if ((endian == .little and le) or (endian == .big and be)) return buf[2..];
    return buf;
}

/// ISO-8859-1 (Latin-1) → UTF-8: every byte is its own code point (U+0000–U+00FF),
/// so 0x00–0x7F pass through and 0x80–0xFF become the 2-byte UTF-8 of U+0080–U+00FF.
/// A pure-ASCII body needs no copy (the common case) and aliases straight through.
fn latin1ToUtf8(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var high = false;
    for (buf) |c| if (c >= 0x80) {
        high = true;
        break;
    };
    if (!high) return buf;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, buf.len + (buf.len >> 2)) catch die("oom\n", .{});
    for (buf) |c| {
        if (c < 0x80) {
            out.appendAssumeCapacity(c);
        } else {
            out.append(a, 0xC0 | (c >> 6)) catch die("oom\n", .{});
            out.append(a, 0x80 | (c & 0x3F)) catch die("oom\n", .{});
        }
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
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
    const has = struct {
        fn f(p: []const u8, comptime suf: []const u8) bool {
            return std.ascii.endsWithIgnoreCase(p, suf);
        }
    }.f;
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
        .gzip => native(a, .gzip, raw),
        .zlib => native(a, .zlib, raw),
        .zstd => nativeZstd(a, raw),
        .xz => nativeXz(a, raw),
        // The long tail: the standard tool, path in, stdout captured, no fork of a
        // decompressor gist can already do in-process.
        .bzip2 => spawnCapture(a, cfg, &.{ "bzip2", "-d", "-c", disk }),
        .lz4 => spawnCapture(a, cfg, &.{ "lz4", "-d", "-c", disk }),
        .brotli => spawnCapture(a, cfg, &.{ "brotli", "-d", "-c", disk }),
        .lzma => spawnCapture(a, cfg, &.{ "xz", "-d", "-c", disk }),
        .dot_z => spawnCapture(a, cfg, &.{ "gzip", "-d", "-c", disk }),
    };
}

/// In-process DEFLATE-family decode (gzip / zlib container). The 64 KiB window is
/// the format maximum, so a stack buffer is exact and allocation-free; the output
/// grows in the caller's arena. Any malformed-stream error degrades to passthru.
fn native(a: std.mem.Allocator, container: flate.Container, raw: []const u8) ?[]const u8 {
    var in: std.Io.Reader = .fixed(raw);
    var win: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, container, &win);
    var out: std.Io.Writer.Allocating = .init(a);
    _ = d.reader.streamRemaining(&out.writer) catch return null;
    return out.toOwnedSlice() catch null;
}

/// In-process Zstandard decode. The window buffer is heap-sized to zstd's
/// recommended default (streams above it can't be decoded — rare for source
/// artifacts) and lives in the arena.
fn nativeZstd(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const win = a.alloc(u8, zstd.default_window_len) catch return null;
    var in: std.Io.Reader = .fixed(raw);
    var d = zstd.Decompress.init(&in, win, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    _ = d.reader.streamRemaining(&out.writer) catch return null;
    return out.toOwnedSlice() catch null;
}

/// In-process XZ decode. `xz.Decompress` owns and grows its own LZMA2 dictionary
/// buffer via `a` as blocks demand; the magic check makes a non-XZ `.xz` degrade
/// to passthru rather than error.
fn nativeXz(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    var in: std.Io.Reader = .fixed(raw);
    const scratch = a.alloc(u8, 1 << 16) catch return null;
    var d = xz.Decompress.init(&in, a, scratch) catch return null;
    var out: std.Io.Writer.Allocating = .init(a);
    _ = d.reader.streamRemaining(&out.writer) catch return null;
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

/// Run the `--pre` command over one file (`argv = {pre, path}`) and return its
/// stdout. A spawn failure or non-zero exit is an ERROR (rg): it prints the tool's
/// stderr, latches exit 2, and drops the file (null). gist's `--pre` command reads
/// the file via its path argument (stdin is closed), the wrapper idiom rg's own
/// docs lead with (`exec gzip -dc "$1"`).
fn runPre(a: std.mem.Allocator, cfg: *const Config, pre: []const u8, disk: []const u8) ?[]const u8 {
    const res = std.process.run(a, cfg.io, .{
        .argv = &.{ pre, disk },
        .stdout_limit = .unlimited,
        .stderr_limit = .limited(64 * 1024),
    }) catch return preFail(cfg, disk, "");
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return preFail(cfg, disk, res.stderr);
    return res.stdout;
}

/// Latch the exit-2 preprocessor error and name the offending file on stderr,
/// echoing the tool's own stderr when it produced any. Returns null (drop file).
fn preFail(cfg: *const Config, disk: []const u8, tool_stderr: []const u8) ?[]const u8 {
    if (cfg.pre_error) |e| e.store(true, .seq_cst);
    if (tool_stderr.len > 0) {
        std.debug.print("gist: {s}: preprocessor command failed: {s}\n", .{ disk, std.mem.trimEnd(u8, tool_stderr, "\n") });
    } else {
        std.debug.print("gist: {s}: preprocessor command failed\n", .{disk});
    }
    return null;
}

/// Run `argv` (an external decompressor), capture stdout, and return it, or null
/// on spawn failure / non-zero exit (⇒ `decompress` passthru). stderr is bounded
/// and discarded; the arena reclaims every allocation at run teardown.
fn spawnCapture(a: std.mem.Allocator, cfg: *const Config, argv: []const []const u8) ?[]const u8 {
    const res = std.process.run(a, cfg.io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return res.stdout;
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

test "latin1 transcode: ASCII aliases, high bytes become 2-byte UTF-8" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pure ASCII returns the same backing slice (no copy).
    const ascii = "func main()";
    try t.expectEqual(ascii.ptr, latin1ToUtf8(a, ascii).ptr);
    // 0xE9 (é in Latin-1) → U+00E9 → 0xC3 0xA9.
    const got = latin1ToUtf8(a, "caf\xE9");
    try t.expectEqualStrings("caf\xC3\xA9", got);
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
