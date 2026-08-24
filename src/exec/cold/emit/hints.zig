//! Hints — the one structured stderr guidance channel.
//!
//! The results contract is sacred: stdout carries rg-shaped bytes and
//! nothing else. But the agent who got *nothing* back deserves to know why
//! and what to try next — on stderr, in one stable grammar shared with the
//! output-budget notice in `corpus.zig`: an outcome line, then suggestion
//! lines (`<name>: try <flag or move> — <why>`) and explanatory lines
//! (`<name>: note: <fact>`), rustc's help/note split:
//!
//!     <name>: no matches for 'Pattern' · 1204 files scanned · scope: services
//!     <name>: try -i — the pattern has uppercase; retry case-insensitive
//!     <name>: try -uu — gitignored and hidden files were excluded
//!
//! Every hint derives from the query's own shape (pattern bytes + the flags
//! in force) — never a second scan — so the channel costs O(|pattern|) when
//! it fires and nothing when it doesn't. At most three hints, ranked by how
//! often each one is the actual fix. Fires only on notable outcomes (zero
//! matches); a plain hit stays silent. `<prefix>HINTS=0` mutes the channel for
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
    /// A metacharacter the ENGINE will act on — not one the author escaped.
    /// See `activeMeta`: the difference decides whether `-F` can possibly help.
    active_meta: bool = false,
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
    /// Does stdout carry the matched text itself, so reading it back says
    /// something about what matched? False for the enumeration modes (`-l`, `-c`,
    /// `--json`) whose output holds no match bytes, and for `-r` which rewrites
    /// them. Gates `deadBranches` and nothing else.
    results_faithful: bool = false,
};

/// Regex metacharacters that also appear routinely in code being searched
/// for verbatim — `foo(bar)`, `arr[0]`, `a+b`, `x?.y`, `${v}`, `end$`, `^top`.
/// `.` `*` `|` are deliberately absent: too weak a literal-intent signal. The
/// escape character is absent too, and that absence is load-bearing — see
/// `activeMeta`.
const code_metas = "()[]{}+?^$";

/// Does the pattern carry a metacharacter the ENGINE WILL ACT ON, rather than
/// one the author already escaped?
///
/// That distinction is the entire worth of the `-F` hint. `foo(bar)` is someone
/// who typed code and got a capture group, and `-F` is their fix. `globals\(\)`
/// is someone who already said "literal parens" and got them, and `-F` would
/// search for the backslashes too — the one suggestion that cannot succeed.
/// This test used to be `indexOfAny("()[]{}+?^$\\")`, which included the escape
/// character itself, so every correctly-escaped pattern was handed the single
/// flag guaranteed to break it.
fn activeMeta(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        // A backslash spends the next byte whatever it is — `\(` is an inert
        // paren, `\\` an inert backslash — so neither byte can be an active
        // metacharacter and both are stepped over as one unit.
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, code_metas, s[i]) != null) return true;
    }
    return false;
}

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
        // `-m` is deliberately in here: a per-file cap can stop before a branch's
        // only hit, and a dead-branch note is worth printing only when the results
        // are the whole answer.
        .results_faithful = o.mode == .standard and o.replace == null and !o.quiet and !o.max_per_file_set,
    };
    for (patterns) |p| {
        if (args.hasUpper(p)) s.has_upper = true;
        if (activeMeta(p)) s.active_meta = true;
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

/// The warm-path variant: a resident-served query's own facts, taken from the
/// classified request rather than a full `Opts`.
///
/// Passed as plain values because the classified request lives a tier ABOVE this
/// module (`exec/session/`) and a hint renderer must not reach up the page to
/// read it. The three corpus-widening flags a `Shape` otherwise carries —
/// `-uu`/`--hidden`/`-U` — are unrepresentable here on purpose: the warm
/// classifier declines every one of them to cold, so a resident answer is always
/// an ignore-respecting, per-line search and the defaults below are the truth
/// rather than a guess.
///
/// `roots` is the fact this used to throw away. It is on the wire (`query_ext`
/// carries the whole `PathFilter`), so a warm miss now earns the same scope tail
/// and widen hint a cold miss does — those two were previously reachable only by
/// the slow path, which is the opposite of where they are needed most.
pub fn shapeWarm(pattern: []const u8, fixed: bool, caseless: bool, invert: bool, roots: []const []const u8) Shape {
    return shape(
        &.{pattern},
        .{ .fixed = fixed, .caseless = caseless, .invert = invert },
        roots,
        roots.len > 0,
    );
}

// ── evidence: what the run PROVED, not what its syntax suggests ───────────────

/// The regex metacharacters that make a branch a PATTERN rather than a string.
/// Wider than `code_metas` on purpose: that set asks "did someone paste code",
/// this one asks "can I look for these bytes verbatim", and `.` `*` `|` answer
/// the second question even though they are weak evidence for the first.
const regex_metas = ".*+?()[]{}^$|";

/// Below three bytes a "prefix" stops being evidence of anything — every corpus
/// on earth contains `KE`. It is also the trigram index's own floor, so the
/// cheapest fact this channel reports is the cheapest fact the corpus can hold.
const prefix_floor: usize = 3;

/// Branches reported for one alternation. A query bundling more probes than this
/// is not being explained line-by-line anyway, so the splitter declines rather
/// than print a wall.
const max_branches = 8;

/// How many resident bytes a probe reads before it stops explaining and gets out
/// of the way. A hint is a courtesy; it must never become the reason a query felt
/// slow. Far above any real scope that came back empty.
const probe_budget_bytes: usize = 64 << 20;

/// One top-level alternation branch, with what the searched bytes say about it.
pub const Branch = struct {
    /// The branch as written, for display.
    text: []const u8,
    /// The longest prefix of the branch's literal that DOES occur in the bytes
    /// the search read — null when not even its first three bytes do, or when
    /// the branch was a real regex and earned no byte probe. Positive claims
    /// only: a prefix appears here because it was FOUND, never because it was
    /// expected, which is what makes it impossible for this field to lie.
    live: ?[]const u8 = null,
    /// Lines carrying `live` — our own counting unit (`-c`).
    lines: usize = 0,
    /// Does this branch reduce to plain bytes at all? False for a real regex
    /// (`a.*b`, `\d+`), which can be neither looked up in an index nor searched
    /// for literally. Independent of the bytes — a property of the pattern.
    literal: bool = false,
    /// Were resident bytes actually examined for it? A branch nobody probed
    /// proves nothing, which is why `live == null` alone cannot be read as
    /// absence. Distinct from `literal`: an engine that streamed its bytes away
    /// has literal branches it never got to probe.
    probed: bool = false,
};

/// A literal absent from the scope that was searched, found in a file that was
/// NOT. The most valuable thing a failed search can say, and the one fact no
/// amount of staring at the pattern can produce: the name was right, the place
/// was wrong.
///
/// Filled by whoever can reach the corpus (`quarry/witness.zig`) and left null
/// otherwise, so this module keeps no index knowledge and stays byte-testable.
/// `path` is always VERIFIED against live bytes rather than taken from the
/// trigram prefilter, which answers with candidates — a hint naming a file that
/// turns out not to hold the string would be worse than no hint.
pub const Sighting = struct {
    /// The branch that was found, as written.
    branch: []const u8,
    /// A file outside the searched scope whose current bytes hold it.
    path: []const u8,
    /// Further files also verified within the probe budget. Never an estimate:
    /// files nobody opened are not counted.
    more: usize = 0,
};

/// What a failed query proved about itself.
///
/// The old channel was priors with no likelihood: `-i` fired on any uppercase,
/// `-F` on any metacharacter, `-uu` on every filesystem run. So a pattern none of
/// them could fix drew all three, and the reader had to test three false claims
/// by hand. Evidence is the missing half — facts confirmed against the exact
/// bytes the search read, so a hint derived from one cannot be false.
///
/// Both kinds of fact here are sound for free. In a run that matched NOTHING
/// every alternation branch is dead by deduction — had one matched, the run
/// would have — so listing them needs no probe at all. And a live prefix is only
/// ever reported because it was found. Whatever the bytes cannot settle stays
/// absent rather than guessed.
pub const Evidence = struct {
    /// Top-level alternation branches in source order, or one entry for a simple
    /// pattern. Empty when nothing was probed.
    branches: []const Branch = &.{},
    /// Proven: no branch occurs in these bytes even when case is ignored, so
    /// `-i` cannot be the fix. Set only for pure-ASCII literals, where ASCII
    /// folding is the whole of case folding — a non-ASCII byte leaves the
    /// question open and this false, because a hint that suppresses a real fix is
    /// worse than one that suggests a useless flag.
    caseless_dead: bool = false,
    /// The pattern is absent HERE but present THERE — see `Sighting`.
    elsewhere: ?Sighting = null,

    /// The branch that got closest — the longest live prefix among them. This is
    /// the one an agent wants: it says WHERE a guessed name stopped being real.
    fn nearest(self: Evidence) ?Branch {
        var best: ?Branch = null;
        for (self.branches) |b| {
            const live = b.live orelse continue;
            if (best == null or live.len > best.?.live.?.len) best = b;
        }
        return best;
    }

    /// Did every branch come back with nothing at all — not even its first three
    /// bytes? Then no respelling of this pattern will match here, and the honest
    /// next move is a different KIND of search rather than another flag.
    fn allCold(self: Evidence) bool {
        if (self.branches.len == 0) return false;
        for (self.branches) |b| {
            if (b.live != null) return false;
            // A branch nothing was probed for proves nothing either way, so it
            // cannot contribute to a claim about the whole pattern.
            if (b.probed == false) return false;
        }
        return true;
    }
};

/// Split a pattern on its TOP-LEVEL `|`, or decline.
///
/// Escape- and nesting-aware, because the alternation an agent means is the one
/// at the top: `KEY_A|KEY_B` is several probes bundled into one query — the idiom
/// this whole channel exists for — while `foo(a|b)` is one pattern, and splitting
/// it would invent branches nobody wrote. Declines for a pattern with no
/// top-level `|`, and for one carrying more branches than `max_branches`.
fn splitBranches(pattern: []const u8, out: *[max_branches][]const u8) ?[][]const u8 {
    var n: usize = 0;
    var start: usize = 0;
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) switch (pattern[i]) {
        // The escape spends the next byte, `|` included — `a\|b` is one branch.
        '\\' => i += 1,
        '[' => in_class = true,
        ']' => in_class = false,
        '(' => if (!in_class) {
            depth += 1;
        },
        ')' => if (!in_class) {
            depth -|= 1;
        },
        '|' => if (!in_class and depth == 0) {
            if (n == out.len - 1) return null; // one slot must remain for the tail
            out[n] = pattern[start..i];
            n += 1;
            start = i + 1;
        },
        else => {},
    };
    if (n == 0) return null; // no top-level alternation
    out[n] = pattern[start..];
    return out[0 .. n + 1];
}

/// The literal BYTES a branch matches, written into `buf`, or null when the
/// branch is a real pattern.
///
/// `globals\(\)` yields `globals()`, which is the only spelling a byte probe
/// could ever find — searching the raw source bytes would look for backslashes
/// that were never on disk. Any UNescaped metacharacter, and any escape that is
/// a class or boundary rather than a literal stand-in (`\d`, `\b`, `\n`), means
/// the branch is a regex and earns no byte probe at all: a literal search for it
/// would be quietly answering a different question.
fn literalOf(s: []const u8, buf: []u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var c = s[i];
        if (c == '\\') {
            i += 1;
            if (i == s.len) return null; // a dangling escape is not a literal
            c = s[i];
            if (c != '\\' and std.mem.indexOfScalar(u8, regex_metas, c) == null) return null;
        } else if (std.mem.indexOfScalar(u8, regex_metas, c) != null) return null;
        if (w == buf.len) return null;
        buf[w] = c;
        w += 1;
    }
    return buf[0..w];
}

/// The bytes a branch could occur as on disk, or null when it is a real pattern
/// and therefore has none. Under `-F` the source bytes ARE the literal; otherwise
/// this is `literalOf`'s unescaping.
///
/// Published because the corpus-side prober (`quarry/witness.zig`) must look for
/// exactly the bytes this module reasoned about — one notion of "what this branch
/// means literally", so a sighting and a live-prefix finding can never disagree
/// about the same branch.
pub fn literalBytes(text: []const u8, fixed: bool, buf: []u8) ?[]const u8 {
    return if (fixed) text else literalOf(text, buf);
}

/// The longest prefix of `needle` present in `hay`, at or above `prefix_floor`.
///
/// Anchored on the three-byte prefix and extended at each hit, so the whole
/// question costs ONE `indexOf` pass rather than a scan per candidate length —
/// and the bytes are already in memory, because the search just read them.
fn longestLivePrefix(needle: []const u8, hay: []const u8) usize {
    if (needle.len <= prefix_floor) return 0;
    var best: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle[0..prefix_floor])) |k| {
        var ext = prefix_floor;
        while (ext < needle.len and k + ext < hay.len and hay[k + ext] == needle[ext]) ext += 1;
        if (ext > best) best = ext;
        if (best == needle.len) return best; // whole literal present; caller judges
        i = k + 1;
    }
    return best;
}

/// Lines of `hay` carrying `text` — one linear pass, and the same unit `-c`
/// counts in, so a hint's number and a follow-up command's number agree.
fn linesWith(text: []const u8, hay: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |ln| if (std.mem.indexOf(u8, ln, text) != null) {
        n += 1;
    };
    return n;
}

/// The branches this pattern asks about, and which of them reduce to plain
/// bytes — everything derivable from the pattern alone, before any corpus is
/// consulted.
///
/// Split out of `probe` because the parallel engine streams each file past its
/// worker and keeps nothing: it reaches the no-match exit with no bytes to probe,
/// yet it still has a pattern, and the corpus-side witness only ever needed the
/// literals. So this is the half that is always available, and `probe` is the
/// half that needs a resident corpus.
pub fn branchesOf(a: std.mem.Allocator, s: Shape) []Branch {
    if (!corpus_mod.hintsEnabled()) return &.{};
    // -v inverts what "no match" means, so a branch's presence explains nothing.
    if (s.invert) return &.{};
    var slots: [max_branches][]const u8 = undefined;
    // Under -F the whole pattern is one literal and `|` is just a byte in it, so
    // splitting would report branches the engine never had.
    const texts = if (s.fixed) blk: {
        slots[0] = s.display;
        break :blk slots[0..1];
    } else splitBranches(s.display, &slots) orelse blk: {
        slots[0] = s.display;
        break :blk slots[0..1];
    };
    const out = a.alloc(Branch, texts.len) catch return &.{};
    for (texts, out) |text, *b| {
        var lit_buf: [256]u8 = undefined;
        b.* = .{ .text = text, .literal = literalBytes(text, s.fixed, &lit_buf) != null };
    }
    return out;
}

/// Gather `Evidence` from the bytes the search already read.
///
/// Deliberately not a second scan OF THE DISK: `files` are the intake records the
/// engine just searched, bytes and all, so this is one more pass over resident
/// memory on a run that already failed — the cheapest possible moment to buy a
/// true hint, and the only moment anybody wants one. `anytype` is what keeps this
/// module a leaf: it needs `.bytes` and nothing else, so the ordinary intake
/// record and the ranked view's live file both satisfy it without this tier
/// importing either.
pub fn probe(a: std.mem.Allocator, s: Shape, files: anytype) Evidence {
    const out = branchesOf(a, s);
    if (out.len == 0) return .{};

    var total: usize = 0;
    for (files) |f| total += f.bytes.len;
    // The counterfactual behind the most frequently false hint of the three: if
    // no branch is here even with case ignored, `-i` is not the fix and saying so
    // costs a slot a real finding could use. Answered from the same resident
    // bytes, in the same pass, so the truth is free.
    var caseless_answerable = true;
    var caseless_hit = false;
    for (out) |*b| {
        if (total > probe_budget_bytes or !b.literal) {
            caseless_answerable = false;
            continue;
        }
        var lit_buf: [256]u8 = undefined;
        const lit = literalBytes(b.text, s.fixed, &lit_buf).?;
        b.probed = true;
        // Non-ASCII puts real case folding out of reach of a byte comparison, so
        // the caseless question goes unanswered rather than answered wrongly.
        if (!isAscii(lit)) caseless_answerable = false else {
            for (files) |f| if (std.ascii.indexOfIgnoreCase(f.bytes, lit) != null) {
                caseless_hit = true;
                break;
            };
        }
        var best: usize = 0;
        for (files) |f| {
            const n = longestLivePrefix(lit, f.bytes);
            if (n > best) best = n;
        }
        // `best == lit.len` means the literal is wholly present even though the
        // run matched nothing — which `-w` and `-x` can both arrange. Reporting a
        // "live prefix" there would be true and useless, so say nothing and let
        // the flag-shaped hints speak.
        if (best < prefix_floor or best >= lit.len) continue;
        const live = a.dupe(u8, lit[0..best]) catch continue;
        var lines: usize = 0;
        for (files) |f| lines += linesWith(live, f.bytes);
        b.live = live;
        b.lines = lines;
    }
    return .{ .branches = out, .caseless_dead = caseless_answerable and !caseless_hit };
}

/// Is every byte ASCII? The gate on the caseless counterfactual: above 0x7F,
/// folding is Unicode's business and a byte comparison cannot settle it.
fn isAscii(s: []const u8) bool {
    for (s) |c| if (c > 0x7F) return false;
    return true;
}

/// Render the no-match summary + up to three ranked hints into `out`.
/// Pure (stderr-free) so tests can assert exact bytes.
pub fn render(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Shape, files_scanned: ?usize, ev: Evidence) !void {
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

    // ── the hints, ranked by EVIDENCE first, then priors, capped at 3 ─────
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
    // Then anything the bytes PROVED. These outrank every flag hint below on
    // purpose: a checked fact about this corpus beats a guess from the pattern's
    // syntax, and when evidence fills the budget the guesses are what get cut.
    if (!s.invert) try renderEvidence(a, out, &left, s, ev);
    // -v flips the meaning of "no matches"; pattern-tuning hints would mislead.
    if (s.invert) {
        try line(a, out, &left, .note, "-v is in force — exit 1 means every scanned line matched; nothing survived the inversion");
    } else {
        // `caseless_dead` is the probe having already tried it: the bytes are not
        // here with case ignored either, so this is the one hint we can retire
        // outright rather than merely rank below a finding.
        if (!s.caseless and s.has_upper and !ev.caseless_dead)
            try line(a, out, &left, .act, "-i — the pattern has uppercase; retry case-insensitive");
        const spans_lines = !s.multiline and s.has_newline;
        if (spans_lines)
            try line(a, out, &left, .act, "-U — the pattern spans a line break; the default per-line search can never match it");
        // A line-break pattern is deliberate regex (the `\n` escape put the `\`
        // there); -U is the dominant fix, so the literal hint stands down.
        if (!s.fixed and s.active_meta and !spans_lines)
            try line(a, out, &left, .act, "-F — the pattern has regex metacharacters; -F searches those bytes literally");
        if (!s.fixed and s.has_space and !s.active_meta)
            try line(a, out, &left, .note, "spaces match literally — 'foo.*bar' finds both words on one line, in order");
    }
    if (s.scope != .stream and !s.searches_ignored)
        try line(a, out, &left, .act, "-uu — gitignored and hidden files were excluded from this search");
    // The same advice the sighting already gave, minus the file name — so it is
    // only worth a slot when no sighting took one.
    if (s.scope == .paths and ev.elsewhere == null)
        try line(a, out, &left, .act, "a wider scope — drop the PATH args to search the whole tree");
}

/// The proven half of the channel, in the same grammar as the rest.
///
/// Three facts at most, ordered by what a reader does next with them: which
/// branch died (the shape of the failure), where a guessed name stopped being
/// real (the fix), and — when even three bytes never occur — that no further
/// respelling can help and the next move is a different kind of search.
fn renderEvidence(a: std.mem.Allocator, out: *std.ArrayList(u8), left: *usize, s: Shape, ev: Evidence) !void {
    // First, because it is not advice — it is the answer. Everything else here
    // describes the failure; this ends it, and it names a file the reader can
    // open. Verified against that file's current bytes, so it cannot send anyone
    // to a path that does not hold the string.
    if (ev.elsewhere) |w|
        try line(a, out, left, .act, try std.fmt.allocPrint(
            a,
            "a wider scope — '{s}' is in {s}{s}, outside the paths you gave",
            .{ w.branch, w.path, try more(a, w.more) },
        ));
    // A bundled multi-probe query hides which probe died; on a zero-match run the
    // answer is "all of them", and that is worth one line because the reader
    // typed several questions and got one answer.
    if (ev.branches.len > 1) {
        var names: std.ArrayList(u8) = .empty;
        for (ev.branches, 0..) |b, i| {
            if (i > 0) try names.appendSlice(a, ", ");
            try names.print(a, "'{s}'", .{b.text});
        }
        try line(a, out, left, .note, try std.fmt.allocPrint(
            a,
            "{d} branches, none of them present — {s}",
            .{ ev.branches.len, names.items },
        ));
    }
    // The money line: a guessed symbol that ALMOST exists. `KEY_THREAD_ID` is
    // absent while `KEY_T` sits on two lines of the very file searched, so the
    // name is wrong from a known byte onward rather than wrong about the place.
    if (ev.nearest()) |b| if (b.live) |live|
        try line(a, out, left, .note, try std.fmt.allocPrint(
            a,
            "'{s}' is here on {d} line{s} — '{s}' stops matching after it",
            .{ live, b.lines, if (b.lines == 1) "" else "s", b.text },
        ));
    // Proven cold: no flag rewrites bytes that are not there, so the honest
    // suggestion is the sibling engine that searches by content instead of by
    // pattern. Earned, never reflexive — it costs a hint slot only after the
    // bytes ruled every respelling out.
    if (ev.allCold() and s.scope != .stream) if (ev.branches.len == 1)
        try line(a, out, left, .act, try std.fmt.allocPrint(
            a,
            "relate similar '{s}' — not even its first three bytes occur here, so no spelling of this pattern will match",
            .{ev.branches[0].text},
        ));
}

/// " (+N more)" or nothing — the tail on a sighting that found company. Counts
/// only files actually opened and confirmed, so it is a floor, never a guess.
fn more(a: std.mem.Allocator, n: usize) ![]const u8 {
    return if (n == 0) "" else try std.fmt.allocPrint(a, " (+{d} more)", .{n});
}

/// The hint voices are the shared CLI guidance grammar (`surface/cli/guide.zig`),
/// bound to this face's name — the kinship face's weak-result verdict speaks
/// the same one.
const Voice = guide.Voice;

fn line(a: std.mem.Allocator, out: *std.ArrayList(u8), left: *usize, voice: Voice, text: []const u8) !void {
    try guide.line(a, out, left, "gist", voice, text);
}

/// The engines' one-call exit hook: render the hint, honoring `<prefix>HINTS`.
/// Never fails — a hint is a courtesy, not a result — and a hint that only
/// half-rendered is not emitted at all, so a truncated courtesy never reaches a
/// terminal.
/// `ev` is `.{}` for the seams that hold no byte set to probe — piped stdin, and
/// the parallel walk, which streams files past its workers instead of collecting
/// them. Empty evidence degrades to exactly the flag-shaped hints this channel
/// always emitted, so a seam that cannot prove anything still says what it can.
pub fn noMatches(s: Shape, files_scanned: ?usize, ev: Evidence) void {
    fault.spare("render the no-match hint", emitNoMatches(s, files_scanned, ev));
}

fn emitNoMatches(s: Shape, files_scanned: ?usize, ev: Evidence) !void {
    if (!corpus_mod.hintsEnabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try render(arena.allocator(), &out, s, files_scanned, ev);
    // Through assay, not `std.debug.print` (law 6): the FFI scopes its sink
    // `.dark`, and a courtesy hint must not be the one thing that still writes
    // to an embedding host's stderr.
    assay.diag("{s}", .{out.items});
}

// ── the successful run that quietly answered fewer questions than it was asked ──

/// The one hint this channel emits on a run that SUCCEEDED.
///
/// A `'A|B|C' PATH` run is several questions in one, and its answer is one exit
/// code. When A and C are present and B is not, the run prints matches, exits 0,
/// and says nothing at all about B — so a bundled probe reads as three answers
/// when it was two, and the missing one is invisible precisely because everything
/// looked fine. That is the failure mode with no symptom, which makes it the only
/// success worth interrupting.
///
/// The claim is deliberately about the RESULTS, not about matching: it reports
/// that a branch's bytes appear nowhere in what was printed, which is exactly
/// what was checked. So the note cannot outrun its evidence even under
/// highlighting, `--trim`, context lines, or a long-line cut.
pub fn deadBranches(s: Shape, results: []const u8) void {
    fault.spare("render the dead-branch note", emitDeadBranches(s, results));
}

fn emitDeadBranches(s: Shape, results: []const u8) !void {
    if (!corpus_mod.hintsEnabled() or !s.results_faithful or s.invert) return;
    // A cut result set is missing bytes for a reason that has nothing to do with
    // the pattern, and every branch below the cut would read as dead.
    if (corpus_mod.outputTruncated()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    if (try renderDead(a, &out, s, results)) assay.diag("{s}", .{out.items});
}

/// Pure half of `deadBranches` — true when it had something to say. Split out for
/// the same reason `render` is: the wording is a contract, so it is asserted on
/// bytes rather than eyeballed on a terminal.
fn renderDead(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Shape, results: []const u8) !bool {
    const branches = branchesOf(a, s);
    // One branch cannot be partially answered, and a regex branch has no bytes to
    // look for — `\d+` matching `42` puts neither `\` nor `d` in the results.
    if (branches.len < 2) return false;
    for (branches) |b| if (!b.literal) return false;

    var dead: std.ArrayList([]const u8) = .empty;
    var alive: usize = 0;
    for (branches) |b| {
        var lit_buf: [256]u8 = undefined;
        const lit = literalBytes(b.text, s.fixed, &lit_buf).?;
        const present = if (s.caseless)
            std.ascii.indexOfIgnoreCase(results, lit) != null
        else
            std.mem.indexOf(u8, results, lit) != null;
        if (present) alive += 1 else try dead.append(a, b.text);
    }
    // Every branch dead is impossible on a run that matched (something produced
    // those lines), and none dead is the ordinary case worth no words.
    if (dead.items.len == 0 or alive == 0) return false;

    var names: std.ArrayList(u8) = .empty;
    for (dead.items, 0..) |text, i| {
        if (i > 0) try names.appendSlice(a, if (i + 1 == dead.items.len) " and " else ", ");
        try names.print(a, "'{s}'", .{text});
    }
    var left: usize = 1;
    try line(a, out, &left, .note, try std.fmt.allocPrint(
        a,
        "{s} appear{s} nowhere in these results — {d} of {d} branches carried them",
        .{ names.items, if (dead.items.len == 1) "s" else "", alive, branches.len },
    ));
    return true;
}

// ── the accelerator that quietly stopped accelerating ────────────────────────

/// What the read-elision oracle actually did, counted (`elide.Verdict`).
///
/// Plain values rather than the oracle itself, for the reason `shapeWarm` takes
/// plain values: the seam that owns these counts lives a tier above this module,
/// and a renderer must not reach up the page to read it.
pub const Elision = struct {
    /// Reads the index spared — the whole point of having one.
    elided: usize = 0,
    /// Reads it bought back: indexed files whose clocks reach the build anchor,
    /// so their postings no longer describe their bytes.
    stale: usize = 0,
    /// Files the index never covered, and so never could have spared.
    unindexed: usize = 0,
    /// Files the trigrams admit as possible matches — the index working.
    candidate: usize = 0,
    /// Age of the build anchor, when one was published.
    anchor_age_s: ?f64 = null,
};

/// The one hint about the INDEX rather than the pattern.
///
/// An index is a bet that most files can be proven out without reading them.
/// When the anchor falls far enough behind the tree, the bet quietly inverts:
/// the same files come back as `stale` and get re-read, and the run is doing
/// bookkeeping for an accelerator that is no longer accelerating. Nothing about
/// that is visible — the results are identical (elision is byte-invisible by
/// construction), the exit code is 0, and the only way to learn the anchor is
/// days old is to run a different command, `gist status`, which nobody runs
/// BEFORE a search because there is no symptom prompting them to.
///
/// So this is the same failure shape `deadBranches` exists for: a success with
/// no symptom. The claim is deliberately about counted verdicts and not about
/// time — "it re-read more than it spared" is arithmetic on what this run did,
/// where "the index is old" would be a guess about whether that mattered.
pub fn indexVerdict(e: Elision) void {
    fault.spare("render the index verdict", emitIndexVerdict(e));
}

fn emitIndexVerdict(e: Elision) !void {
    if (!corpus_mod.hintsEnabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    if (try renderVerdict(a, &out, e)) assay.diag("{s}", .{out.items});
}

/// Pure half — true when it had something to say.
///
/// The gate is the claim: an index that spared at least as many reads as it
/// bought back is doing its job, however old its anchor is, and saying anything
/// there would be noise on a healthy run. Only the inversion earns words.
fn renderVerdict(a: std.mem.Allocator, out: *std.ArrayList(u8), e: Elision) !bool {
    if (e.stale <= e.elided) return false;
    const total = e.elided + e.stale + e.unindexed + e.candidate;
    var left: usize = 2;
    try line(a, out, &left, .note, try std.fmt.allocPrint(
        a,
        "the index spared {d} of {d} reads and bought back {d} that changed since its anchor{s} — it is re-reading more than it elides",
        .{ e.elided, total, e.stale, try anchorAge(a, e.anchor_age_s) },
    ));
    try line(a, out, &left, .act, try std.fmt.allocPrint(
        a,
        "gist index — re-anchoring lets those {d} files be proven out again",
        .{e.stale},
    ));
    return true;
}

/// " (set 3.6 days ago)" or nothing. Coarse on purpose: the number is here to
/// tell a reader whether they are looking at minutes or weeks, and a figure
/// precise enough to imply the age caused the inversion would be claiming more
/// than the counts prove.
fn anchorAge(a: std.mem.Allocator, age_s: ?f64) ![]const u8 {
    const s = age_s orelse return "";
    const day = 60 * 60 * 24;
    if (s >= day) return std.fmt.allocPrint(a, " (set {d:.1} days ago)", .{s / day});
    if (s >= 60 * 60) return std.fmt.allocPrint(a, " (set {d:.1} hours ago)", .{s / (60 * 60)});
    return std.fmt.allocPrint(a, " (set {d:.0} s ago)", .{s});
}

// ── the long walk's own voice ─────────────────────────────────────────────

/// How long a walk may stay silent before it owes the reader an explanation.
/// Two seconds is past every warm query and nearly every cold one, so an
/// ordinary run never speaks — and it lands before a hand reaches for ^C, which
/// is the entire point. The run that motivated this (`-uu -l 'class Prism'`
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
/// Inherits this file's whole contract — stderr only, `<prefix>HINTS=0` mutes it,
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
    return renderedWith(a, s, files, .{});
}

fn renderedWith(a: std.mem.Allocator, s: Shape, files: ?usize, ev: Evidence) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try render(a, &out, s, files, ev);
    return out.toOwnedSlice(a);
}

/// A stand-in for the engine's intake record — `probe` needs `.bytes` and
/// nothing else, which is exactly what keeps this module a leaf.
const Probed = struct { bytes: []const u8 };

test "uppercase pattern gets -i first; -uu rides along" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shape(&.{"AcmeStore"}, .{}, &.{}, false), 1204);
    try t.expectEqualStrings(
        \\gist: no matches for 'AcmeStore' · 1204 files scanned
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
    var s = shape(&.{"Acme"}, .{ .no_ignore = true, .hidden = true }, &.{}, false);
    s.steered_by = "/home/x/.config/gist/preferences";
    try t.expectEqualStrings(
        \\gist: no matches for 'Acme'
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
    const got = try paced(arena.allocator(), shape(&.{"Acme"}, .{}, &.{"services/backend"}, true), .{
        .secs = 4,
        .walked = 812,
        .outstanding = 40,
    });
    try t.expectEqualStrings(assay.tag ++ "still searching for 'Acme' after 4s · 812 directories walked, 40 outstanding\n", got);
}

test "a vigil that never armed is silent rather than crashing on no progress" {
    var v: Vigil = .{};
    v.finish();
    try t.expect(v.progress == null);
    try v.speak(9, true); // `progress == null` short-circuits before any render
}

test "warm shape: pattern facts still drive hints" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try rendered(arena.allocator(), shapeWarm("AcmeStore", false, false, false, &.{}), null);
    try t.expect(std.mem.indexOf(u8, got, "-i — the pattern has uppercase") != null);
}

test "warm shape keeps the scope the request carries, so a warm miss can say widen" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // The regression this closes: the roots are on the wire, but the warm hint
    // dropped them, so the fast path agents hit by DEFAULT emitted strictly
    // worse guidance than the slow path — no scope tail, and no widen hint.
    const got = try rendered(arena.allocator(), shapeWarm("KEY_TS", false, false, false, &.{"services/ai"}), null);
    try t.expectEqualStrings(
        \\gist: no matches for 'KEY_TS' · scope: services/ai
        \\gist: try -i — the pattern has uppercase; retry case-insensitive
        \\gist: try -uu — gitignored and hidden files were excluded from this search
        \\gist: try a wider scope — drop the PATH args to search the whole tree
        \\
    , got);
}

test "an already-escaped pattern is not told to try -F, which could only break it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // `globals\(\)` says "literal parens" and already gets them. Suggesting -F
    // would search for the BACKSLASHES too — advice that cannot succeed. The old
    // `code_metas` included `\`, so every escaped pattern earned exactly that.
    const o = args.Opts{ .caseless = true, .no_ignore = true, .hidden = true };
    const got = try rendered(arena.allocator(), shape(&.{"globals\\(\\)"}, o, &.{}, false), 1);
    try t.expectEqualStrings(assay.tag ++ "no matches for 'globals\\(\\)' · 1 files scanned\n", got);
}

test "an unescaped metacharacter still earns -F" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // The other side of the same test: a caller who typed code and got a capture
    // group is exactly who -F is for, so the hint must survive the escape fix.
    const o = args.Opts{ .caseless = true, .no_ignore = true, .hidden = true };
    const got = try rendered(arena.allocator(), shape(&.{"globals()"}, o, &.{}, false), 1);
    try t.expectEqualStrings(
        \\gist: no matches for 'globals()' · 1 files scanned
        \\gist: try -F — the pattern has regex metacharacters; -F searches those bytes literally
        \\
    , got);
}

// ── evidence ─────────────────────────────────────────────────────────────

/// The file that started this: a re-export module whose generated sibling holds
/// the symbol actually being looked for. `KEY_T` is real here; `KEY_THREAD_ID`
/// is not.
const attrs_py =
    \\KEY_TS: str = _g.KEY_TS
    \\KEY_SEVERITY: str = _g.KEY_SEVERITY
    \\KEY_TRACE_ID: str = _g.KEY_TRACE_ID
;

test "the query that motivated this: three dead branches, one near miss, zero false flags" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every hint the old channel produced here was false: -i finds nothing, -uu
    // finds nothing, and -F on an already-escaped pattern searches for the
    // backslashes. What it never said was that KEY_T is right there.
    const pattern = "KEY_THREAD_ID|__all__|globals\\(\\)";
    const s = shape(&.{pattern}, .{ .no_ignore = true, .hidden = true }, &.{"attrs.py"}, true);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    // All three of the old hints are gone. `-F` because the parens were already
    // escaped, `-uu` because it was already in force, and `-i` because the probe
    // TRIED case-insensitively and the bytes still are not there. What remains is
    // the shape of the failure, the near miss, and the one move left.
    try t.expectEqualStrings(
        \\gist: no matches for 'KEY_THREAD_ID|__all__|globals\(\)' · 1 files scanned · scope: attrs.py
        \\gist: note: 3 branches, none of them present — 'KEY_THREAD_ID', '__all__', 'globals\(\)'
        \\gist: note: 'KEY_T' is here on 2 lines — 'KEY_THREAD_ID' stops matching after it
        \\gist: try a wider scope — drop the PATH args to search the whole tree
        \\
    , try renderedWith(a, s, 1, ev));
}

test "a sighting is the answer, so it leads and the vague widen line stands down" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The whole point of the exercise: the reader searched the re-export module,
    // and the symbol lives in the generated sibling. Nothing about the pattern
    // could have said so — only the corpus could.
    const s = shape(&.{"KEY_THREAD_ID"}, .{}, &.{"…/log/attrs.py"}, true);
    var ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    ev.elsewhere = .{ .branch = "KEY_THREAD_ID", .path = "…/log/attrs.gen.py" };
    try t.expectEqualStrings(
        \\gist: no matches for 'KEY_THREAD_ID' · 1 files scanned · scope: …/log/attrs.py
        \\gist: try a wider scope — 'KEY_THREAD_ID' is in …/log/attrs.gen.py, outside the paths you gave
        \\gist: note: 'KEY_T' is here on 2 lines — 'KEY_THREAD_ID' stops matching after it
        \\gist: try -uu — gitignored and hidden files were excluded from this search
        \\
    , try renderedWith(a, s, 1, ev));
}

test "company found is counted, never estimated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = shape(&.{"KEY_THREAD_ID"}, .{ .no_ignore = true, .hidden = true }, &.{"log/attrs.py"}, true);
    var ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    ev.elsewhere = .{ .branch = "KEY_THREAD_ID", .path = "log/attrs.gen.py", .more = 2 };
    try t.expect(std.mem.indexOf(u8, try renderedWith(a, s, 1, ev), "log/attrs.gen.py (+2 more), outside") != null);
}

test "a proven-useless -i is retired outright, not merely outranked" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = shape(&.{"KEY_THREAD_ID"}, .{ .no_ignore = true, .hidden = true }, &.{}, false);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    try t.expect(ev.caseless_dead);
    try t.expectEqualStrings(
        \\gist: no matches for 'KEY_THREAD_ID' · 1 files scanned
        \\gist: note: 'KEY_T' is here on 2 lines — 'KEY_THREAD_ID' stops matching after it
        \\
    , try renderedWith(a, s, 1, ev));
}

test "-i survives when case really is the fix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The bytes hold `key_ts`, so ignoring case genuinely finds it and the hint
    // must not be suppressed — the gate has to cut only the useless ones.
    const s = shape(&.{"KEY_TS"}, .{ .no_ignore = true, .hidden = true }, &.{}, false);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = "lower key_ts here" }});
    try t.expect(!ev.caseless_dead);
    try t.expect(std.mem.indexOf(u8, try renderedWith(a, s, 1, ev), "-i — the pattern has uppercase") != null);
}

test "a non-ASCII literal leaves the caseless question open rather than answering it wrong" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Above 0x7F, folding is Unicode's business; a byte comparison must not be
    // allowed to suppress a hint that could still be the fix.
    const s = shape(&.{"CAFÉ"}, .{ .no_ignore = true, .hidden = true }, &.{}, false);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = "unrelated bytes" }});
    try t.expect(!ev.caseless_dead);
}

test "evidence outranks the flag priors and crowds them out of the budget" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Same corpus, but nothing widened: the old channel led with -i and -uu, both
    // guesses. Now a checked fact about these bytes leads, -i is gone because it
    // was tried, and -uu survives as the one thing still genuinely unexamined.
    const s = shape(&.{"KEY_THREAD_ID"}, .{}, &.{}, false);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    try t.expectEqualStrings(
        \\gist: no matches for 'KEY_THREAD_ID' · 1 files scanned
        \\gist: note: 'KEY_T' is here on 2 lines — 'KEY_THREAD_ID' stops matching after it
        \\gist: try -uu — gitignored and hidden files were excluded from this search
        \\
    , try renderedWith(a, s, 1, ev));
}

test "proven cold: absence rules out every respelling, so relate is earned" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = shape(&.{"WalletService"}, .{ .caseless = true, .no_ignore = true, .hidden = true }, &.{}, false);
    const ev = probe(a, s, &[_]Probed{.{ .bytes = attrs_py }});
    try t.expectEqualStrings(
        \\gist: no matches for 'WalletService' · 1 files scanned
        \\gist: try relate similar 'WalletService' — not even its first three bytes occur here, so no spelling of this pattern will match
        \\
    , try renderedWith(a, s, 1, ev));
}

test "an escaped literal branch is probed as the bytes it means, not as written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `globals\(\)` can only ever be found as `globals()`; probing the source
    // bytes would hunt backslashes that were never on disk.
    const ev = probe(a, shape(&.{"globals\\(\\)x"}, .{}, &.{}, false), &[_]Probed{.{ .bytes = "call globals() here" }});
    try t.expectEqual(@as(usize, 1), ev.branches.len);
    try t.expect(ev.branches[0].probed);
    try t.expectEqualStrings("globals()", ev.branches[0].live.?);
}

test "a real regex branch earns no byte probe, and so proves nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ev = probe(a, shape(&.{"KEY_.*ID"}, .{}, &.{}, false), &[_]Probed{.{ .bytes = attrs_py }});
    try t.expectEqual(@as(usize, 1), ev.branches.len);
    try t.expect(!ev.branches[0].probed);
    try t.expect(ev.branches[0].live == null);
    // `allCold` must not read an unprobed branch as absence.
    try t.expect(!ev.allCold());
}

test "-F makes the pattern one literal, so a pipe in it is a byte not a branch" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ev = probe(a, shape(&.{"KEY_A|KEY_B"}, .{ .fixed = true }, &.{}, false), &[_]Probed{.{ .bytes = attrs_py }});
    try t.expectEqual(@as(usize, 1), ev.branches.len);
    try t.expectEqualStrings("KEY_A|KEY_B", ev.branches[0].text);
}

test "splitBranches reads nesting and escapes, not bare pipes" {
    var slots: [max_branches][]const u8 = undefined;
    try t.expectEqual(@as(usize, 3), (splitBranches("a|b|c", &slots) orelse return error.TestExpected).len);
    // A pipe inside a group belongs to the group, not to the top level.
    try t.expect(splitBranches("foo(a|b)", &slots) == null);
    // …and one inside a character class, or escaped, is not an alternation.
    try t.expect(splitBranches("[a|b]", &slots) == null);
    try t.expect(splitBranches("a\\|b", &slots) == null);
    try t.expect(splitBranches("plain", &slots) == null);
    // More branches than we will print declines rather than truncating.
    try t.expect(splitBranches("a|b|c|d|e|f|g|h|i|j", &slots) == null);
}

test "literalOf unescapes metacharacters and declines classes and boundaries" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("globals()", literalOf("globals\\(\\)", &buf).?);
    try t.expectEqualStrings("a$b", literalOf("a\\$b", &buf).?);
    try t.expectEqualStrings("plain_symbol", literalOf("plain_symbol", &buf).?);
    // Unescaped metacharacters mean it is a pattern, not a string.
    try t.expect(literalOf("a.*b", &buf) == null);
    try t.expect(literalOf("foo(bar)", &buf) == null);
    // `\d` is a class and `\n` a byte we are not going to reason about here.
    try t.expect(literalOf("KEY_\\d", &buf) == null);
    try t.expect(literalOf("dangling\\", &buf) == null);
}

test "longestLivePrefix stops where the guess stops being real" {
    try t.expectEqual(@as(usize, 5), longestLivePrefix("KEY_THREAD_ID", attrs_py));
    // A literal wholly present reports its full length, so `probe` can tell that
    // case (which -w and -x can both produce) from a genuine near miss.
    try t.expectEqual(@as(usize, 6), longestLivePrefix("KEY_TS", attrs_py));
    // Nothing at all, not even the floor.
    try t.expectEqual(@as(usize, 0), longestLivePrefix("WalletService", attrs_py));
    // Below the floor there is no evidence to be had.
    try t.expectEqual(@as(usize, 0), longestLivePrefix("KE", attrs_py));
}

test "a probe budget keeps a courtesy from becoming the slow part" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Claiming more resident bytes than the budget allows yields branches with no
    // findings rather than a long pass — silence, never a guess.
    const huge = Probed{ .bytes = @as([*]const u8, @ptrFromInt(0x1000))[0 .. probe_budget_bytes + 1] };
    const ev = probe(a, shape(&.{"KEY_THREAD_ID"}, .{}, &.{}, false), &[_]Probed{huge});
    try t.expectEqual(@as(usize, 1), ev.branches.len);
    try t.expect(!ev.branches[0].probed);
}

// ── the index verdict ────────────────────────────────────────────────────

fn verdict(a: std.mem.Allocator, e: Elision) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    return if (try renderVerdict(a, &out, e)) try out.toOwnedSlice(a) else null;
}

test "a healthy index says nothing, however old its anchor" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The bet is paying: far more reads spared than bought back. An age-based
    // trigger would have fired here and been wrong, which is the whole reason
    // the gate is arithmetic on verdicts instead.
    try t.expect(try verdict(a, .{
        .elided = 19_000,
        .stale = 240,
        .candidate = 61,
        .anchor_age_s = 60 * 60 * 24 * 30,
    }) == null);
    // A run with no oracle at all counts nothing and must stay silent rather
    // than divide by zero or announce a verdict it never reached.
    try t.expect(try verdict(a, .{}) == null);
    // The exact boundary: spared == bought back is not yet a loss.
    try t.expect(try verdict(a, .{ .elided = 500, .stale = 500 }) == null);
}

test "an inverted index reports the counts it proved and names the fix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The state that motivated this: a 3.66-day-old anchor on a tree ~10 agents
    // are editing, where the index re-reads more than it spares and every query
    // pays for it silently.
    try t.expectEqualStrings(
        \\gist: note: the index spared 812 of 22442 reads and bought back 2431 that changed since its anchor (set 3.7 days ago) — it is re-reading more than it elides
        \\gist: try gist index — re-anchoring lets those 2431 files be proven out again
        \\
    , (try verdict(a, .{
        .elided = 812,
        .stale = 2431,
        .unindexed = 206,
        .candidate = 18_993,
        .anchor_age_s = 316_074,
    })).?);
}

test "a brand-new file is unindexed, never stale — the count the verdict rests on" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `unindexed` files carry recent clocks too, so classifying them as `stale`
    // would manufacture the very inversion this hint reports. Here they are the
    // majority and the index is otherwise healthy, so nothing is said.
    try t.expect(try verdict(a, .{ .elided = 900, .stale = 100, .unindexed = 5_000 }) == null);
}

test "the anchor age reads in whatever unit a human thinks in" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("", try anchorAge(a, null));
    try t.expectEqualStrings(" (set 42 s ago)", try anchorAge(a, 42));
    try t.expectEqualStrings(" (set 2.5 hours ago)", try anchorAge(a, 9_000));
    try t.expectEqualStrings(" (set 3.7 days ago)", try anchorAge(a, 316_074));
}

test "activeMeta reads escapes rather than bytes" {
    // A backslash spends the next byte, so an escaped meta is inert and `\\` is
    // a literal backslash — neither is something -F can help with.
    try t.expect(activeMeta("foo(bar)"));
    try t.expect(activeMeta("arr[0]"));
    try t.expect(activeMeta("end$"));
    try t.expect(!activeMeta("globals\\(\\)"));
    try t.expect(!activeMeta("a\\\\b"));
    try t.expect(!activeMeta("plain_symbol"));
    // `.` `*` `|` are deliberately not literal-intent signals.
    try t.expect(!activeMeta("KEY_A|KEY_B"));
    try t.expect(!activeMeta("a.*b"));
    // A trailing lone backslash must not read past the end of the pattern.
    try t.expect(!activeMeta("trailing\\"));
}
