//! Adversarial tests for the ripgrep-compatible grep argv parser. Every case
//! here is a reflexive agent invocation that used to fail (silent wrong scope,
//! or a fail-loud on a legal cluster / no-op flag). The parser is the surface
//! an agent's muscle memory hits first, so a regression here reads as "gist is
//! broken" — hence the coverage of bundling, no-ops, long flags, smart-case,
//! and positional path scoping, plus the fail-loud contract for real errors.

const std = @import("std");
const ga = @import("grepargs.zig");
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
