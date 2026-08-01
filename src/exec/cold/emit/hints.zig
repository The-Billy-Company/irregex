//! gist hints — the one structured stderr guidance channel.
//!
//! gist's results contract is sacred: stdout carries rg-shaped bytes and
//! nothing else. But the agent who got *nothing* back deserves to know why
//! and what to try next — on stderr, in one stable grammar shared with the
//! output-budget notice in `corpus.zig`: an outcome line, then suggestion
//! lines (`gist: try <flag or move> — <why>`) and explanatory lines
//! (`gist: note: <fact>`), rustc's help/note split:
//!
//!     gist: no matches for 'Pattern' · 1204 files scanned · scope: services
//!     gist: try -i — the pattern has uppercase; retry case-insensitive
//!     gist: try -uu — gitignored and hidden files were excluded
//!
//! Every hint derives from the query's own shape (pattern bytes + the flags
//! in force) — never a second scan — so the channel costs O(|pattern|) when
//! it fires and nothing when it doesn't. At most three hints, ranked by how
//! often each one is the actual fix. Fires only on notable outcomes (zero
//! matches); a plain hit stays silent. `GIST_HINTS=0` mutes the channel for
//! parity harnesses; stdout is untouched either way.
//!
//! Two triggers, one grammar. An OUTCOME can be notable (`noMatches`), and so
//! can a DURATION: a walk still running after seconds of silence is
//! indistinguishable from a hung process, and gets killed like one. `Vigil`
//! closes that gap by reporting progress while the walk runs, in these same
//! lines and under this same mute — with one extra gate the outcome hints do
//! not need, since a progress line depends on timing rather than on the query
//! (see `Vigil.arm`).
const std = @import("std");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const fault = @import("../../../fault.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const guide = @import("../../../surface/cli/guide.zig");
const preference = @import("../argv/preference.zig");

/// What was searched — drives the summary tail and the widen/unhide hints.
pub const Scope = union(enum) {
    /// The whole tree from CWD (no PATH args) — nothing to widen.
    tree,
    /// Explicit PATH args (roots as given on the command line).
    paths: []const []const u8,
    /// Piped stdin — filesystem hints (scope, -uu) don't apply.
    stream,
};

/// The queryable facts a no-match hint can be derived from. Deliberately a
/// plain value type: the engines build one at their exit seam and hand it
/// over; render() below is a pure function of it (unit-testable, no I/O).
pub const Shape = struct {
    /// First pattern, for the summary line (display-truncated at render).
    display: []const u8 = "",
    /// Patterns beyond the first (-e/-f multiplicity), for honest wording.
    extra_patterns: usize = 0,
    // Pattern facts.
    has_upper: bool = false,
    has_meta: bool = false,
    has_newline: bool = false,
    has_space: bool = false,
    // Flags in force (post smart-case / inline-flag resolution).
    caseless: bool = false,
    fixed: bool = false,
    multiline: bool = false,
    invert: bool = false,
    /// Both ignore rules and hidden-file filtering already lifted (-uu)?
    searches_ignored: bool = false,
    scope: Scope = .tree,
    /// A preferences file that put answer-changing flags into this argv. The
    /// one hint the reader cannot derive from what they typed, because the
    /// cause is not on the line they typed.
    steered_by: ?[]const u8 = null,
};

/// Regex metacharacters that also appear routinely in code being searched
/// for verbatim — `foo(bar)`, `arr[0]`, `a+b`, `x?.y`, `${v}`, `end$`, `^top`.
/// `.` `*` `|` are deliberately absent: too weak a literal-intent signal.
const code_metas = "()[]{}+?^$\\";

/// A line break the default per-line search can never cross: a raw newline
/// byte always; the two-byte `\n`/`\r` escapes too when the pattern is regex.
fn spansLines(s: []const u8, fixed: bool) bool {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return true;
    return !fixed and (std.mem.indexOf(u8, s, "\\n") != null or std.mem.indexOf(u8, s, "\\r") != null);
}

/// Derive a Shape from the engines' parsed state. `roots_are_args` says the
/// roots came from PATH arguments (widen applies) rather than defaults.
pub fn shape(patterns: []const []const u8, o: args.Opts, roots: []const []const u8, roots_are_args: bool) Shape {
    var s = Shape{
        .display = if (patterns.len > 0) patterns[0] else "",
        .extra_patterns = patterns.len -| 1,
        .caseless = o.caseless,
        .fixed = o.fixed,
        .multiline = o.multiline,
        .invert = o.invert,
        .searches_ignored = o.no_ignore and o.hidden,
        .scope = if (roots_are_args) .{ .paths = roots } else .tree,
        .steered_by = preference.steering(),
    };
    for (patterns) |p| {
        if (args.hasUpper(p)) s.has_upper = true;
        if (std.mem.indexOfAny(u8, p, code_metas) != null) s.has_meta = true;
        if (spansLines(p, o.fixed)) s.has_newline = true;
        if (std.mem.indexOfScalar(u8, p, ' ') != null) s.has_space = true;
    }
    return s;
}

/// The stdin variant: no filesystem scope, no walk-derived hints.
pub fn shapeStream(patterns: []const []const u8, o: args.Opts) Shape {
    var s = shape(patterns, o, &.{}, false);
    s.scope = .stream;
    return s;
}

/// The warm-path variant — the resident daemon's client knows only the bare
/// classified request (pattern + a couple of booleans), not a full Opts.
pub fn shapeBare(pattern: []const u8, fixed: bool, caseless: bool) Shape {
    return shape(&.{pattern}, .{ .fixed = fixed, .caseless = caseless }, &.{}, false);
}

/// Render the no-match summary + up to three ranked hints into `out`.
/// Pure (stderr-free) so tests can assert exact bytes.
pub fn render(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Shape, files_scanned: ?usize) !void {
    // ── the outcome, one line ────────────────────────────────────────────
    const max_display = 64;
    const shown = s.display[0..@min(s.display.len, max_display)];
    try out.print(a, assay.tag ++ "no matches for '{s}{s}'", .{ shown, if (s.display.len > max_display) "…" else "" });
    if (s.extra_patterns > 0) try out.print(a, " (+{d} more patterns)", .{s.extra_patterns});
    if (files_scanned) |n| try out.print(a, " · {d} files scanned", .{n});
    switch (s.scope) {
        .tree => {},
        .stream => try out.appendSlice(a, " · piped stdin"),
        .paths => |roots| {
            try out.appendSlice(a, " · scope:");
            for (roots[0..@min(roots.len, 3)]) |r| try out.print(a, " {s}", .{r});
            if (roots.len > 3) try out.print(a, " (+{d} more)", .{roots.len - 3});
        },
    }
    try out.append(a, '\n');

    // ── the hints, ranked by how often each is the actual fix, capped at 3 ─
    var left: usize = 3;
    // First, because it is the only cause NOT visible in what the reader typed:
    // flags arrived from a file. Every other hint is derived from the command
    // line, so the reader can already see its premise.
    if (s.steered_by) |path|
        try line(a, out, &left, .note, try std.fmt.allocPrint(
            a,
            "flags from {s} are in force and change what matches — --no-config ignores them",
            .{path},
        ));
    // -v flips the meaning of "no matches"; pattern-tuning hints would mislead.
    if (s.invert) {
        try line(a, out, &left, .note, "-v is in force — exit 1 means every scanned line matched; nothing survived the inversion");
    } else {
        if (!s.caseless and s.has_upper)
            try line(a, out, &left, .act, "-i — the pattern has uppercase; retry case-insensitive");
        const spans_lines = !s.multiline and s.has_newline;
        if (spans_lines)
            try line(a, out, &left, .act, "-U — the pattern spans a line break; the default per-line search can never match it");
        // A line-break pattern is deliberate regex (the `\n` escape put the `\`
        // there); -U is the dominant fix, so the literal hint stands down.
        if (!s.fixed and s.has_meta and !spans_lines)
            try line(a, out, &left, .act, "-F — the pattern has regex metacharacters; -F searches those bytes literally");
        if (!s.fixed and s.has_space and !s.has_meta)
            try line(a, out, &left, .note, "spaces match literally — 'foo.*bar' finds both words on one line, in order");
    }
    if (s.scope != .stream and !s.searches_ignored)
        try line(a, out, &left, .act, "-uu — gitignored and hidden files were excluded from this search");
    if (s.scope == .paths)
        try line(a, out, &left, .act, "a wider scope — drop the PATH args to search the whole tree");
}

/// The hint voices are the shared CLI guidance grammar (`surface/cli/guide.zig`),
/// bound to this face's name — relate's weak-result verdict speaks the same one.
const Voice = guide.Voice;

fn line(a: std.mem.Allocator, out: *std.ArrayList(u8), left: *usize, voice: Voice, text: []const u8) !void {
    try guide.line(a, out, left, "gist", voice, text);
}

/// The engines' one-call exit hook: render the hint, honoring `GIST_HINTS`.
/// Never fails — a hint is a courtesy, not a result — and a hint that only
/// half-rendered is not emitted at all, so a truncated courtesy never reaches a
/// terminal.
pub fn noMatches(s: Shape, files_scanned: ?usize) void {
    fault.spare("render the no-match hint", emitNoMatches(s, files_scanned));
}

fn emitNoMatches(s: Shape, files_scanned: ?usize) !void {
    if (!corpus_mod.hintsEnabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try render(arena.allocator(), &out, s, files_scanned);
    // Through assay, not `std.debug.print` (law 6): the FFI scopes its sink
    // `.dark`, and a courtesy hint must not be the one thing that still writes
    // to an embedding host's stderr.
    assay.diag("{s}", .{out.items});
}

// ── the long walk's own voice ─────────────────────────────────────────────

/// How long a walk may stay silent before it owes the reader an explanation.
/// Two seconds is past every warm query and nearly every cold one, so an
/// ordinary run never speaks — and it lands before a hand reaches for ^C, which
/// is the entire point. The run that motivated this (`gist -uu -l 'class Prism'`
/// over a tree carrying 25 GB of vendored clones) took 78–122 s and said nothing
/// whatsoever until it finished; it was killed at six seconds as a hang.
const patience_s: u64 = 2;

/// Each notice waits twice as long as the last (2s, 4s, 8s, …) — `drain.zig`'s
/// ramp, applied to explanations instead of bytes. A two-minute walk spends six
/// lines saying so rather than sixty, and the gaps widen in the same direction
/// the reader's patience does.
const ramp_factor: u64 = 2;

/// The vigil's own wakeup granularity. It bounds only how late a notice can be,
/// never whether a finished walk gets announced (`finished` is re-read after
/// every sleep AND again after rendering), so it is tuned purely for a sleeping
/// thread nobody should be able to find on a profile.
const tick_ns: u64 = 250 * std.time.ns_per_ms;

/// What a running walk can say about itself for free: two counters the
/// work-stealing queue already maintains. A vigil never walks, stats, or opens
/// anything — it reads two atomics, so arming one cannot slow the walk it
/// watches. Deliberately plain pointers rather than the queue itself: this
/// channel has no business knowing what a work queue is, and either engine can
/// supply its own pair.
pub const Progress = struct {
    /// Directories fully listed so far — cumulative, only ever rises.
    walked: *const std.atomic.Value(usize),
    /// Directories discovered but not yet finished — the walk's remaining front.
    outstanding: *const std.atomic.Value(usize),
};

/// A background explanation for a walk slow enough to look broken.
///
/// Inherits this file's whole contract — stderr only, `GIST_HINTS=0` mutes it,
/// stdout is never touched — and adds the one gate the outcome hints don't need.
pub const Vigil = struct {
    finished: std.atomic.Value(bool) = .init(false),
    shape: Shape = .{},
    progress: ?Progress = null,

    /// Begin watching, then let the caller get on with the walk.
    ///
    /// The extra gate: a progress line is the only thing on this channel that
    /// depends on TIMING rather than on the query's shape, so it speaks solely
    /// into a terminal. A pipe, a redirect, a captured stderr, and every parity
    /// harness sit outside its reach by construction — which is what lets a
    /// human be told the walk is alive without any captured diagnostic losing
    /// byte-determinism.
    ///
    /// Detached on purpose, exactly like `elide.Lazy`'s loader thread: the
    /// engine's `run` never returns (it exits the process), so the vigil's frame
    /// outlives every worker, there is no join to get wrong, and `finish` only
    /// has to stop it SPEAKING. Failing to spawn is not an error — a walk with
    /// no vigil is simply a quiet one.
    pub fn arm(self: *Vigil, io: std.Io, s: Shape, p: Progress) void {
        if (!corpus_mod.hintsEnabled()) return;
        if (!(std.Io.File.stderr().isTty(io) catch false)) return;
        self.* = .{ .shape = s, .progress = p };
        if (std.Thread.spawn(.{}, watch, .{ self, io })) |th| th.detach() else |_| {}
    }

    /// The walk is over — stop watching. Cheap enough to call unconditionally,
    /// including on a vigil that never armed.
    pub fn finish(self: *Vigil) void {
        self.finished.store(true, .release);
    }

    fn watch(self: *Vigil, io: std.Io) void {
        const since = assay.Span.open(io);
        var deadline_s = patience_s;
        var first = true;
        while (true) {
            // A vigil that cannot sleep retires rather than spinning: it is a
            // courtesy, and burning a core to deliver one would be a worse bug
            // than the silence it exists to fix.
            io.sleep(.fromNanoseconds(tick_ns), .awake) catch return;
            if (self.finished.load(.acquire)) return;
            const elapsed_s: u64 = @intFromFloat(since.read(io).ms() / 1000);
            if (elapsed_s < deadline_s) continue;
            fault.spare("render the slow-walk notice", self.speak(elapsed_s, first));
            first = false;
            // Saturating: the ramp is unbounded in principle, and `*|` says so
            // in one character instead of a comment promising the walk ends.
            deadline_s = deadline_s *| ramp_factor;
        }
    }

    fn speak(self: *const Vigil, secs: u64, first: bool) !void {
        const p = self.progress orelse return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var out: std.ArrayList(u8) = .empty;
        try renderSlow(arena.allocator(), &out, self.shape, .{
            .secs = secs,
            .walked = p.walked.load(.monotonic),
            .outstanding = p.outstanding.load(.monotonic),
            .first = first,
        });
        // Re-read last: the walk can finish while this renders, and announcing a
        // walk that just completed is worse than having said nothing.
        if (self.finished.load(.acquire)) return;
        assay.diag("{s}", .{out.items});
    }
};

/// One notice's measured facts — the timing-dependent half of `renderSlow`,
/// named so the pure renderer can be driven from a test without a clock.
pub const Pace = struct {
    secs: u64,
    walked: usize,
    outstanding: usize,
    /// Is this the run's first notice? The advice cannot change while the walk
    /// runs, so only the first notice carries it; later ones are pure progress.
    first: bool = true,
};

/// Render the still-running notice. Pure (stderr-free), like `render`, so tests
/// assert exact bytes.
pub fn renderSlow(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Shape, pace: Pace) !void {
    const max_display = 64;
    const shown = s.display[0..@min(s.display.len, max_display)];
    try out.print(a, assay.tag ++ "still searching for '{s}{s}' after {d}s · {d} directories walked, {d} outstanding\n", .{
        shown,
        if (s.display.len > max_display) "…" else "",
        pace.secs,
        pace.walked,
        pace.outstanding,
    });
    if (!pace.first) return;
    var left: usize = 2;
    // Ranked by how much time each one gives back. `-uu` readmitted precisely
    // the trees the corpus policy exists to exclude — build output, vendored
    // clones, `.git` — which on a working monorepo is most of the bytes on disk,
    // so dropping it is worth far more than narrowing the scope.
    if (s.searches_ignored)
        try line(a, out, &left, .act, "without -uu — it readmitted the gitignored trees (build output, vendored clones, .git) that are most of this walk");
    if (s.scope == .tree)
        try line(a, out, &left, .act, "a PATH argument — a bounded walk is the cheapest way to make this finish");
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn rendered(a: std.mem.Allocator, s: Shape, files: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try render(a, &out, s, files);
    return out.toOwnedSlice(a);
}

test "uppercase pattern gets -i first; -uu rides along" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shape(&.{"WalletService"}, .{}, &.{}, false), 1204);
    try t.expectEqualStrings(
        \\gist: no matches for 'WalletService' · 1204 files scanned
        \\gist: try -i — the pattern has uppercase; retry case-insensitive
        \\gist: try -uu — gitignored and hidden files were excluded from this search
        \\
    , got);
}

test "metacharacters suggest -F; explicit paths get scope tail + widen" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shape(&.{"foo(bar)"}, .{}, &.{"services/backend"}, true), null);
    try t.expectEqualStrings(
        \\gist: no matches for 'foo(bar)' · scope: services/backend
        \\gist: try -F — the pattern has regex metacharacters; -F searches those bytes literally
        \\gist: try -uu — gitignored and hidden files were excluded from this search
        \\gist: try a wider scope — drop the PATH args to search the whole tree
        \\
    , got);
}

test "a preferences file that steered the answer is named first" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // Every other hint's premise is visible in the command line. This one's is
    // in a file the reader is not looking at, which is why it outranks them and
    // why the run stays silent about a preferences file that changed nothing.
    var s = shape(&.{"Wallet"}, .{ .no_ignore = true, .hidden = true }, &.{}, false);
    s.steered_by = "/home/x/.config/gist/preferences";
    try t.expectEqualStrings(
        \\gist: no matches for 'Wallet'
        \\gist: note: flags from /home/x/.config/gist/preferences are in force and change what matches — --no-config ignores them
        \\gist: try -i — the pattern has uppercase; retry case-insensitive
        \\
    , try rendered(arena.allocator(), s, null));
}

test "already -i -F -uu: nothing pattern-shaped left to say" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = args.Opts{ .caseless = true, .fixed = true, .no_ignore = true, .hidden = true };
    const got = try rendered(arena.allocator(), shape(&.{"Foo[0]"}, o, &.{}, false), 10);
    try t.expectEqualStrings(assay.tag ++ "no matches for 'Foo[0]' · 10 files scanned\n", got);
}

test "inverted match explains itself and suppresses pattern hints" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = args.Opts{ .invert = true, .no_ignore = true, .hidden = true };
    const got = try rendered(arena.allocator(), shape(&.{"MixedCase"}, o, &.{}, false), null);
    try t.expectEqualStrings(
        \\gist: no matches for 'MixedCase'
        \\gist: note: -v is in force — exit 1 means every scanned line matched; nothing survived the inversion
        \\
    , got);
}

test "newline in a regex pattern suggests -U; stdin scope skips -uu" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shapeStream(&.{"end\\nbegin"}, .{ .caseless = true }), null);
    try t.expectEqualStrings(
        \\gist: no matches for 'end\nbegin' · piped stdin
        \\gist: try -U — the pattern spans a line break; the default per-line search can never match it
        \\
    , got);
}

test "hint cap is three; long pattern display-truncates; extra patterns counted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const long = "X" ** 70 ++ "(a)";
    const got = try rendered(arena.allocator(), shape(&.{ long, "second" }, .{}, &.{ "a", "b", "c", "d" }, true), 5);
    var lines = std.mem.splitScalar(u8, got, '\n');
    const head = lines.first();
    try t.expect(std.mem.startsWith(u8, head, assay.tag ++ "no matches for '" ++ "X" ** 64 ++ "…' (+1 more patterns) · 5 files scanned · scope: a b c (+1 more)"));
    var hints_n: usize = 0;
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, assay.tag ++ "try ") or std.mem.startsWith(u8, l, assay.tag ++ "note: ")) hints_n += 1;
    }
    try t.expectEqual(@as(usize, 3), hints_n);
}

fn paced(a: std.mem.Allocator, s: Shape, pace: Pace) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try renderSlow(a, &out, s, pace);
    return out.toOwnedSlice(a);
}

test "the -uu whole-tree walk that read as a hang explains itself" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = args.Opts{ .no_ignore = true, .hidden = true };
    const got = try paced(arena.allocator(), shape(&.{"class Prism"}, o, &.{}, false), .{
        .secs = 8,
        .walked = 38412,
        .outstanding = 12067,
    });
    try t.expectEqualStrings(
        \\gist: still searching for 'class Prism' after 8s · 38412 directories walked, 12067 outstanding
        \\gist: try without -uu — it readmitted the gitignored trees (build output, vendored clones, .git) that are most of this walk
        \\gist: try a PATH argument — a bounded walk is the cheapest way to make this finish
        \\
    , got);
}

test "later notices are pure progress — the advice cannot have changed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = args.Opts{ .no_ignore = true, .hidden = true };
    const got = try paced(arena.allocator(), shape(&.{"class Prism"}, o, &.{}, false), .{
        .secs = 16,
        .walked = 71004,
        .outstanding = 903,
        .first = false,
    });
    try t.expectEqualStrings(assay.tag ++ "still searching for 'class Prism' after 16s · 71004 directories walked, 903 outstanding\n", got);
}

test "an already-scoped walk with ignores in force has no advice to offer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try paced(arena.allocator(), shape(&.{"Wallet"}, .{}, &.{"services/backend"}, true), .{
        .secs = 4,
        .walked = 812,
        .outstanding = 40,
    });
    try t.expectEqualStrings(assay.tag ++ "still searching for 'Wallet' after 4s · 812 directories walked, 40 outstanding\n", got);
}

test "a vigil that never armed is silent rather than crashing on no progress" {
    var v: Vigil = .{};
    v.finish();
    try t.expect(v.progress == null);
    try v.speak(9, true); // `progress == null` short-circuits before any render
}

test "bare shape (warm path): pattern facts still drive hints" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shapeBare("WalletService", false, false), null);
    try t.expect(std.mem.indexOf(u8, got, "-i — the pattern has uppercase") != null);
}
