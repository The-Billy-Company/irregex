//! Stdin as a haystack: admitting and draining fd 0.
//!
//! `cmd | … pat` must search the stream instead of walking the tree, which
//! makes "is fd 0 readable?" a correctness question, not a convenience. The rule
//! is ripgrep's (`is_readable_stdin`: not a tty, and a file / FIFO / socket),
//! with two deliberate departures the sections below justify in full: a socket
//! must prove itself with a byte before we commit to draining it, and a haystack
//! with no a-priori length still gets a ceiling.
//!
//! The classification is non-consuming, so the warm daemon client can ask the
//! same question and decline to cold without stealing the bytes cold will read.
//!
//! ## A pipe is waited for; a clock is not allowed to answer for it
//!
//! ripgrep asks what fd 0 *is* and infers what it will *do*: a FIFO is a pipe, a
//! pipe has a writer, a writer eventually closes, so a blocking read to EOF
//! always terminates. That holds for a pipeline someone typed and fails for a
//! pipe someone merely *inherited*, where the write end is held open by a
//! process that will never write and never exit: `read(2)` then blocks forever,
//! and a tool asked to search a tree becomes one someone has to go and kill.
//!
//! The repair is a deadline on the first byte, and the thing to get right is
//! that the two mistakes are not the same size. Waiting too long costs a pause
//! on a stdin nobody was writing to — visible, killable, and over. Waiting too
//! *little* takes a live producer's bytes off the table and answers the same
//! query **from a different corpus**: exit 0, real-looking rows, not one of them
//! from what was piped in, and nothing on the screen to say so.
//! `contract/engine.toml` forbids exactly that shape of failure, so the deadline
//! must be sized against the *worst honest producer*, never against the
//! impatience of the caller. A 2s window shipped and was sized the other way
//! round: it dropped ordinary producers that were merely slow to their first
//! byte and searched the tree behind them.
//!
//! What makes the deadline sizeable at all is that it bounds the wait for the
//! FIRST byte and nothing after it, and a first byte is early even for slow
//! work. So the shapes are separated by what a silence can prove about each
//! (`admit`):
//!
//! * **A pipe waits a full minute** (`pipe_wait_ms`) — past every real producer
//!   and well past the 2s that was dropping them. A producer that exits also
//!   ends the wait early on its own: closing the pipe makes it readable, `read`
//!   returns 0, and `: | … pat` searches an empty haystack and exits 1 on rg's
//!   schedule. So the minute is only ever spent on a pipe with a live writer
//!   that is saying nothing — the wedge case, and the only one.
//! * **A pipe whose write end is held by US is not waited for at all**
//!   (`exec 9<>fifo`): no other writer's exit can produce the EOF, so its
//!   silence is permanent rather than long — and `portal.holdsWriteEnd` reads
//!   that off `F_GETFL` rather than inferring it from a clock.
//! * **A socket keeps its short window.** It is the shape a sandboxed harness
//!   wires to fd 0 — a control channel that never writes and never closes — and
//!   it is never how a shell spells a pipeline, so no typed command is judged by
//!   it. It is also the case the original guard was built for.
//!
//! The wedge that remains (a harness holding a *pipe's* write end open, which is
//! what `zig build test` does to its own test binaries) is therefore bounded,
//! and it is announced: after `notice_ms` of silence the wait says on stderr
//! that it is still waiting and names the knob that ends it — `STDIN_WAIT_MS`,
//! which re-imposes any deadline you like on either shape, `0` meaning "only
//! bytes already buffered". A pause you can see and switch off beats a wrong
//! answer you cannot.
//!
//! Past the first byte nothing is bounded at all: a stream that pauses for
//! minutes mid-transfer is drained to a true EOF, byte-for-byte rg. Polling
//! every chunk — the oldest shape here — could not do that; it silently
//! truncated a producer that stalled after speaking.
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

/// How long a SOCKET has to produce its first byte before it is judged not to be
/// a haystack at all. Only a socket spends this by default — a pipe waits, and a
/// tty, a `/dev/null`, and a regular file are each decided with no `poll` at
/// all.
///
/// Generous for its own case: the previous guard was 200 ms and was measured
/// dropping a producer whose first byte landed at 500 ms. Two seconds is well
/// clear of that, and a socket on fd 0 is a harness artifact rather than
/// something a shell can produce, so no typed pipeline is judged by it.
const socket_wait_ms: i32 = 2_000;

/// How long a PIPE has to produce its first byte.
///
/// Not a guess at how long a producer takes — a guess at the far side of every
/// producer, which is a different and much easier number to be right about. The
/// wait ends at the FIRST byte, not at the end of the transfer, and a producer
/// whose first byte is a minute away is either broken or not a pipeline anyone
/// typed. `git log -p` on a cold object store, a `curl` over a bad link, a
/// container image being pulled — all speak inside this, and all were being
/// dropped by the 2s window that shipped before it.
///
/// Finite at all only because a pipe someone merely inherited is a real shape
/// (`zig build test` hands its own test binaries exactly that: fd 0 is the build
/// runner's command pipe, open forever and silent between commands). rg waits
/// there indefinitely and wedges; we would rather be slow once, loudly, and
/// then answer. A harness that hits it sets `STDIN_WAIT_MS` once, and
/// `notice_ms` tells it to.
const pipe_wait_ms: i32 = 60_000;

/// How long a silent pipe waits before it says out loud that it is waiting.
///
/// Not a deadline — the wait continues afterwards, up to `pipe_wait_ms`. It
/// exists because the wedge this module cannot rule out used to present as a
/// process that produced nothing and explained nothing. One line turns it into a
/// diagnosis carrying its own cure.
const notice_ms: i32 = 2_000;

/// Operator override, in milliseconds, that re-imposes a finite first-byte
/// deadline on *either* stream shape — the escape for a harness that really does
/// hand us a live-forever silent pipe. `0` is meaningful: it means "admit only a
/// stream with bytes already buffered", the posture a harness that never pipes
/// anything wants. Unset is the default posture, and for a pipe that is rg's:
/// wait.
const wait_knob = "STDIN_WAIT_MS";

fn pinnedWaitMs() ?i32 {
    const ms = assay.knobUsize(wait_knob) orelse return null;
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
/// because asking is no longer free: `admit` can wait on a stream — for a pipe,
/// as long as the pipe takes — and one that timed out for the layout probe but
/// not for the search
/// branch would search an empty haystack and report a clean miss — a silent
/// wrong answer, which is the failure this module exists to prevent. One verdict
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
/// The wait is the second half (see the header for which shape waits and why).
/// It is non-consuming — `poll` moves no bytes — so a delayed pipe's first byte
/// is still there for `readStdin` to read.
///
/// An EOF counts as proof, not as silence: a writer that closed having written
/// nothing sets `POLLIN` and its `read` returns 0, so `: | … pat` still searches
/// an empty haystack and exits 1 exactly as rg does. Only a stream that neither
/// speaks nor closes is judged `.none`.
///
/// On Windows `portal.readable` answers an optimistic `true`, so a stream is
/// admitted on its type alone there, which is what every revision of this guard
/// has done on that target.
fn admit() Admission {
    const st = inode.statFd(portal.stdin()) orelse return .none;
    return switch (st.kind) {
        .file => .{ .file = st.size },
        .fifo => admitStream(.pipe),
        .socket => admitStream(.socket),
        else => .none, // tty, /dev/null char device, … ⇒ fall through to the walk
    };
}

/// The two stream shapes fd 0 can be. They are one case for *reading* and two
/// for *waiting*, because a silence means something different in each: a pipe is
/// how a shell spells a pipeline, a socket is how a harness spells a control
/// channel.
const Stream = enum { pipe, socket };

/// Wait for a stream to prove itself, and return the verdict.
fn admitStream(kind: Stream) Admission {
    const fd = portal.stdin();
    // An operator-pinned deadline outranks the per-shape policy in both
    // directions: it is how a harness bounds a live-forever pipe, and how a
    // caller who knows their socket is slow buys it more time.
    if (pinnedWaitMs()) |ms| {
        if (portal.readable(fd, ms)) return .stream;
        return silent("produced no data in the {d}ms you pinned", .{ms});
    }
    if (kind == .socket) {
        if (portal.readable(fd, socket_wait_ms)) return .stream;
        return silent("is a socket that produced no data in {d}ms (raise {s}{s} to wait longer)", .{
            socket_wait_ms, assay.identity.env_prefix, wait_knob,
        });
    }
    // A pipe we hold the write end of can never deliver a byte and can never
    // close, so waiting for it is not patience, it is a hang with no end state.
    // The only pipe silence we can prove permanent is the only one we refuse.
    if (portal.holdsWriteEnd(fd)) {
        if (portal.readable(fd, 0)) return .stream;
        return silent("is a pipe this process holds the write end of, so nothing can arrive on it", .{});
    }
    if (portal.readable(fd, notice_ms)) return .stream;
    // Still waiting, and now saying so. The difference between a wedge and a
    // slow producer is not ours to know, but it is ours to make legible — rg
    // sits here mute and forever.
    assay.diag("still waiting on stdin — a pipe that has sent nothing in {d}ms. " ++
        "Giving it {d}s; set {s}{s} (ms, 0 = search the tree now) to change that\n", .{
        notice_ms, @divTrunc(pipe_wait_ms, 1_000), assay.identity.env_prefix, wait_knob,
    });
    if (portal.readable(fd, pipe_wait_ms - notice_ms)) return .stream;
    return silent("is a pipe that produced no data in {d}s (raise {s}{s} to wait longer)", .{
        @divTrunc(pipe_wait_ms, 1_000), assay.identity.env_prefix, wait_knob,
    });
}

/// A stream that never spoke: fall through to the walk, and say so.
///
/// The line is not optional noise. Falling back silently would mean a caller who
/// believes they are searching a pipe gets an answer from the tree with nothing
/// to distinguish it — the same invisible divergence a truncated haystack would
/// be. It goes to the fault channel, so stdout stays the rg-shaped bytes an
/// agent parses, the FFI's dark sink stays silent, and a captured run keeps it.
fn silent(comptime why: []const u8, args: anytype) Admission {
    assay.diag("stdin " ++ why ++ " — searching the tree instead (pipe something, or pass a PATH)\n", args);
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

// ── fd 0 is the subject, so every test below installs its own ────────────────
//
// Under `zig build test --listen=-` fd 0 is the build runner's command pipe: a
// live FIFO, silent between commands, held open by a process that will not write
// again until this binary reports back. That is the wedge shape exactly, so a
// test that simply asked about the ambient fd 0 would either judge the runner's
// pipe or sit in `pipe_wait_ms` waiting on a writer that is waiting on it.
const Borrowed = struct {
    saved: c_int,

    /// Make `fd` this process's stdin, forgetting any verdict reached about the
    /// previous one.
    fn stdin(fd: std.posix.fd_t) Borrowed {
        const saved = std.c.dup(0);
        _ = std.c.dup2(fd, 0);
        test_api.forget();
        return .{ .saved = saved };
    }

    fn give_back(self: Borrowed) void {
        if (self.saved >= 0) {
            _ = std.c.dup2(self.saved, 0);
            _ = std.c.close(self.saved);
        }
        test_api.forget();
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "a producer slower than the window that used to drop it is still the haystack" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;

    // The regression this module shipped: the first-byte deadline was 2s, and a
    // pipeline whose command took longer than that to say its first word had its
    // bytes thrown away and the DIRECTORY searched in their place — exit 0, rows
    // that look right, not one of them from what was piped in. So the producer
    // here is deliberately slower than that deadline, and the assertion is that
    // its bytes are still what gets searched.
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var slow = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 2.4; printf 'needle\\n'" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer _ = slow.wait(io) catch {};

    const held = Borrowed.stdin(slow.stdout.?.handle);
    defer held.give_back();

    try t.expect(readableStdin());
    const got = readStdin(t.allocator);
    defer t.allocator.free(got);
    try t.expectEqualStrings("needle\n", got);
}

test "a pinned deadline still bounds a pipe nobody is writing to" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;

    // The escape hatch a harness reaches for, and the reason the wait can be
    // generous by default: an open, silent write end — the inherited-pipe shape —
    // resolves at once to "walk the tree" when the operator says so.
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    _ = setenv(assay.identity.env_prefix ++ wait_knob, "0", 1);
    defer _ = unsetenv(assay.identity.env_prefix ++ wait_knob);

    const held = Borrowed.stdin(fds[0]);
    defer held.give_back();

    try t.expect(!readableStdin());
    // …and the same fd IS admitted once a byte is actually sitting in it, so the
    // pin bounds the waiting rather than refusing the stream.
    _ = std.c.write(fds[1], "x", 1);
    test_api.forget();
    try t.expect(readableStdin());
}

test "the verdict is resolved once and reused" {
    const t = std.testing;
    // Two asks must agree even though `admit` can spend a wall-clock window — an
    // engine that classified fd 0 twice and got two answers would search an
    // empty haystack and call it a clean miss. Judged against /dev/null, the one
    // shape that is decided with no `poll` at all.
    const nul = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (nul < 0) return error.SkipZigTest;
    defer _ = std.c.close(nul);

    const held = Borrowed.stdin(nul);
    defer held.give_back();

    const first = readableStdin();
    try t.expectEqual(first, readableStdin());
    try t.expect(verdict != null);
}

test "only a pipe we hold the write end of is refused without waiting" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    // The one silence that is provably permanent rather than merely long, and
    // the fact that proves it is `F_GETFL`, not a clock. An ordinary pipeline's
    // read end is read-only — someone else holds the writer, and that someone
    // can still speak or exit — so it does not qualify and is waited for.
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try t.expect(!portal.holdsWriteEnd(fds[0]));

    // A read-write descriptor is the `exec 9<>fifo` shape: the only writer is us.
    const both = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (both < 0) return error.SkipZigTest;
    defer _ = std.c.close(both);
    try t.expect(portal.holdsWriteEnd(both));
}
