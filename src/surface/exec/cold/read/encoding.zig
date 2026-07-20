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

// ibm866…x_mac_cyrillic below are the
// single-byte (§9) — windows-1252 subsumes ISO-8859-1/ASCII, windows-1254
// ISO-8859-9, windows-874 ISO-8859-11/TIS-620, iso_8859_8 also ISO-8859-8-I.
// gb18030…x_user_defined are the
// multi-byte CJK + specials
// (GBK decodes through this (§10.1.1) — through gb18030).
/// The resolved `-E`/`--encoding` source encoding. `auto`/`none`/the UTF families
/// are consumed by `ingest.zig`; the remaining variants are the WHATWG legacy
/// encodings this module decodes. Label→variant resolution is `fromLabel`.
pub const Encoding = enum { auto, none, utf8, utf16, utf16le, utf16be, ibm866, iso_8859_2, iso_8859_3, iso_8859_4, iso_8859_5, iso_8859_6, iso_8859_7, iso_8859_8, iso_8859_10, iso_8859_13, iso_8859_14, iso_8859_15, iso_8859_16, koi8_r, koi8_u, macintosh, windows_874, windows_1250, windows_1251, windows_1252, windows_1253, windows_1254, windows_1255, windows_1256, windows_1257, windows_1258, x_mac_cyrillic, gb18030, big5, euc_jp, iso_2022_jp, shift_jis, euc_kr, replacement, x_user_defined };

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
    const key: []const u8 = std.ascii.lowerString(&lower, trimmed);
    if (std.mem.eql(u8, key, "auto")) return .auto;
    if (std.mem.eql(u8, key, "none")) return .none;
    const idx = std.sort.binarySearch(gen.LabelEntry, &gen.labels, key, struct {
        fn cmp(k: []const u8, e: gen.LabelEntry) std.math.Order {
            return std.mem.order(u8, k, e.label);
        }
    }.cmp) orelse return null;
    return std.meta.stringToEnum(Encoding, gen.labels[idx].tag);
}

// ─────────────────────────── table accessors ───────────────────────────

fn u32at(blob: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, blob[i * 4 ..][0..4], .little);
}

/// `index code point for pointer` over a blob of `len` entries; null when the
/// pointer is out of range or maps to nothing (0 sentinel — no index maps to
/// U+0000). Entries are u16 except Big5's — the one index reaching the
/// supplementary planes, so it is stored u32.
fn cpAt(comptime T: type, blob: []const u8, len: usize, pointer: usize) ?u21 {
    if (pointer >= len) return null;
    const v = std.mem.readInt(T, blob[pointer * @sizeOf(T) ..][0..@sizeOf(T)], .little);
    return if (v == 0) null else @intCast(v);
}

/// The single-byte index for one variant (byte 0x80..0xFF → code point), or null
/// for the non-single-byte variants (which `decode` dispatches before this) —
/// each single-byte variant's tag names its generated `gen.sb_<tag>` table.
fn singleTable(enc: Encoding) ?[]const u8 {
    switch (enc) {
        inline else => |e| {
            const name = "sb_" ++ @tagName(e);
            return if (@hasDecl(gen, name)) @field(gen, name) else null;
        },
    }
}

// ─────────────────────────── output sink + input queue ───────────────────────────

/// Accumulates decoded UTF-8. `cp` appends one scalar; `err` appends U+FFFD (the
/// lossy substitute encoding_rs/ripgrep emit for a malformed sequence).
const Sink = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn cp(self: *Sink, c: u21) void {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &enc) catch return self.err();
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
        if (self.pos >= self.in.len) return null;
        defer self.pos += 1;
        return self.in[self.pos];
    }
    /// Push bytes back so `next` re-yields them in this order.
    fn restore(self: *Queue, bytes: []const u8) void {
        for (0..bytes.len) |j| self.pb[self.pbn + j] = bytes[bytes.len - 1 - j];
        self.pbn += bytes.len;
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
        .x_user_defined => singleByte(a, null, buf),
        .replacement => if (buf.len == 0) buf else "\xEF\xBF\xBD",
        .gb18030 => multiByte(Gb18030{}, a, buf),
        .big5 => multiByte(Big5{}, a, buf),
        .euc_jp => multiByte(EucJp{}, a, buf),
        .shift_jis => multiByte(ShiftJis{}, a, buf),
        .euc_kr => multiByte(EucKr{}, a, buf),
        .iso_2022_jp => iso2022jp(a, buf),
        else => singleByte(a, singleTable(enc).?, buf),
    };
}

fn asciiClean(enc: Encoding, buf: []const u8) bool {
    for (buf) |b| if (b >= 0x80 or (enc == .iso_2022_jp and b == 0x1B)) return false;
    return true;
}

// ─────────────────────────── single-byte + algorithmic ───────────────────────────

/// WHATWG single-byte decoder (§9.1): ASCII passes through; a high byte indexes the
/// 128-entry table (byte − 0x80), an undefined slot yielding U+FFFD. A null table
/// is the x-user-defined decoder (§14.5.1): a high byte maps to the Private Use
/// area at 0xF780 + (byte − 0x80). The `buf.len` reservation is a prealloc hint
/// only — high bytes expand to 2-3 UTF-8 bytes, so ASCII appends stay
/// bounds-checked (an assume-capacity append here overran the reservation).
fn singleByte(a: std.mem.Allocator, table: ?[]const u8, buf: []const u8) []const u8 {
    var s = Sink{ .a = a };
    s.out.ensureTotalCapacity(a, buf.len) catch oom();
    for (buf) |b| {
        if (b < 0x80) {
            s.out.append(a, b) catch oom();
        } else if (table) |t| {
            if (cpAt(u16, t, 128, b - 0x80)) |c| s.cp(c) else s.err();
        } else s.cp(@as(u21, 0xF780) + b - 0x80);
    }
    return s.slice();
}

// ─────────────────────────── two-byte CJK skeleton ───────────────────────────

/// One lead+trail step's outcome: `ok` emitted, `fail` applies the driver's
/// restore-to-queue rule, `rearm` re-arms the trail byte as the next lead
/// (EUC-JP's three-byte JIS X 0212 and gb18030's four-byte sequences), and
/// `errored` means the codec already restored its own over-read (gb18030's
/// multi-byte pushbacks) — the driver only emits the U+FFFD.
const Paired = enum { ok, fail, rearm, errored };

/// The WHATWG two-byte `pointer` shared by every banded CJK codec: the trail
/// byte must land in one of `trails`' `{lo, hi, offset}` bands, and the pointer
/// is `(lead − lead_base) × width + (trail − offset)` — null when the trail is
/// outside every band (the codec's `.fail`).
fn pairPointer(l: u8, b: u8, lead_base: u8, width: u32, comptime trails: []const [3]u8) ?u32 {
    inline for (trails) |t| if (b >= t[0] and b <= t[1])
        return (@as(u32, l) - lead_base) * width + (b - t[2]);
    return null;
}

/// Emit `index code point for pointer` through the sink, or report the pair
/// failed (an unmapped pointer) — the tail every table-backed codec shares.
fn emitTable(comptime T: type, blob: []const u8, len: usize, s: *Sink, p: u32) Paired {
    s.cp(cpAt(T, blob, len, p) orelse return .fail);
    return .ok;
}

/// The WHATWG multi-byte decode loop shared by gb18030/GBK (§10.2.1), Big5
/// (§11.1.1), EUC-JP (§12.1.1), Shift_JIS (§12.3.1), and EUC-KR (§13.1.1): ASCII
/// passes through, a `codec.isLead` byte arms, `codec.pair` maps lead+trail, and
/// a failed pair yields U+FFFD after restoring an ASCII trail so it can never be
/// masked. A codec may carry decoder state (EUC-JP's JIS X 0212 flag, gb18030's
/// pending four-byte prefix) and an optional `single` hook for the extra bytes
/// it maps directly (Shift_JIS's 0x80 and half-width katakana, gb18030's €).
fn multiByte(codec: anytype, a: std.mem.Allocator, buf: []const u8) []const u8 {
    var c = codec;
    var s = Sink{ .a = a };
    var q = Queue{ .in = buf };
    var lead: u8 = 0;
    while (q.next()) |b| {
        if (lead != 0) {
            const l = lead;
            lead = 0;
            switch (c.pair(&s, &q, l, b)) {
                .ok => {},
                .rearm => lead = b,
                .errored => s.err(),
                .fail => {
                    if (b < 0x80) q.restore(&.{b});
                    s.err();
                },
            }
            continue;
        }
        if (comptime @hasDecl(@TypeOf(c), "single")) {
            if (c.single(&s, b)) continue;
        } else if (b < 0x80) {
            s.cp(b);
            continue;
        }
        if (c.isLead(b)) lead = b else s.err();
    }
    if (lead != 0) s.err();
    return s.slice();
}

// ─────────────────────────── Big5 (§11.1.1) ───────────────────────────

const Big5 = struct {
    // Four pointers decode to a base letter + combining mark pair
    // (indexes hold single code points, so the spec tables them).
    const double = [_][3]u21{ .{ 1133, 0x00CA, 0x0304 }, .{ 1135, 0x00CA, 0x030C }, .{ 1164, 0x00EA, 0x0304 }, .{ 1166, 0x00EA, 0x030C } };

    fn isLead(_: @This(), b: u8) bool {
        return b >= 0x81 and b <= 0xFE;
    }
    fn pair(_: @This(), s: *Sink, _: *Queue, l: u8, b: u8) Paired {
        const p = pairPointer(l, b, 0x81, 157, &.{ .{ 0x40, 0x7E, 0x40 }, .{ 0xA1, 0xFE, 0x62 } }) orelse return .fail;
        for (double) |d| if (p == d[0]) {
            s.cp(d[1]);
            s.cp(d[2]);
            return .ok;
        };
        return emitTable(u32, gen.big5, gen.big5_len, s, p);
    }
};

// ─────────────────────────── EUC-JP (§12.1.1) ───────────────────────────

const EucJp = struct {
    jis0212: bool = false,

    fn isLead(_: @This(), b: u8) bool {
        return b == 0x8E or b == 0x8F or (b >= 0xA1 and b <= 0xFE);
    }
    fn pair(self: *@This(), s: *Sink, _: *Queue, l: u8, b: u8) Paired {
        if (l == 0x8E and b >= 0xA1 and b <= 0xDF) {
            s.cp(@as(u21, 0xFF61) - 0xA1 + b);
            return .ok;
        }
        if (l == 0x8F and b >= 0xA1 and b <= 0xFE) {
            self.jis0212 = true;
            return .rearm;
        }
        const in0212 = self.jis0212;
        self.jis0212 = false;
        if (l < 0xA1) return .fail;
        const p = pairPointer(l, b, 0xA1, 94, &.{.{ 0xA1, 0xFE, 0xA1 }}) orelse return .fail;
        return if (in0212) emitTable(u16, gen.jis0212, gen.jis0212_len, s, p) else emitTable(u16, gen.jis0208, gen.jis0208_len, s, p);
    }
};

// ─────────────────────────── Shift_JIS (§12.3.1) ───────────────────────────

const ShiftJis = struct {
    fn single(_: @This(), s: *Sink, b: u8) bool {
        if (b <= 0x80) {
            s.cp(b);
        } else if (b >= 0xA1 and b <= 0xDF) {
            s.cp(@as(u21, 0xFF61) - 0xA1 + b);
        } else return false;
        return true;
    }
    fn isLead(_: @This(), b: u8) bool {
        return (b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC);
    }
    fn pair(_: @This(), s: *Sink, _: *Queue, l: u8, b: u8) Paired {
        const p = pairPointer(l, b, if (l < 0xA0) 0x81 else 0xC1, 188, &.{ .{ 0x40, 0x7E, 0x40 }, .{ 0x80, 0xFC, 0x41 } }) orelse return .fail;
        if (p >= 8836 and p <= 10715) { // EUDC Private Use range (Windows legacy)
            s.cp(@intCast(@as(u32, 0xE000) - 8836 + p));
            return .ok;
        }
        return emitTable(u16, gen.jis0208, gen.jis0208_len, s, p);
    }
};

// ─────────────────────────── EUC-KR (§13.1.1) ───────────────────────────

const EucKr = struct {
    fn isLead(_: @This(), b: u8) bool {
        return b >= 0x81 and b <= 0xFE;
    }
    fn pair(_: @This(), s: *Sink, _: *Queue, l: u8, b: u8) Paired {
        const p = pairPointer(l, b, 0x81, 190, &.{.{ 0x41, 0xFE, 0x41 }}) orelse return .fail;
        return emitTable(u16, gen.euc_kr, gen.euc_kr_len, s, p);
    }
};

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

/// gb18030 rides the shared driver with a pending four-byte prefix: a lead + digit
/// opens a FOUR-byte sequence (§10.2.1), threaded through `.rearm` (`first` holds
/// the 0x81..0xFE lead, `second` the first digit; 0 = unset — neither band
/// contains 0), so the codec restores its own multi-byte over-reads.
const Gb18030 = struct {
    first: u8 = 0,
    second: u8 = 0,

    fn single(_: @This(), s: *Sink, b: u8) bool {
        if (b < 0x80) s.cp(b) else if (b == 0x80) s.cp(0x20AC) else return false;
        return true;
    }
    fn isLead(_: @This(), b: u8) bool {
        return b >= 0x81 and b <= 0xFE;
    }
    fn pair(self: *@This(), s: *Sink, q: *Queue, l: u8, b: u8) Paired {
        if (self.first == 0) { // l is a fresh lead: digit opens four-byte, else the two-byte GBK leg
            if (b >= 0x30 and b <= 0x39) {
                self.first = l;
                return .rearm;
            }
            const p = pairPointer(l, b, 0x81, 190, &.{ .{ 0x40, 0x7E, 0x40 }, .{ 0x80, 0xFE, 0x41 } }) orelse return .fail;
            return emitTable(u16, gen.gb18030, gen.gb18030_len, s, p);
        }
        if (self.second == 0) { // l is the first digit; a 0x81..0xFE third byte keeps the sequence alive
            if (b >= 0x81 and b <= 0xFE) {
                self.second = l;
                return .rearm;
            }
            self.first = 0;
            q.restore(&.{ l, b });
            return .errored;
        }
        const f = self.first; // l is the third byte; b must close with a digit
        const sec = self.second;
        self.first = 0;
        self.second = 0;
        if (b < 0x30 or b > 0x39) {
            q.restore(&.{ sec, l, b });
            return .errored;
        }
        const pointer = (@as(u32, f) - 0x81) * (10 * 126 * 10) +
            (@as(u32, sec) - 0x30) * (10 * 126) +
            (@as(u32, l) - 0x81) * 10 + (@as(u32, b) - 0x30);
        s.cp(gbRangesCp(pointer) orelse return .errored);
        return .ok;
    }
};

// ─────────────────────────── ISO-2022-JP (§12.2.1) ───────────────────────────

const IsoState = enum { ascii, roman, katakana, leading, trailing, escape_start, escape };

/// The recognized ESC sequences: `ESC ( B/J/I` (ASCII / JIS X 0201 Roman /
/// katakana) and `ESC $ @/B` (both JIS X 0208 double-byte) — any other pair
/// restores and errors.
const esc_modes = [_]struct { u8, u8, IsoState }{ .{ 0x28, 0x42, .ascii }, .{ 0x28, 0x4A, .roman }, .{ 0x28, 0x49, .katakana }, .{ 0x24, 0x40, .leading }, .{ 0x24, 0x42, .leading } };

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
            // The four steady modes share the ESC arm and the output-flag reset.
            .ascii, .roman, .katakana, .leading => {
                const b = item orelse break;
                if (b == 0x1B) {
                    state = .escape_start;
                    continue;
                }
                output = false;
                switch (state) {
                    .ascii => if (b <= 0x7F and b != 0x0E and b != 0x0F) s.cp(b) else s.err(),
                    .roman => switch (b) {
                        0x5C => s.cp(0x00A5),
                        0x7E => s.cp(0x203E),
                        else => if (b <= 0x7F and b != 0x0E and b != 0x0F) s.cp(b) else s.err(),
                    },
                    .katakana => if (b >= 0x21 and b <= 0x5F) s.cp(@as(u21, 0xFF61) - 0x21 + b) else s.err(),
                    .leading => if (b >= 0x21 and b <= 0x7E) {
                        lead = b;
                        state = .trailing;
                    } else s.err(),
                    else => unreachable,
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
                    continue;
                }
                state = .leading;
                if (b >= 0x21 and b <= 0x7E) {
                    const pointer = (@as(usize, lead) - 0x21) * 94 + (@as(usize, b) - 0x21);
                    if (cpAt(u16, gen.jis0208, gen.jis0208_len, pointer)) |c| s.cp(c) else s.err();
                } else s.err();
            },
            .escape_start => {
                if (item) |b| {
                    if (b == 0x24 or b == 0x28) {
                        lead = b;
                        state = .escape;
                        continue;
                    }
                    q.restore(&.{b});
                }
                output = false;
                state = out_state;
                s.err();
            },
            .escape => {
                const l = lead;
                lead = 0;
                const newstate: ?IsoState = if (item) |b| blk: {
                    for (esc_modes) |m| if (m[0] == l and m[1] == b) break :blk m[2];
                    break :blk null;
                } else null;
                if (newstate) |ns| {
                    state = ns;
                    out_state = ns;
                    const was = output;
                    output = true;
                    if (was) s.err();
                } else {
                    if (item) |b| q.restore(&.{ l, b }) else q.restore(&.{l});
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
