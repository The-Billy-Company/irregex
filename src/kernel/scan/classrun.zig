// MONOLITHIC: SIMD class-run scan — the dense-class boolean match kernel; the SIMD lane state, run detection, and the DFA-fallback boundary co-maintain one loop-carried match invariant
//! gist — SIMD class-run scan: the dense-class boolean match kernel.
//!
//! Why this exists (measured, not assumed): the byte-class DFA is O(1)/byte,
//! but that one operation is a LOOP-CARRIED L1 load — `s = trans[s +
//! class[b]]` serializes at ~4 cycles/byte — and the start-state SIMD
//! acceleration bows out past 3 exit bytes. So every dense-class query
//! (`\w+`, `[a-z]{3,}`, `[0-9]{4}`, `[0-9a-f]{8}` — exactly the crest sieve's
//! literal-free class-repetition family, `math/crest.zig`) pays the full
//! chained table walk, the same ~1 GB/s floor ripgrep's lazy DFA sits on.
//!
//! The escape: for a pattern that IS a class repetition, boolean match is not
//! an automaton problem at all —
//!
//!     hay matches  ⟺  hay holds ≥ min consecutive bytes of one byte set S
//!
//! and that is data-parallel: classify a 64-byte block into a membership
//! bitmask (two-compare SIMD lanes for a few-range set; two pshufb nibble
//! lookups — Hyperscan's "truffle" (Wang et al. 2019, "Hyperscan: A Fast
//! Multi-pattern Regex Matcher") — for an arbitrary one), then prove a ≥ min
//! run of set bits with word tricks: shift-AND doubling inside a block, a
//! carry counter across blocks. No loop-carried memory dependence, so the
//! scan runs at load bandwidth instead of load latency.
//!
//! Which regexes ARE class runs is decided by `analysis.classRunShape` (AST
//! algebra); this module is the pure byte kernel. Unicode codepoint classes
//! (`\w` under rg's default) ride a sound ASCII projection: a run of `min`
//! ASCII members is a match in ANY mode (accept never lies), and a miss is
//! exact unless a ≥ 0x80 byte was seen — then the kernel answers `.unproven`
//! and the caller keeps the DFA/Pike verdict. Byte-exact equivalence with the
//! Pike VM is held by the differential fuzz in `classrun_test.zig`.

const std = @import("std");
const builtin = @import("builtin");
const bitsmod = @import("../math/bits.zig");

const B64 = bitsmod.Field(u64);

/// Block width: one u64 membership mask per 64 haystack bytes (classified in
/// four 16-wide chunks — `tbl`/`pshufb` are 16-byte, and range compares at 16
/// keep one code shape for block and tail).
const W: usize = 64;
const V16 = @Vector(16, u8);

/// Range-backend cap: each range costs two compares per block, so past this
/// many the constant three-shuffle nibble backend wins. 4 covers the dense
/// code-search classes (`\w` = 4 ranges, hex = 3, `[a-z]`/`[0-9]` = 1).
pub const max_ranges: usize = 4;

/// The kernel's three-valued answer. `.unproven` exists only for the ASCII
/// projection of a codepoint class: a ≥ 0x80 byte was seen and no ASCII run
/// sufficed, so only the full engine can decide (never returned when `exact`).
pub const Verdict = enum { hit, miss, unproven };

/// A byte span `[start, end)` of one match — `nextSpan`'s currency, shape-
/// compatible with the Pike VM's `Regex.Span`.
pub const Span = struct { start: usize, end: usize };

/// Unbounded `max` sentinel (mirrors `analysis.no_max`).
pub const no_max: u32 = std.math.maxInt(u32);

/// How membership is classified per block — chosen once at `build` from the
/// set's shape, identical answers either way (held by the differential fuzz).
const Membership = union(enum) {
    ranges: Ranges,
    nibbles: Nibbles,
};

/// ≤ `max_ranges` contiguous byte ranges: `lo ≤ b ≤ hi` two-compare lanes.
/// The 16-wide splats are baked at build time — the per-LINE entry points
/// call `scan` millions of times on ~60-byte haystacks, where re-splatting
/// per call was a measurable share of the whole match.
const Ranges = struct { lo16: [max_ranges]V16, hi16: [max_ranges]V16, n: u8 };

/// Truffle nibble tables for an arbitrary 256-bit set: bit `(b>>4)&7` of
/// `lo_a[b&0xF]` answers membership for bytes 0x00–0x7F, `lo_b` for 0x80–0xFF.
/// Three pshufb-class shuffles per 16 bytes, regardless of set shape.
const Nibbles = struct { lo_a: V16, lo_b: V16 };

/// A compiled class-run query: the byte set S, the forced run floor, and the
/// exactness posture. Immutable, allocation-free, thread-safe by value (`cp`,
/// when present, is a borrowed const slice whose lifetime the compiling Regex
/// owns).
pub const ClassRun = struct {
    bits: [4]u64, // S itself (scalar tail + the oracle tests)
    min: u32, // run floor, ≥ 1 (`build` rejects 0 — nullable patterns match everywhere)
    exact: bool, // byte-exact set (true) vs ASCII projection of a codepoint class
    nl_free: bool, // '\n' ∉ S ⇒ a whole-buffer scan ≡ the per-line model (runs can't cross lines)
    backend: Membership,
    // The projection's FULL codepoint class (sorted, coalesced ranges), when
    // the analysis could carry it. Upgrades the reduction from bytes to
    // codepoints: a would-be `.unproven` resolves in-kernel (scalar UTF-8
    // over just the high-byte spans), so no automaton is ever needed.
    cp: ?[]const [2]u21 = null,
    // Direct-indexed membership for codepoints < 0x800 (every 2-byte UTF-8
    // encoding — the Latin/Greek/Cyrillic mass of real mixed text), baked at
    // `build` from `cp`. One bit test instead of a binary search over the
    // ~700 ranges a Unicode `\w` carries. 3+-byte codepoints stay on `cpIn`.
    bmp2: [32]u64 = @splat(0),
    // Span-exactness posture (`analysis.classSpanShape` — a strictly stronger
    // claim than the boolean reduction): when `span` holds, the leftmost-first
    // match at `p` is precisely "run(p) ≥ min, length lazy ? min :
    // @min(run(p), max)", which is what `nextSpan` chunks by. `max`/`lazy`
    // are meaningful only under `span` (defaults keep boolean-only builds
    // inert).
    span: bool = false,
    max: u32 = no_max,
    lazy: bool = false,

    /// Compile a class-run query. `min == 0` (a nullable pattern — the
    /// `eol_empty` machinery owns it) declines. An empty set is admitted: the
    /// scan then answers `.miss` (or `.unproven` on high bytes) at SIMD speed,
    /// which is exactly right for e.g. `[é]+` over an ASCII corpus.
    pub fn build(bits: [4]u64, min: u32, exact: bool, cp: ?[]const [2]u21) ?ClassRun {
        if (min == 0) return null;
        var bmp2: [32]u64 = @splat(0);
        if (cp) |ranges| for (ranges) |r| {
            var c = @max(r[0], 0x80);
            const hi = @min(r[1], 0x7FF);
            while (c <= hi) : (c += 1) bmp2[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
        };
        return .{
            .bits = bits,
            .min = min,
            .exact = exact,
            .nl_free = !B64.get(&bits, '\n'),
            .backend = membership(bits),
            .cp = cp,
            .bmp2 = bmp2,
        };
    }

    /// Can a codepoint range set back a full in-kernel resolution? Declines
    /// surrogate-touching ranges: `utf8Decode` rejects their encodings while
    /// a byte automaton could conceivably be taught them, so the resolver
    /// only claims the ranges it provably decides like the NFA would.
    pub fn cpResolvable(ranges: []const [2]u21) bool {
        for (ranges) |r| {
            if (r[1] >= 0xD800 and r[0] <= 0xDFFF) return false;
        }
        return true;
    }

    /// Will this kernel SETTLE any whole buffer handed to it — never returning
    /// `.unproven`, and never needing the caller to split lines first?
    ///
    /// Two independent obligations, which is why it is worth one name. `scan`
    /// only reaches `.unproven` through the ASCII projection of a codepoint
    /// class, so `exact` (bytes are the alphabet) or `cp` (the kernel can settle
    /// high bytes itself) discharges the verdict half. `nl_free` discharges the
    /// grain half: with `\n` outside S no run can cross a line, so "some line
    /// holds a run" and "the buffer holds one" are the same question.
    ///
    /// Both callers are downstream of that: `verdict.docMatchFused` reports which
    /// machine will answer, and the accelerator ladder declines to BUILD at all
    /// when this holds — everything it could admit sits below a kernel that has
    /// already decided, so a rung there is unreachable rather than merely slower.
    pub fn decides(self: *const ClassRun) bool {
        return self.nl_free and (self.exact or self.cp != null);
    }

    /// Does `hay` hold ≥ `min` consecutive members of S? `.hit`/`.miss` are
    /// final; `.unproven` (codepoint-class projection + a ≥ 0x80 byte, no
    /// ASCII run sufficed) resolves in-kernel when the full codepoint class
    /// is known, else sends the caller to the DFA/Pike engines.
    pub fn scan(self: *const ClassRun, hay: []const u8) Verdict {
        const v: Verdict = switch (self.backend) {
            .ranges => |*r| if (self.exact) self.scanRanges(true, r, hay) else self.scanRanges(false, r, hay),
            .nibbles => |*t| if (self.exact) self.scanNibbles(true, t, hay) else self.scanNibbles(false, t, hay),
        };
        if (v == .unproven) if (self.cp) |ranges| {
            return if (self.runFull(ranges, hay)) .hit else .miss;
        };
        return v;
    }

    /// The codepoint-level truth: does `hay` hold ≥ `min` consecutive
    /// CODEPOINTS of the full class? Hybrid pass — high-byte-free blocks ride
    /// the same SIMD classify+feed as the projection scan (ASCII codepoints
    /// ≡ bytes, so the run carry composes), and only spans actually touched
    /// by ≥ 0x80 decode scalar. Invalid UTF-8 breaks the run and advances one
    /// byte — exactly "no match can consume this byte", the NFA's posture.
    fn runFull(self: *const ClassRun, ranges: []const [2]u21, hay: []const u8) bool {
        var run: u64 = 0;
        var i: usize = 0;
        while (i < hay.len) {
            if (i + W <= hay.len and !hasHigh(hay[i..][0..W])) {
                if (feed(&run, self.memberMask(hay[i..]).m, self.min)) return true;
                i += W;
                continue;
            }
            const stop = @min(i + W, hay.len);
            while (i < stop) {
                i = self.stepCp(ranges, hay, i, &run);
                if (run >= self.min) return true;
            }
        }
        return false;
    }

    fn scanRanges(self: *const ClassRun, comptime exact: bool, r: *const Ranges, hay: []const u8) Verdict {
        const high16: V16 = @splat(0x80);
        var high = false;
        var run: u64 = 0;
        var i: usize = 0;
        while (i + W <= hay.len) : (i += W) {
            var hits: [W / 16]@Vector(16, bool) = undefined;
            var top: V16 = @splat(0);
            inline for (0..W / 16) |k| {
                const b: V16 = hay[i + k * 16 ..][0..16].*;
                if (!exact) top |= b;
                hits[k] = rangeHits(r, b);
            }
            if (!exact) high = high or @reduce(.Max, top) >= 0x80;
            if (feed(&run, bitsmod.blockMask(hits), self.min)) return .hit;
        }
        // Sub-block tail at the same 16-wide lanes, fed (and early-exited)
        // PER CHUNK. The typical code line is < 64 bytes, so for the per-line
        // entry points this *is* the hot path — and on a dense corpus the
        // verdict lands in the first chunk, where classifying the rest of the
        // line first made the kernel lose to the DFA's accept-state exit.
        const rest = hay[i..];
        var k: usize = 0;
        while (k + 16 <= rest.len) : (k += 16) {
            const b: V16 = rest[k..][0..16].*;
            if (!exact) high = high or bitsmod.laneMask(u16, b >= high16) != 0;
            if (feed16(&run, rangeMask(r, b), self.min)) return .hit;
        }
        return self.finish(exact, rest[k..], run, high);
    }

    /// Hit lanes for one 16-byte chunk: two compares per range, OR-folded.
    /// `n` is ≤ `max_ranges` and loop-unrolled friendly.
    inline fn rangeHits(r: *const Ranges, b: V16) @Vector(16, bool) {
        var hit: @Vector(16, bool) = @splat(false);
        for (r.lo16[0..r.n], r.hi16[0..r.n]) |lo, hi| hit |= (b >= lo) & (b <= hi);
        return hit;
    }

    /// Membership mask for one 16-byte chunk (the sub-block tail's grain).
    inline fn rangeMask(r: *const Ranges, b: V16) u16 {
        return @bitCast(rangeHits(r, b));
    }

    fn scanNibbles(self: *const ClassRun, comptime exact: bool, t: *const Nibbles, hay: []const u8) Verdict {
        const high16: V16 = @splat(0x80);
        var high = false;
        var run: u64 = 0;
        var i: usize = 0;
        while (i + W <= hay.len) : (i += W) {
            var hits: [W / 16]@Vector(16, bool) = undefined;
            var top: V16 = @splat(0);
            inline for (0..W / 16) |k| {
                const b: V16 = hay[i + k * 16 ..][0..16].*;
                if (!exact) top |= b;
                hits[k] = nibbleHits(t, b);
            }
            if (!exact) high = high or @reduce(.Max, top) >= 0x80;
            if (feed(&run, bitsmod.blockMask(hits), self.min)) return .hit;
        }
        // Sub-block tail: truffle is already 16-wide (see scanRanges' note).
        const rest = hay[i..];
        var k: usize = 0;
        while (k + 16 <= rest.len) : (k += 16) {
            const b: V16 = rest[k..][0..16].*;
            if (!exact) high = high or bitsmod.laneMask(u16, b >= high16) != 0;
            if (feed16(&run, nibbleMask(t, b), self.min)) return .hit;
        }
        return self.finish(exact, rest[k..], run, high);
    }

    /// Count LINES holding a ≥ `min` run — rg's `-c` line model (`\n`
    /// terminates; the unterminated tail is a line; min ≥ 1 means an empty
    /// line never counts) — in ONE STREAMING whole-buffer pass. Each 64-byte
    /// block yields two masks from the same loads (membership + newline);
    /// everything after that is register bit-tricks: `runStarts` marks where
    /// a ≥ min run begins, the carry handles seam runs, and the (rare — ~1
    /// per block on code) newline bits settle each ending line with one
    /// segment-mask test. No line is ever re-read and no scan position ever
    /// restarts, so the dense case runs at classification bandwidth — the
    /// hit-jump predecessor paid a `memchr` re-read of every counted line.
    /// The caller gates on `exact` (the count is final) and `nl_free` (a run
    /// can never cross `\n`, so "line holds a run" ≡ the per-line scan).
    pub fn countLines(self: *const ClassRun, hay: []const u8) u64 {
        var count: u64 = 0;
        var run: u64 = 0; // member-run carried across the block seam
        var seen = false; // current line already proven matching
        var i: usize = 0;
        while (i < hay.len) {
            // Codepoint mode: a block touched by ≥ 0x80 (or the sub-block
            // tail, whose scalar remainder only knows bytes) resolves scalar
            // — the byte bit-path would misread a member codepoint's bytes
            // as run breakers. High-byte-free blocks stay on the fast path.
            if (self.cp) |ranges| {
                const stop = @min(i + W, hay.len);
                if (stop - i < W or hasHigh(hay[i..][0..W])) {
                    while (i < stop) {
                        if (hay[i] == '\n') {
                            count += @intFromBool(seen);
                            seen = false;
                            run = 0;
                            i += 1;
                            continue;
                        }
                        i = self.stepCp(ranges, hay, i, &run);
                        seen = seen or run >= self.min;
                    }
                    continue;
                }
            }
            const blk = self.memberMask(hay[i..]);
            // A seam-completed run belongs to the block's FIRST segment (the
            // carry is all members, so no `\n` can sit inside it).
            if (run + @ctz(~blk.m) >= self.min) seen = true;
            const x = if (self.min <= W) runStarts(blk.m, self.min) else 0;
            // Only a block that could settle a line pays for its newline
            // mask: with no live proof (`seen`) and no run start, every line
            // ending here counts zero and `seen` stays false — the miss-heavy
            // regime skips everything below.
            if (seen or x != 0) {
                // Settle each line ending in this block: a line counts iff it
                // was already seen or a run STARTS in its segment (runs never
                // cross `\n`, so a start in the segment is a hit in the line).
                var nls = nlMask(hay[i..][0..blk.len]);
                var from: u32 = 0;
                while (nls != 0) {
                    const p: u32 = @ctz(nls);
                    const seg = lowMask(p) & ~lowMask(from);
                    count += @intFromBool(seen or (x & seg) != 0);
                    seen = false;
                    from = p + 1;
                    nls &= nls - 1;
                }
                seen = seen or (x & ~lowMask(from)) != 0;
            }
            // Trailing member run within the block's live bytes seeds the next
            // carry; a fully-member block extends the carry wholesale (the
            // only way a > 64-byte `min` accumulates).
            const tr: u64 = @clz(~std.math.shl(u64, blk.m, W - blk.len));
            run = if (tr == blk.len) run + blk.len else tr;
            i += W;
        }
        // The unterminated tail line: `seen` can only be true if member bytes
        // followed the last `\n`, so no phantom final line is ever counted.
        return count + @intFromBool(seen);
    }

    /// Leftmost-first match span at/after `from` under the span-exact window
    /// rule (`self.span` must hold, and `exact or cp != null` so the kernel
    /// can settle high bytes itself): find the next member run, and cut it at
    /// `lazy ? min : @min(run, max)` — exactly rust-regex `find_iter` chunking
    /// for a class-repetition pattern, replacing the Pike VM's per-byte thread
    /// closures with the block membership masks. Byte-exact sets ride SIMD
    /// end to end; codepoint classes take the same blocks over high-byte-free
    /// stretches and the scalar UTF-8 resolver otherwise (runs count
    /// codepoints, positions stay bytes). Never zero-width (`min ≥ 1`), so
    /// the caller's progress rule is trivially satisfied.
    pub fn nextSpan(self: *const ClassRun, hay: []const u8, from: usize) ?Span {
        const cap: u64 = if (self.lazy) self.min else if (self.max == no_max) std.math.maxInt(u64) else self.max;
        if (!self.exact) if (self.cp) |ranges| return self.nextSpanCp(ranges, hay, from, cap);
        var run: u64 = 0;
        var start: usize = 0;
        var i: usize = from;
        while (i < hay.len) {
            const blk = self.memberMask(hay[i..]);
            if (self.blockSpan(blk.m, blk.len, i, &run, &start, cap)) |sp| return sp;
            i += blk.len;
        }
        return if (run >= self.min) .{ .start = start, .end = hay.len } else null;
    }

    /// Walk one membership mask's run segments, advancing the cross-block
    /// carry (`run`, `start`); returns the first span it can settle, null
    /// when the block ends mid-run (or empty-handed). Entry invariant:
    /// `run < cap` — an over-cap run was emitted the moment it crossed, so a
    /// cap overshoot here always lands inside THIS block's ones (all single
    /// bytes, which keeps `end` exact even in codepoint mode, where this walk
    /// only ever sees high-byte-free blocks).
    fn blockSpan(self: *const ClassRun, m: u64, len: usize, base: usize, run: *u64, start: *usize, cap: u64) ?Span {
        var pos: usize = 0;
        while (pos < len) {
            if (run.* == 0) {
                const rest = m >> @intCast(pos);
                if (rest == 0) return null;
                pos += @ctz(rest);
                start.* = base + pos;
            }
            const ones = @min(@as(usize, @ctz(~(m >> @intCast(pos)))), len - pos);
            run.* += ones;
            pos += ones;
            if (run.* >= cap) return .{ .start = start.*, .end = base + pos - @as(usize, @intCast(run.* - cap)) };
            if (pos < len) { // breaker bit: the run ends inside this block
                if (run.* >= self.min) return .{ .start = start.*, .end = base + pos };
                run.* = 0;
                pos += 1;
            }
        }
        return null;
    }

    /// `nextSpan`, codepoint mode: same window rule with runs counted in
    /// CODEPOINTS of the full class. Blocks free of ≥ 0x80 take `blockSpan`
    /// unchanged (ASCII codepoints ≡ bytes, so the carry composes across the
    /// seam); touched blocks step the scalar resolver. Invalid UTF-8 breaks
    /// the run and advances one byte — the automaton's own posture.
    fn nextSpanCp(self: *const ClassRun, ranges: []const [2]u21, hay: []const u8, from: usize, cap: u64) ?Span {
        var run: u64 = 0;
        var start: usize = 0;
        var i: usize = from;
        while (i < hay.len) {
            if (i + W <= hay.len and !hasHigh(hay[i..][0..W])) {
                const blk = self.memberMask(hay[i..]);
                if (self.blockSpan(blk.m, W, i, &run, &start, cap)) |sp| return sp;
                i += W;
                continue;
            }
            const stop = @min(i + W, hay.len);
            while (i < stop) {
                const prev = run;
                const ni = self.stepCp(ranges, hay, i, &run);
                if (run > prev) { // member codepoint
                    if (prev == 0) start = i;
                    if (run >= cap) return .{ .start = start, .end = ni };
                } else if (prev >= self.min) { // breaker settled a long-enough run
                    return .{ .start = start, .end = i };
                }
                i = ni;
            }
        }
        return if (run >= self.min) .{ .start = start, .end = hay.len } else null;
    }

    /// One scalar UTF-8 step for the codepoint-resolver paths: decode the
    /// codepoint at `i`, update the codepoint run, and return the position
    /// after it. ASCII consults the byte set (so the per-line `\n` removal
    /// keeps holding); anything undecodable — bad lead byte, truncated or
    /// malformed sequence — breaks the run and advances ONE byte, the same
    /// "no match can consume this byte" the byte automaton enforces.
    fn stepCp(self: *const ClassRun, ranges: []const [2]u21, hay: []const u8, i: usize, run: *u64) usize {
        const b = hay[i];
        if (b < 0x80) {
            run.* = if (B64.get(&self.bits, b)) run.* + 1 else 0;
            return i + 1;
        }
        // Inlined 2-byte decode (the Latin/Greek/Cyrillic mass of real mixed
        // text): lead C2–DF + one continuation, never overlong — one compare
        // chain and a direct bitmap probe instead of the general decoder.
        if (b -% 0xC2 < 0x1E and i + 1 < hay.len and hay[i + 1] & 0xC0 == 0x80) {
            const c: u21 = (@as(u21, b & 0x1F) << 6) | (hay[i + 1] & 0x3F);
            run.* = if (self.bmp2[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0) run.* + 1 else 0;
            return i + 2;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            run.* = 0;
            return i + 1;
        };
        if (n < 3 or i + n > hay.len) { // n < 3: the fast path already rejected it
            run.* = 0;
            return i + 1;
        }
        const c = std.unicode.utf8Decode(hay[i..][0..n]) catch {
            run.* = 0;
            return i + 1;
        };
        run.* = if (cpIn(ranges, c)) run.* + 1 else 0;
        return i + n;
    }

    /// Membership mask over the next ≤ 64 bytes of `rest` (SIMD chunks + a
    /// scalar remainder; pad bits stay zero). The streaming count verb's
    /// block primitive — the boolean scans keep their fused early-exit loops.
    fn memberMask(self: *const ClassRun, rest: []const u8) struct { m: u64, len: usize } {
        if (rest.len >= W) { // the steady state: whole blocks take the fused fold
            var hits: [W / 16]@Vector(16, bool) = undefined;
            switch (self.backend) {
                .ranges => |*r| inline for (0..W / 16) |k| {
                    hits[k] = rangeHits(r, rest[k * 16 ..][0..16].*);
                },
                .nibbles => |*t| inline for (0..W / 16) |k| {
                    hits[k] = nibbleHits(t, rest[k * 16 ..][0..16].*);
                },
            }
            return .{ .m = bitsmod.blockMask(hits), .len = W };
        }
        var m: u64 = 0;
        var k: usize = 0;
        switch (self.backend) {
            .ranges => |*r| while (k + 16 <= rest.len) : (k += 16) {
                m |= @as(u64, rangeMask(r, rest[k..][0..16].*)) << @intCast(k);
            },
            .nibbles => |*t| while (k + 16 <= rest.len) : (k += 16) {
                m |= @as(u64, nibbleMask(t, rest[k..][0..16].*)) << @intCast(k);
            },
        }
        for (rest[k..], k..) |b, j| {
            if (B64.get(&self.bits, b)) m |= @as(u64, 1) << @intCast(j);
        }
        return .{ .m = m, .len = rest.len };
    }

    /// Classify the scalar remainder (< 16 bytes) and settle the verdict.
    /// Padding bits stay ZERO (non-members), which every check below treats
    /// correctly: `ctz(~m)` stops at or before the pad, and phantom runs
    /// cannot appear from zeros.
    fn finish(self: *const ClassRun, comptime exact: bool, rem: []const u8, run: u64, high0: bool) Verdict {
        var m: u16 = 0;
        var high = high0;
        for (rem, 0..) |b, i| {
            if (!exact and b >= 0x80) high = true;
            if (B64.get(&self.bits, b)) m |= @as(u16, 1) << @intCast(i);
        }
        // The remainder is < 16 bytes, so ~m has a set pad bit and ctz is < 16.
        if (run + @ctz(~m) >= self.min) return .hit; // seam run: carry + leading ones
        if (self.min <= 16 and hasRun(m, self.min)) return .hit; // run inside the remainder
        return if (!exact and high) .unproven else .miss;
    }
};

/// Advance the cross-block run state by one 64-bit membership mask (bit i =
/// byte i ∈ S); true ⇒ a ≥ `min` run is proven. Three cases: an all-ones
/// block extends the carry wholesale; a run straddling the block seam is the
/// carry plus the block's leading ones; a run wholly inside the block is the
/// shift-AND fold (only meaningful when `min` fits one word — a longer run
/// necessarily straddles and the carry arithmetic already sees it).
inline fn feed(run: *u64, m: u64, min: u32) bool {
    if (m == std.math.maxInt(u64)) {
        run.* += W;
        return run.* >= min;
    }
    const lead: u64 = @ctz(~m); // ones at the block's low end (earliest bytes)
    if (run.* + lead >= min) return true;
    if (min <= W and hasRun(m, min)) return true;
    run.* = @clz(~m); // ones at the block's high end seed the next carry
    return false;
}

/// `feed`'s 16-bit twin for the sub-block tail chunks: same three cases over
/// a 16-byte mask, so a short line settles at the FIRST chunk that proves a
/// run instead of classifying the whole line before deciding.
inline fn feed16(run: *u64, m: u16, min: u32) bool {
    if (m == std.math.maxInt(u16)) {
        run.* += 16;
        return run.* >= min;
    }
    const lead: u64 = @ctz(~m);
    if (run.* + lead >= min) return true;
    if (min <= 16 and hasRun(m, min)) return true;
    run.* = @clz(~m);
    return false;
}

/// The start positions of every ≥ `n` run of set bits inside `m` (1 ≤ n ≤ bit
/// width). Shift-AND doubling: after folding by `got`, bit i survives iff
/// `got` consecutive bits start at i — O(log n) folds, no data-dependent
/// branches. The count verb reads the mask; the boolean scans just test it.
inline fn runStarts(m: anytype, n: u32) @TypeOf(m) {
    var x = m;
    var got: u32 = 1;
    while (x != 0 and got < n) {
        const s = @min(got, n - got);
        x &= x >> @intCast(s);
        got += s;
    }
    return x;
}

/// ∃ `n` consecutive set bits inside `m`?
inline fn hasRun(m: anytype, n: u32) bool {
    return runStarts(m, n) != 0;
}

/// The low `k` bits set (k ≤ 64 — a segment boundary can sit one past the
/// block, when a `\n` occupies bit 63).
inline fn lowMask(k: u32) u64 {
    return if (k >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(k)) - 1;
}

/// Any byte ≥ 0x80 in the block? One wide max-reduce — the codepoint-mode
/// paths' gate between the byte fast path and the scalar UTF-8 resolver.
inline fn hasHigh(blk: *const [W]u8) bool {
    const v: @Vector(W, u8) = blk.*;
    return @reduce(.Max, v) >= 0x80;
}

/// Codepoint membership by binary search over sorted, coalesced ranges.
fn cpIn(ranges: []const [2]u21, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (c < r[0]) hi = mid else if (c > r[1]) lo = mid + 1 else return true;
    }
    return false;
}

/// Newline mask over one live block slice (bit j ⇔ `rest[j] == '\n'`). Paid
/// only by blocks that can settle a line; the bytes are already in L1 from
/// the membership pass.
inline fn nlMask(rest: []const u8) u64 {
    const nl16: V16 = @splat('\n');
    var nl: u64 = 0;
    var k: usize = 0;
    while (k + 16 <= rest.len) : (k += 16) {
        const b: V16 = rest[k..][0..16].*;
        nl |= @as(u64, bitsmod.laneMask(u16, b == nl16)) << @intCast(k);
    }
    for (rest[k..], k..) |b, j| {
        if (b == '\n') nl |= @as(u64, 1) << @intCast(j);
    }
    return nl;
}

/// Pick the block classifier for a set: few contiguous ranges take the
/// two-compare lanes; anything wider (a negated class, scattered members)
/// takes the truffle nibble tables. Both are exact over all 256 byte values.
/// Pub so the differential test can force BOTH backends onto one set.
pub fn membership(bits: [4]u64) Membership {
    var lo16: [max_ranges]V16 = undefined;
    var hi16: [max_ranges]V16 = undefined;
    var n: usize = 0;
    var c: usize = 0;
    while (c < 256) {
        if (!B64.get(&bits, c)) {
            c += 1;
            continue;
        }
        const start = c;
        while (c < 256 and B64.get(&bits, c)) c += 1;
        if (n == max_ranges) return .{ .nibbles = nibbleTables(bits) };
        lo16[n] = @splat(@intCast(start));
        hi16[n] = @splat(@intCast(c - 1));
        n += 1;
    }
    return .{ .ranges = .{ .lo16 = lo16, .hi16 = hi16, .n = @intCast(n) } };
}

/// Build the truffle tables: for member byte b, set bit `(b>>4)&7` in the
/// low-nibble-indexed cell of the low (b < 0x80) or high (b ≥ 0x80) table.
pub fn nibbleTables(bits: [4]u64) Nibbles {
    var a = [_]u8{0} ** 16;
    var b = [_]u8{0} ** 16;
    for (0..256) |bi| {
        if (!B64.get(&bits, bi)) continue;
        const cell = bi & 0x0F;
        const bit = @as(u8, 1) << @intCast((bi >> 4) & 0x7);
        if (bi < 0x80) a[cell] |= bit else b[cell] |= bit;
    }
    return .{ .lo_a = a, .lo_b = b };
}

/// Hit lanes for one 16-byte chunk via truffle: two table shuffles pick the
/// candidate bit-columns (pshufb's high-bit zeroing splits the byte space at
/// 0x80 for free), a third materializes `1 << ((b>>4)&7)`, and the AND
/// answers all 16 lanes at once.
inline fn nibbleHits(t: *const Nibbles, b: V16) @Vector(16, bool) {
    // {1,2,4,…,128} twice: indexed by the full high nibble (0..15), so no
    // masking shuffle is needed to reduce it mod 8.
    const sel_tbl: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const idx_mask: V16 = @splat(0x8F); // keep the zeroing bit + the low nibble
    const hibit: V16 = @splat(0x80);
    const four: @Vector(16, u3) = @splat(4);
    const zero: V16 = @splat(0);
    const m = pshufb(t.lo_a, b & idx_mask) | pshufb(t.lo_b, (b ^ hibit) & idx_mask);
    const sel = pshufb(sel_tbl, b >> four);
    return (m & sel) != zero;
}

/// Membership mask for one 16-byte chunk (the sub-block tail's grain).
inline fn nibbleMask(t: *const Nibbles, b: V16) u16 {
    return @bitCast(nibbleHits(t, b));
}

/// 16-wide byte shuffle with **pshufb semantics**: `out[i] = 0` when the
/// index's high bit is set, else `table[idx[i] & 0x0F]`. The sibling
/// `teddy.zig` shuffle is the raw-`tbl` twin whose callers pre-mask indices;
/// truffle *relies* on the zeroing, so the scalar fallback implements it too.
/// Predicated on the feature rather than the architecture, for the reason
/// `lanes.shuffle` spells out: inline asm is opaque to LLVM's subtarget check,
/// so an arch-only arm would put SSSE3 into a baseline artifact.
inline fn pshufb(table: V16, idx: V16) V16 {
    // NEON `tbl` zeroes any index ≥ 16; the 0x8F-masked indices the callers
    // pass are either a low nibble (< 16) or carry bit 7 (≥ 0x80) — exactly
    // pshufb's split.
    if (comptime builtin.cpu.has(.aarch64, .neon)) return asm ("tbl %[o].16b, {%[t].16b}, %[i].16b"
        : [o] "=w" (-> V16),
        : [t] "w" (table),
          [i] "w" (idx),
    );
    if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb %[i], %[o]"
        : [o] "=x" (-> V16),
        : [t] "0" (table),
          [i] "x" (idx),
    );
    var out: [16]u8 = undefined;
    const t: [16]u8 = table;
    const ix: [16]u8 = idx;
    for (0..16) |k| out[k] = if (ix[k] & 0x80 != 0) 0 else t[ix[k] & 0x0F];
    return out;
}
