//! Stable C-ABI data contract shared by every package in the ecosystem.
//!
//! This module owns layout and status—not execution. It is the substrate the
//! other three ABIs speak: every product face's library links
//! this library and returns these statuses, these faults, and these rows, so a
//! host that links two of them still reads one vocabulary.
//!
//! It also owns the **one** translation from the kernel's fault vocabulary into
//! that status ("the seam translates exactly once"). The
//! translation belongs here rather than in `fault.zig` because it is the
//! boundary's own job — `fault.zig` owns what a failure *is*, and only a
//! transport knows how to say it. Every rule below is read off
//! `contract/engine.toml`; nothing here invents a mapping.
const std = @import("std");
const fault = @import("../../fault.zig");

/// Which of the three error channels an outcome belongs to — the `disposition`
/// column of `[status_codes]`, made executable.
///
/// It is the load-bearing field precisely because it is the one a consumer
/// would otherwise re-derive from the sign of an integer and get wrong: a
/// `declinature` is negative but is *not* an error (the caller answers one tier
/// down and gets the identical result), and a `fault` must never be flattened
/// into a `result`. With this enum both are properties a switch proves.
pub const Disposition = enum { result, declinature, fault };

/// Every entry returns one status; negative values always mean "decline safely."
pub const Status = enum(i32) {
    ok = 0,
    match = 1,
    stale = -1,
    out_of_memory = -2,
    open_failed = -3,
    invalid = -4,

    /// The channel this status belongs to, per `[status_codes].disposition`.
    pub fn disposition(self: Status) Disposition {
        return switch (self) {
            .ok, .match => .result,
            .stale => .declinature,
            .out_of_memory, .open_failed, .invalid => .fault,
        };
    }

    /// The status a fault crosses the seam as — the single translation, derived
    /// from the contract rather than chosen here. `[status_codes]` binds each
    /// fault-disposition status to one domain of `[fault_domains]`
    /// (`out_of_memory` ↔ resource, `open_failed` ↔ corpus, `invalid` ↔
    /// pattern), so each domain's members follow their own status. Two domains
    /// the C seam has no status for join `open_failed`, the only one whose
    /// subject is the corpus: `persist` (untrustworthy bytes for a corpus
    /// artifact — every one of which is *supposed* to fail closed to the live
    /// path before reaching here) and `wire`, which the contract says cannot
    /// cross this seam at all since the FFI is in-process with no daemon
    /// transport. Both stay total rather than trusted: what the fold loses,
    /// `irgx_last_fault`'s `name` restores per incident.
    ///
    /// Exhaustive on purpose — the NEXT fault member, whatever its ordinal, is a
    /// compile error here instead of a silent `else` prong that would report a new
    /// failure as a clean run.
    pub fn ofFault(f: fault.Fault) Status {
        return switch (f) {
            // `BudgetExceeded` folds here with its domain rather than earning a
            // status of its own. A new status code is an ABI widening every
            // binding must learn, and this fold is the mechanism this seam was
            // built around: what it loses, `irgx_last_fault`'s `name` restores.
            // WHICH ceiling fired does not cross here at all — see the note at
            // `engine.budgetVerdict`. It is deliberately not an `at`/`at_space`
            // pair: every coordinate space names a ruler for a byte OFFSET, and a
            // ceiling ordinal is not an offset into anything.
            error.OutOfMemory,
            error.TimedOut,
            error.Exhausted,
            error.BudgetExceeded,
            => .out_of_memory,
            error.BadPattern,
            error.Unsupported,
            error.BoundUnsupported,
            error.TooManyPatterns,
            error.PowersetCapHit,
            error.NeedleTooShort,
            => .invalid,
            error.FileNotFound,
            error.AccessDenied,
            error.NotDir,
            error.SymLinkLoop,
            error.NameTooLong,
            error.Corrupt,
            error.Truncated,
            error.NonCanonical,
            error.VersionMismatch,
            error.GenerationMismatch,
            error.Oversized,
            error.ConnClosed,
            error.UnexpectedFrame,
            error.StreamTooLong,
            => .open_failed,
        };
    }
};

/// Pattern semantics — what a pattern MEANS, so they belong to the engine that
/// compiles it rather than to any one product. The exact face's library reuses
/// these exact bit values in its own search request and adds its behavioral bits
/// above them, which is why "ignore case" has one definition in the ecosystem.
pub const flag_fixed: u32 = 1 << 0;
pub const flag_ignore_case: u32 = 1 << 1;
pub const flag_word: u32 = 1 << 2;
pub const flag_smart_case: u32 = 1 << 5;
pub const flag_no_unicode: u32 = 1 << 6;
/// `-P`: which grammar the pattern is written in — PCRE2 rather than the
/// linear-time syntax. Bit 8 because that face's behavioral bits already claim
/// 3, 4, and 7; the two sets share one numbering so a flag word means the same
/// thing whichever ABI a host hands it to.
pub const flag_pcre: u32 = 1 << 8;
/// `(?m)`: `^` and `$` also match at a line break, not only at the text's ends.
/// Off by default, as it is in `re`, `rust-regex`, PCRE2 and Go's `regexp` —
/// `\A` and `\z` are the text's ends regardless.
///
/// This is *not* the engine's internal `multiline`, which says "the haystack is
/// a buffer rather than one line" and licenses the whole per-line model. That
/// one is forced on for every pattern this ABI compiles, because a host hands
/// over a whole string and can make no promise about lines; a `\s` that could
/// not see a newline was the bug that separating these two fixed. See
/// `regex/glean/pattern.zig`.
pub const flag_multiline: u32 = 1 << 9;
/// `(?s)`: `.` matches a newline too. Also off by default, and also inert
/// before the buffer model above — the per-line parser had already removed the
/// byte this flag exists to put back.
pub const flag_dotall: u32 = 1 << 10;
/// `(?x)`: ignore unescaped whitespace and `#`-to-end-of-line comments between
/// tokens — Python's `re.VERBOSE`. Off by default.
///
/// It is a *pattern* flag rather than a host convenience because the alternative
/// is worse: a host that pre-strips whitespace itself has to re-implement the
/// grammar to know which spaces are inside a class and which are not, and it
/// reports errors at offsets into a string the user never wrote. Both arms honor
/// this bit (linear parser, PCRE2 `EXTENDED`), so it never forces a host off the
/// linear-time guarantee just to comment a pattern.
pub const flag_verbose: u32 = 1 << 11;

pub const pattern_flags = flag_fixed | flag_ignore_case | flag_word |
    flag_smart_case | flag_no_unicode | flag_pcre | flag_multiline | flag_dotall |
    flag_verbose;

/// The subset of `pattern_flags` a slate pattern can carry.
///
/// A narrower mask rather than the same one, because the slate compiles through
/// `query.Spec`, which has no `(?m)`/`(?s)` knob to carry them into. Rejecting
/// the two it cannot honor is the whole reason this is a separate constant: a
/// host that passes `IRGX_MULTILINE` to a slate has a wrong belief about what it
/// is about to be told, and hearing `IRGX_INVALID` now is strictly better than
/// silently getting single-line anchors and finding out from an answer.
pub const slate_flags = flag_fixed | flag_ignore_case | flag_word |
    flag_smart_case | flag_no_unicode | flag_pcre;

/// A stable, static, NUL-terminated human message for a status code — for a
/// log line, never for a decision (the typed code stays the contract).
///
/// Substrate, so all four ABIs answer one sentence per code rather than four
/// dialects. The wording stays plane-neutral for that reason: `stale` is any
/// tier stepping aside, not specifically a cold search, and `open_failed` is
/// any corpus that would not stand up.
pub fn statusMessage(code: i32) [*:0]const u8 {
    return switch (code) {
        @intFromEnum(Status.ok) => "ok: ran, no (further) match",
        @intFromEnum(Status.match) => "match: a record is available",
        @intFromEnum(Status.stale) => "stale: this tier declines — answer through the fallback",
        @intFromEnum(Status.out_of_memory) => "out of memory",
        @intFromEnum(Status.open_failed) => "open failed: could not stand up the corpus this call needed",
        // Both of `invalid`'s causes, because a host reading only this line
        // after a refused pattern would otherwise go hunting for a null it
        // never passed. Which one it was is `irgx_last_fault`'s to say.
        @intFromEnum(Status.invalid) => "invalid: bad argument, or a pattern this arm cannot compile",
        else => "unknown status",
    };
}

// ── the last-fault pull ──────────────────────────────────────────────────────────
// `sqlite3_errmsg` / `git_error_last` semantics: the host asks AFTER a non-OK
// status, the answer is its own thread's, and it is borrowed until that
// thread's next call. Being a PULL is what keeps it from being a second copy of
// assay's push sink — which the FFI session deliberately keeps `dark`
// (`session.zig`), so the two never carry the same bytes to the same place.
// This adds no sink, no env var, and no escaper: `fault.Detail` is an inert
// value and this entry copies six fields out of it.

/// Which ruler a fault's `at` offset is measured in — the `[coordinate_spaces]`
/// table, made executable.
///
/// One offset, two possible subjects: a byte in the file being read, or a byte
/// in the pattern being compiled. It used to be inferable rather than stated —
/// `at` meant a file offset unless `path` was null — so each binding wrote the
/// same three-clause conjunction, and a missed clause points a user's caret at
/// the wrong string. Naming it costs nothing and removes the inference.
///
/// `none` is 0 because byte 0 is a real offset: absence cannot be spelled by
/// `at`'s own value, so a reader asking only "is there a position" still gets
/// its answer from a zero test.
pub const AtSpace = enum(i32) {
    none = 0,
    file = 1,
    pattern = 2,

    /// The space an installed detail's offset belongs to. A fault with a path
    /// measures against that file; a pathless one that still carries an offset
    /// can only be measuring the pattern, which is the compile seam's case.
    pub fn of(d: fault.Detail) AtSpace {
        if (d.at == null) return .none;
        return if (d.path.len == 0) .pattern else .file;
    }
};

/// Per-incident detail for this thread's last fault — what a static per-code
/// string cannot say: which fault, about which file, at which byte.
///
/// The C-ABI twin of `fault.Detail`. `struct_size` is set by the CALLER and the
/// layout is append-only, so a newer field is a forward-compatible extension
/// and an unknown size fails closed exactly like `SearchRequest`'s.
pub const FaultDetail = extern struct {
    struct_size: u32,
    /// The `Status` this fault translated to — always `fault` disposition.
    status: i32,
    /// Which ruler `at` is measured in, per `[coordinate_spaces]`. Zero means
    /// there is no offset at all, so this stays the "is `at` meaningful" test it
    /// replaced while also answering what it is an offset INTO.
    at_space: i32,
    /// The fault's name — one of `[fault_domains]`' members (`Corrupt`,
    /// `AccessDenied`). NUL-terminated, static lifetime, never null.
    name: [*:0]const u8,
    /// The file the fault was about, or null when it was about no single one.
    /// Borrows the thread slot: NOT NUL-terminated (use `path_len`), valid
    /// until this thread's next work call.
    path: ?[*]const u8,
    path_len: usize,
    /// The offset the fault was detected at, in whichever space `at_space`
    /// names. Zero and meaningless when that is `none`.
    at: u64,
};

/// Fill `out` with this thread's last fault: `.match` when one was written,
/// `.ok` when the thread has none, `.invalid` for a null or wrongly-sized `out`.
/// That is the same pull grammar `cursorNext` speaks, so the surface gains no
/// second vocabulary for "there is nothing more."
///
/// A non-OK status does **not** imply a detail exists, and `.ok` here is not a
/// contradiction of it. The seam's own argument guards (`.invalid` for a null
/// pointer or a stale `struct_size`) have no per-incident detail to add over
/// `irgx_status_message`, and a declinature is not a fault at all — so `.ok`
/// means "nothing further to say", never "the call succeeded".
///
/// **`.ok` still writes.** It used to leave `out` untouched, which made the
/// struct's emptiness the caller's problem: a host that cleared only the field
/// it went on to test kept whatever its own stack had left in the others, and a
/// later reader had no way to know `at` was never set. Two independent bindings
/// had to defend against that, so the seam does it once — every field is cleared
/// and `name` becomes the empty string rather than null, keeping its promise.
///
/// Reading does not consume: a host may ask twice, or ask after
/// `irgx_status_message`, and get the same answer.
pub fn lastFault(out: ?*FaultDetail) Status {
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(FaultDetail)) return .invalid;
    const d = fault.last() orelse {
        slot.* = .{
            .struct_size = @sizeOf(FaultDetail),
            .status = @intFromEnum(Status.ok),
            .at_space = @intFromEnum(AtSpace.none),
            .name = "",
            .path = null,
            .path_len = 0,
            .at = 0,
        };
        return .ok;
    };
    slot.* = .{
        .struct_size = @sizeOf(FaultDetail),
        .status = @intFromEnum(Status.ofFault(d.code)),
        .at_space = @intFromEnum(AtSpace.of(d)),
        .name = @errorName(d.code).ptr,
        .path = if (d.path.len == 0) null else d.path.ptr,
        .path_len = d.path.len,
        .at = d.at orelse 0,
    };
    return .match;
}

/// Record `d` and hand back the status it crosses as — the seam's single act of
/// translation, so no entry point spells a fault's status without also leaving
/// the host the detail behind it.
///
/// A **declinature never comes through here**: `.stale` is returned directly by
/// its call sites, which is what keeps `irgx_last_fault` silent about a tier
/// that merely stepped aside.
pub fn report(d: fault.Detail) Status {
    fault.install(d);
    return Status.ofFault(d.code);
}

/// `report` for a failure whose error set the seam cannot switch over: the warm
/// engine's `open` path infers its errors from `std` (path joins, mmap, the
/// artifact loaders), so members outside the taxonomy ride it. One the taxonomy
/// names is reported in full; anything else returns `unknown` with **no**
/// detail, because naming a fault the kernel never declared would be worse than
/// silence.
pub fn reportAny(e: anyerror, unknown: Status) Status {
    inline for (@typeInfo(fault.Fault).error_set.?) |m|
        if (e == @field(fault.Fault, m.name)) return report(.{ .code = @field(fault.Fault, m.name) });
    return unknown;
}

/// Open one C-ABI call's fault window: drop whatever the PREVIOUS call on this
/// thread left in the slot, so a host asking after a **successful** call is
/// handed nothing rather than an earlier failure.
///
/// Deliberately unpaired with `Scope.end()`, which is the whole policy. The
/// fault a call installs must OUTLIVE that call — that is the borrow the header
/// promises — so the window closes at the NEXT work call's `beginCall`, not at
/// this one's return; ending the scope would restore precisely the stale fault
/// this exists to prevent. (Nested Zig cleanup paths still pair `scope`/`end`
/// normally: they must not displace the fault their caller is about to report.)
///
/// Only the entries that START work call it. Teardown (`close`, `cursorClose`,
/// `cancelFree`, `engineClose`) and the two pure readers
/// (`irgx_status_message`, `irgx_last_fault`) leave the slot alone, so a
/// host can still report the detail from its cleanup path — the one place a
/// uniform "every call clears" rule would silently eat it.
///
/// `clear`, not `scope`, because there is no "afterwards" to restore into — and
/// because `cursorNext` is a per-record entry, so the difference is a tag-byte
/// store instead of copying a 512-byte path buffer out to discard it.
pub fn beginCall() void {
    fault.clear();
}

/// Borrow a `(pointer, length)` pair as a slice, or refuse it.
///
/// The C ABI's only way to say "no text" is a null pointer, and its only way to
/// say "empty text" is a zero length — but a host that computes both from the
/// same expression can hand over null WITH a length, which is a bug in the
/// caller and not an empty string. So null-with-length is `null` here, which
/// every call site turns into `.invalid`; null-with-zero is the empty slice,
/// because a pattern legitimately matches against nothing.
///
/// Lives here rather than in each plane because the three shipped planes had
/// three byte-identical copies, and the `dup-helper` ratchet stands at zero: a
/// fourth would fail a gate no single plane owns.
pub fn view(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| return p[0..len];
    return if (len == 0) &.{} else null;
}

/// The count-versus-capacity window every batch verb publishes.
///
/// The contract these all share is that `*written` is the **true total** and
/// `cap` is merely how much of it the host gave us room for — so a host can ask
/// with `cap = 0` purely to be told the size, then allocate once and ask again.
/// Writing that by hand is four lines of guard and an `if (n < cap)` inside the
/// producer loop, repeated per verb; getting it subtly wrong (capping the count
/// as well as the write) is the silent version, where a host's second call
/// allocates exactly enough room for the truncated answer it already had.
///
/// `open` returns null for the one shape that is a caller bug — no `written`
/// slot, or a null buffer with a non-zero `cap`. `cap = 0` with a null buffer is
/// the legal counting probe.
pub fn Sink(comptime T: type) type {
    return struct {
        room: []T,
        n: usize = 0,
        total: *usize,

        const Self = @This();

        pub fn open(out: ?[*]T, cap: usize, written: ?*usize) ?Self {
            const total = written orelse return null;
            total.* = 0;
            if (cap == 0) return .{ .room = &.{}, .total = total };
            return .{ .room = (out orelse return null)[0..cap], .total = total };
        }

        /// Count it always; store it only if the host left room.
        pub fn push(self: *Self, v: T) void {
            if (self.n < self.room.len) self.room[self.n] = v;
            self.n += 1;
        }

        /// Publish the true total and cross as the batch verbs do: `.ok` for an
        /// empty answer, `.match` for a non-empty one.
        pub fn close(self: *Self) Status {
            self.total.* = self.n;
            return if (self.n == 0) .ok else .match;
        }
    };
}

test "view separates no-text from empty-text" {
    const t = std.testing;
    try t.expectEqualStrings("", view(null, 0).?);
    // A null pointer carrying a length is the caller's arithmetic bug, and the
    // one case that must not read back as an innocent empty string.
    try t.expect(view(null, 7) == null);
    const hay = "abc";
    try t.expectEqualStrings("abc", view(hay.ptr, hay.len).?);
    // A live pointer with zero length is still empty, not refused.
    try t.expectEqualStrings("", view(hay.ptr, 0).?);
}

test "a sink counts past the capacity it writes into" {
    const t = std.testing;
    var seen: usize = 0;
    var room: [2]u32 = .{ 0, 0 };

    var sink = Sink(u32).open(&room, room.len, &seen).?;
    for ([_]u32{ 10, 11, 12, 13 }) |v| sink.push(v);
    try t.expectEqual(Status.match, sink.close());
    // The whole point: four found, two stored, and the host is told four.
    try t.expectEqual(@as(usize, 4), seen);
    try t.expectEqual([2]u32{ 10, 11 }, room);

    // The counting probe — no buffer at all, and a real total.
    var probe = Sink(u32).open(null, 0, &seen).?;
    probe.push(1);
    probe.push(2);
    try t.expectEqual(Status.match, probe.close());
    try t.expectEqual(@as(usize, 2), seen);

    // An empty answer crosses as a result, not a match.
    var none = Sink(u32).open(&room, room.len, &seen).?;
    try t.expectEqual(Status.ok, none.close());
    try t.expectEqual(@as(usize, 0), seen);

    // Caller bugs: no total slot, and room promised but not given.
    try t.expect(Sink(u32).open(&room, room.len, null) == null);
    try t.expect(Sink(u32).open(null, 4, &seen) == null);
}

test "each status keeps the channel the contract assigns it" {
    const t = std.testing;
    try t.expectEqual(Disposition.result, Status.ok.disposition());
    try t.expectEqual(Disposition.result, Status.match.disposition());
    // The row the whole field exists for: negative, but NOT an error value.
    try t.expectEqual(Disposition.declinature, Status.stale.disposition());
    try t.expectEqual(Disposition.fault, Status.out_of_memory.disposition());
    try t.expectEqual(Disposition.fault, Status.open_failed.disposition());
    try t.expectEqual(Disposition.fault, Status.invalid.disposition());
}

test "every fault crosses the seam as a fault — never a result, never a declinature" {
    const all = [_]fault.Fault{
        error.FileNotFound,    error.AccessDenied,       error.NotDir,           error.SymLinkLoop,
        error.NameTooLong,     error.Corrupt,            error.Truncated,        error.NonCanonical,
        error.VersionMismatch, error.GenerationMismatch, error.Oversized,        error.BadPattern,
        error.Unsupported,     error.TooManyPatterns,    error.PowersetCapHit,   error.NeedleTooShort,
        error.OutOfMemory,     error.TimedOut,           error.Exhausted,        error.ConnClosed,
        error.UnexpectedFrame, error.StreamTooLong,      error.BoundUnsupported, error.BudgetExceeded,
    };
    // Pinned to the taxonomy's own size, so a new member cannot slip past this
    // loop by simply not being listed (the switch in `ofFault` catches it too).
    try std.testing.expectEqual(@typeInfo(fault.Fault).error_set.?.len, all.len);
    for (all) |f| try std.testing.expectEqual(Disposition.fault, Status.ofFault(f).disposition());

    // The domain bindings themselves, one witness each.
    try std.testing.expectEqual(Status.out_of_memory, Status.ofFault(error.OutOfMemory));
    try std.testing.expectEqual(Status.invalid, Status.ofFault(error.TooManyPatterns));
    try std.testing.expectEqual(Status.open_failed, Status.ofFault(error.AccessDenied));
    try std.testing.expectEqual(Status.open_failed, Status.ofFault(error.Corrupt));
}

test "the pull hands back the leaf's detail, repeatably, and fails closed" {
    const t = std.testing;
    const sc = fault.scope();
    defer sc.end();

    var out: FaultDetail = undefined;
    out.struct_size = @sizeOf(FaultDetail);
    try t.expectEqual(Status.ok, lastFault(&out)); // a clean thread says nothing

    fault.install(.{ .code = error.Corrupt, .path = "kinship.atlas", .at = 12 });
    try t.expectEqual(Status.match, lastFault(&out));
    try t.expectEqual(@intFromEnum(Status.open_failed), out.status);
    try t.expectEqualStrings("Corrupt", std.mem.span(out.name));
    try t.expectEqualStrings("kinship.atlas", out.path.?[0..out.path_len]);
    try t.expectEqual(@as(u64, 12), out.at);
    try t.expectEqual(@intFromEnum(AtSpace.file), out.at_space);
    try t.expectEqual(Status.match, lastFault(&out)); // reading is not consuming

    // A pathless fault reports absence, not a zero offset over a null pointer.
    fault.install(.{ .code = error.OutOfMemory });
    try t.expectEqual(Status.match, lastFault(&out));
    try t.expectEqual(@intFromEnum(Status.out_of_memory), out.status);
    try t.expect(out.path == null);
    try t.expectEqual(@intFromEnum(AtSpace.none), out.at_space);

    // The distinction the field exists for: same struct, same `at`, a different
    // ruler. A refused pattern is about no file, so its offset indexes the
    // pattern — and a reader must not have to notice that `path` came back null
    // to work that out.
    fault.install(.{ .code = error.BadPattern, .at = 3 });
    try t.expectEqual(Status.match, lastFault(&out));
    try t.expectEqual(@intFromEnum(AtSpace.pattern), out.at_space);
    try t.expectEqual(@as(u64, 3), out.at);
    try t.expect(out.path == null);

    out.struct_size = 0;
    try t.expectEqual(Status.invalid, lastFault(&out));
    try t.expectEqual(Status.invalid, lastFault(null));
}

test "an empty pull clears the slot rather than leaving the caller's stack in it" {
    const t = std.testing;
    const sc = fault.scope();
    defer sc.end();

    // What a host actually hands in: a struct it never initialized. If the
    // empty case left this alone, every field below would read back as 0xAA…
    // — a plausible offset, a non-null path, a name pointing nowhere — and a
    // reader that trusted `at_space` would act on all three.
    var out: FaultDetail = undefined;
    @memset(std.mem.asBytes(&out), 0xAA);
    out.struct_size = @sizeOf(FaultDetail);

    try t.expectEqual(Status.ok, lastFault(&out));
    try t.expectEqual(@intFromEnum(Status.ok), out.status);
    try t.expectEqual(@intFromEnum(AtSpace.none), out.at_space);
    try t.expectEqual(@as(u64, 0), out.at);
    try t.expect(out.path == null);
    try t.expectEqual(@as(usize, 0), out.path_len);
    // `name` keeps its "never null" promise by going empty, not by going away.
    try t.expectEqualStrings("", std.mem.span(out.name));
}
