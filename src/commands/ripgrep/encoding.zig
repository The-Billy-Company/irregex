// MONOLITHIC: WHATWG encoding decoders — per-codec streaming state machines (gb18030, big5, euc-jp, shift_jis, …) share label resolution and one dispatch; each codec is a section, not a module
//! gist `rg` — the `-E`/`--encoding` legacy-code-page decoders (WHATWG Encoding Standard).
//!
//! ripgrep transcodes a file's source encoding to UTF-8 (via encoding_rs) before
//! matching, so a UTF-8 pattern hits regardless of the on-disk code page. This
//! module is gist's decode-side equivalent: the full WHATWG label table (`fromLabel`,
//! generated from `encodings.json`) plus a faithful decoder for every WHATWG legacy
//! encoding — the single-byte pages, the CJK multi-byte pages (gb18030/GBK, Big5,
//! EUC-JP, Shift_JIS, EUC-KR), stateful ISO-2022-JP, and the `replacement` /
//! `x-user-defined` specials. The `auto`/`none`/UTF-8/UTF-16 paths stay in
//! `ingest.zig` (they share the BOM-sniff fast path with the untransformed read);
//! everything else routes here through `decode`.
//!
//! The pointer→code-point tables are generated into `encoding_tables.gen.zig` from
//! the pinned WHATWG indexes (`tools/whatwg/`, provenance in its README). Decoding
//! is lossy (a malformed byte sequence becomes U+FFFD), matching encoding_rs's
//! "replacement" error mode, which is what ripgrep uses. The decoders implement the
//! spec's "restore to the queue" anti-masking rule — a truncated lead byte followed
//! by an ASCII byte yields U+FFFD *and* the ASCII byte, so an illegal combination can
//! never mask a U+0000..U+007F delimiter (Encoding Standard §1, security).
//!
//! Spec: https://encoding.spec.whatwg.org/ (§9 single-byte, §10 gb18030, §11 Big5,
//! §12 Japanese, §13 EUC-KR, §14 misc). Prior art: encoding_rs (Hsivonen), the
//! decoder Rust's regex tooling and ripgrep ride.

const std = @import("std");
const gen = @import("encoding_tables.gen.zig");

/// The resolved `-E`/`--encoding` source encoding. `auto`/`none`/the UTF families
/// are consumed by `ingest.zig`; the remaining variants are the WHATWG legacy
/// encodings this module decodes. Label→variant resolution is `fromLabel`.
pub const Encoding = enum {
    auto,
    none,
    utf8,
    utf16,
    utf16le,
    utf16be,
    // single-byte (§9) — windows-1252 subsumes ISO-8859-1/ASCII, windows-1254
    // ISO-8859-9, windows-874 ISO-8859-11/TIS-620, iso_8859_8 also ISO-8859-8-I.
    ibm866,
    iso_8859_2,
    iso_8859_3,
    iso_8859_4,
    iso_8859_5,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_10,
    iso_8859_13,
    iso_8859_14,
    iso_8859_15,
    iso_8859_16,
    koi8_r,
    koi8_u,
    macintosh,
    windows_874,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1253,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,
    x_mac_cyrillic,
    // multi-byte CJK + specials
    gb18030, // GBK decodes through this (§10.1.1)
    big5,
    euc_jp,
    iso_2022_jp,
    shift_jis,
    euc_kr,
    replacement,
    x_user_defined,
};

fn oom() noreturn {
    std.debug.print("oom\n", .{});
    std.process.exit(2);
}

// ─────────────────────────── label resolution ───────────────────────────

/// Resolve an `-E`/`--encoding` label to an `Encoding`, or null for an unrecognized
/// one (the caller fails loud). Implements WHATWG "get an encoding": strip leading
/// and trailing ASCII whitespace, ASCII-lowercase, then match the label table
/// (encoding_rs's `for_label`, which ripgrep uses). `auto`/`none` are gist's own
/// pre-WHATWG spellings for BOM-sniff / passthrough.
///
/// `gen.labels` is emitted sorted by label, so a runtime binary search resolves it
/// with no comptime map (a ~230-key `StaticStringMap` blows the comptime sort's
/// branch budget and dwarfs the build time). Label resolution runs once per
/// invocation, so O(log n) string compares are free.
pub fn fromLabel(s: []const u8) ?Encoding {
    const trimmed = std.mem.trim(u8, s, "\t\n\x0c\r ");
    if (trimmed.len == 0 or trimmed.len > 64) return null;
    var lower: [64]u8 = undefined;
    for (trimmed, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const key = lower[0..trimmed.len];
    if (std.mem.eql(u8, key, "auto")) return .auto;
    if (std.mem.eql(u8, key, "none")) return .none;
    var lo: usize = 0;
    var hi: usize = gen.labels.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, gen.labels[mid].label, key)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return std.meta.stringToEnum(Encoding, gen.labels[mid].tag),
        }
    }
    return null;
}

// ─────────────────────────── table accessors ───────────────────────────

fn u16at(blob: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, blob[i * 2 ..][0..2], .little);
}
fn u32at(blob: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, blob[i * 4 ..][0..4], .little);
}

/// `index code point for pointer` over a u16 blob of `len` entries; null when the
/// pointer is out of range or maps to nothing (0 sentinel — no index maps to U+0000).
fn cp16(blob: []const u8, len: usize, pointer: usize) ?u21 {
    if (pointer >= len) return null;
    const v = u16at(blob, pointer);
    return if (v == 0) null else v;
}

/// Big5 is the one index reaching the supplementary planes, so it is stored u32.
fn cpBig5(pointer: usize) ?u21 {
    if (pointer >= gen.big5_len) return null;
    const v = u32at(gen.big5, pointer);
    return if (v == 0) null else @intCast(v);
}

/// The single-byte index for one variant (byte 0x80..0xFF → code point), or null
/// for the non-single-byte variants (which `decode` dispatches before this).
fn singleTable(enc: Encoding) ?[]const u8 {
    return switch (enc) {
        .ibm866 => gen.sb_ibm866,
        .iso_8859_2 => gen.sb_iso_8859_2,
        .iso_8859_3 => gen.sb_iso_8859_3,
        .iso_8859_4 => gen.sb_iso_8859_4,
        .iso_8859_5 => gen.sb_iso_8859_5,
        .iso_8859_6 => gen.sb_iso_8859_6,
        .iso_8859_7 => gen.sb_iso_8859_7,
        .iso_8859_8 => gen.sb_iso_8859_8,
        .iso_8859_10 => gen.sb_iso_8859_10,
        .iso_8859_13 => gen.sb_iso_8859_13,
        .iso_8859_14 => gen.sb_iso_8859_14,
        .iso_8859_15 => gen.sb_iso_8859_15,
        .iso_8859_16 => gen.sb_iso_8859_16,
        .koi8_r => gen.sb_koi8_r,
        .koi8_u => gen.sb_koi8_u,
        .macintosh => gen.sb_macintosh,
        .windows_874 => gen.sb_windows_874,
        .windows_1250 => gen.sb_windows_1250,
        .windows_1251 => gen.sb_windows_1251,
        .windows_1252 => gen.sb_windows_1252,
        .windows_1253 => gen.sb_windows_1253,
        .windows_1254 => gen.sb_windows_1254,
        .windows_1255 => gen.sb_windows_1255,
        .windows_1256 => gen.sb_windows_1256,
        .windows_1257 => gen.sb_windows_1257,
        .windows_1258 => gen.sb_windows_1258,
        .x_mac_cyrillic => gen.sb_x_mac_cyrillic,
        else => null,
    };
}

// ─────────────────────────── output sink + input queue ───────────────────────────

/// Accumulates decoded UTF-8. `cp` appends one scalar; `err` appends U+FFFD (the
/// lossy substitute encoding_rs/ripgrep emit for a malformed sequence).
const Sink = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn cp(self: *Sink, c: u21) void {
        if (c < 0x80) {
            self.out.append(self.a, @intCast(c)) catch oom();
            return;
        }
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &enc) catch {
            self.err();
            return;
        };
        self.out.appendSlice(self.a, enc[0..n]) catch oom();
    }
    fn err(self: *Sink) void {
        self.out.appendSlice(self.a, "\xEF\xBF\xBD") catch oom();
    }
    fn slice(self: *Sink) []const u8 {
        return self.out.toOwnedSlice(self.a) catch oom();
    }
};

/// A byte queue with a small pushback stack, modeling the WHATWG I/O queue: a
/// decoder that hits an illegal combination `restore`s the bytes it over-read so
/// they are re-decoded fresh (the anti-masking rule). Restores are ≤ 3 bytes and
/// drained before the next one, so a 4-slot stack is exact.
const Queue = struct {
    in: []const u8,
    pos: usize = 0,
    pb: [4]u8 = undefined,
    pbn: usize = 0,

    fn next(self: *Queue) ?u8 {
        if (self.pbn > 0) {
            self.pbn -= 1;
            return self.pb[self.pbn];
        }
        if (self.pos < self.in.len) {
            defer self.pos += 1;
            return self.in[self.pos];
        }
        return null;
    }
    fn restore1(self: *Queue, b: u8) void {
        self.pb[self.pbn] = b;
        self.pbn += 1;
    }
    fn restore2(self: *Queue, a1: u8, b: u8) void {
        self.pb[self.pbn] = b;
        self.pb[self.pbn + 1] = a1;
        self.pbn += 2;
    }
    fn restore3(self: *Queue, a1: u8, a2: u8, b: u8) void {
        self.pb[self.pbn] = b;
        self.pb[self.pbn + 1] = a2;
        self.pb[self.pbn + 2] = a1;
        self.pbn += 3;
    }
};

// ─────────────────────────── dispatch ───────────────────────────

/// Transcode `buf` from a legacy WHATWG encoding to UTF-8. Only the non-UTF, non-auto
/// variants reach here (`ingest.zig` owns `auto`/`none`/UTF-8/UTF-16). Every legacy
/// decoder maps ASCII to itself with no lead state, so an ASCII-clean buffer aliases
/// straight through with no allocation (the common source-tree case) — except
/// `replacement`, which errors on any input, and ISO-2022-JP, whose ESC (0x1B) is an
/// in-band control.
pub fn decode(a: std.mem.Allocator, enc: Encoding, buf: []const u8) []const u8 {
    if (enc != .replacement and asciiClean(enc, buf)) return buf;
    return switch (enc) {
        .x_user_defined => xUserDefined(a, buf),
        .replacement => if (buf.len == 0) buf else "\xEF\xBF\xBD",
        .gb18030 => gb18030(a, buf),
        .big5 => big5(a, buf),
        .euc_jp => eucJp(a, buf),
        .shift_jis => shiftJis(a, buf),
        .euc_kr => eucKr(a, buf),
        .iso_2022_jp => iso2022jp(a, buf),
        else => singleByte(a, singleTable(enc).?, buf),
    };
}

fn asciiClean(enc: Encoding, buf: []const u8) bool {
    for (buf) |b| {
        if (b >= 0x80) return false;
        if (enc == .iso_2022_jp and b == 0x1B) return false;
    }
    return true;
}

// ─────────────────────────── single-byte + algorithmic ───────────────────────────

/// WHATWG single-byte decoder (§9.1): ASCII passes through; a high byte indexes the
/// 128-entry table (byte − 0x80), an undefined slot yielding U+FFFD.
fn singleByte(a: std.mem.Allocator, table: []const u8, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    s.out.ensureTotalCapacity(a, buf.len) catch oom();
    for (buf) |b| {
        if (b < 0x80) {
            s.out.appendAssumeCapacity(b);
        } else if (cp16(table, 128, b - 0x80)) |c| {
            s.cp(c);
        } else s.err();
    }
    return s.slice();
}

/// x-user-defined decoder (§14.5.1): ASCII passes through; a high byte maps to the
/// Private Use area at 0xF780 + (byte − 0x80).
fn xUserDefined(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    s.out.ensureTotalCapacity(a, buf.len) catch oom();
    for (buf) |b| {
        if (b < 0x80) s.out.appendAssumeCapacity(b) else s.cp(@as(u21, 0xF780) + b - 0x80);
    }
    return s.slice();
}

// ─────────────────────────── gb18030 / GBK (§10.2.1) ───────────────────────────

/// `index gb18030 ranges code point for pointer` (§5): the four-byte code point,
/// or null outside the encodable ranges. The ranges blob is pointer-sorted
/// (pointer, code point) u32 pairs; a binary search finds the covering range.
fn gbRangesCp(pointer: u32) ?u21 {
    if ((pointer > 39419 and pointer < 189000) or pointer > 1237575) return null;
    if (pointer == 7457) return 0xE7C7;
    const n = gen.gb18030_ranges_len / 2;
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) { // first range whose pointer is strictly greater than `pointer`
        const mid = lo + (hi - lo) / 2;
        if (u32at(gen.gb18030_ranges, mid * 2) <= pointer) lo = mid + 1 else hi = mid;
    }
    const idx = lo - 1; // the last range at or below `pointer` (range 0 covers pointer 0)
    const base_ptr = u32at(gen.gb18030_ranges, idx * 2);
    const base_cp = u32at(gen.gb18030_ranges, idx * 2 + 1);
    return @intCast(base_cp + (pointer - base_ptr));
}

fn gb18030(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var first: u8 = 0;
    var second: u8 = 0;
    var third: u8 = 0;
    while (q.next()) |b| {
        if (third != 0) {
            if (b < 0x30 or b > 0x39) {
                q.restore3(second, third, b);
                first = 0;
                second = 0;
                third = 0;
                s.err();
                continue;
            }
            const pointer = (@as(u32, first) - 0x81) * (10 * 126 * 10) +
                (@as(u32, second) - 0x30) * (10 * 126) +
                (@as(u32, third) - 0x81) * 10 + (@as(u32, b) - 0x30);
            first = 0;
            second = 0;
            third = 0;
            if (gbRangesCp(pointer)) |c| s.cp(c) else s.err();
            continue;
        }
        if (second != 0) {
            if (b >= 0x81 and b <= 0xFE) {
                third = b;
                continue;
            }
            q.restore2(second, b);
            first = 0;
            second = 0;
            s.err();
            continue;
        }
        if (first != 0) {
            if (b >= 0x30 and b <= 0x39) {
                second = b;
                continue;
            }
            const leading = first;
            first = 0;
            const offset: u32 = if (b < 0x7F) 0x40 else 0x41;
            const pointer: ?u32 = if ((b >= 0x40 and b <= 0x7E) or (b >= 0x80 and b <= 0xFE))
                (@as(u32, leading) - 0x81) * 190 + (@as(u32, b) - offset)
            else
                null;
            if (pointer) |p| {
                if (cp16(gen.gb18030, gen.gb18030_len, p)) |c| {
                    s.cp(c);
                    continue;
                }
            }
            if (b < 0x80) q.restore1(b);
            s.err();
            continue;
        }
        if (b < 0x80) {
            s.out.append(a, b) catch oom();
        } else if (b == 0x80) {
            s.cp(0x20AC);
        } else if (b >= 0x81 and b <= 0xFE) {
            first = b;
        } else s.err();
    }
    if (first != 0 or second != 0 or third != 0) s.err();
    return s.slice();
}

// ─────────────────────────── Big5 (§11.1.1) ───────────────────────────

fn big5(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var lead: u8 = 0;
    while (q.next()) |b| {
        if (lead != 0) {
            const l = lead;
            lead = 0;
            const offset: u32 = if (b < 0x7F) 0x40 else 0x62;
            const pointer: ?u32 = if ((b >= 0x40 and b <= 0x7E) or (b >= 0xA1 and b <= 0xFE))
                (@as(u32, l) - 0x81) * 157 + (@as(u32, b) - offset)
            else
                null;
            if (pointer) |p| {
                // Four pointers decode to a base letter + combining mark pair
                // (indexes hold single code points, so the spec tables them).
                const pair: ?[2]u21 = switch (p) {
                    1133 => .{ 0x00CA, 0x0304 },
                    1135 => .{ 0x00CA, 0x030C },
                    1164 => .{ 0x00EA, 0x0304 },
                    1166 => .{ 0x00EA, 0x030C },
                    else => null,
                };
                if (pair) |two| {
                    s.cp(two[0]);
                    s.cp(two[1]);
                    continue;
                }
                if (cpBig5(p)) |c| {
                    s.cp(c);
                    continue;
                }
            }
            if (b < 0x80) q.restore1(b);
            s.err();
            continue;
        }
        if (b < 0x80) {
            s.out.append(a, b) catch oom();
        } else if (b >= 0x81 and b <= 0xFE) {
            lead = b;
        } else s.err();
    }
    if (lead != 0) s.err();
    return s.slice();
}

// ─────────────────────────── EUC-JP (§12.1.1) ───────────────────────────

fn eucJp(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var jis0212 = false;
    var lead: u8 = 0;
    while (q.next()) |b| {
        if (lead == 0x8E and b >= 0xA1 and b <= 0xDF) {
            lead = 0;
            s.cp(@as(u21, 0xFF61) - 0xA1 + b);
            continue;
        }
        if (lead == 0x8F and b >= 0xA1 and b <= 0xFE) {
            jis0212 = true;
            lead = b;
            continue;
        }
        if (lead != 0) {
            const l = lead;
            lead = 0;
            var c: ?u21 = null;
            if (l >= 0xA1 and l <= 0xFE and b >= 0xA1 and b <= 0xFE) {
                const pointer = (@as(usize, l) - 0xA1) * 94 + (@as(usize, b) - 0xA1);
                c = if (jis0212) cp16(gen.jis0212, gen.jis0212_len, pointer) else cp16(gen.jis0208, gen.jis0208_len, pointer);
            }
            jis0212 = false;
            if (c) |cc| {
                s.cp(cc);
                continue;
            }
            if (b < 0x80) q.restore1(b);
            s.err();
            continue;
        }
        if (b < 0x80) {
            s.out.append(a, b) catch oom();
        } else if (b == 0x8E or b == 0x8F or (b >= 0xA1 and b <= 0xFE)) {
            lead = b;
        } else s.err();
    }
    if (lead != 0) s.err();
    return s.slice();
}

// ─────────────────────────── Shift_JIS (§12.3.1) ───────────────────────────

fn shiftJis(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var lead: u8 = 0;
    while (q.next()) |b| {
        if (lead != 0) {
            const l = lead;
            lead = 0;
            const offset: u32 = if (b < 0x7F) 0x40 else 0x41;
            const lead_offset: u32 = if (l < 0xA0) 0x81 else 0xC1;
            const pointer: ?u32 = if ((b >= 0x40 and b <= 0x7E) or (b >= 0x80 and b <= 0xFC))
                (@as(u32, l) - lead_offset) * 188 + (@as(u32, b) - offset)
            else
                null;
            if (pointer) |p| {
                if (p >= 8836 and p <= 10715) { // EUDC Private Use range (Windows legacy)
                    s.cp(@intCast(@as(u32, 0xE000) - 8836 + p));
                    continue;
                }
                if (cp16(gen.jis0208, gen.jis0208_len, p)) |c| {
                    s.cp(c);
                    continue;
                }
            }
            if (b < 0x80) q.restore1(b);
            s.err();
            continue;
        }
        if (b < 0x80 or b == 0x80) {
            s.cp(b);
        } else if (b >= 0xA1 and b <= 0xDF) {
            s.cp(@as(u21, 0xFF61) - 0xA1 + b);
        } else if ((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC)) {
            lead = b;
        } else s.err();
    }
    if (lead != 0) s.err();
    return s.slice();
}

// ─────────────────────────── EUC-KR (§13.1.1) ───────────────────────────

fn eucKr(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var lead: u8 = 0;
    while (q.next()) |b| {
        if (lead != 0) {
            const l = lead;
            lead = 0;
            const pointer: ?u32 = if (b >= 0x41 and b <= 0xFE)
                (@as(u32, l) - 0x81) * 190 + (@as(u32, b) - 0x41)
            else
                null;
            if (pointer) |p| {
                if (cp16(gen.euc_kr, gen.euc_kr_len, p)) |c| {
                    s.cp(c);
                    continue;
                }
            }
            if (b < 0x80) q.restore1(b);
            s.err();
            continue;
        }
        if (b < 0x80) {
            s.out.append(a, b) catch oom();
        } else if (b >= 0x81 and b <= 0xFE) {
            lead = b;
        } else s.err();
    }
    if (lead != 0) s.err();
    return s.slice();
}

// ─────────────────────────── ISO-2022-JP (§12.2.1) ───────────────────────────

const IsoState = enum { ascii, roman, katakana, leading, trailing, escape_start, escape };

/// ISO-2022-JP is the one stateful decoder: ESC (0x1B) sequences switch between
/// ASCII, JIS X 0201 Roman/katakana, and JIS X 0208 double-byte modes. The escape
/// states can over-read at end-of-queue and must restore, so this drives the queue
/// with an explicit end-of-queue item rather than the `while (next)` shape.
fn iso2022jp(a: std.mem.Allocator, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var state: IsoState = .ascii;
    var out_state: IsoState = .ascii;
    var lead: u8 = 0;
    var output = false;
    while (true) {
        const item = q.next();
        switch (state) {
            .ascii => {
                const b = item orelse break;
                if (b == 0x1B) {
                    state = .escape_start;
                } else if (b <= 0x7F and b != 0x0E and b != 0x0F) {
                    output = false;
                    s.cp(b);
                } else {
                    output = false;
                    s.err();
                }
            },
            .roman => {
                const b = item orelse break;
                switch (b) {
                    0x1B => state = .escape_start,
                    0x5C => {
                        output = false;
                        s.cp(0x00A5);
                    },
                    0x7E => {
                        output = false;
                        s.cp(0x203E);
                    },
                    0x0E, 0x0F => {
                        output = false;
                        s.err();
                    },
                    else => {
                        if (b <= 0x7F) {
                            output = false;
                            s.cp(b);
                        } else {
                            output = false;
                            s.err();
                        }
                    },
                }
            },
            .katakana => {
                const b = item orelse break;
                if (b == 0x1B) {
                    state = .escape_start;
                } else if (b >= 0x21 and b <= 0x5F) {
                    output = false;
                    s.cp(@as(u21, 0xFF61) - 0x21 + b);
                } else {
                    output = false;
                    s.err();
                }
            },
            .leading => {
                const b = item orelse break;
                if (b == 0x1B) {
                    state = .escape_start;
                } else if (b >= 0x21 and b <= 0x7E) {
                    output = false;
                    lead = b;
                    state = .trailing;
                } else {
                    output = false;
                    s.err();
                }
            },
            .trailing => {
                const b = item orelse {
                    state = .leading;
                    s.err();
                    continue;
                };
                if (b == 0x1B) {
                    state = .escape_start;
                    s.err();
                } else if (b >= 0x21 and b <= 0x7E) {
                    state = .leading;
                    const pointer = (@as(usize, lead) - 0x21) * 94 + (@as(usize, b) - 0x21);
                    if (cp16(gen.jis0208, gen.jis0208_len, pointer)) |c| s.cp(c) else s.err();
                } else {
                    state = .leading;
                    s.err();
                }
            },
            .escape_start => {
                if (item) |b| {
                    if (b == 0x24 or b == 0x28) {
                        lead = b;
                        state = .escape;
                        continue;
                    }
                    q.restore1(b);
                }
                output = false;
                state = out_state;
                s.err();
            },
            .escape => {
                const l = lead;
                lead = 0;
                const newstate: ?IsoState = if (item) |b| switch (l) {
                    0x28 => switch (b) {
                        0x42 => .ascii,
                        0x4A => .roman,
                        0x49 => .katakana,
                        else => null,
                    },
                    0x24 => if (b == 0x40 or b == 0x42) .leading else null,
                    else => null,
                } else null;
                if (newstate) |ns| {
                    state = ns;
                    out_state = ns;
                    const was = output;
                    output = true;
                    if (was) s.err();
                } else {
                    if (item) |b| q.restore2(l, b) else q.restore1(l);
                    output = false;
                    state = out_state;
                    s.err();
                }
            },
        }
    }
    return s.slice();
}

// ─────────────────────────── tests ───────────────────────────

test "fromLabel: WHATWG aliases resolve, latin1 is windows-1252, junk is null" {
    const t = std.testing;
    try t.expectEqual(Encoding.gb18030, fromLabel("gbk").?);
    try t.expectEqual(Encoding.gb18030, fromLabel("GBK").?);
    try t.expectEqual(Encoding.gb18030, fromLabel("gb18030").?);
    try t.expectEqual(Encoding.shift_jis, fromLabel("sjis").?);
    try t.expectEqual(Encoding.shift_jis, fromLabel("Shift_JIS").?);
    try t.expectEqual(Encoding.euc_jp, fromLabel("euc-jp").?);
    try t.expectEqual(Encoding.euc_kr, fromLabel("korean").?);
    try t.expectEqual(Encoding.big5, fromLabel("big5-hkscs").?);
    try t.expectEqual(Encoding.iso_2022_jp, fromLabel("csiso2022jp").?);
    // WHATWG folds ISO-8859-1 / latin1 / us-ascii into windows-1252.
    try t.expectEqual(Encoding.windows_1252, fromLabel("latin1").?);
    try t.expectEqual(Encoding.windows_1252, fromLabel("iso-8859-1").?);
    try t.expectEqual(Encoding.windows_1252, fromLabel("us-ascii").?);
    // ISO-8859-9 is windows-1254; TIS-620 is windows-874.
    try t.expectEqual(Encoding.windows_1254, fromLabel("iso-8859-9").?);
    try t.expectEqual(Encoding.windows_874, fromLabel("tis-620").?);
    // gist's own spellings + surrounding-whitespace trim (WHATWG get-an-encoding).
    try t.expectEqual(Encoding.auto, fromLabel("auto").?);
    try t.expectEqual(Encoding.none, fromLabel("none").?);
    try t.expectEqual(Encoding.euc_jp, fromLabel("  EUC-JP\n").?);
    try t.expectEqual(@as(?Encoding, null), fromLabel("definitely-not-an-encoding"));
}

test "single-byte: ascii aliases, high bytes index the table, undefined → U+FFFD" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // windows-1252 0x80 → € (U+20AC), 0xE9 → é (U+00E9). Byte 0x81 is NOT
    // undefined under WHATWG (encoding_rs / rg): it maps to the C1 control U+0081
    // (\xC2\x81) — the parity point vs Microsoft's best-fit table, which drops it.
    try t.expectEqualStrings("\xE2\x82\xAC", decode(a, .windows_1252, "\x80"));
    try t.expectEqualStrings("caf\xC3\xA9", decode(a, .windows_1252, "caf\xE9"));
    try t.expectEqualStrings("\xC2\x81", decode(a, .windows_1252, "\x81"));
    // A genuinely undefined slot → U+FFFD: ISO-8859-6 (Arabic) byte 0xA1 has no
    // index row.
    try t.expectEqualStrings("\xEF\xBF\xBD", decode(a, .iso_8859_6, "\xA1"));
    // ascii-clean input aliases through with no copy.
    const ascii = "func main()";
    try t.expectEqual(ascii.ptr, decode(a, .windows_1252, ascii).ptr);
    // KOI8-R 0xC1 → а (U+0430 CYRILLIC SMALL A).
    try t.expectEqualStrings("\xD0\xB0", decode(a, .koi8_r, "\xC1"));
}

test "shift_jis / euc-jp / gbk / big5 / euc-kr decode a known CJK sequence" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 日 U+65E5 in each: Shift_JIS 93 FA, EUC-JP C6 FC, GBK C8 D5, Big5 A4 E9,
    // EUC-KR (WHATWG = CP949/UHC) EC ED.
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .shift_jis, "\x93\xFA"));
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .euc_jp, "\xC6\xFC"));
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .gb18030, "\xC8\xD5"));
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .big5, "\xA4\xE9"));
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .euc_kr, "\xEC\xED"));
    // gb18030 four-byte: 𤭢 U+24B62 encodes as 96 37 AA 34.
    try t.expectEqualStrings("\xF0\xA4\xAD\xA2", decode(a, .gb18030, "\x96\x37\xAA\x34"));
    // gb18030 lead byte 0x80 → € (U+20AC).
    try t.expectEqualStrings("\xE2\x82\xAC", decode(a, .gb18030, "\x80"));
}

test "anti-masking: a truncated lead + ASCII byte yields U+FFFD then the ASCII byte" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shift_JIS lead 0x82 then 0x22 (") must NOT mask the quote (Encoding §1 security).
    try t.expectEqualStrings("\xEF\xBF\xBD\"", decode(a, .shift_jis, "\x82\x22"));
    // EUC-KR (CP949) accepts 0x41..0xFE as a trail, so an out-of-range ASCII trail
    // (0x22 " < 0x41) is the masking case: U+FFFD then the restored quote.
    try t.expectEqualStrings("\xEF\xBF\xBD\"", decode(a, .euc_kr, "\x81\x22"));
}

test "x-user-defined maps high bytes into the Private Use area; replacement is one U+FFFD" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 0xFF → U+F780 + 0x7F = U+F7FF.
    try t.expectEqualStrings("A\xEF\x9F\xBF", decode(a, .x_user_defined, "A\xFF"));
    // replacement: any non-empty input collapses to a single U+FFFD.
    try t.expectEqualStrings("\xEF\xBF\xBD", decode(a, .replacement, "anything at all"));
    try t.expectEqualStrings("", decode(a, .replacement, ""));
}

test "ISO-2022-JP switches modes on escape sequences" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ESC $ B enters JIS X 0208; 0x467C is 日 (row/cell for U+65E5); ESC ( B back to ASCII.
    try t.expectEqualStrings("\xE6\x97\xA5", decode(a, .iso_2022_jp, "\x1B$B\x46\x7C\x1B(B"));
    // Roman mode: 0x5C → ¥ (U+00A5), 0x7E → ‾ (U+203E).
    try t.expectEqualStrings("\xC2\xA5\xE2\x80\xBE", decode(a, .iso_2022_jp, "\x1B(J\x5C\x7E\x1B(B"));
}
