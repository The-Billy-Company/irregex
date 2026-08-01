//! gist `rg` — raw bytes made legible to the matcher.
//!
//! Two steps, one answer to "what is actually being searched": the bytes are
//! normalized into matchable UTF-8 (the `auto` encoding leg `ingest.zig`
//! dispatches to — BOM sniff, UTF-16 transcode; explicit WHATWG labels go to
//! `encoding.zig` instead), then split under ripgrep's line model. That split
//! is THE definition of where a line starts and whether a trailing terminator
//! makes another — shared by both walk engines, the binary quit strategy
//! (`binary.zig`), and the warm face, so none of them can drift on the unit
//! every other per-file decision is expressed in.

const std = @import("std");
const oom = @import("../scope/paths.zig").allocFailure;

/// Strip a leading UTF-8 BOM (ripgrep transparently skips it so `^` anchors to
/// the first real byte). Downstream of `decodeBom` this is a no-op for files (the
/// BOM is already gone); it still guards the stdin path, which isn't BOM-decoded.
pub fn stripBom(buf: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, buf, "\xEF\xBB\xBF")) buf[3..] else buf;
}

/// BOM-driven encoding auto-detection, applied once per file at ingest — ripgrep's
/// default (`--encoding auto`) behavior. A UTF-8 BOM is stripped; a UTF-16 LE/BE
/// BOM transcodes the whole file to UTF-8 so the (UTF-8) pattern matches and the
/// UTF-16 NULs never trip binary detection. BOM-less UTF-16 is NOT sniffed (rg
/// needs explicit `-E utf-16` for that, which stays NA); anything else is bytes.
pub fn decodeBom(a: std.mem.Allocator, buf: []const u8) []const u8 {
    if (std.mem.startsWith(u8, buf, "\xFF\xFE")) return utf16ToUtf8(a, buf[2..], .little);
    if (std.mem.startsWith(u8, buf, "\xFE\xFF")) return utf16ToUtf8(a, buf[2..], .big);
    return stripBom(buf);
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
            const lo: u16 = if (i + 3 < bytes.len) std.mem.readInt(u16, bytes[i + 2 ..][0..2], endian) else 0;
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else cp = 0xFFFD;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD; // stray low surrogate
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch blk: {
            // U+FFFD REPLACEMENT CHARACTER — its UTF-8 encoding is a fixed 3 bytes.
            enc[0..3].* = .{ 0xEF, 0xBF, 0xBD };
            break :blk 3;
        };
        out.appendSlice(a, enc[0..n]) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

/// The legal range of the SECOND byte for a UTF-8 lead byte, plus the sequence's
/// total length — or null when the byte cannot lead one at all (`0xC0`/`0xC1`,
/// the overlong two-byte leads; `0xF5`+, past U+10FFFF; a bare continuation).
///
/// This is Unicode 16 §3.9's well-formed-byte-sequence table (the one Rust's
/// `run_utf8_validation` encodes), and the per-lead second-byte range is exactly
/// what makes a maximal subpart computable: `0xE0 0x80` is not "a three-byte
/// sequence with a bad tail" but a subpart that ENDS at the lead, so the `0x80`
/// is re-examined on its own instead of being swallowed.
fn leadRange(b: u8) ?struct { len: usize, lo: u8, hi: u8 } {
    return switch (b) {
        0x00...0x7F => .{ .len = 1, .lo = 0, .hi = 0 },
        0xC2...0xDF => .{ .len = 2, .lo = 0x80, .hi = 0xBF },
        0xE0 => .{ .len = 3, .lo = 0xA0, .hi = 0xBF }, // no overlong three-byte
        0xE1...0xEC, 0xEE, 0xEF => .{ .len = 3, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .len = 3, .lo = 0x80, .hi = 0x9F }, // no UTF-16 surrogate
        0xF0 => .{ .len = 4, .lo = 0x90, .hi = 0xBF }, // no overlong four-byte
        0xF1...0xF3 => .{ .len = 4, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .len = 4, .lo = 0x80, .hi = 0x8F }, // no codepoint past U+10FFFF
        else => null,
    };
}

/// The next sequence's length and whether it is well-formed. When it is not,
/// `len` is the MAXIMAL SUBPART — the longest prefix that could still have grown
/// into a valid sequence — so exactly one U+FFFD stands in for the whole subpart
/// (Unicode 16 §3.9, "U+FFFD Substitution of Maximal Subparts").
fn nextSequence(b: []const u8) struct { len: usize, ok: bool } {
    const r = leadRange(b[0]) orelse return .{ .len = 1, .ok = false };
    if (r.len == 1) return .{ .len = 1, .ok = true };
    if (b.len < 2 or b[1] < r.lo or b[1] > r.hi) return .{ .len = 1, .ok = false };
    var k: usize = 2;
    while (k < r.len) : (k += 1)
        if (b.len <= k or b[k] < 0x80 or b[k] > 0xBF) return .{ .len = k, .ok = false };
    return .{ .len = r.len, .ok = true };
}

/// Sanitize `buf` to well-formed UTF-8, each ill-formed maximal subpart replaced
/// by U+FFFD — the "replacement" error mode encoding_rs decodes in, and
/// therefore what ripgrep's `-E utf-8` prints where the file's bytes are not
/// actually UTF-8. Without this an explicit UTF-8 label was a pure passthrough
/// and gist emitted the raw invalid bytes where rg emitted `�`; the divergence
/// was found differentially by `gist/bench/conformance/rgsuite/fuzz.py` on a corpus of lone
/// continuation bytes.
///
/// Borrows when the bytes are already valid — which is the overwhelming case for
/// an explicit `-E utf-8`, so the common path costs one validation pass and no
/// allocation. Only a file that is genuinely ill-formed pays a copy.
pub fn utf8Lossy(a: std.mem.Allocator, buf: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(buf)) return buf;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, buf.len) catch oom();
    var i: usize = 0;
    while (i < buf.len) {
        const seq = nextSequence(buf[i..]);
        if (seq.ok) out.appendSlice(a, buf[i..][0..seq.len]) catch oom() else out.appendSlice(a, "\u{FFFD}") catch oom();
        i += seq.len;
    }
    return out.toOwnedSlice(a) catch oom();
}

/// rg line semantics: `\n` terminates; trailing `\n` yields no phantom empty
/// line; content after the last `\n` is still a line. `\r` is KEPT (ripgrep's
/// default without `--crlf`). Pre-sized from one `\n` count pass (same idiom
/// as `persist.zig`'s NUL-count split) so appending a file's lines is a single
/// allocation instead of the list's usual grow-and-copy doubling — the search
/// loop calls this once per candidate file, so the saved reallocations
/// scale with the corpus, not just one file.
pub fn collectLines(a: std.mem.Allocator, buf: []const u8, term: u8, out: *std.ArrayList([]const u8)) void {
    out.ensureUnusedCapacity(a, std.mem.count(u8, buf, &.{term}) + 1) catch oom();
    var it = std.mem.splitScalar(u8, buf, term);
    while (it.next()) |line| out.appendAssumeCapacity(line);
    // split's tail after a trailing terminator (or on empty input) is rg's phantom empty line — drop it.
    if (buf.len == 0 or buf[buf.len - 1] == term) _ = out.pop();
}
