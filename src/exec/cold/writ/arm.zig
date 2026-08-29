//! Arm selection: which engine compiles this pattern.
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
//! error union (fault-channel law 1): escalating is the ROUTINE outcome for a
//! lookaround query, so it belongs in the success position — a `try` here would
//! have turned the common case into an abort.

const std = @import("std");
const args = @import("../argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const captures_mod = @import("../../../kernel/regex/regex.zig");
const fault = @import("../../../fault.zig");
const pcre2 = @import("../../../kernel/regex/regex.zig").pcre2;

const Caps = captures_mod.Caps;
const Captures = captures_mod.Captures;
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;
const Opts = args.Opts;
const Pcre = pcre2.Pcre;
const Regex = @import("../../../kernel/regex/regex.zig").Regex;
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;

/// The linear arm of the engine choice: the compiled linear-time engine, or the
/// declinature that routes this pattern to PCRE2 — the linear→PCRE2 seam
/// (fault-channel law 1). It sits in the success position because escalating is the
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
/// the matcher was built with — `gate.winnow` reads both the forced crest and
/// the cover plan off this AST, and a flag that disagreed there would prune real
/// matches rather than merely slow the query down.
pub fn linearOptions(o: Opts) Regex.Options {
    // `records` is `--null-data` and nothing else: it tells the engine a haystack
    // it is handed may CONTAIN a `\n`, which under a NUL terminator is true while
    // `multiline` stays false — the caller still splits its input and still asks
    // per piece, the piece is just a record instead of a line.
    return .{ .caseless = o.caseless, .multiline = o.multiline, .records = o.null_data, .dotall = o.multiline_dotall, .unicode = o.unicode, .word = o.word, .crlf = o.crlf, .line_anchors = o.re_line_anchors, .verbose = o.re_verbose };
}

/// Whether PCRE2 was chosen outright (`-P`) or reached by escalation — the two
/// differ only in the diagnostic they owe when PCRE2 also rejects the pattern.
const PcreRoute = enum { outright, escalated };

/// The PCRE2 arm, for both routes into it. A resource failure is `oom()`; a
/// rejected pattern is a fault with no tier left, so it dies rather than
/// reporting a silent no-match.
/// This invocation's CLI flags as PCRE2's compile options — `linearOptions`'
/// twin, and for the same reason: the escalation and anything that PREDICTS the
/// escalation (`dieUnexpressible` below) must ask under identical options, or
/// the prediction answers about a pattern the run would never have compiled.
pub fn pcreOptions(o: Opts) pcre2.Options {
    return .{ .caseless = o.caseless, .multiline = o.re_line_anchors, .dotall = o.multiline_dotall, .unicode = o.pcre_unicode, .word = o.word, .verbose = o.re_verbose };
}

pub fn pcreArm(gpa: std.mem.Allocator, eff: []const u8, o: Opts, route: PcreRoute) Pcre {
    return Pcre.compileOpts(gpa, eff, pcreOptions(o)) catch |e| switch (e) {
        error.OutOfMemory => oom(),
        else => switch (route) {
            .outright => die(assay.tag ++ "error: bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() }),
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
/// WHICH fault is a question only PCRE2 can answer, so this asks before it
/// speaks. If PCRE2 takes the pattern, the escalation really was the answer,
/// the two `try` flags below really would lift the refusal, and the message
/// stands. If PCRE2 refuses it too, every word of that message is wrong: the
/// pattern is malformed, not merely non-linear, so it blames a construct the
/// pattern does not contain and points at flags that cannot help. `blame` says
/// what is actually broken and where instead.
///
/// The probe costs one PCRE2 compile on a path that is about to exit — and buys
/// the distinction `IRGX_STALE` vs `BadPattern` draws for the C ABI
/// (`surface/ffi/pattern.zig: refuse`), so the CLI and the library now refuse
/// the same pattern for the same stated reason.
///
/// The multi-line diagnostic shares the `<name>: try` / `<name>: note:` grammar
/// (`emit/hints.zig`); these lines always print — they ARE the exit-2
/// explanation, not a courtesy (`<prefix>HINTS` governs only the no-match
/// channel). "linear-time syntax" on line 1 is load-bearing, and now only
/// appears when it is TRUE: the Python/Rust bindings classify
/// unsupported-pattern exits by it, and the rg-conformance oracle reads it to
/// tell a purposeful decline from a divergence.
fn dieUnexpressible(gpa: std.mem.Allocator, eff: []const u8, o: Opts) noreturn {
    if (Pcre.compileOpts(gpa, eff, pcreOptions(o))) |_| die(
        \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
        \\gist: note: not owned by the linear engine: lookaround, backreferences (\0-\9; NUL is \x00),
        \\gist: note:   unrecognized escapes (\q, \e, ...), assertion escapes inside [...], mid-pattern
        \\gist: note:   inline flags (--schema lists the exact surface)
        \\gist: try -P / --pcre2 — run this pattern on the vendored PCRE2 JIT backend
        \\gist: try --engine auto — linear first, escalating to PCRE2 only when it declines
        \\
    , .{eff}) else |e| switch (e) {
        error.OutOfMemory => oom(),
        else => blame(eff),
    }
}

/// A pattern NO engine here can compile: name the defect and point at it, then
/// stop — a `try` line would be a wild goose chase. PCRE2 is the arm that
/// located the defect, so its message and `erroroffset` are the only honest
/// coordinates available; the linear engine reports that it declined, never
/// where.
///
/// Both rendered lines carry the same prefix, so the caret needs exactly the
/// offset's worth of padding to land under the byte it blames. A pattern that
/// would break the drawing — an embedded newline, or one wider than the pad —
/// gets the same two facts inline rather than a misaligned diagram.
fn blame(eff: []const u8) noreturn {
    const pad = " " ** 128;
    const at = @min(pcre2.lastErrorOffset(), eff.len);
    const cannot = assay.tag ++ "note: no engine here compiles it, so -P / --engine auto cannot answer it either\n";
    if (at > pad.len or std.mem.indexOfScalar(u8, eff, '\n') != null)
        die(assay.tag ++ "error: bad pattern '{s}' — {s} (at byte {d})\n" ++ cannot, .{ eff, pcre2.lastError(), at });
    die(
        assay.tag ++ "error: bad pattern — {s}\n" ++
            assay.tag ++ "note: {s}\n" ++
            assay.tag ++ "note: {s}^ here (byte {d})\n" ++ cannot,
        .{ pcre2.lastError(), eff, pad[0..at], at },
    );
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
///     of our fail-closed flag contract.
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
            if (o.engine == .default) if (d.refused()) |_| dieUnexpressible(gpa, eff, o);
            return .{ .pcre = pcreArm(gpa, eff, o, .escalated) };
        },
    }
}
/// Compile the `-r/--replace` capture matcher (one-pass table, linear Pike VM,
/// or PCRE2) for the effective pattern `eff`. One definition shared by the
/// top-level run and every parallel emit shard — `Caps` carries mutable
/// per-find state, so a shard can never share the run's instance and must
/// compile its own.
///
/// The arm choice itself is `Caps.compile`'s — the union owns it, so the C ABI
/// compiles the same pattern into the same arm. What stays here is the CLI's
/// half of the seam: a bad pattern is a diagnosed exit rather than a status.
pub fn compileCaps(gpa: std.mem.Allocator, o: Opts, eff: []const u8, is_pcre: bool) Caps {
    return Caps.compile(gpa, eff, .{
        .caseless = o.caseless,
        .unicode = if (is_pcre) o.pcre_unicode else o.unicode,
        .pcre = is_pcre,
        .multiline = o.re_line_anchors,
        .nl_terminates = !o.null_data,
        .dotall = o.multiline_dotall,
        .word = o.word,
        .crlf = o.crlf,
        .verbose = o.re_verbose,
    }) catch |e| switch (e) {
        error.OutOfMemory => oom(),
        // Same three-way truth as `dieUnexpressible`, so the `-r` path asks the
        // same question rather than assuming the answer: a malformed pattern
        // reached here through `-r` used to be sent to `-P` too.
        error.BadPattern => if (is_pcre)
            die("bad PCRE2 pattern '{s}': {s}\n", .{ eff, pcre2.lastError() })
        else if (Pcre.compileOpts(gpa, eff, pcreOptions(o))) |_|
            die(
                \\gist: error: bad pattern '{s}' — outside gist's linear-time syntax
                \\gist: try -P / --pcre2 — run this pattern on the PCRE2 backend (lookaround, backreferences)
                \\
            , .{eff})
        else |pe| switch (pe) {
            error.OutOfMemory => oom(),
            else => blame(eff),
        },
    };
}
