//! irregex — the curated Zig-native hosted API (exact search, set-shaped primitives, and exact-before-statistical compose).
//!
//! `root.zig` re-exports the engine's internal tiers for the CLI, the tests,
//! and the C-ABI shims. This module is the *product* surface a Zig embedder
//! (or the C ABI + language bindings that sit above it) should program to: a
//! small, coherent vocabulary of owned handles over the same error-returning
//! warm engine the resident daemon and the in-process FFI already ride, so a
//! hosted answer is byte-identical to the cold `gist --json` stream and a bad
//! query can never `die()` the host.
//!
//! The vocabulary mirrors the CLI faces without copying their argv:
//!
//!   * `Engine`      — a hosted corpus: roots + allocator + threaded I/O + the
//!                     warm resident engine, opened once and queried many times.
//!   * `SearchQuery` — one match-finding intent (the `gist` exact face), the
//!                     deep option surface `contract/engine.toml` pins.
//!   * `Cursor`      — a *pull* result handle: `next()` one owned record at a
//!                     time, or `nextBatch()` to amortize the call boundary.
//!                     Records are owned by the cursor (copied off the engine's
//!                     transient scratch), valid until `deinit()`.
//!   * `CancelToken` — a thread-safe cooperative stop, checked at a strided
//!                     gather checkpoint AND at every record boundary, so a long
//!                     scan on one thread is abortable from another even before
//!                     it emits its first record.
//!   * `RunOptions`  — per-operation budgets: cancellation and a wall-clock
//!                     deadline bound the SCAN (a partial cursor, never a torn
//!                     record); a result cap stops at the record boundary.
//!
//! Ownership is explicit end to end: the caller owns the `gpa`; `Engine.open`
//! and `Engine.search` return heap-stable handles (the threaded-I/O interface
//! and the cursor arena capture their own addresses); every handle has exactly
//! one destructor. The two answer channels stay apart (fault-channel law 1): a
//! genuine failure is a Zig error (`OutOfMemory`, and only that), while "the
//! warm tier cannot answer this — run it cold" is a `fault.Answer` declinature,
//! the hosted spelling of the FFI's `IRREGEX_STALE`. It is never fatal, and
//! because it never touches the error channel a `try` cannot mistake it for one.

const std = @import("std");
const fault = @import("../fault.zig");
const resident = @import("../exec/session/warm/resident.zig");
const request = @import("../exec/session/answer/request.zig");

// The relate (compression-kinship) and compose (exact ∩ compression) kernels
// live in the `relate` package now — an embedder reaches them through that
// module (`@import("relate")`) beside this library's `Engine`.

/// A cooperative, thread-safe cancellation flag. One token is shared by
/// reference into `RunOptions.cancel`; any thread may `cancel()` while the
/// engine scans, and it is observed at a strided gather checkpoint AND at the
/// next record boundary — so a long scan stops cleanly whether or not it has
/// reached the emit yet (the cursor keeps whatever it gathered so far). The
/// primitive lives with the engine core it bounds (`resident.CancelToken`);
/// this is the hosted name for it.
pub const CancelToken = resident.CancelToken;

/// One match-finding intent — the deep `SearchRequest` surface, minus the
/// presentation/stats/replace concerns that stay CLI-only. Field semantics
/// track `contract/engine.toml [request_options]` and lower onto the
/// resident engine's `Request`.
pub const SearchQuery = struct {
    /// The regex or (with `fixed`) literal to find.
    pattern: []const u8,
    /// Treat `pattern` as a literal string (`-F`).
    fixed: bool = false,
    /// Case-insensitive (`-i`).
    ignore_case: bool = false,
    /// Case-insensitive unless the pattern has uppercase (`-S`).
    smart_case: bool = false,
    /// Match whole words (`-w`).
    word: bool = false,
    /// Select non-matching lines (`-v`).
    invert: bool = false,
    /// Unicode semantics (`--unicode` / `--no-unicode`); default rg-on.
    unicode: bool = true,
    /// Leading / trailing context lines (`-B` / `-A`).
    before: u64 = 0,
    after: u64 = 0,
    /// Per-file matching-line cap (`-m`); null = unlimited, 0 = match nothing.
    max_count: ?u64 = null,
};

/// Per-operation budgets, all fail-safe: a stop is always CLEAN — the cursor
/// keeps whatever it gathered, a hit is never truncated mid-record. Absent
/// budgets mean "run to completion."
pub const RunOptions = struct {
    /// Cooperative cancellation shared across threads. Observed at a strided
    /// gather checkpoint and at every record boundary, so it bounds a scan that
    /// has not yet emitted (a rare pattern, an invert walk) too.
    cancel: ?*const CancelToken = null,
    /// A monotonic wall-clock budget in nanoseconds, measured from the start of
    /// the search. Bounds both the doc scan (sampled at strided checkpoints) and
    /// the emit; the cursor holds whatever landed before it lapsed.
    timeout_ns: ?u64 = null,
    /// Stop after this many records land (a result budget), at the record
    /// boundary — the gather produces no records to cap.
    max_results: ?usize = null,
};

/// What a hosted result line can be — the exact-match line, or a context
/// neighbor (`-A`/`-B`/`-C`). Distinct from the compression score domains,
/// which never fuse into this exact result.
pub const MatchKind = enum { match, context };

/// One matched span within a line, as owned byte offsets `[start, end)`.
pub const Span = struct { start: usize, end: usize };

/// One owned result record. Unlike the C-ABI callback's aliased view, every
/// slice here is copied into the owning `Cursor`'s arena and stays valid until
/// the cursor is torn down — the natural ownership for a pull iterator.
pub const OwnedMatch = struct {
    path: []const u8,
    line_number: u64,
    text: []const u8,
    spans: []const Span,
    kind: MatchKind,

    /// 1-based column of the first span (0 for a context line).
    pub fn column(self: OwnedMatch) usize {
        return if (self.spans.len == 0) 0 else self.spans[0].start + 1;
    }
};

/// The one fault a hosted search can surface. Everything else the warm tier
/// can hit — a pattern outside the linear-time syntax, freshness it cannot
/// prove — is a **declinature**, not a failure: the embedder answers cold and
/// gets the byte-identical result, so it rides `fault.Answer`'s success
/// position where a `try` cannot silently turn it into an abort (fault-channel law 1).
pub const SearchError = std.mem.Allocator.Error;

/// A pull result handle: an owned, arena-backed record buffer plus a read
/// cursor. `next()` yields one record at a time; `nextBatch()` fills a caller
/// slice to amortize the per-call boundary (the crossing an FFI/binding pays).
/// Heap-stable so the arena's allocator interface (which captures `&arena`)
/// stays valid across the by-pointer return.
pub const Cursor = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(OwnedMatch),
    pos: usize = 0,
    /// Cold's exit-code boolean: did any file match (before any budget cut)?
    matched: bool = false,

    fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Cursor {
        const c = try gpa.create(Cursor);
        c.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .items = .empty };
        return c;
    }

    /// The next owned record, or null at the end.
    pub fn next(self: *Cursor) ?OwnedMatch {
        if (self.pos >= self.items.items.len) return null;
        defer self.pos += 1;
        return self.items.items[self.pos];
    }

    /// Fill `out` with up to `out.len` records; returns how many were written
    /// (0 at the end). The single crossing an embedder amortizes N records over.
    pub fn nextBatch(self: *Cursor, out: []OwnedMatch) usize {
        var n: usize = 0;
        while (n < out.len and self.pos < self.items.items.len) : (n += 1) {
            out[n] = self.items.items[self.pos];
            self.pos += 1;
        }
        return n;
    }

    /// Rewind to the first record (the buffer is retained).
    pub fn reset(self: *Cursor) void {
        self.pos = 0;
    }

    /// Total records gathered (independent of read position).
    pub fn count(self: *const Cursor) usize {
        return self.items.items.len;
    }

    /// Whether any file matched — cold's exit-code boolean, set even when a
    /// budget stopped the scan before draining every hit.
    pub fn anyMatched(self: *const Cursor) bool {
        return self.matched;
    }

    /// Free the record buffer and the handle (idempotent-safe: call once).
    pub fn deinit(self: *Cursor) void {
        self.arena.deinit();
        self.gpa.destroy(self);
    }
};

/// The collecting sink: qualifies as a resident `search` sink (`emit(rec) bool`,
/// true = stop). It copies each record into the cursor arena and enforces the
/// operation budgets at the record boundary — the one place a clean stop is safe.
const Collector = struct {
    arena: std.mem.Allocator,
    list: *std.ArrayList(OwnedMatch),
    cancel: ?*const CancelToken,
    io: std.Io,
    /// Absolute monotonic deadline (`.awake` clock ns), null = no budget.
    deadline: ?i128,
    max_results: ?usize,
    oom: bool = false,

    pub fn emit(self: *Collector, rec: resident.MatchRecord) bool {
        if (self.oom) return true;
        if (self.cancel) |c| if (c.requested()) return true;
        if (self.deadline) |d| if (std.Io.Clock.now(.awake, self.io).nanoseconds >= d) return true;

        const path = self.arena.dupe(u8, rec.path) catch return self.fail();
        const text = self.arena.dupe(u8, rec.text) catch return self.fail();
        const spans = self.arena.alloc(Span, rec.spans.len) catch return self.fail();
        for (rec.spans, spans) |src, *dst| dst.* = .{ .start = src.start, .end = src.end };
        self.list.append(self.arena, .{
            .path = path,
            .line_number = rec.line_number,
            .text = text,
            .spans = spans,
            .kind = @enumFromInt(@intFromEnum(rec.kind)),
        }) catch return self.fail();

        if (self.max_results) |m| if (self.list.items.len >= m) return true;
        return false;
    }

    /// The gather-phase view of this collector's budget: the same cancel token
    /// and deadline it enforces at the record boundary, handed to the doc scan
    /// that precedes any emit so `cancel`/`timeout_ns` also bound a no-match or
    /// invert scan (one that never reaches `emit`). `max_results` stays
    /// record-boundary-only — the gather produces no records to cap.
    pub fn runBudget(self: *const Collector) resident.RunBudget {
        return .{ .cancel = self.cancel, .deadline_ns = self.deadline };
    }

    fn fail(self: *Collector) bool {
        self.oom = true;
        return true;
    }
};

/// A hosted warm corpus. Heap-allocated so the threaded-I/O interface can
/// capture a stable `&self.threaded` (the same reason the FFI session is boxed).
pub const Engine = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    inner: resident.ResidentSession,

    /// Open a warm engine over `roots` (each an absolute or CWD-relative path;
    /// empty = the rootless CWD walk). The engine copies the root bytes, so
    /// `roots` need not outlive the call. Returns a heap-stable handle.
    pub fn open(gpa: std.mem.Allocator, roots: []const []const u8) !*Engine {
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.gpa = gpa;
        e.threaded = std.Io.Threaded.init(gpa, .{});
        e.io = e.threaded.io();
        e.inner = resident.ResidentSession.init(gpa, e.io, roots) catch |err| {
            e.threaded.deinit();
            return err;
        };
        return e;
    }

    /// Run `query` and gather its results into a pull `Cursor`. Records are
    /// gathered in cold's deterministic path order; `opts` budgets stop the scan
    /// at a record boundary. The caller owns the returned cursor (`deinit`).
    ///
    /// Declines (rather than fails) when the warm tier cannot answer this query
    /// — the embedder's own cold path can, identically.
    pub fn search(self: *Engine, query: SearchQuery, opts: RunOptions) SearchError!fault.Answer(*Cursor) {
        const cursor = Cursor.create(self.gpa) catch return error.OutOfMemory;
        errdefer cursor.deinit();

        const req = request.Request{
            .pattern = query.pattern,
            .mode = .files, // the record stream ignores mode; any value compiles
            .fixed = query.fixed,
            .ignore_case = query.ignore_case,
            .smart_case = query.smart_case,
            .word = query.word,
            .invert = query.invert,
            .unicode = query.unicode,
            .before = query.before,
            .after = query.after,
            .max_count = query.max_count,
        };

        var collector = Collector{
            .arena = cursor.arena.allocator(),
            .list = &cursor.items,
            .cancel = opts.cancel,
            .io = self.io,
            .deadline = if (opts.timeout_ns) |t| std.Io.Clock.now(.awake, self.io).nanoseconds + @as(i128, t) else null,
            .max_results = opts.max_results,
        };

        // A fresh per-call scratch arena for the engine's transient candidate
        // list — no engine-wide mutable scratch to race across calls.
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();

        // A declinature returns on the SUCCESS channel, so `errdefer` does not
        // fire for it — the cursor allocated above has to be released by hand or
        // it leaks on every "run this cold". The declinature sitting in the
        // success position is what makes a `try` unable to abort on a routine
        // fallback (fault-channel law 1); the cost is that ownership on that arm is the
        // caller's to discharge, exactly like the `.got` arm hands it to theirs.
        const any = switch (self.inner.search(scratch.allocator(), req, &collector) catch
            return error.OutOfMemory) {
            .got => |got| got,
            .declined => |d| {
                cursor.deinit();
                return .{ .declined = d };
            },
        };
        if (collector.oom) return error.OutOfMemory;
        cursor.matched = any;
        return .{ .got = cursor };
    }

    /// Tear down the warm corpus, index, I/O pool, and the handle.
    pub fn close(self: *Engine) void {
        self.inner.deinit();
        self.threaded.deinit();
        self.gpa.destroy(self);
    }
};
