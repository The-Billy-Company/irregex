//! Preferences grammar — the quoting bugs ripgrep's version has, proven absent.
//!
//! Every adverse case here is a real ripgrep issue report against `.ripgreprc`
//! (a quoted glob arriving with its quotes, a typo'd flag noticed only as wrong
//! results, a bare word becoming a pattern). They are the point of the suite;
//! the happy-path cases only fence them in.

const std = @import("std");
const t = std.testing;
const preference = @import("preference.zig");

/// Parse and hand back the tokens, freeing the wrapper.
fn tokens(gpa: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    const p = try preference.parse(gpa, "prefs", src);
    gpa.free(p.path);
    return p.tokens;
}

fn free(gpa: std.mem.Allocator, toks: []const []const u8) void {
    for (toks) |tok| gpa.free(tok);
    gpa.free(toks);
}

fn expectTokens(src: []const u8, want: []const []const u8) !void {
    const got = try tokens(t.allocator, src);
    defer free(t.allocator, got);
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn refuses(src: []const u8, want: anyerror) !void {
    if (preference.parse(t.allocator, "prefs", src)) |p| {
        p.deinit(t.allocator);
        return error.PreferencesAcceptedMalformedInput;
    } else |e| try t.expectEqual(want, e);
}

test "one flag per line lowers to argv" {
    try expectTokens(
        \\--heading
        \\-n
        \\--max-columns 200
    , &.{ "--heading", "-n", "--max-columns", "200" });
}

test "blank lines and comments are not tokens" {
    try expectTokens(
        \\# my preferences
        \\
        \\--heading   # trailing note
        \\
    , &.{"--heading"});
}

test "a quoted glob arrives without its quotes" {
    // ripgrep #927/#2646: `--glob '!.git/*'` in a .ripgreprc reaches the glob
    // engine WITH the apostrophes, so it matches nothing and reports nothing.
    try expectTokens("--glob '!.git/*'", &.{ "--glob", "!.git/*" });
    try expectTokens("--glob \"!.git/*\"", &.{ "--glob", "!.git/*" });
    try expectTokens("--glob !.git/*", &.{ "--glob", "!.git/*" });
}

test "quoting composes the way a shell's does" {
    try expectTokens("-g 'a b'", &.{ "-g", "a b" });
    try expectTokens("-g a\\ b", &.{ "-g", "a b" });
    try expectTokens("-g \"say \\\"hi\\\"\"", &.{ "-g", "say \"hi\"" });
    try expectTokens("-g 'it # not a comment'", &.{ "-g", "it # not a comment" });
    try expectTokens("-g ''", &.{ "-g", "" });
}

test "attached and bundled spellings pass the catalog" {
    try expectTokens("--max-columns=200", &.{"--max-columns=200"});
    try expectTokens("-in", &.{"-in"});
    try expectTokens("-j4", &.{"-j4"});
}

test "a typo is refused at read time, not diagnosed as bad results" {
    try refuses("--headding", preference.Fault.UnknownFlag);
    try refuses("--max-colums=200", preference.Fault.UnknownFlag);
    try refuses("-Z", preference.Fault.UnknownFlag);
    try refuses("-iZ", preference.Fault.UnknownFlag);
}

test "a bare word cannot become every run's search pattern" {
    // The worst failure mode of a persisted argv file: a stray word silently
    // becomes the pattern (or an extra path) for every invocation forever.
    try refuses("smart-case", preference.Fault.ExpectedFlag);
    try refuses("foo --heading", preference.Fault.ExpectedFlag);
    try refuses("--", preference.Fault.ExpectedFlag);
}

test "an unterminated quote is an error, not a swallowed line" {
    try refuses("--glob 'unclosed", preference.Fault.UnterminatedQuote);
    try refuses("--glob \"unclosed", preference.Fault.UnterminatedQuote);
    try refuses("--glob trailing\\", preference.Fault.UnterminatedQuote);
}

test "reach decides whether the file can change the answer" {
    // Presentation-only preferences leave the answer alone; a corpus- or
    // semantics-reaching one is what a zero-match run must be able to name.
    const quiet = try preference.parse(t.allocator, "prefs", "--heading\n-n\n--color always");
    defer quiet.deinit(t.allocator);
    try t.expect(!quiet.changes_answer);

    const loud = try preference.parse(t.allocator, "prefs", "--heading\n--smart-case");
    defer loud.deinit(t.allocator);
    try t.expect(loud.changes_answer);

    const scoped = try preference.parse(t.allocator, "prefs", "--glob '!vendor/*'");
    defer scoped.deinit(t.allocator);
    try t.expect(scoped.changes_answer);
}

test "a flag that fails loud when typed cannot be persisted quietly" {
    // `--no-config`'s whole job is to disable this file; persisting it is
    // either a no-op or a lie, so the catalog's null reach refuses it.
    try refuses("--no-config", preference.Fault.NotPersistable);
}

test "an empty file is a valid file with nothing in it" {
    try expectTokens("", &.{});
    try expectTokens("\n\n   \n", &.{});
}
