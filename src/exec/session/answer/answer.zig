//! The warm session's answer vocabulary — what a query can come back as, and
//! what bounds it while it runs.
//!
//! Every type here is either a shape the session hands its callers (the daemon
//! worker, the in-process FFI, the tests) or a bound the caller hands the
//! session. Nothing here touches the engine, so it is the one file a consumer
//! can read to learn the contract without reading the engine at all:
//! `resident.zig` re-exports all of it, so `resident.MatchRecord` and
//! `answer.MatchRecord` are the same type.
//!
//! The two budgets are deliberately distinct and must not be conflated: a
//! `Ceiling` overrun DECLINES the query (`freshness_unprovable` → the certified
//! cold path), while a `RunBudget` trip is a CLEAN partial stop that keeps whatever
//! was gathered. One is the daemon's liveness backstop; the other is the hosted
//! caller's cooperative halt.

const std = @import("std");
const fault = @import("../../../fault.zig");
const request = @import("request.zig");
const render = @import("../facet/render.zig");
const query_mod = @import("../../../kernel/query/query.zig");
// The cold path's own path comparator — the warm canonical file order.
const run = @import("../../cold/engine/serial.zig");
const Span = query_mod.Span;
const Mode = request.Mode;

/// Budget checkpoints are strided: `overBudget` reads the clock only when the
/// caller's loop index masks to zero against this power-of-two-minus-one, so a
/// budgeted scan of a huge candidate set pays ~one clock read per 1024 visits.
pub const budget_stride: usize = 1023;

/// A warm query can genuinely fail only when allocation fails. Freshness doubt
/// is a typed success-position declinature (`Answer(T)`), never an error.
pub const QueryError = error{OutOfMemory};
pub const Answer = fault.Answer;

/// A cooperative, thread-safe cancellation flag, shared by reference into a
/// search's `RunBudget`. Any thread may `cancel()` while the engine scans; the
/// scan observes it at a strided gather checkpoint AND at every record boundary
/// (the hosted collector) and stops cleanly, keeping whatever it gathered. Bare
/// atomic-builtin bool so it needs no allocation and no std version pin. The
/// hosted `api.CancelToken` is this type — it lives with the engine core it
/// bounds, not the veneer that names it.
pub const CancelToken = struct {
    flag: bool = false,

    pub fn cancel(self: *CancelToken) void {
        @atomicStore(bool, &self.flag, true, .seq_cst);
    }

    pub fn requested(self: *const CancelToken) bool {
        return @atomicLoad(bool, &self.flag, .seq_cst);
    }

    pub fn reset(self: *CancelToken) void {
        @atomicStore(bool, &self.flag, false, .seq_cst);
    }
};

/// A per-search cooperative halt the DOC GATHER honors so a scan that emits few
/// or no records (a rare pattern, an invert walk, a `-l` superset that mostly
/// fails the whole-doc gate) still respects a hosted `cancel` / `timeout_ns`
/// instead of running the whole corpus first. Distinct from the daemon's
/// `query_budget_ns` ceiling (which DECLINES to the certified cold path via
/// `freshness_unprovable`): a gather halt is a CLEAN partial stop — the docs
/// gathered so far stand, no declinature is raised — mirroring the record-boundary budget the
/// hosted collector already applies at emit. Empty (both null) for the daemon
/// and FFI-callback faces, whose completeness is guarded by the session ceiling
/// instead, so the check compiles away for them.
pub const RunBudget = struct {
    cancel: ?*const CancelToken = null,
    /// Absolute monotonic (`.awake`) deadline in ns; null = no wall-clock cap.
    deadline_ns: ?i128 = null,
};

/// The per-query wall-clock ceiling — computed once under the lock at the top of
/// each query and threaded down the O(corpus) walks as a VALUE, not session
/// state, so concurrent readers each carry their own deadline (the reader/writer
/// session runs many folds at once). `deadline_ns` is an absolute `.awake`
/// instant; 0 disables the ceiling (the embedder/FFI/test default), which
/// short-circuits before any clock read. Distinct from `RunBudget`, the hosted
/// record stream's cooperative CLEAN halt: an overrun here DECLINES the query
/// (→ certified cold path via `freshness_unprovable`), it is the daemon's liveness backstop.
pub const Ceiling = struct {
    deadline_ns: i128 = 0,
    tripped: ?*std.atomic.Value(bool) = null,

    /// Has this query overrun its ceiling? Sampled at strided checkpoints in the
    /// O(corpus) walks — the caller passes its loop index, so the clock is read
    /// at most once per `budget_stride` visits (amortized to noise; the fast
    /// path returns before the first sample for a small candidate set). An
    /// unbudgeted query short-circuits before any clock read. Each parallel
    /// shard walks its own contiguous range with its own index, so the read-only
    /// deadline is sampled independently per shard.
    pub inline fn over(self: Ceiling, io: std.Io, i: usize) bool {
        if (self.deadline_ns == 0) return false;
        if (i & budget_stride != 0) return false;
        const hit = std.Io.Clock.now(.awake, io).nanoseconds >= self.deadline_ns;
        if (hit) self.tripped.?.store(true, .release);
        return hit;
    }

    pub fn declined(self: Ceiling) bool {
        return if (self.tripped) |t| t.load(.acquire) else false;
    }
};

/// One eligible query's answer. `files` are duped into the caller's per-query
/// arena (see `ownFiles`), so they own their bytes rather than aliasing session
/// memory — the caller may release the session read lock before encoding the
/// answer, which is what lets concurrent readers overlap.
pub const Result = struct { mode: Mode, files: []const []const u8 = &.{}, count: u64 = 0 };

/// A `lines`-mode answer: the pre-rendered output bytes (owned by the caller's
/// arena) and whether any file matched (cold's exit-code boolean).
pub const Lines = struct { out: []const u8, matched: bool };

/// One streamed selection: a matching line, or a zero-span nonmatching line for
/// `-v` (ADR-352 rung 3 — the in-process FFI's output unit). `path` aliases the
/// mirror path table / overlay key; `text` is
/// the line CONTENT without its `\n` terminator and aliases session bytes;
/// `spans` alias `search`'s per-line scratch. All three are valid ONLY during
/// the `emit` call — the sink must copy anything it keeps. `line_number` is
/// 1-based over rg's line model, and every span is a non-empty `[start,end)`
/// byte range within `text`, byte-identical to the cold `gist --json` submatch
/// stream (`exec/cold/emit/json.zig`).
pub const MatchKind = enum(u32) { match, context };
pub const MatchRecord = struct { path: []const u8, line_number: u64, text: []const u8, spans: []const Span, kind: MatchKind = .match };

/// A candidate doc gathered before answering so results leave in a
/// deterministic path order. `bytes` aliases mirror/overlay memory; `nul` is
/// the first-NUL byte offset (null ⇒ text), driving each mode's binary rule.
/// Shape-shared with the renderer's `render.Doc`, so the `lines` face hands
/// its gathered slice straight through without a copy.
pub const DocRef = render.Doc;

/// Separator-aware path order — the SAME `pathLess` cold's `--sort path`
/// comparator uses (`exec/cold/engine/serial.zig::cmpFiles`). Cold's default
/// parallel pipeline emits in worker-discovery order (nondeterministic);
/// warm canonicalizes to this deterministic total order instead — per-file
/// bytes stay identical, and the rgsuite oracle's own equivalence
/// (`sort_lines(gist) == sort_lines(rg)`) certifies the file-order freedom.
pub fn docLess(_: void, a: DocRef, b: DocRef) bool {
    return run.pathLess(a.path, b.path);
}

/// Which docs a gather admits: the FFI record stream skips what cold `--json`
/// skips (its 8 KiB `isBinary` window); the `lines` renderer admits every doc
/// and lets `binary.handleBinary` apply cold's NUL-cut policy per file.
pub const Admit = enum { json_stream, lines };
