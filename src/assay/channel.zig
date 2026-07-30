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

/// The parity-gate "force the serial reference" knob — the SINGLE joint that
/// decides which cold plane runs. `GIST_NO_PARALLEL` (internal, undocumented,
/// never a CLI flag) routes every eligible query and every emit-phase shard onto
/// the single-threaded reference engine, so the differential gates
/// (`bench/gates/line_parity.sh`, `bench/rgsuite/run.py`,
/// `bench/evaluate/regimes.py`) can push one case list through BOTH the parallel
/// swarm and the serial oracle and prove them byte-identical.
///
/// It lives here, read by exactly one function, precisely because plane
/// selection is this kernel's highest systemic risk: `swarm.eligible`, both
/// `serial.zig` emit shards, and `json.runParallel` all defer to this, so a new
/// parallel entry point cannot silently mis-spell or skip the knob and blind the
/// gate's serial column — the exact drift this engine's history proves possible
/// (the parallel walk once lagged a serial-only ignore fix). Presence, not
/// truthiness (`=0` still forces serial), matching every gate's `=1`. The
/// sibling loader knob `GIST_NO_PARALLEL_LOAD` (corpus.zig) is deliberately
/// separate — a different plane (index load), gated by `envFlag`.
pub fn serialForced() bool {
    return envSpan("GIST_NO_PARALLEL") != null;
}

// ── the diagnostic lenses (was: four separate `*_TRACE` env vars) ──

/// A named class of trace diagnostic. Enabled per-run via
/// `GIST_TRACE=<lens>[,<lens>…]` (or `all`); off by default. Each lens replaces
/// one former env var: `amend`←`GIST_AMEND_TRACE`, `journal`←`GIST_JOURNAL_TRACE`,
/// `reconcile`←`GIST_RECONCILE_TRACE`, `warm`←`GIST_DEBUG_WARM`. `rank`/`index`/
/// `query`/`session` are new lenses those phases can opt into.
///
/// `fault` is the odd one out: not a phase but a disposition — every failure
/// the kernel deliberately spared because it could not change the answer
/// (`fault.spare`, ADR-373 law 8). Off by default, so best-effort work stays
/// quiet; lit, it is the only way to see a spared failure at all.
///
/// `link` is the OSC-8 hyperlink decision (`cli/beacon.zig`): whether this run
/// links, and which destination it resolved. A feature that is on by default
/// and invisible when it declines needs a way to ask why it declined.
///
/// `walk` is what the corpus walk RETAINED, per worker and by cause — the arena
/// that outlives a directory, the per-worker read scratch, the coalesced
/// path-list buffer, the deferred backlog. A scanner's owned footprint is a
/// competitive number; it cannot be defended without being attributable.
pub const Lens = enum(u5) { amend, journal, reconcile, warm, rank, index, query, session, fault, link, walk };

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

// ── the chatter classes (was: a lane of stderr with no switch at all) ──

/// A class of ALWAYS-ON message a caller may silence — the inverse of `Lens`.
/// A lens is dark until it is named; a chatter class speaks until it is muffled.
///
/// Both members are FILE chatter: the lane that reports, one line per offending
/// path, what the walk could not read or honor. On a tree with an unreadable
/// directory it is the noisiest thing gist writes, and it is exactly the lane
/// ripgrep's `--no-messages` / `--no-ignore-messages` exist to quiet. Nothing
/// else on stderr belongs here — a timing summary, an output-truncation notice,
/// and the `GIST_HINTS` guidance channel each answer to their own switch, and
/// folding them in would silence more than the flag promises.
///
/// Muffling changes what is REPORTED, never what happened: a path the walk
/// could not descend still flags the run's exit 2 (the flagging and the message
/// are separate statements at every call site), so a quiet run and a loud one
/// exit identically. That is ripgrep's rule too — its `err_message!` sets the
/// errored bit before consulting the switch.
pub const Chatter = enum(u5) {
    /// A path that could not be opened, descended, or read, plus the "no files
    /// were searched" verdict the walk's own filters produce. `--no-messages`.
    corpus,
    /// An ignore SOURCE that could not be honored — an `--ignore-file` that
    /// will not open. `--no-ignore-messages` silences this class alone;
    /// `--no-messages` silences it as well, since quieting every file message
    /// quiets this one (ripgrep's `ignore_message!` requires both gates).
    ignore,
};

var muffled: std.atomic.Value(u32) = .init(0);

fn bit(c: Chatter) u32 {
    return @as(u32, 1) << @intFromEnum(c);
}

/// Is this class still speaking? One relaxed atomic load, like `lit`.
pub fn audible(c: Chatter) bool {
    return muffled.load(.monotonic) & bit(c) == 0;
}

/// Apply ripgrep's two message switches, both given as "still on?" booleans.
/// The nesting — `--no-messages` outranks and subsumes `--no-ignore-messages` —
/// is resolved once here rather than re-derived at each `note` call site, which
/// is what keeps a new message class from picking up half the rule.
pub fn muffle(messages: bool, ignore_messages: bool) void {
    var m: u32 = 0;
    if (!messages) m |= bit(.corpus) | bit(.ignore);
    if (!ignore_messages) m |= bit(.ignore);
    muffled.store(m, .monotonic);
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
///
/// `lenses` states the mask outright instead of reading `GIST_TRACE`, for the
/// callers that have no environment to read: an embedder of the C ABI that wants
/// spared failures collected, and a test that must light a lens deterministically.
pub const Policy = struct { sink: Sink = .stderr, json_default: bool = false, lenses: ?u32 = null };

pub fn install(p: Policy) void {
    default_sink = p.sink;
    lens_mask.store(p.lenses orelse if (envSpan("GIST_TRACE")) |s| parseLenses(s) else 0, .monotonic);
    // A freshly installed policy speaks. The message switches are FLAGS, not
    // environment, so they cannot be read here — `muffle` lands them once the
    // argv is parsed, which is still before anything can walk a tree.
    muffled.store(0, .monotonic);
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
        // The one failure in the kernel with nowhere to go: this *is* the
        // diagnostic channel, so reporting its own OOM would re-enter here.
        // Dropping the line is the terminating choice, and it costs only a
        // captured diagnostic — never an answer. Deliberately not
        // `fault.spare`, which would recurse through this same write.
        .buffer => |b| b.list.print(b.gpa, fmt, args) catch |e| switch (e) {
            error.OutOfMemory => {},
        },
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

/// Emit an always-on FILE message unless its class was muffled — the third
/// emit, sitting between `diag` (which no flag silences) and `trace` (silent
/// until a lens is lit). Every message ripgrep's `--no-messages` /
/// `--no-ignore-messages` govern comes through here and nothing else does.
pub fn note(c: Chatter, comptime fmt: []const u8, args: anytype) void {
    if (!audible(c)) return;
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

test "muffle applies ripgrep's nesting: --no-messages subsumes the ignore class" {
    defer muffle(true, true);

    muffle(true, true); // the default run: both classes speak
    try std.testing.expect(audible(.corpus) and audible(.ignore));

    muffle(true, false); // --no-ignore-messages: only the ignore class quiets
    try std.testing.expect(audible(.corpus) and !audible(.ignore));

    // --no-messages is the OUTER gate: it takes the ignore class with it, even
    // though `--ignore-messages` is still nominally on.
    muffle(false, true);
    try std.testing.expect(!audible(.corpus) and !audible(.ignore));

    muffle(false, false);
    try std.testing.expect(!audible(.corpus) and !audible(.ignore));
}

test "note is gated by its chatter class; diag is not" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const sc = scope(.{ .buffer = .{ .list = &buf, .gpa = gpa } });
    defer sc.end();
    defer muffle(true, true);

    muffle(false, true);
    note(.corpus, "locked: Permission denied\n", .{});
    note(.ignore, "missing.ignore: No such file\n", .{});
    try std.testing.expectEqualStrings("", buf.items);

    // A muffled run still gets everything the switch does not govern — a
    // summary or truncation notice is not a file message.
    diag("gist: output truncated\n", .{});
    try std.testing.expectEqualStrings("gist: output truncated\n", buf.items);

    buf.clearRetainingCapacity();
    muffle(true, false);
    note(.corpus, "locked: Permission denied\n", .{});
    note(.ignore, "missing.ignore: No such file\n", .{});
    try std.testing.expectEqualStrings("locked: Permission denied\n", buf.items);
}

test "install restores a speaking policy" {
    defer muffle(true, true);
    muffle(false, false);
    install(.{ .lenses = 0 });
    try std.testing.expect(audible(.corpus) and audible(.ignore));
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
