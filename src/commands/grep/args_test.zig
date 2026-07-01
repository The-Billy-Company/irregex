//! Adversarial tests for the ripgrep-compatible grep argv parser. Every case
//! here is a reflexive agent invocation that used to fail (silent wrong scope,
//! or a fail-loud on a legal cluster / no-op flag). The parser is the surface
//! an agent's muscle memory hits first, so a regression here reads as "gist is
//! broken" — hence the coverage of bundling, no-ops, long flags, smart-case,
//! and positional path scoping, plus the fail-loud contract for real errors.

const std = @import("std");
const ga = @import("args.zig");
const expect = std.testing.expect;
const eqs = std.mem.eql;
const A = std.testing.allocator;

fn parse(args: []const []const u8) !?ga.Parsed {
    return ga.parseGrep(A, args);
}

test "bare pattern, no flags" {
    var p = (try parse(&.{"WalletService"})).?;
    defer p.deinit(A);
    try expect(eqs(u8, p.pattern, "WalletService"));
    try expect(p.opts.filter.isEmpty());
}

test "positional PATH args become filter roots (the silent-scope fix)" {
    var p = (try parse(&.{ "WalletService", "services/backend/api", "./libs/" })).?;
    defer p.deinit(A);
    try expect(p.opts.filter.roots.len == 2);
    // normalizeRoot strips leading ./ and trailing /
    try expect(eqs(u8, p.opts.filter.roots[0], "services/backend/api"));
    try expect(eqs(u8, p.opts.filter.roots[1], "libs"));
    try expect(p.opts.filter.admits("services/backend/api/wallet.go"));
    try expect(p.opts.filter.admits("libs/x/y.zig"));
    try expect(!p.opts.filter.admits("clients/web/app.ts"));
    // a directory root must respect the '/' boundary (no prefix bleed)
    try expect(!p.opts.filter.admits("services/backend/apiv2/x.go"));
}

test "bundled boolean short flags: -ln -in -nw -li" {
    {
        var p = (try parse(&.{ "-ln", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_only); // l
    } // n is a no-op
    {
        var p = (try parse(&.{ "-in", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless); // i
    }
    {
        var p = (try parse(&.{ "-nw", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.word); // w
    }
    {
        var p = (try parse(&.{ "-li", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_only and p.opts.caseless);
    }
}

test "value flag terminates a cluster: -nC3, glued -A2, split -B 4" {
    {
        var p = (try parse(&.{ "-nC3", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.before == 3 and p.opts.after == 3);
    }
    {
        var p = (try parse(&.{ "-A2", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.after == 2);
    }
    {
        var p = (try parse(&.{ "-B", "4", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.before == 4);
    }
}

test "glued and split -t / -g" {
    {
        var p = (try parse(&.{ "-tgo", "pgxpool" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.exts.len > 0);
        try expect(p.opts.filter.admits("services/api/main.go"));
    }
    {
        var p = (try parse(&.{ "-g", "*.ts", "import" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.includes.len == 1);
    }
    {
        var p = (try parse(&.{ "-g!*_test.go", "foo" })).?; // exclude via ! prefix
        defer p.deinit(A);
        try expect(p.opts.filter.excludes.len == 1);
        try expect(!p.opts.filter.admits("x_test.go"));
    }
}

test "-n is an accepted no-op; -N drops the line column" {
    {
        var p = (try parse(&.{ "-n", "foo" })).?; // used to fail loud
        defer p.deinit(A);
        try expect(!p.opts.no_line_num);
    }
    {
        var p = (try parse(&.{ "-N", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.no_line_num);
    }
}

test "-S smart-case: fold iff the pattern has no uppercase" {
    {
        var p = (try parse(&.{ "-S", "wallet" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless); // all-lowercase ⇒ caseless
    }
    {
        var p = (try parse(&.{ "-S", "Wallet" })).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless); // has uppercase ⇒ case-sensitive
    }
}

test "long flags with = and with a following token" {
    {
        var p = (try parse(&.{ "--ignore-case", "--context=2", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless and p.opts.before == 2 and p.opts.after == 2);
    }
    {
        var p = (try parse(&.{ "--type", "go", "--max-count", "5", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.exts.len > 0 and p.opts.max_per_file == 5);
    }
    {
        var p = (try parse(&.{ "--glob=*.rs", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.includes.len == 1);
    }
}

test "no-op long flags are accepted; --color swallows its value" {
    var p = (try parse(&.{ "--no-heading", "--color=never", "--with-filename", "foo" })).?;
    defer p.deinit(A);
    try expect(eqs(u8, p.pattern, "foo"));
    {
        var q = (try parse(&.{ "--color", "always", "foo" })).?; // separate-token value
        defer q.deinit(A);
        try expect(eqs(u8, q.pattern, "foo"));
    }
}

test "-e sets the pattern explicitly (leading-dash safe)" {
    var p = (try parse(&.{ "-e", "-n", "services" })).?;
    defer p.deinit(A);
    try expect(eqs(u8, p.pattern, "-n"));
    try expect(p.opts.filter.roots.len == 1); // 'services' is then a path root
}

test "-- ends flag parsing" {
    var p = (try parse(&.{ "--", "-n" })).?;
    defer p.deinit(A);
    try expect(eqs(u8, p.pattern, "-n"));
}

test "-o only-matching: short cluster and long spelling" {
    {
        var p = (try parse(&.{ "-o", "func \\w+" })).?;
        defer p.deinit(A);
        try expect(p.opts.only_matching);
    }
    {
        var p = (try parse(&.{ "-no", "func" })).?; // bundled with the -n no-op
        defer p.deinit(A);
        try expect(p.opts.only_matching);
    }
    {
        var p = (try parse(&.{ "--only-matching", "func" })).?;
        defer p.deinit(A);
        try expect(p.opts.only_matching);
    }
}

test "--files: pattern-optional, all non-flags are roots" {
    {
        var p = (try parse(&.{"--files"})).?; // no pattern needed
        defer p.deinit(A);
        try expect(p.opts.files_list);
        try expect(eqs(u8, p.pattern, ""));
        try expect(p.opts.filter.roots.len == 0); // whole corpus
    }
    {
        var p = (try parse(&.{ "--files", "services/backend/api", "libs/" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_list);
        try expect(p.opts.filter.roots.len == 2); // both tokens are roots, neither a pattern
        try expect(p.opts.filter.admits("services/backend/api/x.go"));
    }
    {
        var p = (try parse(&.{ "--files", "-t", "go" })).?; // --files + type scope
        defer p.deinit(A);
        try expect(p.opts.files_list and p.opts.filter.exts.len > 0);
    }
    {
        var p = (try parse(&.{ "services", "--files" })).?; // --files after a token: still a root
        defer p.deinit(A);
        try expect(p.opts.files_list and p.opts.filter.roots.len == 1);
        try expect(eqs(u8, p.pattern, ""));
    }
}

test "-r/--replace consumes a value (the silent-misparse landmine fix)" {
    // The bug: `-r` was a boolean no-op, so `-r X pat` parsed X as the pattern
    // and pat as a path root — a confident empty result. It must consume X.
    {
        var p = (try parse(&.{ "-r", "X", "pgxpool" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "pgxpool")); // pattern is pgxpool, NOT X
        try expect(p.opts.replace != null and eqs(u8, p.opts.replace.?, "X"));
        try expect(p.opts.filter.roots.len == 0); // pgxpool is the pattern, not a root
    }
    { // glued short value + bundled with -o, plus the long spelling
        var p = (try parse(&.{ "-o", "-rREPL", "pat" })).?;
        defer p.deinit(A);
        try expect(p.opts.only_matching and eqs(u8, p.opts.replace.?, "REPL"));
    }
    {
        var p = (try parse(&.{ "--replace=$0!", "pat" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.opts.replace.?, "$0!"));
    }
    try expect((try parse(&.{ "-r", "$1", "pat" })) == null); // group ref rejected loud
    try expect((try parse(&.{ "--replace=${2}", "pat" })) == null); // braced group ref too
    try expect((try parse(&.{"-r"})) == null); // missing value fails loud
}

test "leading inline flag group (?i)/(?-u)/(?m) honored; (?s) rejected" {
    {
        var p = (try parse(&.{"(?i)wallet"})).?;
        defer p.deinit(A);
        try expect(p.opts.caseless and eqs(u8, p.pattern, "wallet")); // group stripped
    }
    {
        var p = (try parse(&.{"(?-u)func"})).?; // byte mode = gist default ⇒ no-op strip
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "func"));
    }
    {
        var p = (try parse(&.{"(?im)Foo"})).?; // multiline is gist's default (per-line)
        defer p.deinit(A);
        try expect(p.opts.caseless and eqs(u8, p.pattern, "Foo"));
    }
    {
        var p = (try parse(&.{"(?-i)Foo"})).?; // explicit case-sensitive
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "Foo"));
    }
    { // a non-capturing group is NOT a flag group — left intact for the compiler
        var p = (try parse(&.{"(?:foo|bar)"})).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "(?:foo|bar)"));
    }
    { // `-F` makes `(?i)` a literal string, not a flag
        var p = (try parse(&.{ "-F", "(?i)x" })).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "(?i)x"));
    }
    try expect((try parse(&.{"(?s)a.*b"})) == null); // dotall — gist can't, fail loud
    {
        var p = (try parse(&.{"(?-s)ab"})).?; // dotall OFF is already the default ⇒ ok
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "ab"));
    }
}

test "--count-matches is distinct from --count (the silent-wrong-count fix)" {
    // The bug: `--count-matches` aliased to `--count`, so it counted matching
    // LINES, not match spans — a silent-wrong result on any line with >1 match
    // (`e` → 165 lines vs 988 matches). They must set different options.
    {
        var p = (try parse(&.{ "--count-matches", "e" })).?;
        defer p.deinit(A);
        try expect(p.opts.count_matches and !p.opts.count_only);
    }
    {
        var p = (try parse(&.{ "--count", "e" })).?;
        defer p.deinit(A);
        try expect(p.opts.count_only and !p.opts.count_matches);
    }
    {
        var p = (try parse(&.{ "-c", "e" })).?; // short spelling stays line-count
        defer p.deinit(A);
        try expect(p.opts.count_only and !p.opts.count_matches);
    }
}

test "corpus-policy no-ops gist already satisfies are accepted, not fail-loud" {
    // gist's corpus ignores `.gitignore` and includes hidden dotfiles (README
    // "Scope vs ripgrep"), so these rg flags ask for what gist already does.
    for ([_][]const u8{ "--hidden", "--no-ignore", "--no-ignore-vcs", "--no-ignore-parent", "--no-ignore-dot", "--unrestricted", "--one-file-system" }) |f| {
        var p = (try parse(&.{ f, "WalletService" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "WalletService"));
    }
    { // `-u` / `-uu` short (repeatable --unrestricted), incl. bundled with -i
        var p = (try parse(&.{ "-uu", "wallet" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "wallet"));
    }
    {
        var p = (try parse(&.{ "-iu", "wallet" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless and eqs(u8, p.pattern, "wallet"));
    }
}

test "--sort/--sortr swallow their value (gist emits path-ascending already)" {
    {
        var p = (try parse(&.{ "--sort", "path", "foo" })).?; // separate-token value
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo") and p.opts.filter.roots.len == 0);
    }
    {
        var p = (try parse(&.{ "--sort=path", "foo" })).?; // glued value
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo"));
    }
    {
        var p = (try parse(&.{ "--sortr", "modified", "foo" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo"));
    }
    try expect((try parse(&.{"--sort"})) == null); // missing value still fails loud
}

test "recognized-but-unsupportable flags fail LOUD (never silent-wrong)" {
    // A different engine / output model — fail loud with guidance, but crucially
    // NOT silently ignored (which would give a wrong result on a PCRE/multiline
    // pattern). Each returns null (the fail-loud sentinel).
    try expect((try parse(&.{ "-P", "(?<=x)y" })) == null); // PCRE lookbehind
    try expect((try parse(&.{ "--pcre2", "a" })) == null);
    try expect((try parse(&.{ "-U", "a\\nb" })) == null); // multiline short
    try expect((try parse(&.{ "--multiline", "a" })) == null);
    try expect((try parse(&.{ "--multiline-dotall", "a" })) == null);
    try expect((try parse(&.{ "--json", "a" })) == null);
    try expect((try parse(&.{ "--vimgrep", "a" })) == null);
    try expect((try parse(&.{ "--column", "a" })) == null);
}

test "type aliases: tsx, jsx, rego, mdc resolve" {
    for ([_][]const u8{ "tsx", "jsx", "rego", "mdc", "vue", "svelte", "cedar" }) |t| {
        var p = (try parse(&.{ "-t", t, "x" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.exts.len > 0);
    }
}

test "fail loud: unknown short flag, unknown long flag, missing value, no pattern" {
    try expect((try parse(&.{ "-Z", "foo" })) == null); // unknown short
    try expect((try parse(&.{ "-nZ", "foo" })) == null); // unknown inside a cluster
    try expect((try parse(&.{"--frobnicate"})) == null); // unknown long
    try expect((try parse(&.{"-A"})) == null); // missing value
    try expect((try parse(&.{"--context"})) == null); // missing long value
    try expect((try parse(&.{ "-t", "cobol", "x" })) == null); // unknown type
    try expect((try parse(&.{})) == null); // no pattern
    try expect((try parse(&.{ "-i", "-l" })) == null); // flags but no pattern
}
