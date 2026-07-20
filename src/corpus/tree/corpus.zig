//! irregex — corpus loading, shared by the CLI drivers (`cli/gist/`), the
//! unified search engine (`runtime/cold/`) and the bench/verify harness
//! (`bench/harness/bench.zig`). The corpus is every non-binary, non-gitignored
//! file under the roots (rg-style: a NUL byte ⇒ binary ⇒ skipped), minus the
//! corpus-only build/VCS skip list. Also owns the stdout results contract
//! (`emitResults`) every search path emits through.

const std = @import("std");
const haystack = @import("haystack.zig");

pub const per_file_cap: usize = 4 << 20; // 4 MiB

/// Default artifact home, relative to the working directory — where the
/// trigram index, kinship atlas, codex shelf, freshness anchor, and daemon
/// socket live. `GIST_DIR` overrides it per invocation (`outDir`).
pub const default_out_dir = ".local/gist-verify";

/// The artifact directory for THIS process: `GIST_DIR` when set (trailing
/// slashes trimmed), else `default_out_dir`. The env string outlives the
/// process, so the returned slice is borrow-safe everywhere.
pub fn outDir() []const u8 {
    const v = std.c.getenv("GIST_DIR") orelse return default_out_dir;
    const s = std.mem.trimEnd(u8, std.mem.span(v), "/");
    return if (s.len == 0) default_out_dir else s;
}

/// A named artifact's full path (`<outDir()>/<name>`), formatted once per
/// process into a static buffer. Env-stable, so the first fill is final; a
/// spinlock + release-published length make the fill race-free without an
/// `std.Io` handle (same idiom as `runtime/session/dirty.zig` — these are
/// per-command lookups, never a hot loop). Instantiate per artifact:
/// `const atlas_path = corpus.ArtifactPath("kinship.atlas");` → `.get()`.
pub fn ArtifactPath(comptime name: []const u8) type {
    return struct {
        var locked: std.atomic.Value(bool) = .init(false);
        var len: std.atomic.Value(usize) = .init(0);
        var buf: [1024]u8 = undefined;
        pub fn get() []const u8 {
            if (len.load(.acquire) == 0) {
                while (locked.swap(true, .acquire)) std.atomic.spinLoopHint();
                defer locked.store(false, .release);
                if (len.load(.acquire) == 0) {
                    const d = outDir();
                    std.debug.assert(d.len + 1 + name.len <= buf.len);
                    @memcpy(buf[0..d.len], d);
                    buf[d.len] = '/';
                    @memcpy(buf[d.len + 1 ..][0..name.len], name);
                    len.store(d.len + 1 + name.len, .release);
                }
            }
            return buf[0..len.load(.acquire)];
        }
    };
}

/// The corpus roots for THIS working directory — the shared resolution every
/// build verb (`gist index`, `gist codex build`, `relate index`, live relate
/// verbs) runs when no explicit roots were given. Query paths that ride a
/// persisted artifact prefer the roots persisted BESIDE it (`roots.list`,
/// atlas roots blob) so a query always folds freshness over the corpus the
/// artifact was actually built from; this resolver is the build-time (and
/// no-artifact) answer. Two rungs:
///   1. `GIST_ROOTS` — explicit override, `:`/space/comma-separated paths;
///   2. `.` — the whole tree (the skip-dir policy still prunes VCS/build
///      output). No tree layout is ever assumed; a corpus that wants a
///      narrower scope passes roots positionally or via the env.
/// Every returned string is owned by `gpa`; release with `freeRoots`.
pub fn resolveRoots(gpa: std.mem.Allocator) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }

    if (std.c.getenv("GIST_ROOTS")) |v| {
        var it = std.mem.tokenizeAny(u8, std.mem.span(v), ": ,");
        while (it.next()) |tok| try roots.append(gpa, try gpa.dupe(u8, tok));
        if (roots.items.len > 0) return roots.toOwnedSlice(gpa);
    }

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

/// The shared "explicitly off" spelling for boolean env knobs: `0`/`false`/`no`.
fn envFalsy(s: []const u8) bool {
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no");
}

/// `GIST_UNCAP` truthiness — set to any value except `0`/`false`/`no`/empty
/// lifts the soft guard (the bench harness sets `GIST_UNCAP=1`).
fn envUncap() bool {
    const s = std.mem.span(std.c.getenv("GIST_UNCAP") orelse return false);
    return s.len != 0 and !envFalsy(s);
}

/// `GIST_HINTS` — the kill switch for the stderr guidance channel (`gist:
/// try` / `gist: note:` lines). Unset or any value except `0`/`false`/`no` keeps hints on;
/// a byte-counting capture or parity harness exports `GIST_HINTS=0`. Shared
/// by the CLI hint module (`runtime/cold/emit/hints.zig`) and the
/// truncation notice below — one env read, one policy. Results on stdout are
/// untouched either way; this only governs stderr guidance.
pub fn hintsEnabled() bool {
    return !envFalsy(std.mem.span(std.c.getenv("GIST_HINTS") orelse return true));
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
/// was clipped. The outcome line always prints; the follow-up `gist: try`
/// lines respect the `GIST_HINTS` gate (shared grammar with `hints.zig`).
pub fn finishOutput() void {
    if (!output_budget.truncated.load(.monotonic)) return;
    if (output_budget.announced.swap(true, .monotonic)) return;
    const cap = output_budget.ceiling;
    if (output_budget.soft_disabled) {
        std.debug.print("gist: output truncated at the hard {d}-byte OOM ceiling\n", .{cap});
        if (hintsEnabled())
            std.debug.print("gist: try PATH args / -t / -g to scope the query, or raise GIST_MAX_OUTPUT_BYTES\n", .{});
    } else {
        std.debug.print("gist: output truncated at ~{d} tokens ({d} bytes)\n", .{ cap / bytes_per_token, cap });
        if (hintsEnabled()) {
            std.debug.print("gist: try -l / -c — file list or per-file counts instead of every line\n", .{});
            std.debug.print("gist: try --uncap — stream the full result (or scope with PATH args / -t / -g)\n", .{});
        }
    }
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
        var w = haystack.Walker.initWithRoots(io, a, root_path, roots) catch |e| {
            std.debug.print("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
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
