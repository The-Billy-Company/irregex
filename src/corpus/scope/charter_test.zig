//! The charter grammar, held to its contract.
//!
//! A charter is committed source that decides which files every clone of a tree
//! searches, so the interesting tests are the adverse ones: the shapes that must
//! be REFUSED. A corpus declaration that half-parsed would silently search a
//! corpus nobody described — strictly worse than having no file at all — so
//! every malformed input below has to name a fault rather than yield a partial
//! answer.

const std = @import("std");
const charter = @import("charter.zig");
const misread = @import("misread.zig");

const t = std.testing;

fn parsed(src: []const u8, dir: []const u8) !charter.Charter {
    return charter.parse(t.allocator, ".irregex.toml", dir, src, null);
}

/// Assert that `src` is refused with exactly `want`. A charter that parsed when
/// it should not have is the failure this whole file exists to catch, so the
/// success path here is itself an error.
fn refuses(src: []const u8, want: anyerror) !void {
    var diag: misread.Diagnostic = .{};
    const c = charter.parse(t.allocator, ".irregex.toml", "", src, &diag) catch |e| {
        return t.expectEqual(want, e);
    };
    c.deinit(t.allocator);
    return error.CharterAcceptedMalformedInput;
}

/// Assert that `src` is refused AND that the reader is told where. A fault a
/// person cannot locate is only marginally better than a silent one.
fn refusesAt(src: []const u8, want: anyerror, line: usize, token: []const u8) !void {
    var diag: misread.Diagnostic = .{};
    const c = charter.parse(t.allocator, ".irregex.toml", "", src, &diag) catch |e| {
        try t.expectEqual(want, e);
        try t.expectEqual(line, diag.line);
        try t.expectEqualStrings(token, diag.token);
        return;
    };
    c.deinit(t.allocator);
    return error.CharterAcceptedMalformedInput;
}

test "a charter declares the three corpus facts" {
    const c = try parsed(
        \\# what this corpus is
        \\roots = ["services", "libs"]
        \\skip  = ["graphify-out"]
        \\types = ["zigsrc:*.zig"]
    , "");
    defer c.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), c.roots.len);
    try t.expectEqualStrings("services", c.roots[0]);
    try t.expectEqualStrings("libs", c.roots[1]);
    try t.expectEqualStrings("graphify-out", c.skip[0]);
    try t.expectEqualStrings("zigsrc:*.zig", c.types[0]);
}

test "an absent key is an empty set, not a fault" {
    const c = try parsed("skip = [\"out\"]", "");
    defer c.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), c.roots.len);
    try t.expectEqual(@as(usize, 0), c.types.len);
    try t.expectEqual(@as(usize, 1), c.skip.len);
}

test "roots resolve against the charter's directory, not the working directory" {
    // Run from two levels down: the same declaration must still name the same
    // files, which is the whole reason the prefix is folded in at parse time.
    const c = try parsed("roots = [\"libs\", \"services\"]", "../../");
    defer c.deinit(t.allocator);
    try t.expectEqualStrings("../../libs", c.roots[0]);
    try t.expectEqualStrings("../../services", c.roots[1]);
    // Basenames are position-free, so they are NOT prefixed.
    try t.expectEqualStrings("../../", c.dir);
}

test "a lone string is a set of one" {
    const c = try parsed("roots = \"services\"", "");
    defer c.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), c.roots.len);
    try t.expectEqualStrings("services", c.roots[0]);
}

test "multi-line lists, trailing commas, and comments between entries" {
    const c = try parsed(
        \\roots = [
        \\  "a",   # the first
        \\  "b",
        \\]
        \\# trailing comment with no newline after it
    , "");
    defer c.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), c.roots.len);
    try t.expectEqualStrings("b", c.roots[1]);
}

test "CRLF line endings parse identically" {
    const c = try parsed("roots = [\"a\"]\r\nskip = [\"b\"]\r\n", "");
    defer c.deinit(t.allocator);
    try t.expectEqualStrings("a", c.roots[0]);
    try t.expectEqualStrings("b", c.skip[0]);
}

test "a hash inside a string is data, not a comment" {
    // ripgrep's format cannot express this at all: its lines are verbatim argv
    // elements, so a value containing a quote or a comment character is a
    // silent misparse rather than a value. Here a quote is a quote.
    const c = try parsed("skip = [\"issue#42\", \"a b\"]", "");
    defer c.deinit(t.allocator);
    try t.expectEqualStrings("issue#42", c.skip[0]);
    try t.expectEqualStrings("a b", c.skip[1]);
}

test "the two recognized escapes survive, and no others are invented" {
    const c = try parsed("skip = [\"say \\\"hi\\\"\", \"back\\\\slash\"]", "");
    defer c.deinit(t.allocator);
    try t.expectEqualStrings("say \"hi\"", c.skip[0]);
    try t.expectEqualStrings("back\\slash", c.skip[1]);
    try refuses("skip = [\"tab\\there\"]", charter.Fault.BadEscape);
}

test "malformed declarations are refused, never half-applied" {
    try refuses("generated = [\"*.gen.ts\"]", charter.Fault.UnknownKey);
    try refuses("root = [\"a\"]", charter.Fault.UnknownKey);
    try refuses("skip = [\"a\"]\nskip = [\"b\"]", charter.Fault.DuplicateKey);
    try refuses("roots [\"a\"]", charter.Fault.ExpectedEquals);
    try refuses("roots =", charter.Fault.ExpectedValue);
    try refuses("roots = [\"a\"", charter.Fault.ExpectedValue);
    try refuses("roots = [\"a\n]", charter.Fault.UnterminatedString);
    try refuses("skip = [\"\"]", charter.Fault.EmptyValue);
}

test "an unquoted value is refused rather than guessed at" {
    // The single most common way a TOML-shaped file gets written by hand. Left
    // lenient it would silently accept `roots = services` as something; the
    // charter would rather be unreadable than creatively interpreted.
    try refuses("roots = services", charter.Fault.ExpectedValue);
    try refuses("roots = [services]", charter.Fault.ExpectedValue);
    try refuses("skip = true", charter.Fault.ExpectedValue);
}

test "trailing garbage after a complete declaration is a fault" {
    try refuses("roots = [\"a\"]\nnonsense", charter.Fault.ExpectedEquals);
    try refuses("roots = [\"a\"]\n]", charter.Fault.ExpectedValue);
}

test "a fault says which line, so a long charter is not a hunt" {
    try refusesAt("roots = [\"a\"]\ngenerated = [\"x\"]", charter.Fault.UnknownKey, 2, "generated");
    try refusesAt("# a comment\n\nskip = [\"a\"]\nskip = [\"b\"]", charter.Fault.DuplicateKey, 4, "skip");
    try refusesAt("roots = [\"a\"]\nskip  = [\"b\n]", charter.Fault.UnterminatedString, 2, "skip");
}

test "only a fault about a NAME is answered with a name" {
    // `skip = ["a` faults on the string while its last token is `skip`, a
    // perfectly legal key. Pairing "nearest" with the caller's own idea of
    // which faults are name faults produced `try `skip` — `skip` is not a
    // charter key`, so the gate lives with the fault, not at the call site.
    try t.expectEqualStrings("roots", charter.didYouMean(charter.Fault.UnknownKey, "rotos").?);
    for ([_]anyerror{
        charter.Fault.UnterminatedString,
        charter.Fault.DuplicateKey,
        charter.Fault.ExpectedEquals,
        charter.Fault.ExpectedValue,
        charter.Fault.EmptyValue,
        charter.Fault.Oversized,
    }) |e| try t.expectEqual(@as(?[]const u8, null), charter.didYouMean(e, "skip"));
}

test "an empty or comment-only charter is valid and declares nothing" {
    for ([_][]const u8{ "", "   \n\n", "# nothing yet\n" }) |src| {
        const c = try parsed(src, "");
        defer c.deinit(t.allocator);
        try t.expectEqual(@as(usize, 0), c.roots.len);
        try t.expectEqual(@as(usize, 0), c.skip.len);
        try t.expectEqual(@as(usize, 0), c.types.len);
    }
}
