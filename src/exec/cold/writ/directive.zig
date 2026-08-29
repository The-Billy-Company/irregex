//! The writ of patterns: many argv patterns, one compiled order.
//!
//! `-e`/`-f`/`-F`/positional patterns arrive as a list and must become ONE
//! effective pattern, because a run compiles a single global engine. Two things
//! make that non-trivial, and both live here.
//!
//! A leading `(?flags)` directive is a per-pattern request against a run-wide
//! engine, so it has to be RECONCILED across every pattern rather than applied
//! locally: `i` and `u` resolve to run-wide options and two patterns demanding
//! opposite cases is a loud failure, never a quietly-wins-last. `m` and `s` are
//! inert in the per-line model. `x`/`U`/`R` are semantics this engine cannot
//! reproduce, so they die with the reason and the rg fallback.
//!
//! The contract, stated once: honored where we can, LOUD where we can't — the
//! one thing never permitted is a silent wrong answer.

const std = @import("std");
const args = @import("../argv/args.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const syntax = @import("../../../kernel/regex/regex.zig").syntax;

const Dir = std.Io.Dir;
const Opts = args.Opts;
const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;

/// A leading `(?flags)` directive (rust-regex/rg syntax), read through the
/// engine's own grammar (`regex.syntax.preamble`) and answered the way a CLI
/// has to answer it — the contract is "honored where we can, loud where we
/// can't", never a silent wrong answer:
///   • `i` / `-i` → caseless on/off for the WHOLE pattern (a run compiles one
///     global engine, so the directive resolves to the run-wide option; mixed
///     demands across `-e`/`-f` patterns fail loud — rgsuite boundary #5);
///   • `m` `s` (and negations) → line anchors and dotall, inert in the per-line
///     model: `^`/`$` already anchor every line and no line carries a `\n` for
///     `.` to cross;
///   • `u` / `-u` → Unicode mode on/off for the WHOLE pattern (`u` = our
///     default; `-u` selects byte/ASCII), the run-wide analogue of `-i`
///     reconciled the same way (mixed per-pattern demands fail loud);
///   • `U` `R` → semantics the engine can't reproduce → die with the
///     reason and the rg fallback; `x` is a mode the *engine* now has (the C ABI
///     honors it) but this face has no per-run knob to carry it, so it refuses
///     here rather than stripping the letter and searching non-verbosely.
/// Anything else after `(?` (lookaround, a scoped `(?i:…)` group, `(?P<…>`) is
/// not a flag directive — returns null and the regex parser decides.
///
/// The reading itself is NOT here, and that is the point: `libirgx` has to read
/// the same four letters for a host that never touches argv, and two graphs of
/// what `(?ms-i)` means would agree until one of them grew a letter.
const LeadingFlags = syntax.Directive;
pub fn stripLeadingFlags(pat: []const u8) ?LeadingFlags {
    return switch (syntax.preamble(pat)) {
        .none => null,
        // `x` reads as a directive now, so it has to be refused explicitly:
        // returning it would silently drop the letter and search the pattern
        // with its whitespace significant, which is the wrong answer rather
        // than a missing one.
        .asks => |d| if (d.verbose orelse false)
            die("(?x) unsupported by gist's engine — use ripgrep for this\n", .{})
        else
            d,
        // The only part of the reading that is this face's own: a CLI has no
        // second engine to escalate to, so a flag the grammar lacks is a loud
        // exit naming the tool that has it. (The C ABI answers the same
        // `beyond` by routing its host to PCRE2 instead.)
        .beyond => |c| die("(?{c}) unsupported by gist's engine — use ripgrep for this\n", .{c}),
    };
}

/// One leading-directive flag reconciled across every pattern source. A run
/// compiles a single engine, so a value one pattern explicitly `demand`s must
/// agree with any pattern that only `inherit`s the CLI base — `see` collects
/// each pattern's stance, `resolve` folds them onto the effective option (or
/// fails loud when a demand contradicts an inheritor, rg's per-branch scoping).
pub const Directive = struct {
    name: []const u8,
    demand: ?bool = null,
    inherit: bool = false,
    fn see(self: *Directive, v: ?bool) void {
        if (v) |w| {
            if (self.demand != null and self.demand.? != w)
                die("mixed per-pattern (?{s}) demands — gist compiles one engine; use rg for this\n", .{self.name});
            self.demand = w;
        } else self.inherit = true;
    }
    fn resolve(self: Directive, cur: *bool) void {
        if (self.demand) |w| {
            if (self.inherit and w != cur.*)
                die("(?{s}) on some patterns but not others — gist compiles one engine; use rg for this\n", .{self.name});
            cur.* = w;
        }
    }
};

/// Combine every pattern source — bare/`-e`/`--regexp` plus each `-f/--file`
/// line — into one regex: `-F` escapes each literal, multiple patterns OR via
/// `(?:…)|(?:…)`, and `-x/--line-regexp` anchors the whole with `^(?:…)$`.
/// Returns null for the "zero patterns" case (an empty `-f` file with no other
/// source) — ripgrep matches nothing (and everything under `-v`); the caller
/// handles that without the engine. An empty pattern LINE is kept (it's a valid
/// empty pattern = match-all), only the phantom line after a trailing `\n` drops.
/// Leading `(?flags)` directives are resolved here (see `stripLeadingFlags`),
/// which may flip `o.caseless` — under `-F` the bytes `(?i)` stay a literal,
/// exactly as in rg.
pub fn combinePatterns(a: std.mem.Allocator, io: std.Io, parsed: args.Parsed, o: *Opts) ?[]const u8 {
    var pats: std.ArrayList([]const u8) = .empty;
    pats.appendSlice(a, parsed.patterns) catch oom();
    for (parsed.pattern_files) |pf| {
        const buf = Dir.cwd().readFileAlloc(io, pf, a, .limited(corpus_mod.per_file_cap)) catch die("cannot read pattern file: {s}\n", .{pf});
        if (buf.len == 0) continue;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |ln| {
            // The piece after a final '\n' is a phantom (not a pattern); every
            // other line — including a genuinely empty one — is a real pattern.
            if (it.index == null and ln.len == 0) break;
            pats.append(a, std.mem.trimEnd(u8, ln, "\r")) catch oom();
        }
    }
    if (pats.items.len == 0) return null;
    // The regex `m` flag rides `-U` by default (rg: `-U` is `m` ON); leading
    // `(?m)`/`(?-m)` directives below override it. Set before both branches so
    // the `-F` and no-directive paths inherit the base unchanged.
    //
    // `--null-data` needs it for a different reason, and it is the one case where
    // the per-line default is not self-evidently right. `^` in per-line mode means
    // "the haystack's first byte", which is exact while a haystack IS a line — but
    // under `--null-data` the haystack is a NUL-delimited RECORD that may hold many
    // newlines, and there `^` would only ever match the record's own start. Both
    // incumbents disagree: `rg --null-data '^zz'` and BSD `grep -z '^zz'` each match
    // a `zz` sitting after an interior `\n`, because `^` in a line-oriented tool is
    // an assertion about NEWLINES and the record separator does not retract it. So
    // the `\n`-boundary anchor (`closure.zig`'s `lineStart`) is what `^` must mean
    // here, which is exactly `re_line_anchors` — no new engine concept, just the
    // one already built for `-U`, admitted for the one other mode whose haystack is
    // wider than a line. `(?-m)` still overrides, as it does under `-U`.
    o.re_line_anchors = o.multiline or o.null_data;
    if (parsed.opts.fixed) {
        for (pats.items) |*p| p.* = query_mod.escapeLiteral(a, p.*) catch oom();
    } else {
        // Resolve leading `(?flags)` directives. A run compiles ONE engine, so a
        // flag some pattern explicitly demands may not disagree with a pattern
        // that merely inherits the CLI's own setting (rg scopes flags per branch).
        // `(?i)` case, `(?u)` Unicode, `(?m)` line anchors, `(?s)` dotall each
        // reconcile through the same demand/inherit rule.
        var ci = Directive{ .name = "i" };
        var uni = Directive{ .name = "u" };
        var mln = Directive{ .name = "m" };
        var dot = Directive{ .name = "s" };
        for (pats.items) |*p| {
            const sf = stripLeadingFlags(p.*) orelse {
                for ([_]*Directive{ &ci, &uni, &mln, &dot }) |d| d.inherit = true;
                continue;
            };
            p.* = sf.rest;
            ci.see(sf.caseless);
            uni.see(sf.unicode);
            mln.see(sf.line_anchors);
            dot.see(sf.dotall);
        }
        ci.resolve(&o.caseless);
        uni.resolve(&o.unicode);
        mln.resolve(&o.re_line_anchors);
        dot.resolve(&o.multiline_dotall);
    }
    var combined: []const u8 = pats.items[0];
    if (pats.items.len > 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (pats.items, 0..) |p, i| {
            if (i != 0) buf.append(a, '|') catch oom();
            buf.print(a, "(?:{s})", .{p}) catch oom();
        }
        combined = buf.toOwnedSlice(a) catch oom();
    }
    if (parsed.opts.line_regexp) combined = std.fmt.allocPrint(a, "^(?:{s})$", .{combined}) catch oom();
    return combined;
}
// The dying arms (`(?u)`, `(?x)`, mixed demands) exit the process by design,
// so tests cover the honor/strip/decline paths; build.zig's black-box guard
// covers the end-to-end exit codes.
test "stripLeadingFlags honors i/-i and strips the directive" {
    const t = std.testing;
    const ci = stripLeadingFlags("(?i)Foo.*bar").?;
    try t.expectEqualStrings("Foo.*bar", ci.rest);
    try t.expectEqual(@as(?bool, true), ci.caseless);
    const cs = stripLeadingFlags("(?-i)Foo").?;
    try t.expectEqualStrings("Foo", cs.rest);
    try t.expectEqual(@as(?bool, false), cs.caseless);
    const both = stripLeadingFlags("(?i-s)x").?; // `-` negates only what follows it
    try t.expectEqual(@as(?bool, true), both.caseless);
    try t.expectEqualStrings("x", both.rest);
}

test "stripLeadingFlags resolves m/s flags; u/-u select Unicode mode" {
    const t = std.testing;
    // `(?sm)` turns dotall + line anchors ON; `-` negates only what follows it.
    const sf = stripLeadingFlags("(?sm)^func$").?;
    try t.expectEqualStrings("^func$", sf.rest);
    try t.expectEqual(@as(?bool, null), sf.caseless);
    try t.expectEqual(@as(?bool, null), sf.unicode);
    try t.expectEqual(@as(?bool, true), sf.dotall);
    try t.expectEqual(@as(?bool, true), sf.line_anchors);
    // `(?-m)` clears line anchors (rg's whole-buffer `^`/`$`-at-BOF), dotall untouched.
    const nm = stripLeadingFlags("(?-m)^baz").?;
    try t.expectEqualStrings("^baz", nm.rest);
    try t.expectEqual(@as(?bool, false), nm.line_anchors);
    try t.expectEqual(@as(?bool, null), nm.dotall);
    // `(?-s)` clears dotall only.
    const ns = stripLeadingFlags("(?-s).").?;
    try t.expectEqual(@as(?bool, false), ns.dotall);
    try t.expectEqual(@as(?bool, null), ns.line_anchors);
    // `(?-u)` selects the byte/ASCII engine; `(?u)` re-selects the default.
    const nu = stripLeadingFlags("(?-u)\\w+").?;
    try t.expectEqualStrings("\\w+", nu.rest);
    try t.expectEqual(@as(?bool, null), nu.caseless);
    try t.expectEqual(@as(?bool, false), nu.unicode);
    const yu = stripLeadingFlags("(?u)\\w+").?;
    try t.expectEqualStrings("\\w+", yu.rest);
    try t.expectEqual(@as(?bool, true), yu.unicode);
    // Combined with case: `(?i-u)` is caseless + ASCII (the `-` negates only `u`).
    const iu = stripLeadingFlags("(?i-u)Foo").?;
    try t.expectEqual(@as(?bool, true), iu.caseless);
    try t.expectEqual(@as(?bool, false), iu.unicode);
}

test "stripLeadingFlags declines non-directive groups (parser decides)" {
    const t = std.testing;
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i:foo)bar")); // scoped group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?=foo)")); // lookahead
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?P<n>a)")); // named group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?)x")); // empty directive
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("foo(?i)")); // not leading
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i")); // unclosed
}
