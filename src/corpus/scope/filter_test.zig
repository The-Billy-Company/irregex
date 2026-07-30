//! Adversarial tests for path scoping: the resolved `PathFilter` constraint
//! set, positional-root boundaries, and the `-t` type table asserted against
//! the real repo's languages. The matcher's own tests are
//! `kernel/math/glob_test.zig`.

const std = @import("std");
const scope = @import("filter.zig");
const glob = @import("../../kernel/math/glob.zig");
const types = @import("types.zig");
const genus = @import("genus.zig");
const globMatch = glob.globMatch;
const PathFilter = scope.PathFilter;
const expect = std.testing.expect;

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

test "PathFilter: a genus gate narrows, composes with roots, and never un-hides" {
    var docs: genus.Set = .empty;
    docs.add(.docs);
    var code: genus.Set = .empty;
    code.add(.code);

    const prose = PathFilter{ .genera = docs };
    try expect(prose.admits("docs/architecture/README.md"));
    try expect(prose.admits("pkg/kernels/irregex/CHANGELOG.rst"));
    try expect(!prose.admits("services/api/main.go"));
    try expect(!prose.admits("contracts/wire/wire.schema.json")); // data is not prose

    // The negative polarity is the complement of the positive one, path for path.
    const no_prose = PathFilter{ .neg_genera = docs };
    for ([_][]const u8{ "docs/x.md", "services/api/main.go", "contracts/a.json" }) |p|
        try expect(no_prose.admits(p) != prose.admits(p));

    // A selection unions; excluding both leaves only the third.
    var both: genus.Set = .empty;
    both.add(.docs);
    both.add(.data);
    const not_code = PathFilter{ .genera = both };
    try expect(not_code.admits("docs/x.md") and not_code.admits("contracts/a.json"));
    try expect(!not_code.admits("services/api/main.go"));

    // Genus ANDs with the other families rather than widening past them.
    const scoped = PathFilter{ .genera = docs, .roots = &.{"libs"} };
    try expect(scoped.admits("pkg/kernels/irregex/README.md"));
    try expect(!scoped.admits("docs/architecture/README.md")); // right genus, wrong root
    const vetoed = PathFilter{ .genera = docs, .excludes = &.{"**/CHANGELOG.md"} };
    try expect(!vetoed.admits("libs/x/CHANGELOG.md")); // an exclude still wins outright
    try expect(vetoed.admits("libs/x/README.md"));

    // A genus is a narrowing, never a whitelist: `code` is the partition's
    // default, so if it could un-hide, every unrecognized dotfile in `.git/`
    // would be dragged back into a `--code` search.
    try expect(!(PathFilter{ .genera = code }).surfacesHidden(".git/COMMIT_EDITMSG", false));
    try expect(!(PathFilter{ .genera = docs }).surfacesHidden(".github/README.md", false));
    try expect(!(PathFilter{ .neg_genera = docs }).surfacesHidden(".hidden/x.go", false));
    // …whereas a `-g` glob in the same filter still un-hides, unchanged.
    try expect((PathFilter{ .genera = docs, .includes = &.{".github/**"} }).surfacesHidden(".github/README.md", false));
}

test "PathFilter: prune over a mixed corpus keeps exactly the genus asked for" {
    const paths = [_][]const u8{
        "README.md",       "services/api/main.go", "contracts/wire/wire.schema.json",
        "docs/adr/091.md", "libs/x/build.zig",     "quality/registry/tests.toml",
    };
    var docs: genus.Set = .empty;
    docs.add(.docs);

    var ids = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const kept = (PathFilter{ .genera = docs }).prune(&paths, &ids);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, kept);

    // The complement is exhaustive: the three sets partition the corpus with no
    // path counted twice and none dropped on the floor.
    var seen: usize = 0;
    inline for (.{ genus.Genus.docs, .code, .data }) |g| {
        var one: genus.Set = .empty;
        one.add(g);
        var each = [_]u32{ 0, 1, 2, 3, 4, 5 };
        seen += (PathFilter{ .genera = one }).prune(&paths, &each).len;
    }
    try std.testing.expectEqual(paths.len, seen);
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
    try expect(std.mem.eql(u8, scope.normalizeRoot("./services/"), "services"));
    try expect(std.mem.eql(u8, scope.normalizeRoot("libs/x/"), "libs/x"));
    try expect(std.mem.eql(u8, scope.normalizeRoot("services"), "services"));
    try expect(std.mem.eql(u8, scope.normalizeRoot("."), "."));
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
    try types.writeTypeList(a, &out, .{}, null);

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
    try types.writeTypeList(arena.allocator(), &out, .{}, null);
    // Frozen against `rg --type-list` (ripgrep 15.2.0): these rows are pure
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

test "writeTypeList reflects the run's --type-add / --type-clear overlay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A new name appears EXACTLY once. Pinned because the first cut of the merge
    // leaned on a `for … |row| if (…) {…} else …`, where Zig binds the `else` to
    // the `if` rather than the loop — so the row was appended once per
    // non-matching row and the listing carried ~230 copies of it. A count, not a
    // presence check, is the only assertion that catches that.
    var out: std.ArrayList(u8) = .empty;
    try types.writeTypeList(a, &out, .{ .added = &.{.{ .name = "widget", .globs = &.{"*.wid"} }} }, null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\nwidget: *.wid\n"));

    // Extending an existing name UNIONS with the built-in globs (rg's reading)
    // and leaves one row, deduped.
    out = .empty;
    try types.writeTypeList(a, &out, .{ .added = &.{.{ .name = "zig", .globs = &.{ "*.zg", "*.zig" } }} }, null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\nzig: *.zg, *.zig, *.zon\n"));

    // A cleared name is not an empty type, it is no type: gone from the listing.
    out = .empty;
    try types.writeTypeList(a, &out, .{ .cleared = &.{"zig"} }, null);
    try expect(std.mem.indexOf(u8, out.items, "\nzig:") == null);
    try expect(std.mem.indexOf(u8, out.items, "\nzsh:") != null); // a neighbor survives

    // Clear-then-add REPLACES rather than extends — the clear drops the built-in
    // globs and the add supplies the whole definition.
    out = .empty;
    try types.writeTypeList(a, &out, .{
        .added = &.{.{ .name = "zig", .globs = &.{"*.zig"} }},
        .cleared = &.{},
    }, null);
    try expect(std.mem.indexOf(u8, out.items, "\nzig: *.zig, *.zon\n") != null);
}

/// The row a printed type name belongs to, by its canonical spelling. Null for a
/// name the table never had — an overlay type invented for one run.
fn canonicalOf(name: []const u8) ?[]const u8 {
    for (types.type_table) |row| {
        for (row.names) |n| if (std.mem.eql(u8, n, name)) return row.names[0];
    }
    return null;
}

test "writeTypeList narrowed to a genus lists that genus, aliases and all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The listing is how an agent asks "what counts as docs here?" without
    // reading genus.zig, so it must be the SAME roster the filter searches by:
    // every row present answers to the genus asked for, and none of the others do.
    var out: std.ArrayList(u8) = .empty;
    try types.writeTypeList(a, &out, .{}, genus.listingFor(.one(.docs)));
    try expect(std.mem.indexOf(u8, out.items, "\nmarkdown:") != null);
    try expect(std.mem.indexOf(u8, out.items, "\nzig:") == null);
    try expect(std.mem.indexOf(u8, out.items, "\njson:") == null); // data, not prose
    // An ALIAS travels with its row: genus is declared per row, so narrowing must
    // not silently drop the spelling most people type.
    try expect(std.mem.indexOf(u8, out.items, "\nmd:") != null);

    // Every row a narrowed listing prints must really be that genus. Checking the
    // roster wholesale rather than three spot names is what catches a predicate
    // that admits by accident (an `orelse .code` reached for a docs query, say).
    // Each printed name is resolved back to its row before being judged, since
    // the declaration is per row and half the printed names are aliases.
    inline for (comptime std.enums.values(genus.Genus)) |g| {
        out = .empty;
        try types.writeTypeList(a, &out, .{}, genus.listingFor(.one(g)));
        try expect(out.items.len > 0);
        var rows = std.mem.tokenizeScalar(u8, out.items, '\n');
        while (rows.next()) |row| {
            const name = row[0 .. std.mem.indexOfScalar(u8, row, ':') orelse row.len];
            try expect((genus.declaredFor(canonicalOf(name) orelse name) orelse .code) == g);
        }
    }

    // An empty selection is the rg-parity listing — the whole table, untouched.
    out = .empty;
    try types.writeTypeList(a, &out, .{}, genus.listingFor(.empty));
    try expect(std.mem.indexOf(u8, out.items, "\nzig:") != null);
    try expect(std.mem.indexOf(u8, out.items, "\nmarkdown:") != null);

    // An overlay is judged by the same predicate, so a narrowed listing cannot be
    // widened back through --type-add. `notes` is nobody's declared type, so it
    // takes the default direction (code) exactly as an unrecognized FILE would.
    const overlay: types.Overlay = .{ .added = &.{.{ .name = "notes", .globs = &.{"*.note"} }} };
    out = .empty;
    try types.writeTypeList(a, &out, overlay, genus.listingFor(.one(.docs)));
    try expect(std.mem.indexOf(u8, out.items, "\nnotes:") == null);
    out = .empty;
    try types.writeTypeList(a, &out, overlay, genus.listingFor(.one(.code)));
    try expect(std.mem.indexOf(u8, out.items, "\nnotes: *.note\n") != null);
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
