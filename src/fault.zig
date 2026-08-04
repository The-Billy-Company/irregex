//! The kernel's error vocabulary: what a failure *is*, and what a declinature
//! is instead (fault-channel law 1–3).
//!
//! irregex is one kernel behind four planes, and until this module each plane
//! answered "which of these outcomes is even an error?" its own way. Two facts
//! forced the answer into one file.
//!
//! **Zig unifies error names globally.** `error.Corrupt`, `error.BadFormat`
//! and `error.CorruptIndex` all meant "these persisted bytes are
//! untrustworthy", which is worse than untidy: synonyms cannot be handled
//! uniformly and homonyms merge silently. So the merge has to be deliberate —
//! five sets are declared here and every producer imports them rather than
//! minting a sixth spelling for a fact that already has one.
//!
//! **A declinature is not a failure.** Eight names — `Bail`, `Stale`,
//! `NoIndex`, `NotWorthwhile`, … — meant *"this accelerator declines; a correct
//! answer exists one tier down"*. Riding the error channel, `try` — the thing a
//! new call site reaches for without thinking — converted a routine fallback
//! into an abort, silently, with no compiler complaint. `Answer(T)` moves them
//! into the **success** position, where `try` cannot reach them at all.
//!
//! The two vocabularies overlap on exactly one fact, and that is the design
//! rather than a leak: `Pattern.Unsupported` and `Decline.unsupported_syntax`
//! are the same observation about a pattern the linear engine cannot express.
//! It is a declinature while PCRE2 can still answer it and a fault once the
//! caller has refused PCRE2. `Decline.refused` is the single point where one
//! becomes the other, and it is partial on purpose — see there.
//!
//! Scope is exact: this module owns **vocabulary, payload, and disposition**,
//! and owns no transport. Where a diagnostic goes, whether it renders as prose
//! or as one NDJSON record, and which `GIST_*` knob gates it are `assay`'s
//! decisions and stay there. `Detail` is an inert value, never a sink.
//!
//! `spare` (law 8) is the single outbound call, and it does not weaken that
//! line: deciding a failure is spared rather than propagated is disposition,
//! and it hands assay a lens name and a format string — assay still decides
//! whether that reaches a stream, and in which shape.

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("assay/assay.zig");

// ── law 2: one flat taxonomy, five domains, declared once ──
//
// Flat rather than hierarchical because Zig error sets do not nest and the
// taxonomy's job is uniform handling, which flatness serves better than depth.
// The domain is the unit a handler switches over; `Fault` is the union for the
// surfaces that carry any of them.

/// A path in the tree could not be read or descended. Exactly the set
/// ripgrep's walk reports, so `pathNote` below can be exhaustive over it.
pub const Corpus = error{ FileNotFound, AccessDenied, NotDir, SymLinkLoop, NameTooLong };

/// Persisted bytes are untrustworthy — the trigram index, the kinship atlas,
/// the codex shelf, the fragment table. `BadFormat` and `CorruptIndex`
/// collapse into `Corrupt`: one fact, one spelling. Every artifact fails
/// **closed** to the live path, so a persist fault costs speed, never answers.
///
/// `Oversized` is the writer's mirror of the same closure: the artifact this
/// corpus *would* need does not fit what can hold or address it — more docs
/// than the record count admits, a length that overflows, a destination too
/// short. Three spellings of that (`TooManyDocuments`, `SizeOverflow`,
/// `BufferTooSmall`) named the check rather than the fact, and no caller ever
/// told them apart.
pub const Persist = error{ Corrupt, Truncated, NonCanonical, VersionMismatch, GenerationMismatch, Oversized };

/// The query itself has no answer under the selected engine. `Unsupported` is
/// the member that also lives in the declinature vocabulary (`Decline.refused`);
/// `BadPattern` is deliberately NOT that — a pattern the grammar rejects
/// (`(unterminated`) has no answer under ANY engine, so escalating to PCRE2
/// would only reproduce the same rejection.
///
/// `BoundUnsupported` is the one that points the other way, and it is a member
/// rather than a declinature for exactly that reason: a bounded window asks the
/// engine to search `[from, to]` while still reading the haystack end to end,
/// which the linear engine does natively and PCRE2 structurally cannot — its
/// subject has one length, so the only way to stop a match at `to` is to claim
/// the subject ends there, which also moves `$`, `\z`, `\b`, and every
/// lookahead. So there is no slower tier to route to (`Decline`'s invariant is
/// that every member names one), and the remedy is a different engine, not a
/// bigger one. Distinct from `Unsupported` because a host that conflated them
/// would retry under PCRE2 — the one arm guaranteed to refuse again.
pub const Pattern = error{ BadPattern, Unsupported, BoundUnsupported, TooManyPatterns, PowersetCapHit, NeedleTooShort };

/// The machine or the budget ran out. `OutOfMemory` is the one the `zig-oom`
/// ratchet already keeps to a single canonical exit in the command plane;
/// `Exhausted` is its non-heap sibling — the OS refused a *handle* (a fork, a
/// pipe), which is the same fact about the same machine and wants the same
/// prong, not a `ForkFailed`/`WakePipeFailed` pair naming the call site instead
/// of the condition.
pub const Resource = error{ OutOfMemory, TimedOut, Exhausted };

/// The resident-session UDS protocol failed mid-frame. It does not cross the C
/// seam — the FFI is in-process and has no daemon transport — and the daemon
/// *client* converts one into a declinature at its own boundary by falling open
/// to the cold subprocess. The daemon itself has no slower tier, so it faults.
pub const Wire = error{ ConnClosed, UnexpectedFrame, StreamTooLong };

/// Every fault the kernel can produce, for the surfaces that must hold any of
/// them (`Detail.code`, and the C seam's status translation). A handler that
/// can act on the difference should take the narrower domain instead.
pub const Fault = Corpus || Persist || Pattern || Resource || Wire;

// ── law 1: declinature leaves the error channel ──

/// Why a tier declined. **Every member names a slower tier that can answer**,
/// which is what makes a declinature a routing fact rather than a failure. It
/// applies at six seams and nowhere else — warm→cold, linear→PCRE2,
/// indexed→live, shadow-rewriter→none, bulk-stat→per-file, daemon→subprocess.
/// Inside a tier, `try` and ordinary error sets are unchanged.
pub const Decline = enum {
    /// The linear engine cannot express this pattern (lookaround, a
    /// backreference). PCRE2 can. Also the shadow rewriter declining a pattern
    /// it cannot safely rewrite, which PCRE2 then answers unrewritten.
    unsupported_syntax,
    /// The warm tier cannot prove its resident bytes still match the tree.
    /// The cold path re-reads it.
    freshness_unprovable,
    /// No persisted index covers these roots. The live walk does.
    index_absent,
    /// One does cover them and the savings model said it would not pay. The
    /// live walk is the cheaper answer here, not a worse one.
    not_worthwhile,
    /// The platform lacks the syscall this accelerator rides (bulk stat). The
    /// per-file path does the same work, slower.
    capability_missing,

    /// The fault this declinature becomes when the caller has **forbidden** the
    /// tier that would have answered — the one place the two vocabularies meet.
    ///
    /// Partial by design. Only `unsupported_syntax` is refusable: `--engine
    /// linear` is the caller saying "do not escalate to PCRE2", and the fact
    /// then has no answer anywhere. The other four fall back to a tier that is
    /// always present (the cold scan, the live walk, per-file stat), so there
    /// is nothing to refuse and returning a fault for them would be a lie.
    pub fn refused(d: Decline) ?Pattern {
        return switch (d) {
            .unsupported_syntax => error.Unsupported,
            .freshness_unprovable, .index_absent, .not_worthwhile, .capability_missing => null,
        };
    }
};

/// A tiered answer: the value, or the reason a tier declined to produce it.
///
/// The declinature sits in the success position deliberately. `try` cannot
/// reach it, so a call site cannot convert a routine fallback into an abort
/// without the compiler first making it say what to do with the other prong.
pub fn Answer(comptime T: type) type {
    return union(enum) { got: T, declined: Decline };
}

// ── law 3: the payload rides a thread-local slot ──
//
// Zig error values are payload-free, and the obvious alternative — the
// diagnostics out-parameter `std.zig.Ast.parse` and `std.json` use — infects
// every intermediate signature between the leaf that knows the detail and the
// surface that renders it. That cost is paid by functions which neither
// produce nor consume the detail, on paths that never fail, and it scales with
// call-chain depth rather than with failure sites. One slot costs the leaf a
// line and everything between it and the surface nothing.
//
// It is also assay's own idiom (`install` / `scope`), so the package gains no
// second convention, and it is the one mechanism the C ABI's last-fault pull
// reads — `sqlite3_errmsg` / `git_error_last` semantics: last fault wins, per
// thread, borrowed until the next call on this thread. Per-thread is the right
// granularity for the parallel engine too; a worker's fault is its own, and the
// aggregate verdict already travels by its existing walk-error atomic.

/// What a fault was about. An **inert value**: constructing one records
/// nothing and renders nothing. `install` puts it in the slot, `last` reads it
/// back, and assay alone decides whether any of it reaches a stream.
pub const Detail = struct {
    code: Fault,
    /// The file the fault was about, when it was about one. Borrowed on the
    /// way in (the slot copies it) and borrowed on the way out (it points at
    /// the slot). Never owning — the slot has no allocator.
    path: []const u8 = "",
    /// Byte offset within `path` at which the fault was detected — a corrupt
    /// header, a truncated record. Absent when the fault is about the file as
    /// a whole.
    at: ?u64 = null,
};

/// The slot's own storage. A detail outlives the leaf's scratch arena — the C
/// ABI reads it *after* the failing call has returned — so the slot copies the
/// path instead of aliasing it. Long enough for any real repository path;
/// beyond it the path truncates rather than allocating, because the diagnostic
/// must never be the thing that fails.
const path_cap = 512;

const Slot = struct {
    code: Fault,
    at: ?u64,
    path: [path_cap]u8,
    path_len: usize,
};

threadlocal var slot: ?Slot = null;

/// Record `d` as this thread's last fault, displacing any previous one. The
/// leaf's single line on the way out, beside its `return error.…`.
pub fn install(d: Detail) void {
    const n = @min(d.path.len, path_cap);
    var s = Slot{ .code = d.code, .at = d.at, .path = undefined, .path_len = n };
    @memcpy(s.path[0..n], d.path[0..n]);
    slot = s;
}

/// This thread's last fault, or null if it has none. The returned `path`
/// borrows the slot and stays valid until the next `install` on this thread.
pub fn last() ?Detail {
    if (slot) |*s| return .{ .code = s.code, .path = s.path[0..s.path_len], .at = s.at };
    return null;
}

/// Drop this thread's fault without keeping anything to restore — the open half
/// of `scope`, for a caller that never wants the old value back.
///
/// A C entry point is exactly that caller: it opens a window so a host asking
/// after a *successful* call is never handed a stale fault, and it has no
/// "afterwards" in which to restore one. `scope()` would hand it a `Scope`
/// carrying a whole `Slot` by value — a 512-byte path buffer — to immediately
/// discard, which is a real cost on a per-record entry like `cursorNext`. This
/// writes the optional's tag and nothing else.
pub fn clear() void {
    slot = null;
}

/// A scoped isolation of the slot, restored by `end()` — pair it with `defer`,
/// exactly like `assay.scope`. The caller that needs the restore is a
/// best-effort cleanup path, whose own faults must not displace the fault its
/// caller is about to be told about. A caller that wants no restore wants
/// `clear`.
pub const Scope = struct {
    prev: ?Slot,

    pub fn end(self: Scope) void {
        slot = self.prev;
    }
};

pub fn scope() Scope {
    const prev = slot;
    slot = null;
    return .{ .prev = prev };
}

// ── law 8: a discarded failure is a named operation, not an empty block ──
//
// About one call in twenty here is best-effort: unlinking the temp file an
// atomic rename already superseded, an optional sidecar, a socket nicety, a
// journal note the next run would rebuild anyway. Those have nowhere to return
// to — the answer is already computed, or already failing for another reason —
// and discarding the failure is the correct local decision.
//
// `catch {}` is also the exact shape of *forgetting*, and no reviewer can tell
// the two apart. That ambiguity is the whole cost: it is why 70 empty blocks
// accumulated behind a gate that believed the kernel was clean. So the empty
// block is banned outright and the deliberate ones come through here, where
// intent is stated and the failure is observable rather than gone.

/// Discard a failure that cannot change the answer — on the record.
///
/// `what` names the intent at the site, which is what an empty block cannot do.
/// The failure then lands on the `fault` lens instead of vanishing, so
/// `GIST_TRACE=fault` shows every spared failure in a run while the default run
/// stays silent. Cost when the lens is dark is one relaxed atomic load, and only
/// on the failing branch.
///
/// Takes the *result*, so a call site reads as one expression:
///
///     fault.spare("unlink superseded temp", Dir.cwd().deleteFile(io, tmp));
///
/// Which means the spared call has already run by the time we are here — if it
/// installed a `Detail`, it has already displaced the caller's. That is only
/// possible for a host function (std never installs), and the fix is the
/// explicit `scope()` the caller already has; `spare` does not pretend to do it,
/// because a scope opened after the fact would restore the wrong thing.
pub fn spare(what: []const u8, result: anytype) void {
    if (result) |_| {} else |e| assay.trace(.fault, "spared {s}: {t}\n", .{ what, e });
}

// ── what law 2 buys: an exhaustive renderer ──

/// ripgrep's `<bin>: <path>: <errno phrase>` note for a path that could not be
/// opened or descended.
///
/// The switch is exhaustive over the corpus domain, and that is the whole
/// payoff: the version this stands in front of takes `anyerror` and falls
/// through to `@errorName`, so a new member becomes a mystery string in a
/// user's terminal instead of a compile error here.
///
/// The phrases are ripgrep's own, byte for byte. The differential harness keys
/// on the errno phrase and the exit class (never the `rg:`/`gist:` prefix), so
/// these strings are contract, not prose.
pub fn pathNote(e: Corpus) []const u8 {
    return switch (e) {
        // ENOENT/EACCES/ENOTDIR carry the same number on every target we build.
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied => "Permission denied (os error 13)",
        error.NotDir => "Not a directory (os error 20)",
        // These two do NOT: ELOOP and ENAMETOOLONG are 62/63 on Darwin but
        // 40/36 on Linux. ripgrep prints whatever number the OS gave it, so a
        // literal here is right on the machine it was written on and wrong on
        // the other — silently, and only in the differential harness's output.
        error.SymLinkLoop => errnoNote("Too many levels of symbolic links", .LOOP),
        error.NameTooLong => errnoNote("File name too long", .NAMETOOLONG),
    };
}

/// `pathNote`'s phrase when `e` is a corpus member, else the raw error name —
/// for the producers whose own error set is WIDER than the domain. A real
/// descent yields EMFILE, ENODEV, a bad UTF-8 name; a file read yields its own
/// set. ripgrep prints the OS string for those too, so the widening is the
/// filesystem's truth rather than an erased domain.
///
/// It does not weaken law 2. Each caller still names its set (`notice.WalkFault`
/// and friends) and `pathNote` above stays exhaustive, so a sixth corpus member
/// is still a compile error there — and picks up rg's phrasing here for every
/// producer at once, rather than in whichever one happened to be updated.
pub fn pathNoteOf(e: anytype) []const u8 {
    inline for (@typeInfo(Corpus).error_set.?) |m| {
        const member = @field(Corpus, m.name);
        if (e == member) return pathNote(member);
    }
    return @errorName(e);
}

/// `<phrase> (os error <n>)` with `n` read from the TARGET's errno table.
fn errnoNote(comptime phrase: []const u8, comptime e: std.posix.E) []const u8 {
    return std.fmt.comptimePrint("{s} (os error {d})", .{ phrase, @intFromEnum(e) });
}

test "the five domains merge without collapsing a member" {
    // The load-bearing row: Zig unifies error names globally, so two domains
    // that reached for the same spelling would merge SILENTLY and become
    // indistinguishable at every handler. 5 + 6 + 6 + 3 + 3 = 23 is the proof
    // that no two did.
    try std.testing.expectEqual(@as(usize, 23), @typeInfo(Fault).error_set.?.len);
}

test "pathNote answers each corpus member with ripgrep's own phrasing" {
    try std.testing.expectEqualStrings("No such file or directory (os error 2)", pathNote(error.FileNotFound));
    try std.testing.expectEqualStrings("Permission denied (os error 13)", pathNote(error.AccessDenied));
    try std.testing.expectEqualStrings("Not a directory (os error 20)", pathNote(error.NotDir));
    // The two platform-varying rows, asserted against the numbers this target's
    // libc actually reports rather than against `pathNote`'s own lookup — the
    // point is to catch a literal that only holds on the author's machine, and a
    // test that re-derived it the same way could not.
    const loop, const long = switch (builtin.os.tag) {
        .linux => .{ "os error 40", "os error 36" },
        else => .{ "os error 62", "os error 63" },
    };
    try std.testing.expectEqualStrings("Too many levels of symbolic links (" ++ loop ++ ")", pathNote(error.SymLinkLoop));
    try std.testing.expectEqualStrings("File name too long (" ++ long ++ ")", pathNote(error.NameTooLong));
}

test "pathNoteOf answers a wider producer's set without erasing the domain" {
    const Wider = Corpus || error{ SystemFdQuotaExceeded, InvalidUtf8 };
    const denied: Wider = error.AccessDenied;
    const alien: Wider = error.SystemFdQuotaExceeded;
    try std.testing.expectEqualStrings("Permission denied (os error 13)", pathNoteOf(denied));
    try std.testing.expectEqualStrings("SystemFdQuotaExceeded", pathNoteOf(alien));
}

test "Answer keeps a declinature in the success position" {
    const declined: Answer(u32) = .{ .declined = .index_absent };
    switch (declined) {
        .got => try std.testing.expect(false),
        .declined => |d| try std.testing.expectEqual(Decline.index_absent, d),
    }
    const answered: Answer(u32) = .{ .got = 7 };
    try std.testing.expectEqual(@as(u32, 7), answered.got);
}

test "only the refusable declinature has a fault twin" {
    // One fact, two vocabularies: `--engine linear` refuses PCRE2, so the
    // pattern that was merely routable becomes unanswerable.
    try std.testing.expectEqual(@as(?Pattern, error.Unsupported), Decline.unsupported_syntax.refused());
    for ([_]Decline{ .freshness_unprovable, .index_absent, .not_worthwhile, .capability_missing }) |d|
        try std.testing.expect(d.refused() == null);
}

test "the slot owns its path and the last fault wins" {
    const sc = scope();
    defer sc.end();
    try std.testing.expect(last() == null);

    var scratch = "atlas.bin".*;
    install(.{ .code = error.Corrupt, .path = &scratch, .at = 12 });
    @memset(&scratch, 'x'); // the leaf's buffer dies; the slot must not follow.

    const d = last().?;
    try std.testing.expectEqual(@as(Fault, error.Corrupt), d.code);
    try std.testing.expectEqualStrings("atlas.bin", d.path);
    try std.testing.expectEqual(@as(?u64, 12), d.at);

    install(.{ .code = error.TimedOut });
    try std.testing.expectEqual(@as(Fault, error.TimedOut), last().?.code);
    try std.testing.expectEqualStrings("", last().?.path);
}

test "a nested scope cannot displace the caller's last fault" {
    const outer = scope();
    defer outer.end();
    install(.{ .code = error.AccessDenied, .path = "vendor" });

    {
        const inner = scope();
        defer inner.end();
        try std.testing.expect(last() == null); // a nested run starts clean
        install(.{ .code = error.ConnClosed });
    }
    try std.testing.expectEqual(@as(Fault, error.AccessDenied), last().?.code);
}

test "a spared failure is silent by default and visible under its lens" {
    // The whole difference from `catch {}`: the failure still exists. Capture
    // assay's stream so the assertion is on the bytes a user would see.
    const gpa = std.testing.allocator;
    var cap: std.ArrayList(u8) = .empty;
    defer cap.deinit(gpa);

    const sink = assay.scope(.{ .buffer = .{ .gpa = gpa, .list = &cap } });
    defer sink.end();
    defer assay.install(.{}); // this test writes process-wide policy; put it back

    const failed: error{Corrupt}!void = error.Corrupt;
    const fine: error{Corrupt}!void = {};

    assay.install(.{ .lenses = 0 }); // default run: no lens lit
    spare("unlink superseded temp", failed);
    try std.testing.expectEqualStrings("", cap.items);

    assay.install(.{ .lenses = @as(u32, 1) << @intFromEnum(assay.Lens.fault) });
    spare("unlink superseded temp", failed);
    try std.testing.expect(std.mem.indexOf(u8, cap.items, "unlink superseded temp") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.items, "Corrupt") != null);

    // A success spares nothing — the lens stays quiet on the happy path.
    cap.clearRetainingCapacity();
    spare("unlink superseded temp", fine);
    try std.testing.expectEqualStrings("", cap.items);
}

test "an oversized path truncates rather than failing the diagnostic" {
    const sc = scope();
    defer sc.end();
    install(.{ .code = error.NameTooLong, .path = "z" ** (path_cap + 7) });
    try std.testing.expectEqual(path_cap, last().?.path.len);
}
