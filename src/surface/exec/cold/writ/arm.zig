//! gist — arm selection: which engine compiles this pattern.
//!
//! Two engines sit behind the `Matcher` seam: the linear-time RE2-style matcher
//! that backs every default query, and the vendored PCRE2 JIT for the syntax a
//! linear automaton provably cannot express (lookaround, backreferences).
//! Choosing between them is a THREE-way decision, not a boolean — `-P` routes
//! outright, `--engine auto` compiles linear first and ESCALATES only on a
//! declinature, and the bare default refuses to escalate silently because a
//! user who did not ask for PCRE2 should learn their pattern needs it rather
//! than silently pay backtracking's worst case.
//!
//! The declinature is why `linearArm` returns `fault.Answer` instead of an
//! error union (ADR-373 law 1): escalating is the ROUTINE outcome for a
//! lookaround query, so it belongs in the success position — a `try` here would
//! have turned the common case into an abort.

const std = @import("std");
const args = @import("../argv/args.zig");
const captures_mod = @import("../../../../kernel/match/regex/compile/captures.zig");
const fault = @import("../../../../fault.zig");
const pcre2 = @import("../../../../kernel/match/regex/pcre2/backend.zig");

const Caps = captures_mod.Caps;
const Captures = captures_mod.Captures;
const Matcher = @import("../../../../kernel/match/regex/linear/ladder/matcher.zig").Matcher;
const Opts = args.Opts;
const Pcre = pcre2.Pcre;
const Regex = @import("../../../../kernel/match/regex/linear/program/core.zig").Regex;
const die = args.die;
const oom = args.oom;

/// The linear arm of the engine choice: the compiled linear-time engine, or the
/// declinature that routes this pattern to PCRE2 — the linear→PCRE2 seam
/// (ADR-373 law 1). It sits in the success position because escalating is the
/// routine outcome for every lookaround query, and a `try` here would have
/// turned that into an abort.
pub fn linearArm(gpa: std.mem.Allocator, eff: []const u8, o: Opts) fault.Answer(Regex) {
    if (Regex.compileOpts(gpa, eff, linearOptions(o))) |r|
        return .{ .got = r }
    else |_|
        return .{ .declined = .unsupported_syntax };
}

/// This invocation's CLI flags as the linear engine's compile options. ONE
/// owner, because every derived analysis has to parse under exactly the options
/// the matcher was built with — `gate.crestSieve` reads its forced crest off
/// this AST, and a flag that disagreed there would prune real matches rather
/// than merely slow the query down.
pub fn linearOptions(o: Opts) Regex.Options {
    return .{ .caseless = o.caseless, .multiline = o.multiline, .dotall = o.multiline_dotall, .unicode = o.unicode, .line_anchors = o.re_line_anchors };
}

/// Whether PCRE2 was chosen outright (`-P`) or reached by escalation — the two
/// differ only in the diagnostic they owe when PCRE2 also rejects the pattern.
const PcreRoute = enum { outright, escalated };

/// The PCRE2 arm, for both routes into it. A resource failure is `oom()`; a
/// rejected pattern is a fault with no tier left, so it dies rather than
/// reporting a silent no-match.
pub fn pcreArm(gpa: std.mem.Allocator, eff: []const u8, o: Opts, route: PcreRoute) Pcre {
    return Pcre.compileOpts(gpa, eff, .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode }) catch |e| switch (e) {
        error.OutOfMemory => oom(),
        else => switch (route) {
            .outright => die("gist: error: bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() }),
            .escalated => die(
                \\gist: error: regex '{s}' compiles under neither engine
                \\gist: note: the linear engine declined it (lookaround / backreferences / an unknown escape)
                \\gist: note: PCRE2 rejected it too: {s}
                \\
            , .{ eff, pcre2.lastError() }),
        },
    };
}

/// The linear arm declined and the caller refused the tier that would have
/// answered (`--engine default`), so the declinature has become a fault.
///
/// The multi-line diagnostic shares the `gist: try` / `gist: note:` grammar
/// (`emit/hints.zig`); these lines always print — they ARE the exit-2
/// explanation, not a courtesy (`GIST_HINTS` governs only the no-match
/// channel). "linear-time syntax" on line 1 is load-bearing: the Python/Rust
/// bindings classify unsupported-pattern exits by it.
fn dieUnexpressible(eff: []const u8) noreturn {
    die(
        \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
        \\gist: note: not owned by the linear engine: lookaround, backreferences (\0-\9; NUL is \x00),
        \\gist: note:   unrecognized escapes (\q, \e, ...), assertion escapes inside [...], mid-pattern
        \\gist: note:   inline flags (--schema lists the exact surface)
        \\gist: try -P / --pcre2 — run this pattern on the vendored PCRE2 JIT backend
        \\gist: try --engine auto — linear first, escalating to PCRE2 only when it declines
        \\
    , .{eff});
}

/// Compile the search matcher for the resolved engine — `run`'s single build
/// point, reused by the `-r` capture matcher so both sides pick the SAME backend.
///   • `.pcre2` (`-P`/`--pcre2`, `--engine pcre2`) — the vendored PCRE2 JIT
///     backend outright; fail loud on a PCRE2 compile error.
///   • `.default` — the linear RE2/Pike engine, with PCRE2 REFUSED. The linear
///     arm's declinature therefore has no tier left to answer it, which is
///     exactly what `fault.Decline.refused` names, and the death below points
///     at the two flags that would lift the refusal.
///   • `.auto` (`--engine auto`, `--auto-hybrid-regex`) — ripgrep's hybrid: the
///     linear engine first (its speed + trigram AST + `--rank`), escalating on
///     the same declinature. When NEITHER engine accepts the pattern, fail loud
///     with the PCRE2 diagnostic — never a silent wrong answer, the whole point
///     of gist's fail-closed flag contract.
/// Returns a compiled `Matcher`; every fault path is a `die` (noreturn), so the
/// caller reads the resolved backend off the union tag.
pub fn buildMatcher(gpa: std.mem.Allocator, eff: []const u8, o: Opts) Matcher {
    if (o.engine == .pcre2) return .{ .pcre = pcreArm(gpa, eff, o, .outright) };
    switch (linearArm(gpa, eff, o)) {
        .got => |r| return .{ .linear = r },
        .declined => |d| {
            // `--engine default` forbade the tier that would have answered, so
            // the declinature has become a fault — `Decline.refused` is that one
            // conversion. It is total for this arm, whose only declinature is
            // `unsupported_syntax`, so `.default` never reaches the escalation.
            if (o.engine == .default) if (d.refused()) |_| dieUnexpressible(eff);
            return .{ .pcre = pcreArm(gpa, eff, o, .escalated) };
        },
    }
}
/// Compile the `-r/--replace` capture matcher (linear Pike VM or PCRE2) for the
/// effective pattern `eff`. One definition shared by the top-level run and every
/// parallel emit shard — `Caps` carries mutable Pike-VM scratch, so a shard can
/// never share the run's instance and must compile its own.
pub fn compileCaps(gpa: std.mem.Allocator, o: Opts, eff: []const u8, is_pcre: bool) Caps {
    return if (is_pcre)
        Caps{ .pcre = captures_mod.PcreCaptures.compile(gpa, eff, .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode }) catch |e| switch (e) {
            error.OutOfMemory => oom(),
            else => die("bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() }),
        } }
    else
        Caps{ .linear = Captures.compile(gpa, eff, o.caseless, o.unicode) catch die(
            \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
            \\gist: try -P / --pcre2 — run this pattern on the PCRE2 backend (lookaround, backreferences)
            \\
        , .{eff}) };
}
