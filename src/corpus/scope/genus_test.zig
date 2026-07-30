//! The corpus partition, judged against its contract rather than itself.
//!
//! Every expectation below is derived from what the path IS — GitHub Linguist's
//! category for that language, or one of the two rules `genus.zig` states in
//! prose — and never from running the classifier and recording what came back.
//! The adverse cases are the ones that carry the argument: a source file under
//! `docs/`, a documentation stem wearing a code extension, and the paths
//! Linguist would classify differently than we deliberately do.

const std = @import("std");
const genus = @import("genus.zig");
const types = @import("types.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// One row of the oracle: a path, and the genus its nature demands.
const Case = struct { path: []const u8, want: genus.Genus, why: []const u8 };

test "prose extensions are docs (Linguist type: prose)" {
    const cases = [_]Case{
        .{ .path = "README.md", .want = .docs, .why = "Markdown — Linguist prose" },
        .{ .path = "docs/architecture/cognition.md", .want = .docs, .why = "Markdown at depth" },
        .{ .path = "guide/intro.rst", .want = .docs, .why = "reStructuredText — Linguist prose" },
        .{ .path = "notes.adoc", .want = .docs, .why = "AsciiDoc — Linguist prose" },
        .{ .path = "plan.org", .want = .docs, .why = "Org — Linguist prose" },
        .{ .path = "notes.txt", .want = .docs, .why = "Text — Linguist prose" },
        .{ .path = "paper.tex", .want = .docs, .why = "TeX — authoring language" },
        .{ .path = "gist.1", .want = .docs, .why = "roff man page — irregular glob *.[0-9lnpx]" },
        .{ .path = ".cursor/rules/irregex.mdc", .want = .docs, .why = "Cursor rule — prose instructions" },
        .{ .path = "LICENSE", .want = .docs, .why = "license type carries it" },
        .{ .path = "COPYING", .want = .docs, .why = "license type carries it" },
        .{ .path = "vendor/pcre2/COPYING.md", .want = .docs, .why = "license, at depth" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "serialization and configuration are data (Linguist type: data)" {
    const cases = [_]Case{
        .{ .path = "package.json", .want = .data, .why = "JSON — Linguist data" },
        .{ .path = "infra/pulumi/Pulumi.production.yaml", .want = .data, .why = "YAML — Linguist data" },
        .{ .path = "contracts/domain/tools/nouns.toml", .want = .data, .why = "TOML — Linguist data" },
        .{ .path = "Cargo.lock", .want = .data, .why = "lockfile — bare-name glob in the toml row" },
        .{ .path = "pnpm-lock.yaml", .want = .data, .why = "YAML lockfile" },
        .{ .path = "rows.csv", .want = .data, .why = "CSV — Linguist data" },
        .{ .path = "app.log", .want = .data, .why = "log payload" },
        .{ .path = "fix.patch", .want = .data, .why = "a patch is data about code, not code" },
        .{ .path = "icon.svg", .want = .data, .why = "an image, not source you change behavior in" },
        .{ .path = "billy.service", .want = .data, .why = "systemd unit — INI values, no expressions" },
        .{ .path = "corpus.tar.gz", .want = .data, .why = "compressed bytes" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "source, build recipes, and IDLs are code" {
    const cases = [_]Case{
        .{ .path = "src/corpus/scope/genus.zig", .want = .code, .why = "Zig" },
        .{ .path = "services/ai/graph/build.py", .want = .code, .why = "Python" },
        .{ .path = "clients/web/src/App.tsx", .want = .code, .why = "TSX" },
        .{ .path = "Makefile", .want = .code, .why = "build recipe" },
        .{ .path = "scripts/mk/lint.mk", .want = .code, .why = "make fragment" },
        .{ .path = "CMakeLists.txt", .want = .code, .why = "build recipe, not the *.txt prose type" },
        .{ .path = "infra/Dockerfile", .want = .code, .why = "contains-glob *Dockerfile*" },
        .{ .path = "contracts/wire/proto/chat.proto", .want = .code, .why = "IDL compiled into code" },
        .{ .path = "schema.graphql", .want = .code, .why = "IDL" },
        .{ .path = "queries/wallet.sql", .want = .code, .why = "SQL is source" },
        .{ .path = "main.tf", .want = .code, .why = "Terraform has expressions" },
        .{ .path = "policy.cedar", .want = .code, .why = "policy as code" },
        .{ .path = "styles/app.css", .want = .code, .why = "Linguist markup, the UI half" },
        .{ .path = "notebook.ipynb", .want = .code, .why = "a notebook's cells hold source" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "code is the default, so an unrecognized path is never hidden from --code" {
    // The whole safety argument: a gap in the type table costs `--code` one
    // extra line, never a silent miss. There is no fourth genus to fall into.
    const cases = [_]Case{
        .{ .path = "tool.qqzzx", .want = .code, .why = "extension nothing recognizes" },
        .{ .path = "bin/gist", .want = .code, .why = "no extension at all" },
        .{ .path = "weird.name.with.dots", .want = .code, .why = "dotted but unrecognized" },
        .{ .path = "", .want = .code, .why = "the empty path must not crash or be docs" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "a documentation location promotes only what nothing else recognized" {
    // Spelling decides first; location speaks for the unclaimed. This is the
    // divergence from Linguist that keeps `--code` honest.
    const cases = [_]Case{
        .{ .path = "docs/CONVENTIONS", .want = .docs, .why = "extensionless under docs/" },
        .{ .path = "doc/notes", .want = .docs, .why = "singular doc/ counts too" },
        .{ .path = "man/gist", .want = .docs, .why = "man/ is a doc directory" },
        .{ .path = "Documentation/kernel", .want = .docs, .why = "case-insensitive, as Linguist's [Dd]" },
        .{ .path = "services/ai/docs/OVERVIEW", .want = .docs, .why = "doc dir at depth (monorepo divergence)" },
        // The promotions that must NOT happen.
        .{ .path = "docs/conf.py", .want = .code, .why = "Sphinx config is still Python source" },
        .{ .path = "docs/site/App.tsx", .want = .code, .why = "a docs-site component is still source" },
        .{ .path = "docs/data.json", .want = .data, .why = "recognized as data before location speaks" },
        .{ .path = "docs/Makefile", .want = .code, .why = "a build recipe under docs/ is a build recipe" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "a documentation stem promotes an extensionless paper trail" {
    const cases = [_]Case{
        .{ .path = "CHANGELOG", .want = .docs, .why = "Linguist CHANGE(S|LOG)" },
        .{ .path = "CHANGELOG.old", .want = .docs, .why = "stem is the changelog; .old is unrecognized" },
        .{ .path = "CONTRIBUTING", .want = .docs, .why = "Linguist documentation file" },
        .{ .path = "INSTALL", .want = .docs, .why = "Linguist documentation file" },
        .{ .path = "CITATION", .want = .docs, .why = "Linguist documentation file" },
        .{ .path = "pkg/kernels/irregex/AUTHORS", .want = .docs, .why = "paper trail at depth" },
        .{ .path = "todo", .want = .docs, .why = "case-insensitive" },
        // A documentation NAME cannot outrank a code spelling either.
        .{ .path = "security.py", .want = .code, .why = "a Python module named security is code" },
        .{ .path = "history.ts", .want = .code, .why = "a TS module named history is code" },
        .{ .path = "news.json", .want = .data, .why = "recognized as data first" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "examples and samples are code, diverging from Linguist on purpose" {
    // Linguist excludes these from language statistics, where over-exclusion is
    // free. For retrieval it is a silent miss, so they stay searchable as code.
    const cases = [_]Case{
        .{ .path = "examples/basic.py", .want = .code, .why = "example source is source" },
        .{ .path = "examples/NOTES", .want = .code, .why = "not a doc dir here, so no promotion" },
        .{ .path = "demos/app.ts", .want = .code, .why = "demo source is source" },
        .{ .path = "samples/main.go", .want = .code, .why = "sample source is source" },
        .{ .path = "examples/README.md", .want = .docs, .why = "still docs — by its own spelling" },
    };
    for (cases) |c| expectEqual(c.want, genus.of(c.path)) catch |e| {
        std.debug.print("{s} ({s})\n", .{ c.path, c.why });
        return e;
    };
}

test "the partition is total and disjoint" {
    // Totality is structural (`of` returns a Genus), so what needs proving is
    // that each genus is actually reachable and that the three names round-trip.
    var seen: genus.Set = .empty;
    for ([_][]const u8{ "a.md", "a.json", "a.zig" }) |p| seen.add(genus.of(p));
    try expect(seen.docs and seen.data and seen.code);
    inline for (.{ genus.Genus.code, genus.Genus.docs, genus.Genus.data }) |g| {
        const back = genus.named(g.label()) orelse return error.NameDidNotRoundTrip;
        try expect(back.has(g));
    }
}

test "genus names and their aliases resolve; other names do not" {
    try expect(genus.named("docs").?.has(.docs));
    try expect(genus.named("doc").?.has(.docs));
    try expect(genus.named("prose").?.has(.docs));
    try expect(genus.named("code").?.has(.code));
    try expect(genus.named("source").?.has(.code));
    try expect(genus.named("data").?.has(.data));
    // A language type is NOT a genus name — the two namespaces must not blur,
    // or `-t md` would silently widen to every prose format.
    for ([_][]const u8{ "md", "py", "all", "zig", "docsx", "" }) |n|
        try expect(genus.named(n) == null);
}

test "a genus set unions and never leaks between members" {
    var s: genus.Set = .empty;
    try expect(!s.any());
    s.add(.docs);
    try expect(s.any() and s.has(.docs) and !s.has(.code) and !s.has(.data));
    s.add(.data);
    try expect(s.has(.docs) and s.has(.data) and !s.has(.code));
}

test "an alias resolves to its row's genus, not to the default" {
    // The comptime proof in genus.zig gates that every row is classified; this
    // pins that a row's SECOND name reaches the same answer, since the globs
    // are shared and only the canonical name is classified.
    try expectEqual(genus.of("a.py"), genus.of("a.pyi")); // py/python row
    try expectEqual(genus.Genus.code, genus.of("a.rs")); // rust/rs row
    try expectEqual(genus.Genus.docs, genus.of("a.markdown")); // markdown/md row
    try expectEqual(genus.Genus.data, genus.of("a.yml")); // yaml/yml row
}

/// Substitute a concrete path for a glob: `*` → a filler, a character class →
/// its first member. Enough for the whole type table, which uses no braces,
/// `?`, or negated classes — asserted below so a new glob shape cannot slip
/// past unnoticed.
///
/// The filler has to be a string NOTHING else in the table claims, or the stub
/// answers a different question than the one asked: a single `x` made
/// `gradle-wrapper.*` instantiate as `gradle-wrapper.x`, which the man type's
/// `*.[0-9lnpx]` legitimately claims, and the oracle reported a collision that
/// no real path has.
const filler = "stub";

fn instantiate(pattern: []const u8, buf: []u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) switch (pattern[i]) {
        '*' => {
            @memcpy(buf[n..][0..filler.len], filler);
            n += filler.len;
        },
        '[' => {
            const close = std.mem.indexOfScalarPos(u8, pattern, i, ']') orelse return error.UnclosedClass;
            const member = pattern[i + 1];
            if (member == '!' or member == '^') return error.NegatedClassNeedsAWiderStub;
            buf[n] = member;
            n += 1;
            i = close;
        },
        '?', '{', '}' => return error.GlobShapeNeedsAWiderStub,
        else => {
            buf[n] = pattern[i];
            n += 1;
        },
    };
    return buf[0..n];
}

test "every glob in the type table classifies as its own row's genus" {
    // The exhaustive oracle, and the one that would catch a shadowing
    // regression anywhere in 223 rows: instantiate each of the ~1000 globs and
    // demand the partition agree with the list that row is declared in. The
    // expectation comes from genus.zig's DECLARATION, not from `of`'s output.
    //
    // One documented dispute, and it is a genuine one rather than a bug: two
    // rows claim `*.conf` from opposite genera — BitBake's recipe includes
    // (code) and systemd/config units (data). Data wins, because a bare
    // `.conf` file is configuration to everyone who is not building Yocto,
    // and because the loss is bounded the safe way: `--code` still shows it
    // (nothing is hidden), it is only `--docs`/`--data` that gains a file.
    const disputed = [_]struct { type_name: []const u8, glob: []const u8, resolved: genus.Genus }{
        .{ .type_name = "bitbake", .glob = "*.conf", .resolved = .data },
    };

    var buf: [256]u8 = undefined;
    var checked: usize = 0;
    var fired = [_]bool{false} ** disputed.len;
    for (types.type_table) |row| {
        const name = row.names[0];
        const declared = declaredGenus(name);
        for (row.globs) |pattern| {
            if (pattern.len == 0) continue;
            const path = try instantiate(pattern, &buf);
            const got = genus.of(path);
            checked += 1;
            if (got == declared) continue;
            for (disputed, 0..) |d, i| {
                if (std.mem.eql(u8, d.type_name, name) and std.mem.eql(u8, d.glob, pattern) and got == d.resolved) {
                    fired[i] = true;
                    break;
                }
            } else {
                std.debug.print(
                    "-t {s} is declared {s}, but its glob {s} (as {s}) classifies as {s}\n",
                    .{ name, declared.label(), pattern, path, got.label() },
                );
                return error.GlobDisagreesWithItsRow;
            }
        }
    }
    // A dispute that stopped disputing is a stale exception, and leaving it
    // listed would quietly license a future collision on the same glob.
    for (disputed, fired) |d, hit| if (!hit) {
        std.debug.print("-t {s} {s} is listed as disputed but no longer is\n", .{ d.type_name, d.glob });
        return error.StaleDisputeEntry;
    };
    // Guard the oracle itself: a table that stopped yielding globs would make
    // every assertion above vacuously true.
    if (checked < 600) {
        std.debug.print("only {d} globs reached the oracle\n", .{checked});
        return error.OracleWentQuiet;
    }
}

/// Which list does `genus.zig` declare this type in? Read back through `of` on a
/// path only that row can claim would be circular, so this asks the module.
fn declaredGenus(name: []const u8) genus.Genus {
    return genus.declaredFor(name) orelse unreachable; // the comptime proof forbids null
}
