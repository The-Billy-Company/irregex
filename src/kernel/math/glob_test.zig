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
