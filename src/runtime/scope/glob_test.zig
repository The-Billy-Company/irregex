//! Adversarial tests for path scoping. The glob matcher is the risky surface —
//! a wrong `*`/`**`/class boundary silently drops or admits files, which an
//! agent reads as "no matches" and trusts. So these pin the segment/`/` rules,
//! the basename-vs-full-path dispatch, class edge cases, and pathological star
//! backtracking, and assert the type table against the real repo's languages.

const std = @import("std");
const glob = @import("glob.zig");
const types = @import("types.zig");
const globMatch = glob.globMatch;
const PathFilter = glob.PathFilter;
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
    try expect(globMatch("**/*.pb.go", "a/b/wallet.pb.go"));
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
    try expect(globMatch("*_test.go", "wallet_test.go"));
    try expect(!globMatch("*_test.go", "wallet.go"));
    // adversarial: many stars against a long non-matching tail must terminate false
    try expect(!globMatch("a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaac"));
    try expect(globMatch("a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaab"));
}

test "PathFilter: type glob union, AND with globs, exclude veto" {
    const go_rs = PathFilter{ .exts = &.{ "*.go", "*.rs" } };
    try expect(go_rs.admits("services/api/main.go"));
    try expect(go_rs.admits("services/vox/src/lib.rs"));
    try expect(!go_rs.admits("clients/web/app.ts"));

    // type AND include-glob: must be a .go file under services/
    const scoped = PathFilter{ .exts = &.{"*.go"}, .includes = &.{"services/**"} };
    try expect(scoped.admits("services/api/main.go"));
    try expect(!scoped.admits("libs/x/main.go")); // right ext, wrong subtree
    try expect(!scoped.admits("services/api/app.ts")); // right subtree, wrong ext

    // exclude veto beats everything (e.g. drop generated + tests)
    const no_test = PathFilter{ .exts = &.{"*.go"}, .excludes = &.{ "*_test.go", "*.pb.go" } };
    try expect(no_test.admits("services/api/handler.go"));
    try expect(!no_test.admits("services/api/handler_test.go"));
    try expect(!no_test.admits("services/api/wallet.pb.go"));
}

test "positional roots: dir prefix, exact file, whole-corpus '.', boundary" {
    // A directory root admits paths under it, respecting the '/' boundary so a
    // sibling with a shared prefix is NOT bled in.
    const in_services = PathFilter{ .roots = &.{"services"} };
    try expect(in_services.admits("services/api/main.go"));
    try expect(!in_services.admits("libs/x.zig"));
    try expect(!in_services.admits("services_old/x.go")); // '/' boundary, no bleed

    // An exact-file root admits only that file.
    const one_file = PathFilter{ .roots = &.{"services/api/main.go"} };
    try expect(one_file.admits("services/api/main.go"));
    try expect(!one_file.admits("services/api/other.go"));

    // Multiple roots OR together; '.' matches the whole corpus.
    const two = PathFilter{ .roots = &.{ "services", "libs" } };
    try expect(two.admits("libs/x.zig") and two.admits("services/y.go"));
    try expect(!two.admits("clients/z.ts"));
    const dot = PathFilter{ .roots = &.{"."} };
    try expect(dot.admits("anywhere/at/all.rs"));

    // roots AND with type/glob/exclude, same as the other constraint sets.
    const scoped = PathFilter{ .exts = &.{"*.go"}, .roots = &.{"services"} };
    try expect(scoped.admits("services/api/main.go"));
    try expect(!scoped.admits("services/api/app.ts")); // right root, wrong ext
    try expect(!scoped.admits("libs/api/main.go")); // right ext, wrong root
}

test "normalizeRoot strips leading ./ and trailing /" {
    try expect(std.mem.eql(u8, glob.normalizeRoot("./services/"), "services"));
    try expect(std.mem.eql(u8, glob.normalizeRoot("libs/x/"), "libs/x"));
    try expect(std.mem.eql(u8, glob.normalizeRoot("services"), "services"));
    try expect(std.mem.eql(u8, glob.normalizeRoot("."), "."));
}

test "empty filter admits everything and prunes nothing" {
    const empty = PathFilter{};
    try expect(empty.isEmpty());
    try expect(empty.admits("anything/at/all.zig"));
    var ids = [_]u32{ 0, 1, 2, 3 };
    const paths = [_][]const u8{ "a.go", "b.ts", "c.rs", "d.py" };
    try expect(empty.prune(&paths, &ids).len == 4);
}

test "prune keeps only admitted ids, order-preserving" {
    const only_go = PathFilter{ .exts = &.{"*.go"} };
    const paths = [_][]const u8{ "a.go", "b.ts", "c.go", "d.py", "e.go" };
    var ids = [_]u32{ 0, 1, 2, 3, 4 };
    const kept = only_go.prune(&paths, &ids);
    try expect(kept.len == 3);
    try expect(kept[0] == 0 and kept[1] == 2 and kept[2] == 4);
}

test "type table spans the mainstream language ecosystem, not just the repo" {
    // The repo's seven + aliases…
    for ([_][]const u8{ "go", "py", "python", "rust", "rs", "ts", "typescript", "swift", "zig", "sql", "proto" }) |t|
        try expect(types.extsForType(t) != null);
    // …and the wider world, so irregex scopes on ANY codebase, not only Billy's.
    for ([_][]const u8{
        "java",   "kotlin", "scala",   "clojure", "cs",        "csharp", "fsharp",
        "ruby",   "php",    "perl",    "lua",     "r",         "julia",  "dart",
        "elixir", "erlang", "haskell", "ocaml",   "c",         "cpp",    "cuda",
        "objc",   "html",   "css",     "json",    "yaml",      "toml",   "xml",
        "make",   "cmake",  "bazel",   "docker",  "terraform", "nix",    "graphql",
    }) |t| try expect(types.extsForType(t) != null);
    try expect(types.extsForType("cobol") == null); // unknown ⇒ null ⇒ caller errors
}

test "writeTypeList renders rg-identical sort order: names and globs lexicographic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try types.writeTypeList(a, &out);

    // Every non-empty line is `name: g1, g2, …`. Names must ascend lexically
    // across lines (rg's presentation), and each row's globs must ascend too.
    var prev_name: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, out.items, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        const name = line[0..colon];
        try expect(std.mem.lessThan(u8, prev_name, name)); // strictly ascending, no dupes
        prev_name = name;
        seen += 1;

        var prev_glob: []const u8 = "";
        var globs = std.mem.splitSequence(u8, line[colon + 2 ..], ", ");
        while (globs.next()) |g| {
            try expect(!std.mem.lessThan(u8, g, prev_glob)); // non-decreasing
            prev_glob = g;
        }
    }
    // The whole table is emitted (one line per name, aliases expanded).
    var expected: usize = 0;
    for (types.type_table) |row| expected += row.names.len;
    try std.testing.expectEqual(expected, seen);
}

test "writeTypeList is byte-identical to rg for representative shared rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try types.writeTypeList(arena.allocator(), &out);
    // Frozen against `rg --type-list` (ripgrep 15.1.0): these rows are pure
    // parity — irregex adds nothing, so they must match ripgrep verbatim, proving
    // the sort/framing is rg-faithful, not merely "close".
    // Framed with surrounding newlines so a match is a whole line, not a
    // substring of a longer row. Rows chosen to never be the first line.
    for ([_][]const u8{
        "\nasm: *.S, *.asm, *.s\n",
        "\nats: *.ats, *.dats, *.hats, *.sats\n",
        "\ncython: *.pxd, *.pxi, *.pyx\n",
        "\nelixir: *.eex, *.ex, *.exs, *.heex, *.leex, *.livemd\n",
    }) |row| try expect(std.mem.indexOf(u8, out.items, row) != null);
}

test "bare-filename type rows match by suffix (Makefile, Dockerfile, go.mod)" {
    // A row may list a dotless filename; `admits` is a plain suffix test, so it
    // catches build files that have no extension — what rg's filename globs do.
    const mk = PathFilter{ .exts = types.extsForType("make").? };
    try expect(mk.admits("services/Makefile"));
    try expect(mk.admits("scripts/mk/lint.mk"));
    try expect(!mk.admits("services/main.go"));
    const dk = PathFilter{ .exts = types.extsForType("docker").? };
    try expect(dk.admits("infra/docker/Dockerfile"));
    const go = PathFilter{ .exts = types.extsForType("go").? };
    try expect(go.admits("services/api/go.mod"));
    try expect(go.admits("services/api/main.go"));
}
