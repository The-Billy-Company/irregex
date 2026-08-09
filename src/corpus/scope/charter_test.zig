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
const misread = @import("../../kernel/math/misread.zig");

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
        \\skip  = ["derived-out"]
        \\types = ["zigsrc:*.zig"]
    , "");
    defer c.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), c.roots.len);
    try t.expectEqualStrings("services", c.roots[0]);
    try t.expectEqualStrings("libs", c.roots[1]);
    try t.expectEqualStrings("derived-out", c.skip[0]);
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
    try refuses("skip = [\"tab\\there\"]", error.BadEscape);
}

test "malformed declarations are refused, never half-applied" {
    try refuses("generated = [\"*.gen.ts\"]", error.UnknownKey);
    try refuses("root = [\"a\"]", error.UnknownKey);
    try refuses("skip = [\"a\"]\nskip = [\"b\"]", error.DuplicateKey);
    try refuses("roots [\"a\"]", error.ExpectedEquals);
    try refuses("roots =", error.ExpectedValue);
    try refuses("roots = [\"a\"", error.ExpectedValue);
    try refuses("roots = [\"a\n]", error.UnterminatedString);
    try refuses("skip = [\"\"]", error.EmptyValue);
}

test "an unquoted value is refused rather than guessed at" {
    // The single most common way a TOML-shaped file gets written by hand. Left
    // lenient it would silently accept `roots = services` as something; the
    // charter would rather be unreadable than creatively interpreted.
    try refuses("roots = services", error.ExpectedValue);
    try refuses("roots = [services]", error.ExpectedValue);
    try refuses("skip = true", error.ExpectedValue);
}

test "trailing garbage after a complete declaration is a fault" {
    try refuses("roots = [\"a\"]\nnonsense", error.ExpectedEquals);
    try refuses("roots = [\"a\"]\n]", error.ExpectedValue);
}

test "a fault says which line, so a long charter is not a hunt" {
    try refusesAt("roots = [\"a\"]\ngenerated = [\"x\"]", error.UnknownKey, 2, "generated");
    try refusesAt("# a comment\n\nskip = [\"a\"]\nskip = [\"b\"]", error.DuplicateKey, 4, "skip");
    try refusesAt("roots = [\"a\"]\nskip  = [\"b\n]", error.UnterminatedString, 2, "skip");
}

test "only a fault about a NAME is answered with a name" {
    // `skip = ["a` faults on the string while its last token is `skip`, a
    // perfectly legal key. Pairing "nearest" with the caller's own idea of
    // which faults are name faults produced `try `skip` — `skip` is not a
    // charter key`, so the gate lives with the fault, not at the call site.
    try t.expectEqualStrings("roots", charter.didYouMean(error.UnknownKey, "rotos").?);
    for ([_]anyerror{
        error.UnterminatedString,
        error.DuplicateKey,
        error.ExpectedEquals,
        error.ExpectedValue,
        error.EmptyValue,
        error.Oversized,
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

/// The charter's real keys, not a copy of them — three short names a few
/// letters apart are the hardest suggestion case here, and a fixture that
/// drifted from the live list would stop testing that case. They live
/// here in the scope tier, so `misread.zig` stays a leaf both layers use.
const charter_keys = @import("charter.zig").keys;

test "a near-miss is guessed at, a genuinely foreign name is not" {
    try t.expectEqualStrings("roots", misread.nearest("root", &charter_keys).?);
    try t.expectEqualStrings("roots", misread.nearest("rootz", &charter_keys).?);
    try t.expectEqualStrings("types", misread.nearest("type", &charter_keys).?);
    try t.expectEqualStrings("skip", misread.nearest("skips", &charter_keys).?);

    // Real keys someone might reasonably try that mean nothing here. A
    // confident wrong answer would send them to edit the wrong line.
    for ([_][]const u8{ "generated", "exclude", "include", "ignore", "" }) |foreign| {
        try t.expectEqual(@as(?[]const u8, null), misread.nearest(foreign, &charter_keys));
    }
}

test "a library may not be given the posture that ends its host's process" {
    // The default is the whole bug fix: `governing()` used to `exit(2)` on a
    // malformed charter, so a C host that opened a walk in a tree carrying one
    // bad config line lost its process with no way to catch it. Nothing has to
    // be *called* for the safe posture to hold — that is what makes it safe.
    try t.expectEqual(charter.Refusal.fault, charter.refusalNow());
}

test "a face adopts the loud exit, and a scope puts back what it found" {
    // `honorNoConfig` is the seam that arms it in production (every face's first
    // act, and the only one that takes an argv); `failLoud` is what it calls, so
    // the posture is a named greppable thing rather than a side effect hidden in
    // an argv loop. Scoped here so the assertion cannot leak `exit` into another
    // test in this process — the exact hazard `StatedRefusal` exists for.
    const held = charter.stateRefusal(.fault);
    defer held.release();

    charter.failLoud();
    try t.expectEqual(charter.Refusal.exit, charter.refusalNow());

    // Nested statement restores its own predecessor, not the global default.
    {
        const inner = charter.stateRefusal(.fault);
        try t.expectEqual(charter.Refusal.fault, charter.refusalNow());
        inner.release();
    }
    try t.expectEqual(charter.Refusal.exit, charter.refusalNow());
}

test "the reason for a dropped charter is pulled, not thrown" {
    // `governing()` returns an optional rather than an error union because its
    // three callers ask while assembling a walk and none can act on the reason;
    // `faulted()` is where the reason lives instead. What matters for the C seam
    // is that a fault is NAMEABLE afterwards — every refusal the grammar can
    // produce has a note, so the seam always has something to say when it turns
    // one into `Corrupt` on `irgx_last_fault`.
    for ([_]anyerror{
        error.UnknownKey,     error.DuplicateKey,       error.ExpectedEquals,
        error.ExpectedValue,  error.UnterminatedString, error.BadEscape,
        error.TooManyEntries, error.Oversized,          error.EmptyValue,
    }) |e| {
        const note = charter.faultNote(e);
        try t.expect(note.len > 0);
        try t.expect(!std.mem.eql(u8, note, "unreadable")); // the catch-all, not a real note
    }
}

test "a transposition is one edit, not two" {
    // The most common typing error there is, and the reason the metric is
    // Damerau rather than plain Levenshtein — plain scores these 2, which
    // falls outside a budget tight enough to reject the foreign names above.
    try t.expectEqualStrings("roots", misread.nearest("rotos", &charter_keys).?);
    try t.expectEqualStrings("types", misread.nearest("tpyes", &charter_keys).?);
    try t.expectEqualStrings("heading", misread.nearest("headnig", &.{ "heading", "hidden" }).?);
}
