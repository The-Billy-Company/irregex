//! Adversarial tests for the `gist search` argv parser — BOTH flag sets.
//!
//! Set B (native) is the primary surface: `--show`, `--rank`, `--lang`, `--word`,
//! `--fixed`, `--ignore-case`, `--live`, `--json`, `--pattern`, … Set A (legacy)
//! is every ripgrep/grep spelling an agent's muscle memory types, each an alias
//! onto exactly one native option. This file proves the two sets are wired to the
//! SAME `Options` (a native flag and its legacy alias set identical state), that
//! the reflexive-invocation fixes the grep parser earned still hold (bundling,
//! no-ops, positional scope, the `-r`/`--count-matches`/inline-flag landmines),
//! and that the two genuinely-new capabilities (`--live`, `--json`) parse where
//! the old parser failed loud — while the truly-unsupportable flags still do.

const std = @import("std");
const ga = @import("args.zig");
const expect = std.testing.expect;
const eqs = std.mem.eql;
const A = std.testing.allocator;

fn parse(argv: []const []const u8) !?ga.Parsed {
    return ga.parseSearch(A, argv);
}

// ─────────────────────────── native (Set B) ───────────────────────────

test "native --show selects the output shape" {
    {
        var p = (try parse(&.{ "--show", "files", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_only and !p.opts.count_only and !p.opts.ranked);
    }
    {
        var p = (try parse(&.{ "--show=count", "foo" })).?; // glued value
        defer p.deinit(A);
        try expect(p.opts.count_only and !p.opts.files_only);
    }
    {
        var p = (try parse(&.{ "--show", "ranked", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.ranked);
    }
    {
        var p = (try parse(&.{ "--show", "lines", "foo" })).?; // the explicit default
        defer p.deinit(A);
        try expect(!p.opts.files_only and !p.opts.count_only and !p.opts.ranked);
    }
    try expect((try parse(&.{ "--show", "bogus", "foo" })) == null); // unknown mode fails loud
    try expect((try parse(&.{"--show"})) == null); // missing value fails loud
}

test "native --rank[=N] is shorthand for --show ranked, top-K default" {
    {
        var p = (try parse(&.{ "--rank", "wallet" })).?;
        defer p.deinit(A);
        try expect(p.opts.ranked and p.opts.rank_k == 0); // 0 ⇒ engine default (20)
    }
    {
        var p = (try parse(&.{ "--rank=5", "wallet" })).?;
        defer p.deinit(A);
        try expect(p.opts.ranked and p.opts.rank_k == 5);
    }
    try expect((try parse(&.{ "--rank=abc", "x" })) == null); // non-numeric fails loud
}

test "native --lang is the primary spelling; -t/--type alias onto it" {
    var native = (try parse(&.{ "--lang", "go", "pgxpool" })).?;
    defer native.deinit(A);
    var legacy_short = (try parse(&.{ "-t", "go", "pgxpool" })).?;
    defer legacy_short.deinit(A);
    var legacy_long = (try parse(&.{ "--type", "go", "pgxpool" })).?;
    defer legacy_long.deinit(A);
    // all three resolve to the same extension set + admit the same path
    try expect(native.opts.filter.exts.len == legacy_short.opts.filter.exts.len);
    try expect(native.opts.filter.exts.len == legacy_long.opts.filter.exts.len);
    try expect(native.opts.filter.admits("services/api/main.go"));
    try expect(legacy_short.opts.filter.admits("services/api/main.go"));
    try expect((try parse(&.{ "--lang", "cobol", "x" })) == null); // unknown lang fails loud
}

test "native booleans set the same state as their legacy aliases" {
    const Case = struct { native: []const []const u8, legacy: []const []const u8, get: *const fn (ga.Options) bool };
    const cases = [_]Case{
        .{ .native = &.{ "--word", "f" }, .legacy = &.{ "-w", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.word;
            }
        }.g },
        .{ .native = &.{ "--fixed", "f" }, .legacy = &.{ "-F", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.fixed;
            }
        }.g },
        .{ .native = &.{ "--ignore-case", "f" }, .legacy = &.{ "-i", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.caseless;
            }
        }.g },
        .{ .native = &.{ "--invert", "f" }, .legacy = &.{ "-v", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.invert;
            }
        }.g },
        .{ .native = &.{ "--only-matching", "f" }, .legacy = &.{ "-o", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.only_matching;
            }
        }.g },
        .{ .native = &.{ "--spans", "f" }, .legacy = &.{ "--count-matches", "f" }, .get = struct {
            fn g(o: ga.Options) bool {
                return o.count_matches;
            }
        }.g },
    };
    for (cases) |c| {
        var n = (try parse(c.native)).?;
        defer n.deinit(A);
        var l = (try parse(c.legacy)).?;
        defer l.deinit(A);
        try expect(c.get(n.opts) and c.get(l.opts));
    }
}

test "native --before/--after/--context alias -B/-A/-C" {
    {
        var p = (try parse(&.{ "--context", "2", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.before == 2 and p.opts.after == 2);
    }
    {
        var p = (try parse(&.{ "--before=3", "--after", "4", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.before == 3 and p.opts.after == 4);
    }
}

test "native --limit aliases -m/--max-count" {
    var native = (try parse(&.{ "--limit", "5", "foo" })).?;
    defer native.deinit(A);
    var legacy = (try parse(&.{ "-m", "5", "foo" })).?;
    defer legacy.deinit(A);
    try expect(native.opts.max_per_file == 5 and legacy.opts.max_per_file == 5);
}

test "native --smart-case folds iff the pattern has no uppercase" {
    {
        var p = (try parse(&.{ "--smart-case", "wallet" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless);
    }
    {
        var p = (try parse(&.{ "--smart-case", "Wallet" })).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless);
    }
}

test "native --pattern sets the pattern explicitly (leading-dash safe)" {
    var native = (try parse(&.{ "--pattern", "-n", "services" })).?;
    defer native.deinit(A);
    try expect(eqs(u8, native.pattern, "-n") and native.opts.filter.roots.len == 1);
    var legacy = (try parse(&.{ "-e", "-n", "services" })).?; // -e alias
    defer legacy.deinit(A);
    try expect(eqs(u8, legacy.pattern, "-n"));
}

test "native --live parses (the new index-free capability)" {
    var p = (try parse(&.{ "--live", "WalletService", "services/" })).?;
    defer p.deinit(A);
    try expect(p.opts.live and eqs(u8, p.pattern, "WalletService"));
    try expect(p.opts.filter.roots.len == 1);
}

test "native --json parses where the old parser failed loud" {
    var p = (try parse(&.{ "--json", "foo" })).?;
    defer p.deinit(A);
    try expect(p.opts.json and eqs(u8, p.pattern, "foo"));
    { // --json composes with a shape and a filter
        var q = (try parse(&.{ "--json", "--show", "files", "-t", "go", "foo" })).?;
        defer q.deinit(A);
        try expect(q.opts.json and q.opts.files_only and q.opts.filter.exts.len > 0);
    }
}

test "native --glob aliases -g and keeps the ! exclude convention" {
    var native = (try parse(&.{ "--glob", "*.ts", "import" })).?;
    defer native.deinit(A);
    try expect(native.opts.filter.includes.len == 1);
    var excl = (try parse(&.{ "--glob=!*_test.go", "foo" })).?;
    defer excl.deinit(A);
    try expect(excl.opts.filter.excludes.len == 1 and !excl.opts.filter.admits("x_test.go"));
}

// ─────────────────────────── legacy (Set A) — the grep-parity battery ───────────────────────────

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
    try expect(eqs(u8, p.opts.filter.roots[0], "services/backend/api"));
    try expect(eqs(u8, p.opts.filter.roots[1], "libs"));
    try expect(p.opts.filter.admits("services/backend/api/wallet.go"));
    try expect(p.opts.filter.admits("libs/x/y.zig"));
    try expect(!p.opts.filter.admits("clients/web/app.ts"));
    try expect(!p.opts.filter.admits("services/backend/apiv2/x.go"));
}

test "bundled boolean short flags: -ln -in -nw -li" {
    {
        var p = (try parse(&.{ "-ln", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_only);
    }
    {
        var p = (try parse(&.{ "-in", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.caseless);
    }
    {
        var p = (try parse(&.{ "-nw", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.word);
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
        var p = (try parse(&.{ "-g!*_test.go", "foo" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.excludes.len == 1);
        try expect(!p.opts.filter.admits("x_test.go"));
    }
}

test "-n is an accepted no-op; -N drops the line column" {
    {
        var p = (try parse(&.{ "-n", "foo" })).?;
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
        try expect(p.opts.caseless);
    }
    {
        var p = (try parse(&.{ "-S", "Wallet" })).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless);
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
        var q = (try parse(&.{ "--color", "always", "foo" })).?;
        defer q.deinit(A);
        try expect(eqs(u8, q.pattern, "foo"));
    }
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
        var p = (try parse(&.{ "-no", "func" })).?;
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
        var p = (try parse(&.{"--files"})).?;
        defer p.deinit(A);
        try expect(p.opts.files_list);
        try expect(eqs(u8, p.pattern, ""));
        try expect(p.opts.filter.roots.len == 0);
    }
    {
        var p = (try parse(&.{ "--files", "services/backend/api", "libs/" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_list);
        try expect(p.opts.filter.roots.len == 2);
        try expect(p.opts.filter.admits("services/backend/api/x.go"));
    }
    {
        var p = (try parse(&.{ "--files", "-t", "go" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_list and p.opts.filter.exts.len > 0);
    }
    {
        var p = (try parse(&.{ "services", "--files" })).?;
        defer p.deinit(A);
        try expect(p.opts.files_list and p.opts.filter.roots.len == 1);
        try expect(eqs(u8, p.pattern, ""));
    }
}

test "-r/--replace consumes a value (the silent-misparse landmine fix)" {
    {
        var p = (try parse(&.{ "-r", "X", "pgxpool" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "pgxpool"));
        try expect(p.opts.replace != null and eqs(u8, p.opts.replace.?, "X"));
        try expect(p.opts.filter.roots.len == 0);
    }
    {
        var p = (try parse(&.{ "-o", "-rREPL", "pat" })).?;
        defer p.deinit(A);
        try expect(p.opts.only_matching and eqs(u8, p.opts.replace.?, "REPL"));
    }
    {
        var p = (try parse(&.{ "--replace=$0!", "pat" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.opts.replace.?, "$0!"));
    }
    try expect((try parse(&.{ "-r", "$1", "pat" })) == null);
    try expect((try parse(&.{ "--replace=${2}", "pat" })) == null);
    try expect((try parse(&.{"-r"})) == null);
}

test "leading inline flag group (?i)/(?-u)/(?m)/(?s) honored" {
    {
        var p = (try parse(&.{"(?i)wallet"})).?;
        defer p.deinit(A);
        try expect(p.opts.caseless and eqs(u8, p.pattern, "wallet"));
    }
    {
        var p = (try parse(&.{"(?-u)func"})).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "func"));
    }
    {
        var p = (try parse(&.{"(?im)Foo"})).?;
        defer p.deinit(A);
        try expect(p.opts.caseless and eqs(u8, p.pattern, "Foo"));
    }
    {
        var p = (try parse(&.{"(?-i)Foo"})).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "Foo"));
    }
    {
        var p = (try parse(&.{"(?:foo|bar)"})).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "(?:foo|bar)"));
    }
    {
        var p = (try parse(&.{ "-F", "(?i)x" })).?;
        defer p.deinit(A);
        try expect(!p.opts.caseless and eqs(u8, p.pattern, "(?i)x"));
    }
    {
        // `(?s)` is now HONORED: it sets dotall (`.` also matches `\n`, meaningful
        // under `-U`) and is stripped from the pattern handed to the compiler.
        var p = (try parse(&.{"(?s)a.*b"})).?;
        defer p.deinit(A);
        try expect(p.opts.dotall and eqs(u8, p.pattern, "a.*b"));
    }
    {
        var p = (try parse(&.{"(?-s)ab"})).?;
        defer p.deinit(A);
        try expect(!p.opts.dotall and eqs(u8, p.pattern, "ab"));
    }
}

test "--count-matches is distinct from --count (the silent-wrong-count fix)" {
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
        var p = (try parse(&.{ "-c", "e" })).?;
        defer p.deinit(A);
        try expect(p.opts.count_only and !p.opts.count_matches);
    }
}

test "corpus-policy no-ops gist already satisfies are accepted, not fail-loud" {
    for ([_][]const u8{ "--hidden", "--no-ignore", "--no-ignore-vcs", "--no-ignore-parent", "--no-ignore-dot", "--unrestricted", "--one-file-system" }) |f| {
        var p = (try parse(&.{ f, "WalletService" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "WalletService"));
    }
    {
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
        var p = (try parse(&.{ "--sort", "path", "foo" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo") and p.opts.filter.roots.len == 0);
    }
    {
        var p = (try parse(&.{ "--sort=path", "foo" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo"));
    }
    {
        var p = (try parse(&.{ "--sortr", "modified", "foo" })).?;
        defer p.deinit(A);
        try expect(eqs(u8, p.pattern, "foo"));
    }
    try expect((try parse(&.{"--sort"})) == null);
}

test "recognized-but-unsupportable flags fail LOUD (never silent-wrong)" {
    // A different engine — fail loud, never silently ignored. NB: `--json` and
    // `-U`/`--multiline[-dotall]` are now SUPPORTED native capabilities (covered
    // below), so they're dropped from here. What remains needs a feature gist's
    // linear-time RE2-style engine or line-oriented output model genuinely lacks.
    try expect((try parse(&.{ "-P", "(?<=x)y" })) == null); // PCRE lookbehind
    try expect((try parse(&.{ "--pcre2", "a" })) == null);
    try expect((try parse(&.{ "--vimgrep", "a" })) == null);
    try expect((try parse(&.{ "--column", "a" })) == null);
}

test "multiline (-U/--multiline/--multiline-dotall) is honored, not fail-loud" {
    {
        var p = (try parse(&.{ "-U", "a\\nb" })).?;
        defer p.deinit(A);
        try expect(p.opts.multiline and !p.opts.dotall);
    }
    {
        var p = (try parse(&.{ "--multiline", "a" })).?;
        defer p.deinit(A);
        try expect(p.opts.multiline and !p.opts.dotall);
    }
    {
        // `--multiline-dotall` implies both: whole-buffer AND `.` crosses `\n`.
        var p = (try parse(&.{ "--multiline-dotall", "a" })).?;
        defer p.deinit(A);
        try expect(p.opts.multiline and p.opts.dotall);
    }
    // `-o`/`-r` WITH `-U` is still fail-loud (the multiline emitter frames whole
    // touched lines, so a per-match cross-line span would silently disagree).
    try expect((try parse(&.{ "-U", "-o", "a" })) == null);
    try expect((try parse(&.{ "-U", "-r", "X", "a" })) == null);
}

test "type aliases: tsx, jsx, rego, mdc resolve" {
    for ([_][]const u8{ "tsx", "jsx", "rego", "mdc", "vue", "svelte", "cedar" }) |t| {
        var p = (try parse(&.{ "-t", t, "x" })).?;
        defer p.deinit(A);
        try expect(p.opts.filter.exts.len > 0);
    }
}

test "fail loud: unknown short flag, unknown long flag, missing value, no pattern" {
    try expect((try parse(&.{ "-Z", "foo" })) == null);
    try expect((try parse(&.{ "-nZ", "foo" })) == null);
    try expect((try parse(&.{"--frobnicate"})) == null);
    try expect((try parse(&.{"-A"})) == null);
    try expect((try parse(&.{"--context"})) == null);
    try expect((try parse(&.{ "-t", "cobol", "x" })) == null);
    try expect((try parse(&.{})) == null);
    try expect((try parse(&.{ "-i", "-l" })) == null);
}
