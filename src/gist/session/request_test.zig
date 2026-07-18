//! gist resident session — the request-eligibility classifier suite (ADR-352
//! rung 2.5). `classify` is the fail-closed gate that decides whether an
//! rg-style argv can be answered warm; the one unforgivable failure is
//! classifying an INELIGIBLE request as eligible (the resident path would then
//! answer a query it can't serve correctly), so this pins both the accepted
//! surface and — exhaustively — the boundary that must fall back to cold.

const std = @import("std");
const request = @import("request.zig");

fn ok(argv: []const []const u8) !request.Request {
    return request.classify(argv);
}

test "classify: -l / --files-with-matches select the files mode" {
    const a = try ok(&.{ "-l", "needle" });
    try std.testing.expectEqual(request.Mode.files, a.mode);
    try std.testing.expectEqualStrings("needle", a.pattern);
    try std.testing.expect(!a.fixed);
    try std.testing.expect(!a.ignore_case);

    const b = try ok(&.{ "--files-with-matches", "needle" });
    try std.testing.expectEqual(request.Mode.files, b.mode);
}

test "classify: -c / --count select the count mode" {
    const a = try ok(&.{ "-c", "needle" });
    try std.testing.expectEqual(request.Mode.count, a.mode);
    const b = try ok(&.{ "--count", "needle" });
    try std.testing.expectEqual(request.Mode.count, b.mode);
}

test "classify: -F and -i are carried onto the request" {
    const a = try ok(&.{ "-l", "-F", "-i", "needle" });
    try std.testing.expect(a.fixed);
    try std.testing.expect(a.ignore_case);
    const b = try ok(&.{ "-c", "--fixed-strings", "--ignore-case", "needle" });
    try std.testing.expect(b.fixed);
    try std.testing.expect(b.ignore_case);
}

test "classify: pattern via a bare token, -e VALUE, or --regexp=VALUE" {
    const bare = try ok(&.{ "needle", "-l" }); // order-free: flag after the pattern
    try std.testing.expectEqualStrings("needle", bare.pattern);
    try std.testing.expectEqual(request.Mode.files, bare.mode);

    const eflag = try ok(&.{ "-c", "-e", "needle" });
    try std.testing.expectEqualStrings("needle", eflag.pattern);

    const inline_e = try ok(&.{ "-l", "--regexp=needle" });
    try std.testing.expectEqualStrings("needle", inline_e.pattern);
}

test "classify: a bare -l/-c with no pattern is NoPattern (the walk lists files)" {
    try std.testing.expectError(request.ClassifyError.NoPattern, ok(&.{"-l"}));
    try std.testing.expectError(request.ClassifyError.NoPattern, ok(&.{"-c"}));
}

test "classify: a bare pattern with no mode flag is the default lines search" {
    const a = try ok(&.{"needle"});
    try std.testing.expectEqual(request.Mode.lines, a.mode);
    try std.testing.expectEqualStrings("needle", a.pattern);
    try std.testing.expect(!a.line_num);

    const b = try ok(&.{ "-F", "needle" });
    try std.testing.expectEqual(request.Mode.lines, b.mode);
    try std.testing.expect(b.fixed);
}

test "classify: -n/--line-number carried; -N undoes it left-to-right (rg parity)" {
    const a = try ok(&.{ "-n", "needle" });
    try std.testing.expectEqual(request.Mode.lines, a.mode);
    try std.testing.expect(a.line_num);
    const b = try ok(&.{ "--line-number", "needle" });
    try std.testing.expect(b.line_num);
    const c = try ok(&.{ "-n", "-N", "needle" });
    try std.testing.expect(!c.line_num);
    const d = try ok(&.{ "-N", "-n", "needle" });
    try std.testing.expect(d.line_num);
    // Carried (and ignored) on the fold modes, exactly as cold does.
    const e = try ok(&.{ "-l", "-n", "needle" });
    try std.testing.expectEqual(request.Mode.files, e.mode);
    try std.testing.expect(e.line_num);
}

test "classify: a pattern carrying a newline or NUL stays cold" {
    // Warm whole-doc gates would match ACROSS lines where rg's per-line model
    // cannot; a NUL byte interacts with binary detection. Cold owns both.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{"multi\nline"}));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-F", "nul\x00byte" }));
}

test "classify: a rootless -l/-c query is eligible" {
    // The daemon serves exactly the rootless CWD tree, so a rootless eligible
    // query is the one shape routed warm — byte-identical to `gist <pattern>`.
    const a = try ok(&.{ "-l", "needle" });
    try std.testing.expectEqual(request.Mode.files, a.mode);
    const b = try ok(&.{ "-c", "-F", "needle" });
    try std.testing.expectEqual(request.Mode.count, b.mode);
}

test "classify: ANY explicit PATH arg is ineligible (rootless-only parity)" {
    // The daemon serves only the rootless CWD tree and the wire carries no
    // roots, so every explicit scope stays cold — a subtree (would over-report
    // against the whole tree), a foreign path, the full former default-root set,
    // and even `.` (which cold renders with a `./` prefix the daemon omits).
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "services" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "services", "libs" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "/tmp/foreign" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "." }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "services", "libs", "clients", "contracts", "scripts", "quality" }));
    // A `--` separator ends flag parsing; the paths after it are still paths.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "--", "services" }));
}

test "classify: any unrecognized flag hands the whole request to cold" {
    for ([_][]const []const u8{
        &.{ "-l", "-w", "needle" }, // whole-word
        &.{ "-l", "-v", "needle" }, // invert
        &.{ "-l", "-C", "2", "needle" }, // context
        &.{ "-l", "--json", "needle" }, // structured output
        &.{ "-l", "-g", "*.zig", "needle" }, // glob scope
        &.{ "-l", "--hidden", "needle" }, // hidden files
    }) |argv| {
        try std.testing.expectError(request.ClassifyError.Unsupported, ok(argv));
    }
}

test "classify: conflicting modes and duplicate patterns are ineligible" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-c", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-e", "a", "-e", "b" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-e", "a", "b" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "--regexp=a", "b" }));
}

test "classify: a dangling -e and empty patterns fail closed" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-e" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "--regexp=" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "" }));
}
