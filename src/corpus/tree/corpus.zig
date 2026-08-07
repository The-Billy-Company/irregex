//! irregex — corpus loading, shared by the CLI drivers (`surface/face/gist/`), the
//! unified search engine (`exec/cold/`) and the bench/verify harness
//! (`gist/bench/apparatus/harness/bench.zig`). The corpus is every non-binary, non-gitignored
//! file under the roots (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the
//! corpus-only build/VCS skip list. Also owns the stdout results contract
//! (`emitResults`) every search path emits through.

const std = @import("std");
const haystack = @import("haystack.zig");
const assay = @import("../../assay/assay.zig");
const charter = @import("../scope/charter.zig");
const drain = @import("drain.zig");
const fault = @import("../../fault.zig");
const ward = @import("../../kernel/math/lease.zig");
const portal = @import("../../portal.zig");

/// When result bytes leave this process, and in how many syscalls — see
/// `drain.zig`. Re-exported here because `writeStdout` is the seam every
/// caller already knows, and the policy is a property of that seam.
pub const StdoutPolicy = drain.Policy;

pub const per_file_cap: usize = 4 << 20; // 4 MiB

/// The corpus roots for THIS working directory — the shared resolution every
/// build verb (`gist index`, `gist codex build`, `relate index`, live relate
/// verbs) runs when no explicit roots were given. Query paths that ride a
/// persisted artifact prefer the roots persisted BESIDE it (`roots.list`,
/// atlas roots blob) so a query always folds freshness over the corpus the
/// artifact was actually built from; this resolver is the build-time (and
/// no-artifact) answer. Three rungs:
///   1. `GIST_ROOTS` — explicit override, `:`/space/comma-separated paths;
///   2. the tree's committed charter (`.irregex.toml roots`), already resolved
///      against the charter's own directory, so the answer does not depend on
///      which subdirectory the command happened to run from;
///   3. `.` — the whole tree (the skip-dir policy still prunes VCS/build
///      output). No tree layout is ever assumed; a corpus that wants a
///      narrower scope declares it, passes roots positionally, or sets the env.
/// Every returned string is owned by `gpa`; release with `freeRoots`.
pub fn resolveRoots(gpa: std.mem.Allocator) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }

    if (assay.knob("ROOTS")) |v| {
        var it = std.mem.tokenizeAny(u8, v, ": ,");
        while (it.next()) |tok| try roots.append(gpa, try gpa.dupe(u8, tok));
        if (roots.items.len > 0) return roots.toOwnedSlice(gpa);
    }

    if (charter.governing()) |c| if (c.roots.len > 0) {
        for (c.roots) |r| try roots.append(gpa, try gpa.dupe(u8, r));
        return roots.toOwnedSlice(gpa);
    };

    try roots.append(gpa, try gpa.dupe(u8, "."));
    return roots.toOwnedSlice(gpa);
}

/// Free a `resolveRoots` result (each string + the outer slice).
pub fn freeRoots(gpa: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |r| gpa.free(r);
    gpa.free(roots);
}

// ── output budget — the agent-context guard + the OOM ceiling ────────────────
// irregex "pays tokens for every line of output": an unbounded result dump can blow
// an agent's context window, or at the extreme OOM the serial engine (which
// renders its whole result into one buffer before a single flush). Two byte
// ceilings — irregex reasons in bytes, never tokens (it scans raw bytes and cannot
// know a caller's tokenizer; ~4 B/token is the coarse cross-model rule of thumb):
//
//   • soft — the agent guard. Default `default_soft_output_bytes` (~25k tokens).
//     Once the emitted/accumulated total crosses it, irregex stops producing
//     results and `finishOutput` prints a one-line notice to STDERR (never
//     stdout — a redirected capture stays clean rg-shaped bytes, just fewer of
//     them). Lifted by `--uncap` / `GIST_UNCAP` for the agent that wants the
//     firehose. Applied symmetrically across every content path: the cold serial
//     loop polls `outputFull` at file boundaries, the streaming parallel sink
//     refuses fragments past the ceiling, and a WARM-served pre-rendered answer
//     is cut at a whole-line boundary by `writeStdoutCapped` (so a daemon hit no
//     longer emits the firehose a daemon-less run would truncate).
//   • hard — the OOM ceiling. Always on, even under `--uncap`; the most irregex will
//     ever stream/accumulate. Tunable only via `GIST_MAX_OUTPUT_BYTES` (0 ⇒ truly
//     unlimited — the parity-harness escape hatch).
//
// The parity/bench harnesses (`bench/`) diff gist byte-for-byte against ripgrep,
// which has no such cap, so they export `GIST_UNCAP=1` to keep the oracle exact.
pub const bytes_per_token: usize = 4;
pub const default_soft_output_bytes: usize = 100 << 10; // ~25k tokens
pub const default_hard_output_bytes: usize = 256 << 20; // OOM ceiling

/// What a run is BOUND BY — the policy half of the budget, split from the run
/// counters below because it is the only half a caller states. A CLI resolves it
/// from the flag plus the environment (`resolveOutputBudget`); a caller with no
/// environment to read — an embedder of the C ABI, a test that must be bound
/// deterministically rather than by whatever the operator's shell exported —
/// states it outright and hands it to `installOutputBudget`. Same shape, and the
/// same reason, as the explicit `lenses` mask on `assay.install`.
pub const Budget = struct {
    /// The effective stop for both streaming and serial accumulation, in bytes;
    /// 0 ⇒ unlimited. `--uncap` ⇒ the hard ceiling; otherwise min(soft, hard).
    ceiling: usize = @min(default_soft_output_bytes, default_hard_output_bytes),
    /// True once the soft guard is lifted (`--uncap`/`GIST_UNCAP`) — only the hard
    /// OOM ceiling remains, which shapes the truncation notice's wording.
    soft_disabled: bool = false,

    /// What a run with no flag and no environment is bound by.
    pub const default: Budget = .{};
};

const OutputBudget = struct {
    limit: Budget = .default,
    written: std.atomic.Value(usize) = .init(0), // bytes streamed so far (Sink-serialized under its lock)
    chrome: std.atomic.Value(usize) = .init(0), // of those, escapes nobody reads — see `noteChrome`
    truncated: std.atomic.Value(bool) = .init(false), // any path hit the ceiling
    announced: std.atomic.Value(bool) = .init(false), // one-time notice guard
};
var output_budget: OutputBudget = .{};

/// `GIST_UNCAP` truthiness — set to any value except `0`/`false`/`no`/empty
/// lifts the soft guard (the bench harness sets `GIST_UNCAP=1`).
fn envUncap() bool {
    return assay.knobFlag("UNCAP");
}

/// `GIST_HINTS` — the kill switch for the stderr guidance channel (`gist:
/// try` / `gist: note:` lines). Unset or any value except `0`/`false`/`no` keeps hints on;
/// a byte-counting capture or parity harness exports `GIST_HINTS=0`. Shared
/// by the CLI hint module (`exec/cold/emit/hints.zig`) and the
/// truncation notice below — one env read, one policy. Results on stdout are
/// untouched either way; this only governs stderr guidance.
pub fn hintsEnabled() bool {
    return if (assay.knob("HINTS")) |s| !assay.envFalsy(s) else true;
}

/// Read this process's ceilings out of the `--uncap` flag and the `GIST_UNCAP` /
/// `GIST_MAX_OUTPUT_TOKENS` / `GIST_MAX_OUTPUT_BYTES` env knobs. Consulting the
/// environment is ALL it does — that is what lets the install below be driven by
/// a caller that has none, and what keeps "which knobs bind a run" one readable
/// expression instead of a side effect buried in a setter.
pub fn resolveOutputBudget(flag_uncap: bool) Budget {
    const disabled = flag_uncap or envUncap();
    const soft = if (assay.knobUsize("MAX_OUTPUT_TOKENS")) |t| t *| bytes_per_token else default_soft_output_bytes;
    const hard = assay.knobUsize("MAX_OUTPUT_BYTES") orelse default_hard_output_bytes;
    return .{
        .soft_disabled = disabled,
        .ceiling = if (disabled) hard else if (hard == 0) soft else @min(soft, hard),
    };
}

/// Bind this run to `limit` and reset the run counters — the one place a budget
/// takes effect, whether it came from the environment or from a caller stating it.
pub fn installOutputBudget(limit: Budget) void {
    output_budget.limit = limit;
    output_budget.written.store(0, .monotonic);
    output_budget.chrome.store(0, .monotonic);
    output_budget.truncated.store(false, .monotonic);
    output_budget.announced.store(false, .monotonic);
}

/// Resolve the ceilings from flag + environment and install them. Idempotent:
/// the CLI calls it once from the dispatch shell (so the warm client honors the
/// env) and again from the cold engine (so the `--uncap` flag — which always
/// routes cold — takes effect).
pub fn initOutputBudget(flag_uncap: bool) void {
    installOutputBudget(resolveOutputBudget(flag_uncap));
}

/// Report the run's cumulative **chrome** — the color escapes and OSC-8 link
/// frames included in the byte totals below. The ceiling exists to bound what a
/// reader reads; an escape is swallowed by the emulator and shown to nobody, so
/// charging it trades results for bytes that were never on screen, and the same
/// query silently answers less the moment it becomes colored or clickable. (rg
/// has no cap, so it never faced the question; measured here, color alone cost
/// a third of the rows.) A SET, not an add: the writer keeps the running total
/// and hands it over — the serial loop from its emitter, the sharded merge from
/// the file marks it is folding in, since its shards render out of order and a
/// counter they all raced would discount work not yet merged.
pub fn noteChrome(total: usize) void {
    output_budget.chrome.store(total, .monotonic);
}

/// Bytes of the ceiling consumed by `pending` unflushed bytes plus everything
/// already written, less the chrome inside them. Saturating, and the subtraction
/// is over the SUM: the buffered engines flush once at the end, so their chrome
/// is entirely in `pending` while `written` is still zero — discounting from
/// `written` alone would floor at zero and quietly charge them for every escape.
fn spent(pending: usize) usize {
    return (pending +| output_budget.written.load(.monotonic)) -| output_budget.chrome.load(.monotonic);
}

/// One rendered file's end in a shard buffer: `end` slices the bytes, `content`
/// is what the budget counts (`end` minus the chrome written through here). The
/// two differ only under `--color`/`--hyperlink`, where they must, or the cut
/// lands earlier for a prettier run than a plain one.
pub const Mark = struct {
    end: usize,
    content: usize,

    /// The mark a run with no chrome records — every byte is content.
    pub fn plain(end: usize) Mark {
        return .{ .end = end, .content = end };
    }
};

/// Lift the SOFT context cap for this run, leaving only the hard OOM ceiling —
/// the enumeration modes (`Opts.enumeration`: `-l`/`-c`/`--count-matches`/
/// `--files-without-match`/`--files`) call this so their result SET is complete
/// and reproducible, never a soft-cap-truncated (and, on the unordered parallel
/// engine, nondeterministic) subset. Must run AFTER `initOutputBudget`, which it
/// overrides. An EXPLICIT soft budget (`GIST_MAX_OUTPUT_TOKENS`) is honored —
/// the caller asked to be bounded; only the DEFAULT ~25k-token guard is lifted.
/// `--uncap` already leaves only the hard ceiling, so this is a no-op there.
pub fn exemptSoftCap() void {
    if (assay.knobSet("MAX_OUTPUT_TOKENS")) return;
    output_budget.limit = .{
        .soft_disabled = true,
        .ceiling = assay.knobUsize("MAX_OUTPUT_BYTES") orelse default_hard_output_bytes,
    };
}

/// Write RESULTS (the match list / ranked rows) to **stdout** — the Unix
/// convention `rg` follows: data on stdout, any diagnostic (`[pipeline]`, "no
/// index"/"bad pattern" guidance, `--rank`'s timing line) stays on stderr via
/// `assay.diag`. This is what makes irregex agent-friendly in a shell: `gist
/// foo -l > files` captures the paths and `gist foo | head` shows only
/// results. A raw `posix.write` loop (handling partial writes) mirrors the
/// blocking-syscall idiom the read path already uses, and sidesteps the std
/// Io.Writer surface churn. Returns whether every byte was accepted — `false`
/// means the pipe is gone (EPIPE, e.g. `| head` already exited), a signal
/// interrupted the call (EINTR), OR the output budget is spent; the caller
/// decides what that means (the parallel engine's streaming sink, `pipeline.zig`,
/// treats it as "cancel the rest of the walk", the same EPIPE-triggered shape
/// ripgrep itself uses). The budget check straddles the write so the first
/// crossing fragment still lands (whole lines, no mid-line cut) and every
/// subsequent one is refused.
pub fn writeStdout(bytes: []const u8) bool {
    const ceiling = output_budget.limit.ceiling;
    if (ceiling != 0 and spent(0) >= ceiling) {
        output_budget.truncated.store(true, .monotonic);
        return false;
    }
    if (!drain.write(rawWriteStdout, bytes)) return false;
    if (ceiling != 0) _ = output_budget.written.fetchAdd(bytes.len, .monotonic);
    return true;
}

/// Install the stdout buffering policy for the rest of this process
/// (`--line-buffered` / `--block-buffered` / `--buffer-size`, resolved against
/// the destination by the engine). `term` is the run's line terminator, so a
/// `--null-data` record stream flushes on `\0` rather than a `\n` it will never
/// contain. Fail-open: an arming failure leaves the pre-policy pass-through.
pub fn armStdout(policy: StdoutPolicy, capacity: usize, term: u8) void {
    drain.arm(policy, capacity, term);
}

/// Does the armed policy owe the reader output *during* the run? Only
/// `--line-buffered` does; the serial engine reads this to decide whether to
/// hand each file's rendered bytes over as it finishes it, instead of holding
/// the whole run for one terminal flush.
pub fn stdoutStreams() bool {
    return drain.streams();
}

/// Emit whatever the drain is holding. Idempotent and safe before the drain is
/// ever armed, which is why the process's exit seams (`Outcome.exit` → `depart`,
/// `die`) can call it unconditionally — buffered output that never reached the
/// fd is the one failure mode a buffering policy must not have.
pub fn flushStdout() void {
    _ = drain.flush();
}

/// The partial-write retry loop — the drain's sink, and the one place a result
/// byte becomes a syscall. The budget accounting is `writeStdout`'s and the
/// buffering policy is `drain.zig`'s; this only lands the bytes. `false` ⇒ the
/// pipe is gone (EPIPE) or a signal cut the call (EINTR). `portal.writeOnce` is
/// the raw one-attempt write (returns isize; <=0 ⇒ error/closed-pipe), the same
/// seam layer the read path's `close` already rides on — `std.posix.write` is
/// absent this Zig cut, and stdout is a handle rather than fd 1 on Windows.
fn rawWriteStdout(bytes: []const u8) bool {
    var off: usize = 0;
    const out = portal.stdout();
    while (off < bytes.len) {
        const n = portal.writeOnce(out, bytes[off..]);
        if (n <= 0) {
            carbonCopy(bytes[0..off], .torn);
            return false;
        }
        off += @intCast(n);
    }
    carbonCopy(bytes, .whole);
    return true;
}

// ── the carbon copy ────────────────────────────────────────────────────────
//
// A verb whose answer may be held by the resident daemon's keep needs a copy of
// exactly what it printed. Taking it HERE — at the one syscall every stdout byte
// passes through — rather than at each verb's emit site is what makes the copy
// trustworthy: it is the bytes the terminal got, after the output budget cut,
// with no second rendering path to drift from. It also means a verb that exits
// early has already written what it wrote; the copy is a tee, never a buffer, so
// arming it can never swallow output.

var carbon: struct {
    mu: ward.Latch = .{},
    into: ?*std.ArrayList(u8) = null,
    gpa: std.mem.Allocator = undefined,
    /// A short write or an allocation failure means the copy no longer equals
    /// what was printed. Sticky: a torn copy is never offered to the keep.
    torn: bool = false,
} = .{};

/// Start copying stdout into `into`. One armed copy per process (a CLI runs one
/// verb); arming twice replaces the destination.
pub fn carbonOn(into: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    carbon.mu.lock();
    defer carbon.mu.unlock();
    carbon.into = into;
    carbon.gpa = gpa;
    carbon.torn = false;
}

/// Stop copying and hand back what was printed, or null if the copy is torn —
/// a closed pipe, a failed allocation, or an unarmed call. Null always means
/// "do not treat this as the answer".
pub fn carbonOff() ?[]const u8 {
    carbon.mu.lock();
    defer carbon.mu.unlock();
    const into = carbon.into orelse return null;
    carbon.into = null;
    return if (carbon.torn) null else into.items;
}

fn carbonCopy(bytes: []const u8, how: enum { whole, torn }) void {
    if (@atomicLoad(?*std.ArrayList(u8), &carbon.into, .monotonic) == null) return;
    carbon.mu.lock();
    defer carbon.mu.unlock();
    const into = carbon.into orelse return;
    if (how == .torn) carbon.torn = true;
    into.appendSlice(carbon.gpa, bytes) catch {
        carbon.torn = true;
    };
}

/// Emit a fully-assembled ONE-SHOT answer, honoring the output budget by cutting
/// at the last whole LINE that fits under the ceiling. `writeStdout`'s "the first
/// crossing fragment lands whole" rule assumes each call is one small per-file
/// fragment (the streaming parallel sink, whose next fragment is refused past the
/// ceiling). A WARM-served answer instead arrives pre-rendered as a SINGLE buffer,
/// so that rule would let the entire corpus dump land in one call — silently
/// defeating the ~25k-token agent-context guard the cold engines enforce. This
/// treats `bytes` as the whole result and bounds it: the daemon renders in the
/// canonical path-sorted order (`render`/`docLess`), so the surviving prefix is
/// the SAME reproducible cut the cold serial loop's `outputFull` poll produces —
/// never a nondeterministic subset. The line that crosses the ceiling lands whole
/// (no mid-line cut), mirroring the cold budget's per-file "crossing fragment
/// lands whole" shape. Marks the run truncated (for `finishOutput`) when it cuts.
/// `false` ⇒ stdout is spent/closed (nothing more to send), like `writeStdout`.
pub fn writeStdoutCapped(bytes: []const u8) bool {
    const ceiling = output_budget.limit.ceiling;
    if (ceiling == 0) return drain.write(rawWriteStdout, bytes); // GIST_MAX_OUTPUT_BYTES=0 ⇒ truly unbounded
    const already = output_budget.written.load(.monotonic);
    if (already >= ceiling) {
        if (bytes.len != 0) output_budget.truncated.store(true, .monotonic);
        return false;
    }
    const room = ceiling - already;
    if (bytes.len <= room) return writeStdout(bytes); // fits under the ceiling whole
    // Extend past `room` to the newline that ends the crossing line (or the
    // buffer end for a newline-free tail) — whole lines, no mid-line cut.
    var cut = room;
    while (cut < bytes.len and bytes[cut - 1] != '\n') cut += 1;
    if (!drain.write(rawWriteStdout, bytes[0..cut])) return false;
    _ = output_budget.written.fetchAdd(cut, .monotonic);
    if (cut < bytes.len) output_budget.truncated.store(true, .monotonic);
    return true;
}

/// Did a ceiling cut this run's output? Read by the emitters whose format has a
/// machine consumer, so the loss can be reported IN BAND — the stderr notice
/// `finishOutput` prints is loud to a human and invisible to a pipe that captured
/// only stdout.
pub fn outputTruncated() bool {
    return output_budget.truncated.load(.monotonic);
}

/// Write a **protocol terminator** — the one bounded metadata record that closes a
/// machine-readable stream (`--json`'s trailing `summary`) — past the ceiling the
/// result rows obey.
///
/// The budget exists to bound what a reader reads, which is why `noteChrome`
/// already refuses to charge escapes nobody sees. A terminator is the same kind of
/// byte: not a result, one per run, a few hundred bytes, and it cannot become a
/// firehose. Charging it is worse than free — it is the difference between a
/// well-formed truncated stream and a malformed one, because the terminator is
/// written last and so is precisely the record a spent budget refuses. Bypassing
/// the ceiling also leaves the cut point of the rows *exactly* where it was, where
/// reserving headroom would move every capped run's boundary.
pub fn writeStdoutTerminator(bytes: []const u8) void {
    _ = drain.write(rawWriteStdout, bytes);
}

/// `writeStdout` for a fire-and-forget one-shot emit, followed by the one-time
/// truncation notice: write errors are swallowed (a closed stdout must not crash
/// the query) because these callers have nothing left to cancel — they're already
/// at their last write. This is the serial engine's terminal-flush seam, so it
/// owns announcing a budget cut (`finishOutput`); the streaming/warm paths call
/// `finishOutput` themselves.
pub fn emitStdout(bytes: []const u8) void {
    _ = writeStdout(bytes);
    finishOutput();
}

/// The serial engine renders its whole result into one buffer before `emitStdout`
/// flushes it, so it polls this between files: `true` once the pending (unflushed)
/// bytes plus anything already streamed reach the ceiling — which both bounds peak
/// memory (the OOM guard) and stops at the exact point streaming would cut.
/// Uncapped (ceiling 0) ⇒ always false. Marks the run truncated for `finishOutput`.
pub fn outputFull(pending: usize) bool {
    const ceiling = output_budget.limit.ceiling;
    if (ceiling == 0 or spent(pending) < ceiling) return false;
    output_budget.truncated.store(true, .monotonic);
    return true;
}

/// Concatenate one parallel emit shard's rendered `buf` into the merged `out`,
/// honoring the SAME output budget at each per-file boundary so the parallel
/// truncation point is byte-identical to the serial loop's file-boundary break.
/// A shard renders its whole file range into `buf` without polling the budget
/// (its buffer isn't the real cumulative output); the ordered merge is the ONE
/// place the budget applies — exactly as the warm engine's serial record feed
/// halts a fully-collected shard. `marks[j]` is `buf`'s length after shard file
/// `j` (one entry per file, in order), so the first mark whose GLOBAL position
/// (`out.len + mark`) reaches the ceiling is the cut: append the prefix through
/// it and return that file index so the driver caps its per-file side data (the
/// `--json` summary tally) at the same file and stops merging later shards.
/// Returns null when the whole buffer fit. When `budgeted` is false (`--stats`
/// searches every file regardless; `--quiet --json` suppresses the stream) the
/// whole buffer is appended. `a` owns `out`.
///
/// The chrome counter doubles as this merge's running total: at entry it holds
/// what the already-merged shards spent on escapes, so folding each mark's own
/// share in keeps `outputFull` measuring content across shard boundaries.
pub fn appendBudgeted(a: std.mem.Allocator, out: *std.ArrayList(u8), buf: []const u8, marks: []const Mark, budgeted: bool) std.mem.Allocator.Error!?usize {
    const merged = output_budget.chrome.load(.monotonic);
    if (budgeted) for (marks, 0..) |m, i| {
        noteChrome(merged +| (m.end - m.content));
        if (outputFull(out.items.len + m.end)) {
            try out.appendSlice(a, buf[0..m.end]);
            return i;
        }
    };
    if (marks.len != 0) noteChrome(merged +| (marks[marks.len - 1].end - marks[marks.len - 1].content));
    try out.appendSlice(a, buf);
    return null;
}

/// One-time truncation notice on STDERR — called at the end of every emit path
/// (idempotent, a no-op when nothing was cut). Kept off stdout so a redirected
/// capture stays clean rg-shaped bytes. Under `--uncap` it still fires if the
/// hard OOM ceiling did the cutting, so a firehose caller still learns the output
/// was clipped. The outcome line always prints; the follow-up `gist: try`
/// lines respect the `GIST_HINTS` gate (shared grammar with `hints.zig`).
pub fn finishOutput() void {
    // Every terminal emit path lands here, so this is where a buffering policy
    // settles its debt — before any notice, and unconditionally, since a clean
    // untruncated run is exactly the one that must not lose its held tail.
    flushStdout();
    if (!output_budget.truncated.load(.monotonic)) return;
    if (output_budget.announced.swap(true, .monotonic)) return;
    const cap = output_budget.limit.ceiling;
    if (output_budget.limit.soft_disabled) {
        assay.diag(assay.tag ++ "output truncated at the hard {d}-byte OOM ceiling\n", .{cap});
        if (hintsEnabled())
            assay.diag(assay.tag ++ "try PATH args / -t / -g to scope the query, or raise GIST_MAX_OUTPUT_BYTES\n", .{});
    } else {
        assay.diag(assay.tag ++ "output truncated at ~{d} tokens ({d} bytes)\n", .{ cap / bytes_per_token, cap });
        if (hintsEnabled()) {
            assay.diag(assay.tag ++ "try -l / -c — file list or per-file counts instead of every line\n", .{});
            assay.diag(assay.tag ++ "try --uncap — stream the full result (or scope with PATH args / -t / -g)\n", .{});
        }
    }
}

test "the ceiling counts what is read, not the escapes around it" {
    // The regression this pins: the budget once measured emitted bytes, so a
    // colored or clickable run answered roughly half as many rows as the same
    // query in plain text — you paid for results in bytes nobody ever saw.
    // Stated, not resolved: `initOutputBudget` reads `GIST_UNCAP` and the two
    // override knobs, so a test that called it would assert the default ceiling
    // while bound by whatever the operator's shell exported (the bench harness
    // exports `GIST_UNCAP=1`). The claim here is about the default budget, so the
    // test hands itself that budget.
    defer installOutputBudget(.default);
    installOutputBudget(.default);
    const ceiling = default_soft_output_bytes;

    noteChrome(0);
    try std.testing.expect(!outputFull(ceiling - 1));
    try std.testing.expect(outputFull(ceiling));

    // Half of it chrome ⇒ the same content reaches exactly as far, and the
    // pending total may run over the ceiling by precisely the chrome in it.
    noteChrome(ceiling / 2);
    try std.testing.expect(!outputFull(ceiling + ceiling / 2 - 1));
    try std.testing.expect(outputFull(ceiling + ceiling / 2));
}

test "a sharded merge cuts on content, so a decorated run keeps every file" {
    // Four files of 40 KiB each, three quarters of it escapes: 160 KiB of bytes
    // but only 40 KiB to read. Charged as bytes it would cut at the third file;
    // charged as content the whole thing fits under the 100 KiB ceiling.
    defer installOutputBudget(.default);
    installOutputBudget(.default); // the default budget, stated — see the test above
    noteChrome(0);

    const a = std.testing.allocator;
    const per_file = 40 << 10;
    const buf = try a.alloc(u8, 4 * per_file);
    defer a.free(buf);
    @memset(buf, 'x');

    var dressed: [4]Mark = undefined;
    var plain: [4]Mark = undefined;
    for (0..4) |i| {
        const end = (i + 1) * per_file;
        dressed[i] = .{ .end = end, .content = end / 4 };
        plain[i] = .plain(end);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), try appendBudgeted(a, &out, buf, &dressed, true));
    try std.testing.expectEqual(buf.len, out.items.len);

    // The same bytes with nothing to discount are what the ceiling is for.
    installOutputBudget(.default);
    noteChrome(0);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(?usize, 2), try appendBudgeted(a, &out, buf, &plain, true));
}

/// Directory basenames rg skips by default (gitignore + VCS + build output) —
/// re-exported for anyone still spelling it `corpus.isSkipDir`; the canonical
/// definition (and the walk that applies it) now lives in `haystack.zig`.
pub const isSkipDir = haystack.isSkipDir;

/// How far into a file the binary verdict looks. Named because a caller that
/// only wants the VERDICT — the index build's census, which classifies members
/// without keeping their bytes — must read exactly this much to reach the same
/// answer a whole-file read would: fewer bytes could miss a NUL the full read
/// would have seen, and more is wasted IO the rule ignores.
pub const binary_window: usize = 8192;

/// rg-style binary detection: a NUL byte in the first 8 KiB ⇒ treat as binary.
pub fn isBinary(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, binary_window)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

/// Read `sub_path` (under `dir`) as a corpus member: its body capped at
/// `per_file_cap`, or `null` when the path is not a member — unreadable,
/// empty, or binary. This is the ONE membership rule `load` and every
/// freshness fold (atlas / frag / trigram) apply, so a warm folded view and a
/// cold live build can never disagree on what counts as corpus. `null` folds
/// all three rejection reasons together because every fold treats them
/// identically (tombstone the entry / skip the file).
pub fn readMember(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, a: std.mem.Allocator) ?[]u8 {
    const buf = dir.readFileAlloc(io, sub_path, a, .limited(per_file_cap)) catch return null;
    return if (buf.len == 0 or isBinary(buf)) null else buf;
}

/// Every loaded doc + its root-joined path, arena-owned; `deinit` frees all.
/// The serial `load` owns every byte in `arena`; the fused parallel loader
/// (`loadpar`) accumulates doc/path bytes in per-worker arenas that outlive the
/// walk — it hands them off as `shards` (freed with `owner` in `deinit`), while
/// the slice HEADERS still live in `arena`.
pub const Corpus = struct {
    docs: [][]const u8,
    paths: [][]const u8,
    bytes: u64,
    arena: std.heap.ArenaAllocator,
    /// Releases `shards`. Null when `arena` owns every byte.
    owner: ?std.mem.Allocator = null,
    shards: []std.heap.ArenaAllocator = &.{},

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
        const g = self.owner orelse return;
        for (self.shards) |*s| s.deinit();
        g.free(self.shards);
    }
};

/// The corpus described rather than held: which files are members, in the same
/// doc-id order `load` would have numbered them, and how long each one says it
/// is. `paths` and `sizes` are parallel and index by doc id.
///
/// This is the corpus a build reads in doc order instead of carrying. It is the
/// SAME membership rule and the SAME ordering as `Corpus` — `loadpar` runs one
/// walk for both and differs only in what it keeps — so a census may be used
/// anywhere the doc numbering matters and only the bytes are missing.
///
/// `sizes` is what each handle STATED, which a held snapshot never needed to
/// distinguish from what a read returned. A file that changes size between the
/// census and the read is described one way here and another there; its clocks
/// then stand at or after the build anchor, so the freshness gate re-reads it
/// live rather than trusting either figure.
pub const Census = struct {
    paths: [][]const u8,
    sizes: []u32,
    bytes: u64,
    arena: std.heap.ArenaAllocator,
    /// Releases `shards` (the per-worker arenas holding the path bytes).
    owner: ?std.mem.Allocator = null,
    shards: []std.heap.ArenaAllocator = &.{},

    pub fn deinit(self: *Census) void {
        self.arena.deinit();
        const g = self.owner orelse return;
        for (self.shards) |*s| s.deinit();
        g.free(self.shards);
    }

    /// Read doc `doc`'s bytes back into `buf`, allocating nothing. This is the
    /// census's other half: the walk decided WHICH files are docs and in what
    /// order, and this returns one of them on demand so a build never has to
    /// hold them all.
    ///
    /// **A doc that cannot be recalled is the empty document, not an error.**
    /// The file may have been deleted, truncated, made unreadable, or turned
    /// binary since the walk; the doc id is already spent and every parallel
    /// array is already sized, so the only coherent answer is "no bytes". Search
    /// then behaves exactly as it would for a file that is not there — which is
    /// the truth — and the freshness anchor folds the file back in live, because
    /// whatever changed it moved its clocks past the anchor stamped before the
    /// walk.
    ///
    /// Thread-safe: it touches nothing but its own arguments and the kernel.
    pub fn recall(self: *const Census, doc: u32, buf: []u8) []const u8 {
        const fd = portal.openFile(portal.cwd(), self.paths[doc]) catch return &.{};
        defer portal.close(fd);
        // Never past what the caller sized for, and never past the cap the walk
        // itself enforced — a file that grew since is read as its first
        // `sizes[doc]` bytes rather than overrunning a buffer cut to fit it.
        const room = buf[0..@min(buf.len, per_file_cap)];
        var n: usize = 0;
        while (n < room.len) {
            const r = portal.read(fd, room[n..]) catch return &.{};
            if (r == 0) break;
            n += r;
        }
        return if (n == 0 or isBinary(room[0..n])) &.{} else room[0..n];
    }
};

/// Classify the corpus under `roots` without materializing it. No serial twin
/// and no fallback: a census is an accelerator for the build that wants one, so
/// a caller that cannot get one runs the ordinary `load` path instead.
pub fn census(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !Census {
    return @import("loadpar.zig").census(gpa, io, roots);
}

/// `GIST_NO_PARALLEL_LOAD` truthy (any value but `0`/`false`/`no`/empty) forces
/// the serial loader — the parity gate + escape hatch, mirroring the search
/// engine's `GIST_NO_PARALLEL`.
fn parallelLoadDisabled() bool {
    return assay.knobFlag("NO_PARALLEL_LOAD");
}

/// How the caller intends to USE the corpus — the one fact that decides whether
/// `compact`'s copy earns its transient 2×.
pub const Layout = enum {
    /// One contiguous scan-order blob. For a corpus that will be scanned an
    /// unbounded number of times (the resident session): one copy up front buys
    /// every later query the prefetcher's ramp across document boundaries
    /// instead of restarting it 175k times (Layer C: 52.8 vs 28.7 GB/s).
    contiguous,
    /// Bodies left where the walk put them. For a corpus read a FIXED, small
    /// number of times and then dropped — `gist index` extracts trigrams once
    /// and writes the shard once, so the copy is pure cost. Measured on
    /// llvm-project (1926 MiB, 175,110 docs): scattered loads ~1.0 s faster,
    /// finishes the whole build ~1.2 s faster, and peaks 1027 MiB lower.
    scattered,
};

/// Read every non-binary file under `roots` into memory (per-file cap applies;
/// an unreadable root is reported to stderr and skipped, matching rg's walk-on
/// behavior). Dispatches to the fused parallel walk+read (`loadpar`) by default
/// — ~3× faster on a broad build — and to the serial walk below under
/// `GIST_NO_PARALLEL_LOAD` (parity gate) or when the parallel path fails to
/// start (fail-open: the result is never worse than the serial build).
pub fn load(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, layout: Layout) !Corpus {
    var c = blk: {
        if (!parallelLoadDisabled()) {
            if (@import("loadpar.zig").load(gpa, io, roots) catch null) |c| break :blk c;
        }
        break :blk try loadSerial(gpa, io, roots);
    };
    if (layout == .contiguous and !compactDisabled()) compact(gpa, &c);
    return c;
}

/// `GIST_NO_COMPACT` truthy (any value but `0`/`false`/`no`/empty) keeps the
/// scattered per-worker-arena doc layout — the A/B toggle for the contiguity
/// win and a parity escape hatch, mirroring `GIST_NO_PARALLEL_LOAD`.
pub fn compactDisabled() bool {
    return assay.knobFlag("NO_COMPACT");
}

/// Relocate every doc body into ONE contiguous, scan-order buffer so a
/// full-corpus scan (`for (docs) |d| contains(d, …)`) streams across document
/// boundaries. The default parallel loader leaves ~20k bodies scattered across
/// per-worker arenas at unrelated addresses, so the scan restarts the hardware
/// prefetcher's ramp at every one of them — the per-doc ramp being the dominant
/// tax on this many-small-files corpus (Layer C: contiguous 52.8 GB/s vs
/// fragmented corpus 28.7 GB/s on M4). Laid back-to-back in the exact order they
/// are scanned, the HW prefetcher — which streams linearly and does not stop at
/// a slice boundary — warms the next doc's head while the current doc's tail is
/// still in flight. Each doc slice stays independent (scanned within its own
/// bounds), so no separator is needed and no cross-doc match can appear.
/// Content, paths, iteration order, and doc ids are byte-identical to the input
/// — only the addresses change (`loadpar`'s parity test doubles as the proof).
/// Paths are copied along, which lets the scattered source arenas + worker
/// shards free, so steady-state retention is one tight blob (a transient 2×
/// during the copy). Fail-open: any allocation failure leaves the corpus in its
/// original scattered layout, never worse than before.
///
/// That transient IS the build's memory ceiling at this stage, and it is not
/// removable by reordering the copy: the average corpus file is well under a
/// page, so bodies from different worker arenas share destination pages, and any
/// order that retires a source early still has to touch nearly every page of the
/// destination first. Copying by source arena was measured — same peak, and
/// markedly slower for scattering the writes. What removes it is not holding the
/// second copy in anonymous memory at all (see `content/shard.zig`).
fn compact(gpa: std.mem.Allocator, c: *Corpus) void {
    fault.spare("compact doc bodies (keeps the scattered layout)", compactFallible(gpa, c));
}

fn compactFallible(gpa: std.mem.Allocator, c: *Corpus) !void {
    if (c.docs.len == 0) return;
    var blob_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer blob_arena.deinit(); // only reachable while allocating; the swap below is infallible
    const ba = blob_arena.allocator();

    // Bodies first, so the blob sits at the arena base as one uninterrupted run
    // (the slice headers + copied paths trail it and never split the stream).
    // `c.bytes` is the u64 corpus tally; here it sizes one heap run, so a total
    // past this address space is `OutOfMemory` — and `compact` is fail-open, so
    // that simply leaves the corpus in its existing scattered layout.
    const blob = try ba.alloc(u8, std.math.cast(usize, c.bytes) orelse return error.OutOfMemory);
    const new_docs = try ba.alloc([]const u8, c.docs.len);
    const new_paths = try ba.alloc([]const u8, c.paths.len);
    var off: usize = 0;
    for (c.docs, c.paths, new_docs, new_paths) |d, p, *nd, *np| {
        @memcpy(blob[off..][0..d.len], d);
        nd.* = blob[off..][0..d.len];
        off += d.len;
        np.* = try ba.dupe(u8, p);
    }

    // Infallible swap-and-free: retarget the corpus at the blob, then release
    // the scattered source. No `try` runs past this point, so the errdefer above
    // can never double-free the moved arena, and `ba` is not touched after the
    // move.
    var old = c.*;
    c.arena = blob_arena;
    c.docs = new_docs;
    c.paths = new_paths;
    c.shards = &.{};
    c.owner = null;
    old.deinit();
}

/// The single-cursor reference loader: walk one directory at a time, read each
/// member as it is yielded. Kept as the parallel loader's fallback + parity
/// oracle (`GIST_NO_PARALLEL_LOAD`, and `loadpar`'s membership test).
pub fn loadSerial(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var docs: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;

    for (roots) |root_path| {
        var w = haystack.Walker.initWithRoots(io, a, root_path, roots) catch |e| {
            assay.diag("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
            continue;
        };
        defer w.deinit(io);
        while (try w.next(io)) |hay| {
            const buf = readMember(io, hay.dir, hay.name, a) orelse continue;
            try docs.append(a, buf);
            try paths.append(a, hay.path);
            total += buf.len;
        }
    }
    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
}
