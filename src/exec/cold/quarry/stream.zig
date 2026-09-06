//! Stdin as a haystack: admitting and draining fd 0.
//!
//! `cmd | … pat` must search the stream instead of walking the tree, which
//! makes "is fd 0 readable?" a correctness question, not a convenience. The rule
//! is ripgrep's (`is_readable_stdin`: not a tty, and a file / FIFO / socket),
//! with one deliberate departure: a haystack with no a-priori length still gets
//! a ceiling. A caller can also explicitly bound its wait for the first byte;
//! reaching that deadline refuses the input instead of searching another source.
//!
//! The classification is non-consuming, so the warm daemon client can ask the
//! same question and decline to cold without stealing the bytes cold will read.
//!
//! ## Source identity does not expire
//!
//! A regular file, FIFO or socket selects stdin immediately. A quiet producer
//! can still send bytes or close; neither a deadline nor an O_RDWR descriptor
//! proves otherwise. The old first-byte probe changed a slow pipeline into a
//! CWD search. Raising its timeout from two seconds to a minute merely moved
//! the same wrong answer later. Admission is now one non-consuming stat, shared
//! by the warm client and cold engine, with no readiness wait or corpus switch.
//!
//! Reading waits for bytes or true EOF and remains interruptible by the caller.
//! An inherited, unused pipe is a harness configuration question: pass a PATH
//! or /dev/null when the intended source is a tree. `STDIN_WAIT_MS` still lets a
//! caller request a first-byte deadline, but expiry is exit 2 with no result.
//! Past that first byte, pauses never truncate the stream. Read failures are
//! also refusals; partial input cannot produce a trustworthy search answer.
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

/// Optional first-byte deadline, in milliseconds. Zero requires bytes or EOF
/// already waiting; expiry refuses this source, never selects another one.
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
    /// the tree. A quiet stream never becomes this case.
    none,
    /// A regular file, whose `read` cannot block and whose length we know.
    file: u64,
    /// A FIFO or socket, including an empty or temporarily quiet one.
    /// Length unknown, so the ceiling is checked as bytes arrive.
    stream,
};

/// fd 0's verdict, resolved at most once per process.
///
/// Memoized so the layout probe, daemon client and search branch agree on their
/// source. One verdict also means one stat where the engine previously did three.
///
/// A plain `var` with no lock: every caller resolves this on the main thread
/// before any search worker exists (the engine's layout decision precedes the
/// walk, and the daemon client is single-threaded), the same process-wide
/// install discipline `beacon` documents.
var verdict: ?Admission = null;

/// Classify fd 0 without waiting for or consuming any bytes.
///
/// ripgrep's `is_readable_stdin` is the type half: `!is_terminal(fd0) &&
/// (is_file || is_fifo || is_socket)`. Whitelisting exactly those three by
/// construction excludes a tty and a char device (`/dev/null`), so rg's separate
/// `is_terminal` guard is subsumed. The socket case matters for exec APIs that
/// wire fd 0 to a socketpair; omitting it silently diverged from rg on
/// piped-socket input.
///
/// EOF and silence do not affect admission. Reading an empty stream returns an
/// empty haystack on every platform, regardless of its readiness event shape.
fn admit() Admission {
    const st = inode.statFd(portal.stdin()) orelse return .none;
    return switch (st.kind) {
        .file => .{ .file = st.size },
        .fifo, .socket => .stream,
        else => .none, // tty, /dev/null char device, … ⇒ fall through to the walk
    };
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
/// per-chunk deadline: a stream that pauses mid-transfer must be waited for,
/// not truncated. Only an explicit first-byte deadline can refuse the wait.
fn drainStream(a: std.mem.Allocator) []const u8 {
    if (pinnedWaitMs()) |ms| {
        if (!portal.readable(portal.stdin(), ms))
            die("stdin did not become readable within {d}ms ({s}{s}); input was not searched\n", .{
                ms, assay.identity.env_prefix, wait_knob,
            });
    }
    var buf: std.ArrayList(u8) = .empty;
    return pump(a, &buf, ceiling());
}

/// The shared read loop: block to true EOF, refusing at the chunk that crosses
/// `cap`. A failed read refuses the input; partial bytes cannot answer a search.
fn pump(a: std.mem.Allocator, buf: *std.ArrayList(u8), cap: u64) []const u8 {
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = portal.read(portal.stdin(), &tmp) catch |err|
            die("cannot read stdin: {s}\n", .{@errorName(err)});
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
// pipe or wait on a writer that is waiting on it.
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

test "a pinned deadline cannot reclassify a quiet pipe as a tree" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;

    // Readiness can refuse a read, but never determine the source. In
    // particular a zero deadline must not turn this quiet pipe into a tree.
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    _ = setenv(assay.identity.env_prefix ++ wait_knob, "0", 1);
    defer _ = unsetenv(assay.identity.env_prefix ++ wait_knob);

    const held = Borrowed.stdin(fds[0]);
    defer held.give_back();

    try t.expect(!portal.readable(portal.stdin(), 0));
    try t.expect(readableStdin());
    // A later byte changes readiness, while the memoized source stays a stream.
    _ = std.c.write(fds[1], "x", 1);
    try t.expect(portal.readable(portal.stdin(), 0));
    try t.expect(readableStdin());
}

test "the verdict is resolved once and reused" {
    const t = std.testing;
    // The layout and search branch must agree about their source. /dev/null
    // is a char device, so it still selects the ordinary interactive tree.
    const nul = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (nul < 0) return error.SkipZigTest;
    defer _ = std.c.close(nul);

    const held = Borrowed.stdin(nul);
    defer held.give_back();

    const first = readableStdin();
    try t.expectEqual(first, readableStdin());
    try t.expect(verdict != null);
}

test "an empty closed pipe remains an empty haystack including a pinned deadline" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    // POSIX can report bare HUP for an empty pipe. That is EOF, not a timeout
    // and never permission to answer from a directory containing a match.
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);

    _ = setenv(assay.identity.env_prefix ++ wait_knob, "0", 1);
    defer _ = unsetenv(assay.identity.env_prefix ++ wait_knob);
    const held = Borrowed.stdin(fds[0]);
    defer held.give_back();
    try t.expect(readableStdin());
    try t.expect(portal.readable(portal.stdin(), 0));
    const got = readStdin(t.allocator);
    defer t.allocator.free(got);
    try t.expectEqualStrings("", got);
}
