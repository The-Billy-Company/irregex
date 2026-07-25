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
const std = @import("std");
const args = @import("../argv/args.zig");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const guide = @import("../../../cli/guide.zig");

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
    try out.print(a, "gist: no matches for '{s}{s}'", .{ shown, if (s.display.len > max_display) "…" else "" });
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

/// The engines' one-call exit hook: render to stderr, honoring `GIST_HINTS`.
/// Never fails — a hint is a courtesy, not a result.
pub fn noMatches(s: Shape, files_scanned: ?usize) void {
    if (!corpus_mod.hintsEnabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    render(arena.allocator(), &out, s, files_scanned) catch return;
    std.debug.print("{s}", .{out.items});
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

test "already -i -F -uu: nothing pattern-shaped left to say" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = args.Opts{ .caseless = true, .fixed = true, .no_ignore = true, .hidden = true };
    const got = try rendered(arena.allocator(), shape(&.{"Foo[0]"}, o, &.{}, false), 10);
    try t.expectEqualStrings("gist: no matches for 'Foo[0]' · 10 files scanned\n", got);
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
    try t.expect(std.mem.startsWith(u8, head, "gist: no matches for '" ++ "X" ** 64 ++ "…' (+1 more patterns) · 5 files scanned · scope: a b c (+1 more)"));
    var hints_n: usize = 0;
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "gist: try ") or std.mem.startsWith(u8, l, "gist: note: ")) hints_n += 1;
    }
    try t.expectEqual(@as(usize, 3), hints_n);
}

test "bare shape (warm path): pattern facts still drive hints" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shapeBare("WalletService", false, false), null);
    try t.expect(std.mem.indexOf(u8, got, "-i — the pattern has uppercase") != null);
}
