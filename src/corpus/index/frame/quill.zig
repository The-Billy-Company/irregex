//! quill — a sealed artifact written in PIECES.
//!
//! `frame.writeAtomic` needs the finished bytes in one slice, which is right for
//! a header-sized artifact and ruinous for a large one: `content.shard` is a
//! concatenation of the whole corpus, so building it in order to seal it made
//! `gist index` hold a SECOND full copy of every file it had just read —
//! measured at +1.75 GiB on a 1.9 GiB corpus, the largest single line item in
//! the build's peak. Nothing about the format wanted that. A `signet` seal
//! covers the bytes in order, so a rolling `Scribe` reaches the identical digest
//! while the bytes themselves go straight to the file as each region is
//! produced.
//!
//! Same atomicity as `writeAtomic` (temp-then-rename), same seal, no blob.

const std = @import("std");
const signet = @import("signet.zig");

/// The writer. Its cost is this struct's buffer plus whatever region is in
/// flight — never the artifact. Regions may be fed in any number of `put` calls
/// of any size; the buffer coalesces small ones, so a 175k-document body run
/// does not become 175k `write` syscalls.
///
/// Failure semantics match `frame.writeAtomic`: the destination is replaced only
/// by `seal`, so an abandoned `Quill` (any error, or a `deinit` without `seal`)
/// leaves the previous artifact exactly as it was.
pub const Quill = struct {
    af: std.Io.File.Atomic,
    scribe: signet.Scribe,
    held: usize = 0,
    /// Sized to amortize the syscall over many small regions without becoming a
    /// memory line item itself. 64 KiB is where the per-write cost stops being
    /// visible against the page-cache write it turns into.
    buf: [64 * 1024]u8 = undefined,

    /// Begin a sealed artifact at `sub_path`. Nothing at that path changes until
    /// `seal`.
    pub fn init(io: std.Io, sub_path: []const u8) !Quill {
        return .{
            .af = try std.Io.Dir.cwd().createFileAtomic(io, sub_path, .{ .make_path = true, .replace = true }),
            .scribe = .init(.artifact),
        };
    }

    /// Add `bytes` to the artifact and to its seal.
    pub fn put(q: *Quill, io: std.Io, bytes: []const u8) !void {
        q.scribe.update(bytes);
        // A region at or past the buffer's size gains nothing from a copy: flush
        // what is held (order matters) and hand the rest straight to the file.
        if (bytes.len >= q.buf.len) {
            try q.flush(io);
            return q.af.file.writeStreamingAll(io, bytes);
        }
        if (q.held + bytes.len > q.buf.len) try q.flush(io);
        @memcpy(q.buf[q.held..][0..bytes.len], bytes);
        q.held += bytes.len;
    }

    /// A little-endian fixed-width int, the `putInt` shape as a region.
    pub fn putInt(q: *Quill, io: std.Io, comptime T: type, v: T) !void {
        var scratch: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
        std.mem.writeInt(T, &scratch, v, .little);
        return q.put(io, &scratch);
    }

    /// Append the seal over everything written and atomically replace the
    /// destination. The `Quill` is spent either way.
    pub fn seal(q: *Quill, io: std.Io) !void {
        const mark = q.scribe.finish();
        try q.put(io, &mark.bytes);
        try q.flush(io);
        try q.af.replace(io);
    }

    /// Release the temp file without publishing it. Safe after `seal`, which is
    /// why every caller can `defer` it.
    pub fn deinit(q: *Quill, io: std.Io) void {
        q.af.deinit(io);
    }

    fn flush(q: *Quill, io: std.Io) !void {
        if (q.held == 0) return;
        const held = q.held;
        // Cleared BEFORE the write, so a failed flush cannot re-emit these bytes
        // on a later attempt and desynchronize the file from the seal.
        q.held = 0;
        try q.af.file.writeStreamingAll(io, q.buf[0..held]);
    }
};
