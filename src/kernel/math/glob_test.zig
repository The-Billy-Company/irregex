//! Adversarial tests for the glob matcher — the risky surface: a wrong
//! `*`/`**`/class boundary silently drops or admits files, which an agent
//! reads as "no matches" and trusts. Pins the segment/`/` rules, the
//! basename-vs-full-path dispatch, class edge cases, and pathological star
//! backtracking.

const std = @import("std");
const glob = @import("glob.zig");
const globMatch = glob.globMatch;
const expect = std.testing.expect;

test "literal and single-star within a segment" {
    try expect(globMatch("*.go", "main.go"));
    try expect(globMatch("*.go", "a.b.go"));
    try expect(!globMatch("*.go", "main.rs"));
    // a single `*` must NOT cross a '/' — this is the rule rg relies on.
    try expect(!globMatch("*.go", "pkg/main.go"));
    try expect(globMatch("a*c", "abbbc"));
    try expect(globMatch("a*c", "ac"));
    try expect(!globMatch("a*c", "ab/c"));
}

test "double-star spans slashes and may match zero dirs" {
    try expect(globMatch("**/*.go", "main.go")); // zero intermediate dirs
    try expect(globMatch("**/*.go", "a/b/c/main.go"));
    try expect(globMatch("services/**/*.go", "services/x/y/z.go"));
    try expect(globMatch("services/**/*.go", "services/z.go"));
    try expect(!globMatch("services/**/*.go", "libs/z.go"));
    try expect(globMatch("**", "anything/at/all.txt"));
}

test "double-star segment token anchors at path-segment boundaries (rg parity)" {
    // `**/X` skips whole segments, then X must match a segment from its START —
    // it must NOT bind to a suffix inside a component. This is the rg/gitignore
    // rule the `!**/_pb2*` lint excludes rely on: a generated stub whose basename
    // merely CONTAINS `_pb2` is not the same as one that begins with it.
    try expect(globMatch("**/_pb2*", "a/b/_pb2.pyi")); // basename starts with _pb2 ⇒ match
    try expect(globMatch("**/_pb2*", "_pb2foo.py")); // zero dirs, starts with _pb2
    try expect(!globMatch("**/_pb2*", "a/outreach_pb2.pyi")); // merely CONTAINS _pb2 ⇒ no match
    try expect(!globMatch("**/_pb2*", "svc/outreachpb/outreach_pb2_grpc.pyi"));
    // The positive cases the exclude set still must catch.
    try expect(globMatch("**/*_pb2*", "a/outreach_pb2.pyi")); // leading `*` DOES span the prefix
    try expect(globMatch("**/target/**", "services/x/target/debug/app"));
    try expect(!globMatch("**/target/**", "services/x/mytarget/debug/app")); // segment, not substring
    try expect(globMatch("**/*.pb.go", "a/b/acme.pb.go"));
    try expect(!globMatch("**/generated/**", "a/pregenerated/x.ts")); // 'generated' as a segment only
    try expect(globMatch("**/generated/**", "a/generated/x.ts"));
}

test "question mark is exactly one non-slash byte" {
    try expect(globMatch("a?c", "abc"));
    try expect(!globMatch("a?c", "ac"));
    try expect(!globMatch("a?c", "abbc"));
    try expect(!globMatch("a?c", "a/c"));
}

test "character classes: ranges, negation, literal-close, slash-immunity" {
    try expect(globMatch("[a-z].go", "x.go"));
    try expect(!globMatch("[a-z].go", "X.go"));
    try expect(globMatch("[!a-z].go", "X.go"));
    try expect(!globMatch("[!a-z].go", "x.go"));
    try expect(globMatch("[abc]x", "bx"));
    try expect(!globMatch("[abc]x", "dx"));
    // a class never matches '/'
    try expect(!globMatch("[a-z/]x", "/x"));
    // unterminated class ⇒ '[' is a literal byte
    try expect(globMatch("[oops", "[oops"));
    try expect(!globMatch("[oops", "x"));
}

test "star backtracking does not over- or under-match" {
    try expect(globMatch("*test*.go", "my_test_thing.go"));
    try expect(globMatch("*_test.go", "acme_test.go"));
    try expect(!globMatch("*_test.go", "acme.go"));
    // adversarial: many stars against a long non-matching tail must terminate false
    try expect(!globMatch("a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaac"));
    try expect(globMatch("a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaab"));
}

// ── brace alternation ────────────────────────────────────────────────────────

/// Expand `pat` into an arena the caller frees in one go — the shape every real
/// caller uses, and the reason the expander never has to free a partial answer.
fn expanded(arena: std.mem.Allocator, pat: []const u8, cap: usize) glob.BraceError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try glob.braceExpand(arena, pat, &out, cap);
    return out.items;
}

test "brace expansion is the cartesian product, in argv order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = std.testing.expectEqualDeep;

    // The claim the walk plane rests on: one alternation names exactly the
    // patterns a caller would have written by hand, in the order it wrote them.
    try eq(@as([]const []const u8, &.{ "*.js", "*.ts" }), try expanded(a, "*.{js,ts}", glob.brace_cap));
    // Groups MULTIPLY, and the product is enumerated prefix-first.
    try eq(@as([]const []const u8, &.{ "ac", "ad", "bc", "bd" }), try expanded(a, "{a,b}{c,d}", glob.brace_cap));
    // Nesting is resolved from the inside out; the comma inside the inner group
    // is not a separator of the outer one.
    try eq(@as([]const []const u8, &.{ "ad", "bd", "cd" }), try expanded(a, "{a,{b,c}}d", glob.brace_cap));
    // An empty alternative is an alternative (`{a,}` is rg's own reading).
    try eq(@as([]const []const u8, &.{ "x.a", "x." }), try expanded(a, "x.{a,}", glob.brace_cap));
    // No group ⇒ the pattern itself, so a caller may expand unconditionally.
    try eq(@as([]const []const u8, &.{"src/**/*.go"}), try expanded(a, "src/**/*.go", glob.brace_cap));
    // An UNBALANCED `{` is left literal — the lenient reading a `.gitignore`
    // line gets. A caller that must refuse one asks `unterminatedBrace` first.
    try eq(@as([]const []const u8, &.{"*.{c,h"}), try expanded(a, "*.{c,h", glob.brace_cap));
}

test "brace expansion refuses a ceiling rather than truncating it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Thirteen two-way groups name 8192 patterns against a 1024 ceiling. A
    // shortened list would answer about a smaller corpus than the one asked
    // about, which is the one outcome a glob cannot make visible — so it is a
    // fault, and `BudgetExceeded` says whose limit was reached.
    const hostile = "{a,b}" ** 13;
    try std.testing.expectError(error.BudgetExceeded, expanded(a, hostile, glob.brace_cap));
    // Same pattern, a ceiling big enough to hold it: the refusal is the
    // ceiling's and not the expander's.
    try std.testing.expectEqual(@as(usize, 8192), (try expanded(a, hostile, 8192)).len);

    // The other way to be hostile, which a product ceiling structurally cannot
    // see: a product of ONE and one stack frame per group. Left unbounded this
    // is a stack overflow inside a library — the exact failure this expander
    // was moved out of the CLI to stop being able to cause.
    const deep = "{a}" ** (glob.brace_group_cap + 1);
    try std.testing.expectError(error.BudgetExceeded, expanded(a, deep, glob.brace_cap));
    try std.testing.expectEqual(@as(usize, 1), (try expanded(a, "{a}" ** glob.brace_group_cap, glob.brace_cap)).len);

    // A cap of zero admits nothing, rather than admitting one for free.
    try std.testing.expectError(error.BudgetExceeded, expanded(a, "*.go", 0));
}

test "an unterminated brace is a different fact from an expandable one" {
    // What the strict `-g` seams key on. Well-formed, at any nesting:
    try expect(!glob.unterminatedBrace("*.{c,h}"));
    try expect(!glob.unterminatedBrace("{a,{b,c}}d"));
    try expect(!glob.unterminatedBrace("src/**/*.go"));
    // A stray `}` is literal to every glob dialect and is not this question.
    try expect(!glob.unterminatedBrace("a}b"));
    // Unclosed, including one that opens AFTER a group that closed cleanly —
    // scanning only the first group would have called this well-formed.
    try expect(glob.unterminatedBrace("*.{c,h"));
    try expect(glob.unterminatedBrace("{a,b}{c"));
    try expect(glob.unterminatedBrace("{a,{b,c}"));
}
