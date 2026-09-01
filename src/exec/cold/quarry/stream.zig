//! Stdin as a haystack: admitting and draining fd 0.
//!
//! `cmd | … pat` must search the stream instead of walking the tree, which
//! makes "is fd 0 readable?" a correctness question, not a convenience. The rule
//! is ripgrep's (`is_readable_stdin`: not a tty, and a file / FIFO / socket),
//! with two deliberate departures the sections below justify in full: a stream
//! must prove itself with a byte before we commit to draining it, and a haystack
//! with no a-priori length still gets a ceiling.
//!
//! The classification is non-consuming, so the warm daemon client can ask the
//! same question and decline to cold without stealing the bytes cold will read.
//!
//! ## Why an fd TYPE is not enough
//!
//! ripgrep asks what fd 0 *is* and infers what it will *do*: a FIFO is a pipe, a
//! pipe has a writer, a writer eventually closes, so a blocking read to EOF
//! always terminates. Every step of that holds for a pipeline someone typed and
//! fails for a pipe someone merely *inherited* — an agent harness, a `sleep 20 |
//! …`, an `exec 9<>fifo` — where the write end is held open by a process that
//! will never write and never exit. `read(2)` then blocks forever, and a tool
//! asked to search a tree becomes a process someone has to go and kill. That is
//! the observed failure this module exists to make impossible; a socket was
//! already guarded against it, and a FIFO — the shape an agent actually hands
//! us — was not.
//!
//! The fix is not a tighter type test and not a timeout on every read. It is the
//! observation that the two cases differ in something exact: **a real producer
//! eventually delivers a first byte, and a dead stdin never delivers one.** So
//! the wait is bounded before the first byte and unbounded after it (`admit`). A
//! slow producer is admitted the instant it speaks, however long it took; a
//! stream that pauses for minutes mid-transfer is still drained to a true EOF,
//! byte-for-byte rg; and a silent-forever fd 0 falls through to the directory
//! walk, which is what the caller meant by running a search with no PATH args.
//! Polling every chunk — the older shape, kept only for sockets — could do
//! neither: it dropped a producer that was merely late, and it silently
//! truncated one that stalled after speaking.
//!
//! ## Why a regular file is its own case
//!
//! Collapsing `.file` and `.fifo` into one "safe to block-read" class threw away
//! the two facts that make a regular file the easy one: its `read` cannot block
//! at all, so it needs no guard, and its LENGTH is already known from the `stat`
//! this module performs anyway. Growing an `ArrayList` toward a size we were
//! told up front cost a measured **1245 MB of RSS for a 381 MB stdin** — the
//! doubling's slack on top of the bytes. Sizing the buffer once (`drainFile`) is
//! both the memory fix and the faster path, which is the good kind of trade:
//! nothing is given up for it.
//!
//! ## Why an unbounded haystack still gets a bound
//!
//! ripgrep caps no read by default and neither do we — `--max-filesize` cannot
//! apply to a stream with no a-priori length. But "no cap" was reaching the
//! machine rather than just this process: `cat 8GB | … pat` is an allocation the
//! OOM killer resolves, and it takes the developer's session with it. So there
//! is a ceiling (`ceiling`), derived from the machine the way a resident
//! session's ration is, overridable by whoever actually wants a multi-gigabyte
//! haystack.
//!
//! Crossing it is a **refusal** (`outcome.die`, exit 2), never a truncation. A
//! truncated haystack answers the wrong question in the one direction that is
//! invisible — a miss that should have been a hit — and `contract/engine.toml`
//! forbids exactly that ("never a silent empty result"). A file is refused
//! before a byte is allocated, since its size is known; a stream is refused at
//! the chunk that crosses.

const std = @import("std");
const inode = @import("../../../corpus/read/inode.zig");
const portal = @import("../../../portal.zig");
const assay = @import("../../../assay/assay.zig");

const outcome = @import("../../../surface/cli/outcome.zig");
const oom = outcome.oom;
const die = outcome.die;

/// How long fd 0 has to produce its FIRST byte before it is judged not to be a
/// haystack at all. Only a stream (FIFO / socket) can be silent, so only a
/// stream ever spends this — a tty, a `/dev/null`, and a regular file are each
/// decided with no `poll` at all, which is every shape but one.
///
/// Generous on purpose, because the two errors are not symmetric: waiting too
/// long costs a bounded pause on a stdin nobody was writing to, while waiting
/// too little DROPS a real stream and answers from the tree instead. The
/// previous socket-only guard was 200 ms and was measured dropping a producer
/// whose first byte landed at 500 ms; two seconds is well clear of that and
/// still turns "forever" into a blink.
const first_byte_ms_default: i32 = 2_000;

/// Operator override for the window above, in milliseconds. `0` is meaningful —
/// it means "admit only a stream with bytes already buffered", the posture a
/// harness that never pipes anything wants.
fn firstByteMs() i32 {
    const ms = assay.knobUsize("STDIN_WAIT_MS") orelse return first_byte_ms_default;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

/// Operator override for the haystack ceiling, in **megabytes**, matching
/// `GIST_MEMORY_MB`'s spelling and units because it is the same question about
/// the same laptop. `0` means "refuse any stdin haystack".
const ceiling_knob = "STDIN_MB";

/// Largest fraction of physical RAM one stdin haystack may claim, and the term
/// that binds on a small container.
const commons_fraction: u64 = 4;

/// What a haystack may claim no matter how large the machine is. A fraction
/// alone is the intuitive rule and is wrong at the top end for the reason
/// `warden/ration.zig` documents: owning 128 GB is not a reason a code search
/// should hold 32 GB of piped bytes.
const absolute_ceiling: u64 = 2 << 30;

/// Floor, so a machine whose size we cannot read — or a very small container —
/// still admits the ordinary `git diff | … pat` rather than refusing every
/// stream. Below this a cap stops being a protection and becomes a bug.
const floor: u64 = 64 << 20;

/// Bytes fd 0 may contribute as a haystack. One machine read over pure
/// arithmetic, so both edges are testable without a 128 GB box (`shareOf`).
fn ceiling() u64 {
    if (assay.knobUsize(ceiling_knob)) |mb|
        return std.math.mul(u64, mb, 1 << 20) catch std.math.maxInt(u64);
    return shareOf(std.process.totalSystemMemory() catch 0);
}

/// One haystack's share of a known machine size: the smaller of what the machine
/// can spare and what the work can justify, never under the floor. A machine
/// that will not report its size answers the floor, which fails toward admitting
/// the ordinary case rather than toward refusing it.
fn shareOf(physical_bytes: u64) u64 {
    return @max(floor, @min(physical_bytes / commons_fraction, absolute_ceiling));
}

/// What fd 0 turned out to be, and what draining it therefore costs.
///
/// The `.file` size is carried rather than re-`stat`ed because it is the whole
/// reason a file is the cheap case: one exactly-sized allocation instead of a
/// doubling climb, and a refusal decided before any allocation at all.
const Admission = union(enum) {
    /// A tty, a `/dev/null` char device, a directory — no haystack here, walk
    /// the tree. Also where a stream that never spoke lands.
    none,
    /// A regular file, whose `read` cannot block and whose length we know.
    file: u64,
    /// A FIFO or socket that has proven itself with a readable first byte.
    /// Length unknown, so the ceiling is checked as bytes arrive.
    stream,
};

/// fd 0's verdict, resolved at most once per process.
///
/// Memoized because the answer must be the SAME one every asker gets, and
/// because asking is no longer free: `admit` can spend the first-byte window,
/// and a stream that timed out for the layout probe but not for the search
/// branch would search an empty haystack and report a clean miss — a silent
/// wrong answer, which is worse than the hang this module removes. One verdict
/// also means fd 0 is `stat`ed once where the engine used to do it three times,
/// so the guard arrives at a lower syscall count than the code it replaced.
///
/// A plain `var` with no lock: every caller resolves this on the main thread
/// before any search worker exists (the engine's layout decision precedes the
/// walk, and the daemon client is single-threaded), the same process-wide
/// install discipline `beacon` documents.
var verdict: ?Admission = null;

/// Classify fd 0 and — for a stream — wait for it to prove itself.
///
/// ripgrep's `is_readable_stdin` is the type half: `!is_terminal(fd0) &&
/// (is_file || is_fifo || is_socket)`. Whitelisting exactly those three by
/// construction excludes a tty and a char device (`/dev/null`), so rg's separate
/// `is_terminal` guard is subsumed. The socket case matters for exec APIs that
/// wire fd 0 to a socketpair; omitting it silently diverged from rg on
/// piped-socket input.
///
/// The wait is the second half, and it is this module's departure from rg (see
/// the header). It is non-consuming — `poll` moves no bytes — so a delayed
/// pipe's first byte is still there for `readStdin` to read.
///
/// An EOF counts as proof, not as silence: a writer that closed having written
/// nothing sets `POLLIN` and its `read` returns 0, so `: | … pat` still searches
/// an empty haystack and exits 1 exactly as rg does. Only a timeout — nothing
/// arriving and nothing closing — is judged `.none`.
///
/// On Windows `portal.readable` answers an optimistic `true`, so a stream is
/// admitted on its type alone there, which is what both this and the previous
/// socket-only guard already did on that target.
fn admit() Admission {
    const st = inode.statFd(portal.stdin()) orelse return .none;
    return switch (st.kind) {
        .file => .{ .file = st.size },
        .fifo, .socket => if (portal.readable(portal.stdin(), firstByteMs())) .stream else silent(),
        else => .none, // tty, /dev/null char device, … ⇒ fall through to the walk
    };
}

/// A stream that never spoke: fall through to the walk, and say so.
///
/// The line is not optional noise. Falling back silently would mean a caller who
/// believes they are searching a pipe gets an answer from the tree with nothing
/// to distinguish it — the same invisible divergence a truncated haystack would
/// be. It goes to the fault channel, so stdout stays the rg-shaped bytes an
/// agent parses, the FFI's dark sink stays silent, and a captured run keeps it.
fn silent() Admission {
    assay.diag("stdin produced no data in {d}ms — searching the tree instead " ++
        "(pipe something, pass a PATH, or set {s}STDIN_WAIT_MS)\n", .{ firstByteMs(), assay.identity.env_prefix });
    return .none;
}

/// True iff fd 0 is a readable stdin haystack. `pub` for the warm client
/// (`exec/session/daemon/client/client.zig`): a rootless query with a readable
/// stdin is a STREAM search only the cold engine can answer, so the client
/// detects the same condition — through the same verdict — and declines to cold.
pub fn readableStdin() bool {
    return standing() != .none;
}

/// The memoized verdict, resolved on first ask.
fn standing() Admission {
    if (verdict) |v| return v;
    const v = admit();
    verdict = v;
    return v;
}

/// Drain fd 0 into `a`, honoring the verdict `readableStdin` already reached, so
/// the bytes come from the fd 0 that was admitted and a stream that was never
/// admitted is never read from.
///
/// ripgrep has no default cap on stdin size (`--max-filesize` cannot apply to a
/// stream with no a-priori length) — read to EOF, not to `per_file_cap` (that
/// constant is an indexing-corpus budget, not a search ceiling; see
/// `readOneCandidate`'s identical reasoning for on-disk files). The ceiling here
/// is a machine protection at a far higher water mark, and it refuses rather
/// than truncating.
pub fn readStdin(a: std.mem.Allocator) []const u8 {
    return switch (standing()) {
        .none => "",
        .file => |size| drainFile(a, size),
        .stream => drainStream(a),
    };
}

/// A regular file: refuse before allocating, then claim the exact length once.
///
/// The capacity is `ensureTotalCapacityPrecise` rather than the append path's
/// doubling, which is the whole memory fix — a 381 MB stdin costs 381 MB and not
/// the 1245 MB the growth slack used to. The loop still appends, so a file that
/// GREW between the `stat` and the read is followed to its real EOF instead of
/// being cut at a stale size; only that rare case pays a growth step, and the
/// ceiling still bounds it.
fn drainFile(a: std.mem.Allocator, size: u64) []const u8 {
    const cap = ceiling();
    if (size > cap) refuse(size, cap);
    var buf: std.ArrayList(u8) = .empty;
    buf.ensureTotalCapacityPrecise(a, @intCast(size)) catch oom();
    return pump(a, &buf, cap);
}

/// A stream: length unknown, so grow and check the ceiling as bytes arrive. No
/// per-chunk deadline — the first byte already proved a producer exists, and a
/// real stream that pauses mid-transfer must be waited for, not truncated.
fn drainStream(a: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    return pump(a, &buf, ceiling());
}

/// The shared read loop: block to true EOF, refusing at the chunk that crosses
/// `cap`. A failed `read` ends the haystack — the bytes already in hand are the
/// answer, exactly as a mid-file read error ends a file.
fn pump(a: std.mem.Allocator, buf: *std.ArrayList(u8), cap: u64) []const u8 {
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = portal.read(portal.stdin(), &tmp) catch break;
        if (n == 0) break;
        if (buf.items.len + n > cap) refuse(buf.items.len + n, cap);
        buf.appendSlice(a, tmp[0..n]) catch oom();
    }
    return buf.toOwnedSlice(a) catch oom();
}

/// The ceiling bound, and why the caller is hearing about it rather than getting
/// a shorter answer. Exit 2 (`die`) is rg's code for "your input was unusable",
/// which a haystack we refuse to hold is.
///
/// The message names the ceiling and its knob and stops there. It deliberately
/// does NOT suggest passing the same bytes as a PATH instead: this engine holds
/// a haystack whole either way, so that would trade a refusal for the same
/// allocation under a different name. The honest escape is to raise the ceiling
/// on purpose, or to narrow what is being piped.
fn refuse(wanted: u64, cap: u64) noreturn {
    die("stdin haystack reached {d} MB, over the {d} MB this search may hold — " ++
        "pipe less, or raise {s}{s}\n", .{ wanted >> 20, cap >> 20, assay.identity.env_prefix, ceiling_knob });
}

/// Test-only seam: the verdict is process-wide and memoized, so a test needing a
/// second classification has to be able to clear it.
pub const test_api = struct {
    pub fn forget() void {
        verdict = null;
    }
    pub const shareOfBytes = shareOf;
};

test "the ceiling scales with the machine and saturates at both ends" {
    const t = std.testing;
    // Small container: the fraction decides, so the cap tracks what is there.
    try t.expectEqual(@as(u64, 512 << 20), shareOf(2 << 30));
    try t.expectEqual(@as(u64, 1 << 30), shareOf(4 << 30));
    // Workstation: the work-shaped ceiling decides, and a bigger machine stops
    // buying a bigger haystack. This is the correction a fraction alone misses —
    // a quarter of 128 GB is 32 GB, which is not a protection.
    try t.expectEqual(absolute_ceiling, shareOf(64 << 30));
    try t.expectEqual(absolute_ceiling, shareOf(128 << 30));
    try t.expect(shareOf(128 << 30) < (128 << 30) / commons_fraction);
    // Monotone but saturating.
    var prev: u64 = 0;
    for ([_]u64{ 1, 2, 4, 8, 16, 32, 64, 128, 512 }) |gb| {
        const s = shareOf(gb << 30);
        try t.expect(s >= prev and s <= absolute_ceiling);
        prev = s;
    }
}

test "an unreadable machine size still admits the ordinary pipeline" {
    const t = std.testing;
    // `totalSystemMemory` failing must not refuse every `git diff | … pat`: the
    // cap exists to stop a runaway, and defaulting it to zero would make this
    // module the reason a normal pipeline broke.
    try t.expectEqual(floor, shareOf(0));
    try t.expectEqual(floor, shareOf(64 << 20)); // a tiny container gets the floor, not a sliver
    try t.expect(floor > 0);
}

test "the verdict is resolved once and reused" {
    const t = std.testing;
    // Two asks must agree even though `admit` can spend a wall-clock window — an
    // engine that classified fd 0 twice and got two answers would search an
    // empty haystack and call it a clean miss.
    test_api.forget();
    const first = readableStdin();
    try t.expectEqual(first, readableStdin());
    try t.expect(verdict != null);
}
