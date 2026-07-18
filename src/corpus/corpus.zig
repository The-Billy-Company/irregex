//! irregex — corpus loading, shared by the CLI drivers (`gist/faces/cli/`), the
//! unified search engine (`gist/faces/ripgrep/`) and the bench/verify harness
//! (`bench/harness/bench.zig`). The corpus is every non-binary file under the roots
//! (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the build/VCS subtrees rg
//! also skips. Also owns the stdout results contract (`emitResults`) every
//! search path emits through.

const std = @import("std");
const haystack = @import("haystack.zig");
const Dir = std.Io.Dir;

pub const per_file_cap: usize = 4 << 20; // 4 MiB
pub const out_dir = ".local/gist-verify";
pub const default_roots = [_][]const u8{ "services", "libs", "clients", "contracts", "scripts", "quality" };

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
//     firehose.
//   • hard — the OOM ceiling. Always on, even under `--uncap`; the most irregex will
//     ever stream/accumulate. Tunable only via `GIST_MAX_OUTPUT_BYTES` (0 ⇒ truly
//     unlimited — the parity-harness escape hatch).
//
// The parity/bench harnesses (`bench/`) diff gist byte-for-byte against ripgrep,
// which has no such cap, so they export `GIST_UNCAP=1` to keep the oracle exact.
pub const bytes_per_token: usize = 4;
pub const default_soft_output_bytes: usize = 100 << 10; // ~25k tokens
pub const default_hard_output_bytes: usize = 256 << 20; // OOM ceiling

const OutputBudget = struct {
    // The effective stop for both streaming and serial accumulation, in bytes;
    // 0 ⇒ unlimited. `--uncap` ⇒ the hard ceiling; otherwise min(soft, hard).
    ceiling: usize = @min(default_soft_output_bytes, default_hard_output_bytes),
    // True once the soft guard is lifted (`--uncap`/`GIST_UNCAP`) — only the hard
    // OOM ceiling remains, which shapes the truncation notice's wording.
    soft_disabled: bool = false,
    written: std.atomic.Value(usize) = .init(0), // bytes streamed so far (Sink-serialized under its lock)
    truncated: std.atomic.Value(bool) = .init(false), // any path hit the ceiling
    announced: std.atomic.Value(bool) = .init(false), // one-time notice guard
};
var output_budget: OutputBudget = .{};

/// A base-10 `usize` env value, or null when the key is unset or unparsable.
fn envUsize(key: [*:0]const u8) ?usize {
    const v = std.c.getenv(key) orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, std.mem.span(v), " \t"), 10) catch null;
}

/// `GIST_UNCAP` truthiness — set to any value except `0`/`false`/`no`/empty
/// lifts the soft guard (the bench harness sets `GIST_UNCAP=1`).
fn envUncap() bool {
    const v = std.c.getenv("GIST_UNCAP") orelse return false;
    const s = std.mem.span(v);
    return !(s.len == 0 or std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no"));
}

/// Resolve this process's output ceilings from the `--uncap` flag and the
/// `GIST_UNCAP` / `GIST_MAX_OUTPUT_TOKENS` / `GIST_MAX_OUTPUT_BYTES` env knobs,
/// and reset the run counters. Idempotent: the CLI calls it once from the
/// dispatch shell (so the warm client honors the env) and again from the cold
/// engine (so the `--uncap` flag — which always routes cold — takes effect).
pub fn initOutputBudget(flag_uncap: bool) void {
    const disabled = flag_uncap or envUncap();
    const soft = if (envUsize("GIST_MAX_OUTPUT_TOKENS")) |t| t *| bytes_per_token else default_soft_output_bytes;
    const hard = envUsize("GIST_MAX_OUTPUT_BYTES") orelse default_hard_output_bytes;
    output_budget.soft_disabled = disabled;
    output_budget.ceiling = if (disabled) hard else if (hard == 0) soft else @min(soft, hard);
    output_budget.written.store(0, .monotonic);
    output_budget.truncated.store(false, .monotonic);
    output_budget.announced.store(false, .monotonic);
}

/// Write RESULTS (the match list / ranked rows) to **stdout** — the Unix
/// convention `rg` follows: data on stdout, any diagnostic (`[pipeline]`, "no
/// index"/"bad pattern" guidance, `--rank`'s timing line) stays on stderr via
/// `std.debug.print`. This is what makes irregex agent-friendly in a shell: `gist
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
    const ceiling = output_budget.ceiling;
    if (ceiling != 0 and output_budget.written.load(.monotonic) >= ceiling) {
        output_budget.truncated.store(true, .monotonic);
        return false;
    }
    var off: usize = 0;
    while (off < bytes.len) {
        // `std.posix.system.write` is the raw C-ABI extern (returns isize; <=0 ⇒
        // error/closed-pipe), the same `std.posix.system.*` layer the read path's
        // `close` already rides on — `std.posix.write` is absent this Zig cut.
        const n = std.posix.system.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    if (ceiling != 0) _ = output_budget.written.fetchAdd(bytes.len, .monotonic);
    return true;
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
    const ceiling = output_budget.ceiling;
    if (ceiling == 0 or pending +| output_budget.written.load(.monotonic) < ceiling) return false;
    output_budget.truncated.store(true, .monotonic);
    return true;
}

/// One-time truncation notice on STDERR — called at the end of every emit path
/// (idempotent, a no-op when nothing was cut). Kept off stdout so a redirected
/// capture stays clean rg-shaped bytes. Under `--uncap` it still fires if the
/// hard OOM ceiling did the cutting, so a firehose caller still learns the output
/// was clipped.
pub fn finishOutput() void {
    if (!output_budget.truncated.load(.monotonic)) return;
    if (output_budget.announced.swap(true, .monotonic)) return;
    const cap = output_budget.ceiling;
    if (output_budget.soft_disabled)
        std.debug.print("gist: output truncated at the hard {d}-byte OOM ceiling — scope the query or raise GIST_MAX_OUTPUT_BYTES\n", .{cap})
    else
        std.debug.print("gist: output truncated (~{d} tokens / {d} bytes) — narrow the query (-l, -c, or scope a path) or pass --uncap for the full result\n", .{ cap / bytes_per_token, cap });
}

/// Directory basenames rg skips by default (gitignore + VCS + build output) —
/// re-exported for anyone still spelling it `corpus.isSkipDir`; the canonical
/// definition (and the walk that applies it) now lives in `haystack.zig`.
pub const isSkipDir = haystack.isSkipDir;

/// rg-style binary detection: a NUL byte in the first 8 KiB ⇒ treat as binary.
pub fn isBinary(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, 8192)];
    return std.mem.indexOfScalar(u8, window, 0) != null;
}

/// Every loaded doc + its root-joined path, arena-owned; `deinit` frees all.
pub const Corpus = struct {
    docs: [][]const u8,
    paths: [][]const u8,
    bytes: u64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
    }
};

/// Read every non-binary file under `roots` into one arena (per-file cap
/// applies; an unreadable root is reported to stderr and skipped, matching
/// rg's walk-on behavior).
pub fn load(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var docs: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;

    for (roots) |root_path| {
        var w = haystack.Walker.init(io, a, root_path) catch |e| {
            std.debug.print("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
            continue;
        };
        defer w.deinit(io);
        while (try w.next(io)) |hay| {
            const buf = hay.dir.readFileAlloc(io, hay.name, a, .limited(per_file_cap)) catch continue;
            if (buf.len == 0 or isBinary(buf)) continue;
            try docs.append(a, buf);
            try paths.append(a, hay.path);
            total += buf.len;
        }
    }
    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
}
