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

test "classify: -S/-s case family is eligible with rg's last-wins precedence" {
    // Each of -i/-s/-S clears the other two (args.zig's `.case` arm): the
    // final spelling on the argv decides the case mode.
    const smart = try ok(&.{ "-S", "needle" });
    try std.testing.expect(smart.smart_case);
    try std.testing.expect(!smart.ignore_case);
    const long = try ok(&.{ "--smart-case", "needle" });
    try std.testing.expect(long.smart_case);

    const sensitive = try ok(&.{ "-s", "needle" });
    try std.testing.expect(!sensitive.smart_case and !sensitive.ignore_case);
    const long_s = try ok(&.{ "--case-sensitive", "needle" });
    try std.testing.expect(!long_s.smart_case and !long_s.ignore_case);

    // -s -S ⇒ smart · -S -s ⇒ sensitive · -i -s ⇒ sensitive · -S -i ⇒ ignore.
    const s_then_smart = try ok(&.{ "-s", "-S", "needle" });
    try std.testing.expect(s_then_smart.smart_case and !s_then_smart.ignore_case);
    const smart_then_s = try ok(&.{ "-S", "-s", "needle" });
    try std.testing.expect(!smart_then_s.smart_case and !smart_then_s.ignore_case);
    const i_then_s = try ok(&.{ "-i", "-s", "needle" });
    try std.testing.expect(!i_then_s.smart_case and !i_then_s.ignore_case);
    const smart_then_i = try ok(&.{ "-S", "-i", "needle" });
    try std.testing.expect(!smart_then_i.smart_case and smart_then_i.ignore_case);
    const i_then_smart = try ok(&.{ "-i", "-S", "needle" });
    try std.testing.expect(i_then_smart.smart_case and !i_then_smart.ignore_case);
}

test "Request.effectiveIgnoreCase mirrors cold's finalize-time smart-case fold" {
    // -S + all-lowercase pattern ⇒ folds caseless, exactly like -i.
    const lower = request.Request{ .pattern = "walkdir", .mode = .lines, .smart_case = true };
    try std.testing.expect(lower.effectiveIgnoreCase());
    // -S + any uppercase ⇒ stays case-sensitive.
    const upper = request.Request{ .pattern = "WalkDir", .mode = .lines, .smart_case = true };
    try std.testing.expect(!upper.effectiveIgnoreCase());
    // hasUpper is codepoint-aware: a non-ASCII uppercase (É) blocks the fold.
    const uni = request.Request{ .pattern = "caf\xc3\x89", .mode = .lines, .smart_case = true };
    try std.testing.expect(!uni.effectiveIgnoreCase());
    const uni_lower = request.Request{ .pattern = "caf\xc3\xa9", .mode = .lines, .smart_case = true };
    try std.testing.expect(uni_lower.effectiveIgnoreCase());
    // -i always folds regardless of pattern shape; bare stays sensitive.
    const icase = request.Request{ .pattern = "WalkDir", .mode = .lines, .ignore_case = true };
    try std.testing.expect(icase.effectiveIgnoreCase());
    const bare = request.Request{ .pattern = "walkdir", .mode = .lines };
    try std.testing.expect(!bare.effectiveIgnoreCase());
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

test "classify: -w/--word-regexp is eligible and carried onto the request" {
    // Lane 2: the shared search core applies cold's exact post-match word
    // rule, so `-w` routes warm across all three answer shapes.
    const a = try ok(&.{ "-l", "-w", "needle" });
    try std.testing.expectEqual(request.Mode.files, a.mode);
    try std.testing.expect(a.word);
    const b = try ok(&.{ "-c", "--word-regexp", "needle" });
    try std.testing.expectEqual(request.Mode.count, b.mode);
    try std.testing.expect(b.word);
    const c = try ok(&.{ "-w", "needle" }); // bare lines search
    try std.testing.expectEqual(request.Mode.lines, c.mode);
    try std.testing.expect(c.word);
    // Composes with -F and the case family (the word check runs on the
    // original bytes regardless of the fold).
    const d = try ok(&.{ "-l", "-F", "-i", "-w", "needle" });
    try std.testing.expect(d.word and d.fixed and d.ignore_case);
    const e = try ok(&.{ "-w", "-S", "needle" });
    try std.testing.expect(e.word and e.smart_case);
    // Absent ⇒ false.
    const f = try ok(&.{ "-l", "needle" });
    try std.testing.expect(!f.word);
}

test "classify: any unrecognized flag hands the whole request to cold" {
    for ([_][]const []const u8{
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
