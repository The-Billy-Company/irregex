//! assay/debug — one diagnostic channel: knob vocabulary, lens gate, sink.
//!
//! Diagnostics (timing summaries, `*_TRACE` phase lines, the warm-routing
//! verdict, walk/degradation notices) used to be ~90 scattered
//! `std.debug.print` calls straight to stderr. Three problems compounded:
//!
//!   1. The C-ABI/session contract "an embedding host must never see us write to
//!      stdout/stderr or `exit`" (src/root.zig, ADR-352) was held only by
//!      auditing all 90 sites — one stray `debug.print` on a warm path would
//!      break it silently.
//!   2. The warm daemon dropped diagnostics entirely (it can't write the
//!      client's stderr), so a warm query was unmeasurable.
//!   3. Four trace env vars (`GIST_AMEND_TRACE`/`…_JOURNAL_TRACE`/…) each used
//!      bare-presence truthiness, unlike the `envFalsy` policy the `GIST_HINTS`/
//!      `GIST_UNCAP` knobs beside them use.
//!
//! This module is the single seam every diagnostic flows through. The **sink**
//! is thread-local (default stderr; the FFI session installs `.dark`, a daemon
//! worker installs a per-request `.buffer`), so the never-write contract and the
//! warm-timing capability are both properties of one routing point rather than a
//! convention re-checked at every call. The **lens** gate replaces the four
//! bare-presence trace vars with one `GIST_TRACE=amend,journal,…` list sharing
//! the `envFalsy` policy. The **env vocabulary** (`envSpan`/`envFalsy`/
//! `envUsize`/`envFlag`) is the one place `GIST_*` knobs are read.

const std = @import("std");

// ── env-knob vocabulary — the one place a `GIST_*` variable is read ──

/// A `getenv` that arrives as a slice (null when unset). Every `GIST_*`/`HOME`/
/// XDG probe goes through here rather than a scattered `std.c.getenv` +
/// `std.mem.span` pair per site.
pub fn envSpan(key: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(key)) |v| std.mem.span(v) else null;
}

/// The shared "explicitly off" spelling for boolean knobs: `0`/`false`/`no`
/// (case-insensitive). Shared by every knob whose default is ON.
pub fn envFalsy(s: []const u8) bool {
    return std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no");
}

/// A base-10 `usize` env value, or null when unset or unparsable (leading/
/// trailing ASCII whitespace tolerated).
pub fn envUsize(key: [*:0]const u8) ?usize {
    const v = envSpan(key) orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null;
}

/// An "explicitly on" flag: present, non-empty, and not a falsy spelling — the
/// policy `GIST_UNCAP` uses ("any value except `0`/`false`/`no`/empty").
pub fn envFlag(key: [*:0]const u8) bool {
    const v = envSpan(key) orelse return false;
    return v.len != 0 and !envFalsy(v);
}

// ── the diagnostic lenses (was: four separate `*_TRACE` env vars) ──

/// A named class of trace diagnostic. Enabled per-run via
/// `GIST_TRACE=<lens>[,<lens>…]` (or `all`); off by default. Each lens replaces
/// one former env var: `amend`←`GIST_AMEND_TRACE`, `journal`←`GIST_JOURNAL_TRACE`,
/// `reconcile`←`GIST_RECONCILE_TRACE`, `warm`←`GIST_DEBUG_WARM`. `rank`/`index`/
/// `query`/`session` are new lenses those phases can opt into.
pub const Lens = enum(u5) { amend, journal, reconcile, warm, rank, index, query, session };

var lens_mask: std.atomic.Value(u32) = .init(0);
var format_json: bool = false;

/// Is a lens enabled this run? One relaxed atomic load — cheap enough to guard
/// every phase-timing call site.
pub fn lit(l: Lens) bool {
    return lens_mask.load(.monotonic) & (@as(u32, 1) << @intFromEnum(l)) != 0;
}

/// Parse a `GIST_TRACE` value into the lens mask. `all` lights every lens; an
/// unknown token is ignored (forward-compatible with new lenses). Public for
/// tests; `install` calls it from the environment.
pub fn parseLenses(spec: []const u8) u32 {
    var mask: u32 = 0;
    var it = std.mem.tokenizeAny(u8, spec, ", \t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "all")) return ~@as(u32, 0);
        inline for (@typeInfo(Lens).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(tok, f.name)) mask |= @as(u32, 1) << f.value;
        }
    }
    return mask;
}

// ── the sink (thread-local): where diagnostics actually go ──

/// A destination for diagnostic bytes. `stderr` is the cold-CLI default;
/// `dark` discards (the FFI session's never-write contract, by construction);
/// `buffer` accumulates into a caller-owned list (a daemon worker drains it into
/// a diagnostic frame so a warm query's timing reaches the client's stderr).
pub const Sink = union(enum) {
    stderr,
    dark,
    buffer: Buffer,

    pub const Buffer = struct { list: *std.ArrayList(u8), gpa: std.mem.Allocator };
};

// Process default, set once by `install` before any worker thread spawns.
var default_sink: Sink = .stderr;
// Per-thread override; null falls through to the process default.
threadlocal var tl_sink: ?Sink = null;

fn current() Sink {
    return tl_sink orelse default_sink;
}

/// Install the process-wide diagnostic policy from argv + environment. Call once
/// at process start, before dispatch: sets the default sink, reads the lens mask
/// from `GIST_TRACE`, and picks the trace/summary render format (`GIST_TRACE_
/// FORMAT=text|json`, defaulting to `json_default` — i.e. a `--json` run traces
/// as NDJSON so its stderr is machine-parseable too).
pub const Policy = struct { sink: Sink = .stderr, json_default: bool = false };

pub fn install(p: Policy) void {
    default_sink = p.sink;
    lens_mask.store(if (envSpan("GIST_TRACE")) |s| parseLenses(s) else 0, .monotonic);
    format_json = if (envSpan("GIST_TRACE_FORMAT")) |f|
        std.ascii.eqlIgnoreCase(f, "json")
    else
        p.json_default;
}

/// Whether summary/trace lines should render as NDJSON. `run_json` is the
/// verb's own `--json` flag; `GIST_TRACE_FORMAT` overrides it when set.
pub fn jsonFormat(run_json: bool) bool {
    return if (envSpan("GIST_TRACE_FORMAT") != null) format_json else run_json;
}

/// A scoped thread-local sink override. `end()` restores the prior sink — pair
/// it with `defer`. This is how a daemon worker captures one request's
/// diagnostics into a buffer, and how the FFI session goes dark for one call,
/// without disturbing other threads.
pub const Scope = struct {
    prev: ?Sink,
    pub fn end(self: Scope) void {
        tl_sink = self.prev;
    }
};

pub fn scope(s: Sink) Scope {
    const prev = tl_sink;
    tl_sink = s;
    return .{ .prev = prev };
}

fn write(comptime fmt: []const u8, args: anytype) void {
    switch (current()) {
        .stderr => std.debug.print(fmt, args),
        .dark => {},
        .buffer => |b| b.list.print(b.gpa, fmt, args) catch {},
    }
}

/// Emit an always-on diagnostic (a summary line, a truncation/degradation
/// notice, a walk error) through the current sink. Suppressed automatically
/// under a `dark` sink; captured under a `buffer` sink.
pub fn diag(comptime fmt: []const u8, args: anytype) void {
    write(fmt, args);
}

/// Emit a lens-gated phase trace: a no-op unless `l` is lit this run, then
/// routed through the current sink like `diag`.
pub fn trace(l: Lens, comptime fmt: []const u8, args: anytype) void {
    if (!lit(l)) return;
    write(fmt, args);
}

test "envFalsy recognizes the off spellings" {
    try std.testing.expect(envFalsy("0"));
    try std.testing.expect(envFalsy("false"));
    try std.testing.expect(envFalsy("NO"));
    try std.testing.expect(!envFalsy("1"));
    try std.testing.expect(!envFalsy(""));
}

test "parseLenses maps names and all" {
    try std.testing.expectEqual(@as(u32, 1) << @intFromEnum(Lens.amend), parseLenses("amend"));
    const both = (@as(u32, 1) << @intFromEnum(Lens.amend)) | (@as(u32, 1) << @intFromEnum(Lens.warm));
    try std.testing.expectEqual(both, parseLenses("amend, warm"));
    try std.testing.expectEqual(both, parseLenses("warm,amend,bogus"));
    try std.testing.expectEqual(~@as(u32, 0), parseLenses("all"));
    try std.testing.expectEqual(@as(u32, 0), parseLenses("nope"));
}

test "buffer sink captures, dark sink discards, restore works" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    {
        const sc = scope(.{ .buffer = .{ .list = &buf, .gpa = gpa } });
        defer sc.end();
        diag("hello {d}\n", .{7});
    }
    try std.testing.expectEqualStrings("hello 7\n", buf.items);

    {
        const sc = scope(.dark);
        defer sc.end();
        diag("swallowed\n", .{});
    }
    try std.testing.expectEqualStrings("hello 7\n", buf.items); // unchanged
}

test "trace is gated by the lens mask" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sc = scope(.{ .buffer = .{ .list = &buf, .gpa = gpa } });
    defer sc.end();

    lens_mask.store(0, .monotonic);
    trace(.amend, "amend line\n", .{});
    try std.testing.expectEqualStrings("", buf.items);

    lens_mask.store(parseLenses("amend"), .monotonic);
    trace(.amend, "amend line\n", .{});
    trace(.journal, "journal line\n", .{});
    try std.testing.expectEqualStrings("amend line\n", buf.items);
    lens_mask.store(0, .monotonic);
}
