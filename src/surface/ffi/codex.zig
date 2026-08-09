//! The self-index: a byte string compressed into a structure that can still be
//! searched, counted, and read back — without keeping the original.
//!
//! This is the primitive with no competitor in a grep-shaped library. A trigram
//! index tells you which documents to open; an FM-index answers `count` in time
//! proportional to the PATTERN rather than the text, locates every occurrence,
//! and reconstructs the original bytes it never stored. It is what makes
//! attribution ("where is this phrase from") cheap enough to ask casually.
//!
//! Shipped, sealed, versioned, and driven by three sibling binaries — and
//! entirely absent from the C ABI.
//!
//! ## The one thing a host will get wrong
//!
//! **`build` does not retain the text.** The suffix array, the BWT and the
//! caller's bytes are all gone by the time the handle exists; what remains is a
//! wavelet tree, a 257-entry cumulative table and the optional locate samples.
//! So `extract` is a *reconstruction*, not a borrow — it decodes bytes out of
//! the structure into a buffer the caller owns, and there is no pointer into
//! the original anywhere in this plane to hand back. A host that frees its text
//! after `build` loses nothing; a host that expects `extract` to return a
//! pointer has misread the whole tier.
//!
//! ## Two capabilities, bought separately
//!
//! Counting is free with the index. *Locating* costs one `u32` per
//! `sample_rate` bytes of corpus, and a host may decline to buy it
//! (`IRGX_CODEX_NO_LOCATE`). Such an index counts exactly and declines to say
//! where — `.stale`, the declinature, never a fault, because a smaller artifact
//! that answers fewer questions is a choice its builder made and not a failure
//! at the seam. `extract` is unaffected: it still answers, from the corpus end,
//! at the cost `restore` always paid.
//!
//! ## Two shapes of search, and why both are published
//!
//! `count` and `locate` take a pattern and are the whole story for a host that
//! wants matches. `rows_whole` + `rows_extend` are the FM backward search taken
//! one byte at a time, and they are published because they are what lets a host
//! build its OWN matcher over this index — a wildcard, an approximate walk, a
//! bidirectional probe — instead of being limited to the exact-substring
//! question this plane happens to have wrapped. Pair either with `position` to
//! turn a row into a text offset. That is the difference between shipping an
//! index and shipping a toolkit.
//!
//! Ownership: an `irgx_codex` owns everything it holds and dies with
//! `irgx_codex_free`. Nothing in this plane hands back a borrowed pointer;
//! every byte-producing verb writes into the caller's buffer under the
//! cap/`written` contract. Handles are SINGLE-THREADED: `extract` and `save`
//! memoize into the handle, so two threads sharing one corrupt it.
//!
//! No `export fn` lives here: `exports.zig` is the `libirgx` artifact's root
//! and the three bindings are landed with it.

const std = @import("std");
const contract = @import("contract.zig");
const kernel = @import("../../kernel/codex/codex.zig");
const wavelet = @import("../../kernel/math/succinct/wavelet.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// `sample_rate` for an index that will never be asked *where* — the count-only
/// artifact. Spelled as a sentinel rather than as zero so that a zeroed options
/// struct means today's default, which is the rule every options struct at this
/// seam keeps. (The kernel spells the same choice as `sample_rate = 0`; the
/// translation happens once, in `optionsOf`.)
pub const no_locate: u32 = std.math.maxInt(u32);

/// The stride a zeroed `sample_rate` resolves to — the kernel's own default,
/// read off its `Options` rather than restated, so the two cannot drift.
pub const default_sample_rate: u32 = (kernel.Options{}).sample_rate;

/// Bitvector posture. Same answers either way; a space/time knob only.
pub const Encoding = enum(u32) {
    /// Entropy space — offer every level to RRR and keep the smaller. Zero, so
    /// a zeroed options struct asks for the posture the kernel defaults to.
    adopt_min = 0,
    /// Plain bitvectors everywhere: roughly twice the space, roughly five times
    /// the rank throughput.
    plain_only = 1,

    fn of(v: u32) ?wavelet.Encoding {
        return switch (v) {
            @intFromEnum(Encoding.adopt_min) => .adopt_min,
            @intFromEnum(Encoding.plain_only) => .plain_only,
            else => null,
        };
    }
};

/// What to build. `struct_size` is FAIL-CLOSED and the layout is APPEND-ONLY: a
/// size this build does not recognize is `.invalid`, never a best-effort read
/// of the prefix it thinks it recognizes. Every field's zero is the documented
/// default, so `{ .struct_size = sizeof }` over zeroed memory builds what the
/// kernel builds unasked.
pub const Options = extern struct {
    struct_size: u32,
    /// Suffix-rank sampling stride. Zero means `default_sample_rate`;
    /// `no_locate` means build no locate structures at all. Any other value is
    /// taken literally — smaller locates faster, larger indexes smaller.
    sample_rate: u32 = 0,
    /// One of `Encoding`. An unrecognized value is `.invalid`, not a default.
    encoding: u32 = 0,
    reserved: u32 = 0,
};

/// What the index cost and what it can do — one read, so a host sizing a shelf
/// or deciding whether to rebuild does not need four verbs. `struct_size` is
/// fail-closed exactly as `Options`' is.
pub const Stats = extern struct {
    struct_size: u32,
    /// The stride this index was actually built at, in the KERNEL's spelling:
    /// zero when it holds no locate structures. Deliberately not `no_locate` —
    /// this reports what was built, where `Options.sample_rate` requests it.
    sample_rate: u32,
    /// 1 when `locate` and `position` will answer, 0 when they decline.
    locates: u32,
    reserved: u32 = 0,
    /// The original corpus length. What `extract` reconstructs, and what
    /// `irgx_codex_len` returns.
    text_len: usize,
    /// Resident bytes: the tree, the locate structures, and the handle.
    index_bytes: usize,
    tree_bytes: usize,
    locate_bytes: usize,
};

/// A suffix-array row interval — the state of an incremental backward search,
/// and the only value type this plane crosses with. Empty (`lo == hi`) means
/// the pattern built so far does not occur; `hi - lo` is the occurrence count.
///
/// Rows are NOT text offsets. Turning one into an offset is `position`, which
/// is a real walk and can decline; subtracting these two numbers to index a
/// corpus is the one arithmetic error this plane makes available.
pub const Rows = extern struct { lo: usize, hi: usize };

/// The FM-index and the two answers it memoizes. Opaque to C.
pub const Codex = struct {
    inner: kernel.Codex,
    /// A serialized image `save` produced but could not fully hand over,
    /// held for the retry that will. See `save`.
    pending: ?[]u8 = null,
};

/// The corpus ceiling: the longest text `build` will accept, past which it
/// faults `Oversized` rather than truncating.
///
/// A verb rather than a `#define` because the number belongs to the suffix sort
/// vendored into this build, and a header constant is a copy that can be wrong
/// about the library the host actually linked.
pub fn maxTextLen() usize {
    return kernel.max_text_len;
}

/// Build an index over `text`. The text is NOT retained — see the module note.
///
/// `opts` may be null for the defaults. Faults `Oversized` above `maxTextLen`,
/// `OutOfMemory` when the build cannot be sized (peak residency is dominated by
/// a ~4n-byte suffix array, released before the wavelet phase begins).
pub fn build(text: ?[*]const u8, len: usize, opts: ?*const Options, out: ?**Codex) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const bytes = contract.view(text, len) orelse return .invalid;
    const wanted = optionsOf(opts) orelse return .invalid;

    const handle = gpa.create(Codex) catch return contract.report(.{ .code = error.OutOfMemory });
    // No `errdefer`: this entry returns a Status rather than an error union, so
    // one would never fire. The allocation above is unwound by hand.
    handle.* = .{ .inner = kernel.Codex.build(gpa, bytes, wanted) catch |e| {
        gpa.destroy(handle);
        return contract.reportAny(e, .invalid);
    } };
    slot.* = handle;
    return .ok;
}

/// Read a caller's options into the kernel's, or refuse them.
///
/// The one place the C spelling and the Zig spelling of "no locate" are
/// reconciled, so the seam's rule (every field's zero is today's default) and
/// the kernel's rule (zero builds no samples) can both hold without either
/// giving way. A null `opts` is the defaults, spelled by absence.
fn optionsOf(opts: ?*const Options) ?kernel.Options {
    const o = opts orelse return .{};
    if (o.struct_size != @sizeOf(Options)) return null;
    if (o.reserved != 0) return null;
    return .{
        .sample_rate = switch (o.sample_rate) {
            0 => default_sample_rate,
            no_locate => 0,
            else => o.sample_rate,
        },
        .encoding = Encoding.of(o.encoding) orelse return null,
    };
}

/// Rebuild an index from a `save` image. Fails closed: any framing, seal, or
/// structural violation is `Corrupt` — which is also what a version this build
/// cannot read comes back as.
pub fn load(bytes: ?[*]const u8, len: usize, out: ?**Codex) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const image = contract.view(bytes, len) orelse return .invalid;

    const handle = gpa.create(Codex) catch return contract.report(.{ .code = error.OutOfMemory });
    handle.* = .{ .inner = kernel.Codex.load(gpa, image) catch |e| {
        gpa.destroy(handle);
        return contract.reportAny(e, .invalid);
    } };
    slot.* = handle;
    return .ok;
}

/// Release the index and any image `save` is still holding for a retry.
///
/// No `beginCall`: teardown leaves the fault slot alone, so a host can still
/// report the detail behind the failure it is cleaning up after.
pub fn free(cx: *Codex) void {
    if (cx.pending) |blob| gpa.free(blob);
    cx.inner.deinit(gpa);
    gpa.destroy(cx);
}

/// The original corpus length in bytes — the buffer size a full `extract`
/// wants. A pure getter: it cannot refuse, so it neither returns a status nor
/// disturbs the fault slot.
pub fn length(cx: *const Codex) usize {
    return cx.inner.len();
}

/// What the index cost and what it can do.
///
/// It calls `beginCall` despite doing no work, because it can still REFUSE (a
/// `struct_size` this build does not know), and a refusal that left the
/// previous call's fault standing would hand the host a detail about the wrong
/// call.
pub fn measure(cx: *const Codex, out: ?*Stats) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Stats)) return .invalid;
    const s = cx.inner.stats;
    slot.* = .{
        .struct_size = @sizeOf(Stats),
        .sample_rate = if (cx.inner.locates()) cx.inner.sample_rate else 0,
        .locates = @intFromBool(cx.inner.locates()),
        .text_len = s.text_len,
        .index_bytes = s.index_bytes,
        .tree_bytes = s.tree_bytes,
        .locate_bytes = s.locate_bytes,
    };
    return .ok;
}

/// Occurrences of `pattern`, overlapping counted — the operation this whole
/// tier exists for, answered in |pattern| rank steps and INDEPENDENT of corpus
/// size.
///
/// The empty pattern counts 0. That is a search answer rather than the vacuous
/// n+1 the mathematics gives, and it is the answer a host looping over user
/// input needs.
pub fn count(cx: *const Codex, pattern: ?[*]const u8, len: usize, out: ?*usize) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const needle = contract.view(pattern, len) orelse return .invalid;
    slot.* = cx.inner.count(needle);
    return if (slot.* == 0) .ok else .match;
}

/// Every match position of `pattern`, ascending.
///
/// `.stale` when the index was built without locate structures: counting is
/// exact either way, so the remedy is real — rebuild with a `sample_rate` — and
/// a declinature installs no fault. `*written` is untouched in that case, as
/// the seam's refusal contract requires.
///
/// Otherwise the standard window: at most `cap` positions are written and
/// `*written` reports how many EXIST, so `cap == 0` with a null buffer is the
/// sizing probe and a short buffer sizes its own retry.
pub fn locate(
    cx: *const Codex,
    pattern: ?[*]const u8,
    len: usize,
    out: ?[*]usize,
    cap: usize,
    written: ?*usize,
) Status {
    contract.beginCall();
    const needle = contract.view(pattern, len) orelse return .invalid;
    // Probed BEFORE the sink opens: a declinature must leave `*written`
    // untouched, and `Sink.open` zeroes it.
    if (!cx.inner.locates()) return .stale;
    var sink = contract.Sink(usize).open(out, cap, written) orelse return .invalid;
    const answer = cx.inner.find(gpa, needle) catch
        return contract.report(.{ .code = error.OutOfMemory });
    const hits = switch (answer) {
        .got => |v| v,
        // Unreachable through the guard above, and answered rather than
        // asserted: the kernel owns when it declines, and this plane restating
        // that as an invariant is how the two get to disagree later.
        .declined => return .stale,
    };
    defer gpa.free(hits);
    for (hits) |p| sink.push(p);
    return sink.close();
}

/// The text offset a suffix-array row begins at — one sampled-mark walk, the
/// cheapest locate there is.
///
/// This is what turns an interval built with `rows_extend` into text positions,
/// and it is why the incremental search is publishable rather than a curiosity.
/// `.stale` without locate structures, `.invalid` for a row outside `[0, len]`
/// (there are `len + 1` rows: the sentinel suffix owns the last one).
pub fn position(cx: *const Codex, row: usize, out: ?*usize) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (row > cx.inner.len()) return .invalid;
    return switch (cx.inner.posOf(row)) {
        .got => |p| blk: {
            slot.* = p;
            break :blk .ok;
        },
        .declined => .stale,
    };
}

/// The interval of the empty pattern: every row. Where an incremental backward
/// search starts.
pub fn rowsWhole(cx: *const Codex, out: ?*Rows) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const r = cx.inner.whole();
    slot.* = .{ .lo = r.lo, .hi = r.hi };
    return .match;
}

/// One FM backward-search step: `rows` becomes the interval of `byte ++ P` from
/// the interval of `P`. Two rank queries — O(code length), independent of
/// corpus size.
///
/// Read RIGHT TO LEFT: to search for `abc`, extend by `c`, then `b`, then `a`.
/// `.match` while the interval is non-empty, `.ok` the moment it empties — and
/// an empty interval stays empty under every further step, so a host may stop
/// at the first `.ok` without checking again.
pub fn rowsExtend(cx: *const Codex, rows: ?*Rows, byte: u8) Status {
    contract.beginCall();
    const slot = rows orelse return .invalid;
    if (slot.lo > slot.hi or slot.hi > cx.inner.len() + 1) return .invalid;
    const r = cx.inner.extend(.{ .lo = slot.lo, .hi = slot.hi }, byte);
    slot.* = .{ .lo = r.lo, .hi = r.hi };
    return if (r.width() == 0) .ok else .match;
}

/// Reconstruct `text[at ..]` into `out`, up to `cap` bytes — the index decoding
/// bytes it never stored.
///
/// **This is also `restore`.** Reconstructing the whole corpus is this verb at
/// `at = 0` with `cap = irgx_codex_len`, and there is no second name for it,
/// because starting the decode beside the answer instead of at the corpus end
/// is the only difference between the two and it is an argument, not an
/// operation. The cost follows the argument: O(sample_rate + cap) from a
/// sampled anchor, O(len - at) on an index built without locate structures,
/// which is what `restore` always cost.
///
/// The standard window, measured from `at`: `*written` is `len - at`, the bytes
/// that EXIST past that offset, whatever `cap` was — so `cap == 0` with a null
/// buffer asks how much is left, and a short buffer sizes its own retry. `at`
/// beyond the corpus is `.invalid` rather than an empty answer: it is a caller
/// arithmetic bug, and the empty answer at `at == len` is a real one.
pub fn extract(cx: *Codex, at: usize, out: ?[*]u8, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const total = written orelse return .invalid;
    const text_len = cx.inner.len();
    if (at > text_len) return .invalid;
    total.* = text_len - at;
    const n = @min(cap, total.*);
    if (n > 0) cx.inner.extract(gpa, (out orelse return .invalid)[0..n], at);
    return if (total.* == 0) .ok else .match;
}

/// Serialize the index into `out`, up to `cap` bytes — magic, version, payload,
/// BLAKE3 seal. Feed the result back to `load`.
///
/// The same window as every other batch verb, with one wrinkle it earns: the
/// image can only be produced whole, so a call that cannot hand all of it over
/// KEEPS it on the handle and the retry copies out of that rather than
/// serializing a second time. The image is released the moment a call writes it
/// out completely, and by `free` regardless — so the usual sizing probe
/// (`cap == 0`, then allocate, then ask again) costs exactly one serialization
/// and holds the extra copy only between the two calls.
pub fn save(cx: *Codex, out: ?[*]u8, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const total = written orelse return .invalid;
    const image = cx.pending orelse cx.inner.save(gpa) catch
        return contract.report(.{ .code = error.OutOfMemory });
    cx.pending = image;
    total.* = image.len;
    if (cap < image.len) return if (image.len == 0) .ok else .match;
    if (image.len > 0) @memcpy((out orelse return .invalid)[0..image.len], image);
    gpa.free(image);
    cx.pending = null;
    return if (image.len == 0) .ok else .match;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

/// A handle over `text`, or the failure that stopped one being made.
fn built(text: []const u8, opts: ?*const Options) !*Codex {
    var handle: *Codex = undefined;
    try testing.expectEqual(Status.ok, build(text.ptr, text.len, opts, &handle));
    return handle;
}

test "the seam refuses every shape a caller can get wrong" {
    var handle: *Codex = undefined;
    // A null pointer carrying a length is arithmetic, not an empty corpus.
    try testing.expectEqual(Status.invalid, build(null, 9, null, &handle));
    try testing.expectEqual(Status.invalid, build("ab", 2, null, null));
    // Fail-closed sizing, in both directions, and on the reserved word.
    var opts = Options{ .struct_size = @sizeOf(Options) - 1 };
    try testing.expectEqual(Status.invalid, build("ab", 2, &opts, &handle));
    opts = .{ .struct_size = @sizeOf(Options), .encoding = 7 };
    try testing.expectEqual(Status.invalid, build("ab", 2, &opts, &handle));
    opts = .{ .struct_size = @sizeOf(Options), .reserved = 1 };
    try testing.expectEqual(Status.invalid, build("ab", 2, &opts, &handle));

    const cx = try built("mississippi", null);
    defer free(cx);
    var n: usize = 0;
    try testing.expectEqual(Status.invalid, count(cx, null, 3, &n));
    try testing.expectEqual(Status.invalid, count(cx, "iss", 3, null));
    try testing.expectEqual(Status.invalid, position(cx, cx.inner.len() + 1, &n));
    // Past the corpus end is a bug; AT the corpus end is the empty answer.
    try testing.expectEqual(Status.invalid, extract(cx, 12, null, 0, &n));
    try testing.expectEqual(Status.ok, extract(cx, 11, null, 0, &n));
    try testing.expectEqual(@as(usize, 0), n);
    var stats = Stats{ .struct_size = 3, .sample_rate = 0, .locates = 0, .text_len = 0, .index_bytes = 0, .tree_bytes = 0, .locate_bytes = 0 };
    try testing.expectEqual(Status.invalid, measure(cx, &stats));
}

test "a zeroed options struct builds the kernel's own default" {
    const zeroed = Options{ .struct_size = @sizeOf(Options) };
    const cx = try built("mississippi", &zeroed);
    defer free(cx);
    var stats: Stats = undefined;
    stats.struct_size = @sizeOf(Stats);
    try testing.expectEqual(Status.ok, measure(cx, &stats));
    try testing.expectEqual(default_sample_rate, stats.sample_rate);
    try testing.expectEqual(@as(u32, 1), stats.locates);
    try testing.expectEqual(@as(usize, 11), stats.text_len);
    try testing.expectEqual(@as(usize, 11), length(cx));
    try testing.expect(maxTextLen() >= std.math.maxInt(i32));
}

test "count and locate agree, and the window sizes its own retry" {
    const cx = try built("mississippi", null);
    defer free(cx);
    var n: usize = 0;
    try testing.expectEqual(Status.match, count(cx, "issi", 4, &n));
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Status.ok, count(cx, "zz", 2, &n));
    try testing.expectEqual(@as(usize, 0), n);
    // The empty pattern counts nothing rather than every position.
    try testing.expectEqual(Status.ok, count(cx, null, 0, &n));
    try testing.expectEqual(@as(usize, 0), n);

    // The sizing probe: no buffer, and the true total anyway.
    var found: usize = 0;
    try testing.expectEqual(Status.match, locate(cx, "i", 1, null, 0, &found));
    try testing.expectEqual(@as(usize, 4), found);
    // A short window writes what fits and still reports what exists — the
    // property that makes "did I get everything?" decidable.
    var room: [2]usize = @splat(0);
    try testing.expectEqual(Status.match, locate(cx, "i", 1, &room, room.len, &found));
    try testing.expectEqual(@as(usize, 4), found);
    try testing.expectEqual([2]usize{ 1, 4 }, room);
    var all: [4]usize = @splat(0);
    try testing.expectEqual(Status.match, locate(cx, "i", 1, &all, all.len, &found));
    try testing.expectEqual([4]usize{ 1, 4, 7, 10 }, all);
}

test "an index that declines to locate still counts and still extracts" {
    const text = "count only, no locate";
    const opts = Options{ .struct_size = @sizeOf(Options), .sample_rate = no_locate };
    const cx = try built(text, &opts);
    defer free(cx);
    var stats: Stats = undefined;
    stats.struct_size = @sizeOf(Stats);
    try testing.expectEqual(Status.ok, measure(cx, &stats));
    try testing.expectEqual(@as(u32, 0), stats.locates);
    try testing.expectEqual(@as(u32, 0), stats.sample_rate);
    try testing.expectEqual(@as(usize, 0), stats.locate_bytes);

    var n: usize = 0;
    try testing.expectEqual(Status.match, count(cx, "o", 1, &n));
    try testing.expectEqual(@as(usize, 4), n);
    // The declinature: negative, but not an error, and it leaves `*written`
    // alone rather than reporting a total of zero that the host might believe.
    var found: usize = 0xdead;
    try testing.expectEqual(Status.stale, locate(cx, "o", 1, null, 0, &found));
    try testing.expectEqual(@as(usize, 0xdead), found);
    try testing.expectEqual(Status.stale, position(cx, 0, &n));

    var buf: [4]u8 = undefined;
    const at = std.mem.indexOf(u8, text, "only").?;
    try testing.expectEqual(Status.match, extract(cx, at, &buf, buf.len, &n));
    try testing.expectEqualStrings("only", &buf);
    try testing.expectEqual(text.len - at, n);
}

test "the incremental backward search builds its own matcher" {
    const cx = try built("mississippi", null);
    defer free(cx);
    var rows: Rows = undefined;
    try testing.expectEqual(Status.match, rowsWhole(cx, &rows));
    try testing.expectEqual(@as(usize, 12), rows.hi - rows.lo); // every row, sentinel included

    // Right to left, one byte at a time — the same interval `count` derives in
    // one call, reached the way a host writing its own matcher would reach it.
    var j: usize = "issi".len;
    while (j > 0) {
        j -= 1;
        try testing.expectEqual(Status.match, rowsExtend(cx, &rows, "issi"[j]));
    }
    try testing.expectEqual(@as(usize, 2), rows.hi - rows.lo);
    // The interval turned into text, which is what makes the pair usable.
    var seen: [2]usize = undefined;
    for (&seen, rows.lo..) |*p, row| try testing.expectEqual(Status.ok, position(cx, row, p));
    std.mem.sort(usize, &seen, {}, std.sort.asc(usize));
    try testing.expectEqual([2]usize{ 1, 4 }, seen);

    // A byte that cannot precede it empties the interval, and an empty one
    // stays empty however far the host keeps going.
    try testing.expectEqual(Status.ok, rowsExtend(cx, &rows, 'z'));
    try testing.expectEqual(@as(usize, 0), rows.hi - rows.lo);
    try testing.expectEqual(Status.ok, rowsExtend(cx, &rows, 'i'));

    // A caller-invented interval is refused rather than walked.
    rows = .{ .lo = 5, .hi = 4 };
    try testing.expectEqual(Status.invalid, rowsExtend(cx, &rows, 'i'));
    rows = .{ .lo = 0, .hi = 13 };
    try testing.expectEqual(Status.invalid, rowsExtend(cx, &rows, 'i'));
}

test "extract is restore when you ask for all of it" {
    const text = "attribution wants eighty bytes\x00not a gigabyte of them";
    const cx = try built(text, null);
    defer free(cx);
    var n: usize = 0;
    const whole = try testing.allocator.alloc(u8, length(cx));
    defer testing.allocator.free(whole);
    try testing.expectEqual(Status.match, extract(cx, 0, whole.ptr, whole.len, &n));
    try testing.expectEqual(text.len, n);
    try testing.expectEqualStrings(text, whole);

    // Every range of it, against that reconstruction — the seam's own version
    // of the kernel's proof, so a bad offset conversion here cannot hide behind
    // a kernel that is right.
    const buf = try testing.allocator.alloc(u8, text.len);
    defer testing.allocator.free(buf);
    for (0..text.len + 1) |at| {
        for (0..text.len + 1 - at) |take| {
            const st = extract(cx, at, buf.ptr, take, &n);
            try testing.expectEqual(text.len - at, n);
            try testing.expectEqual(if (n == 0) Status.ok else Status.match, st);
            try testing.expectEqualSlices(u8, whole[at..][0..take], buf[0..take]);
        }
    }
}

test "save hands the image over in one piece, however small the window" {
    const cx = try built("integrity is not optional", null);
    defer free(cx);
    // Probe, allocate, ask again: the image is serialized once and held only
    // across the pair.
    var size: usize = 0;
    try testing.expectEqual(Status.match, save(cx, null, 0, &size));
    try testing.expect(size > 0);
    try testing.expect(cx.pending != null);
    const blob = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(blob);
    var again: usize = 0;
    try testing.expectEqual(Status.match, save(cx, blob.ptr, blob.len, &again));
    try testing.expectEqual(size, again);
    try testing.expect(cx.pending == null); // released the moment it lands

    var loaded: *Codex = undefined;
    try testing.expectEqual(Status.ok, load(blob.ptr, blob.len, &loaded));
    defer free(loaded);
    var n: usize = 0;
    try testing.expectEqual(Status.match, count(loaded, "not", 3, &n));
    try testing.expectEqual(@as(usize, 1), n);
    var buf: [9]u8 = undefined;
    try testing.expectEqual(Status.match, extract(loaded, 0, &buf, buf.len, &n));
    try testing.expectEqualStrings("integrity", &buf);

    // Corruption and a version this build cannot read arrive as the same
    // fault, and neither may be answered as an empty index.
    const rotted = try testing.allocator.dupe(u8, blob);
    defer testing.allocator.free(rotted);
    rotted[size / 2] ^= 0x40;
    var refused: *Codex = undefined;
    try testing.expectEqual(Status.open_failed, load(rotted.ptr, rotted.len, &refused));
    try testing.expectEqual(Status.open_failed, load(blob.ptr, blob.len / 2, &refused));
    try testing.expectEqual(Status.invalid, load(null, 4, &refused));
}
