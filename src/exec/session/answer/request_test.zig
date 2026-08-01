//! gist resident session — the request-eligibility classifier suite. `classify` is the fail-closed gate that decides whether an
//! rg-style argv can be answered warm; the one unforgivable failure is
//! classifying an INELIGIBLE request as eligible (the resident path would then
//! answer a query it can't serve correctly), so this pins both the accepted
//! surface and — exhaustively — the boundary that must fall back to cold.

const std = @import("std");
const request = @import("request.zig");

// `classify` writes its `PathFilter` root headers into caller scratch that must
// outlive the returned request. A file-scope buffer is safe here: each `test`
// runs to completion before the next, and no case retains a request across the
// next `ok`. A case that needs to read `.filter.roots` after another `ok` copies
// the roots first (see the scoped-roots cases).
var scratch: request.ScopeArgs = .{};

fn ok(argv: []const []const u8) !request.Request {
    return request.classify(argv, &scratch);
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

test "classify: a bare -l/-c with no pattern declines to cold (the walk lists files)" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{"-l"}));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{"-c"}));
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

test "classify: a clean relative PATH scope is eligible; unrenderable roots decline" {
    // A subtree/file the resident mirror stores byte-identically to cold's walk
    // is served warm, carried on the request's `PathFilter.roots`.
    {
        const a = try ok(&.{ "-l", "needle", "services" });
        try std.testing.expectEqual(request.Mode.files, a.mode);
        try std.testing.expectEqual(@as(usize, 1), a.filter.roots.len);
        try std.testing.expectEqualStrings("services", a.filter.roots[0]);
    }
    {
        const b = try ok(&.{ "-l", "needle", "services", "libs" });
        try std.testing.expectEqual(@as(usize, 2), b.filter.roots.len);
        try std.testing.expectEqualStrings("services", b.filter.roots[0]);
        try std.testing.expectEqualStrings("libs", b.filter.roots[1]);
    }
    {
        // A single-file root and a nested subtree are both clean.
        const c = try ok(&.{ "needle", "libs/x/README.md" });
        try std.testing.expectEqual(request.Mode.lines, c.mode);
        try std.testing.expectEqualStrings("libs/x/README.md", c.filter.roots[0]);
    }
    {
        // A trailing slash is stripped (rg parity: `libs/` == `libs`).
        const d = try ok(&.{ "-l", "needle", "libs/" });
        try std.testing.expectEqualStrings("libs", d.filter.roots[0]);
    }
    {
        // A `--` separator ends flag parsing; the path after it is a clean root.
        const e = try ok(&.{ "-l", "needle", "--", "services" });
        try std.testing.expectEqualStrings("services", e.filter.roots[0]);
    }
    // Roots cold would render with a prefix the CWD-relative mirror lacks — or
    // that escape/blur the walk set — stay cold: `.` (a `./` display prefix), an
    // explicit `./`/`../`, an absolute path, and a glob (that is `-g`).
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "." }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "./services" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "../sibling" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "a/../b" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "/tmp/foreign" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "src/*.zig" }));
}

test "classify: an explicitly named hidden root declines (cold un-hides it, the mirror cannot)" {
    // rg searches a root you NAME even when the default walk would have pruned
    // it as hidden (`rg needle .circleci` → hits), and cold matches that via
    // `Ignore.scopeToRoot`. The resident mirror is the whole-tree default walk,
    // which pruned the directory outright — so serving these warm would answer
    // a clean "no match" where cold and rg both answer. Decline instead.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", ".circleci" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", ".circleci/" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", ".git" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", ".dotfile.txt" }));
    // A hidden segment anywhere along the root, not just in front.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "libs/.hidden" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "libs/.hidden/deep" }));
    // No over-decline: a dot INSIDE a segment is an ordinary name, not hidden.
    try std.testing.expectEqualStrings("libs.old", (try ok(&.{ "-l", "needle", "libs.old" })).filter.roots[0]);
    try std.testing.expectEqualStrings("libs/a.b/c", (try ok(&.{ "-l", "needle", "libs/a.b/c" })).filter.roots[0]);
}

test "classify: -g / --glob is eligible and routed to includes/excludes" {
    {
        // `-g <glob>` (value in the next token) and `--glob=<glob>` are includes.
        const a = try ok(&.{ "-l", "-g", "*.go", "needle" });
        try std.testing.expectEqual(@as(usize, 1), a.filter.includes.len);
        try std.testing.expectEqualStrings("*.go", a.filter.includes[0]);
        try std.testing.expectEqual(@as(usize, 0), a.filter.excludes.len);
    }
    {
        const b = try ok(&.{ "--glob=*.zig", "needle" });
        try std.testing.expectEqualStrings("*.zig", b.filter.includes[0]);
    }
    {
        // Glued short form `-g<glob>`.
        const c = try ok(&.{ "-l", "-g*.rs", "needle" });
        try std.testing.expectEqualStrings("*.rs", c.filter.includes[0]);
    }
    {
        // A leading `!` is an exclude, stripped of the `!`.
        const d = try ok(&.{ "-l", "-g", "!*_test.go", "needle" });
        try std.testing.expectEqual(@as(usize, 0), d.filter.includes.len);
        try std.testing.expectEqual(@as(usize, 1), d.filter.excludes.len);
        try std.testing.expectEqualStrings("*_test.go", d.filter.excludes[0]);
    }
    {
        // Includes and excludes compose; both accumulate in order.
        const e = try ok(&.{ "-l", "-g", "*.go", "-g", "!vendor/**", "needle" });
        try std.testing.expectEqualStrings("*.go", e.filter.includes[0]);
        try std.testing.expectEqualStrings("vendor/**", e.filter.excludes[0]);
    }
}

test "classify: -g forms outside the warm PathFilter model decline to cold" {
    // rg errors on an unterminated class (its exit 2) — cold owns that.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-g", "*.[ch", "needle" }));
    // A leading-`/` anchored glob: cold strips the anchor vs the search root, a
    // rule the flat prune does not reproduce → cold.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-g", "/src/*.go", "needle" }));
    // An empty glob value, and a dangling `-g` with no value.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-g", "", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "-g" }));
    // `--iglob` (case-insensitive) is not the includes model → cold.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "--iglob", "*.go", "needle" }));
    // A `{a,b}` alternation: cold expands it into one glob per branch, the flat
    // filter cannot, and pushing it raw matched NOTHING instead of both branches
    // — the wrong answer a warm path must never produce. Every carrier form of
    // the glob (spaced, glued, `--glob=`, `!`-exclude) declines, and so does an
    // unbalanced `{`, which cold treats as a literal.
    for ([_][]const []const u8{
        &.{ "-l", "-g", "*{intent,grammar}.zig", "needle" },
        &.{ "-l", "-g*{a,b}.go", "needle" },
        &.{ "--glob={src,lib}/**", "needle" },
        &.{ "-l", "-g", "!{vendor,third_party}/**", "needle" },
        &.{ "-l", "-g", "*{unbalanced.zig", "needle" },
    }) |argv| try std.testing.expectError(request.ClassifyError.Unsupported, ok(argv));
}

test "classify: -t / --type resolves to its extension globs" {
    {
        // `-t go` flattens to the type's globs (*.go, go.mod, go.sum).
        const a = try ok(&.{ "-l", "-t", "go", "needle" });
        try std.testing.expectEqual(@as(usize, 3), a.filter.exts.len);
        try std.testing.expectEqualStrings("*.go", a.filter.exts[0]);
    }
    {
        // `--type=py` and the glued `-tpy` both resolve `py` → *.py, *.pyi.
        const b = try ok(&.{ "--type=py", "needle" });
        try std.testing.expectEqual(@as(usize, 2), b.filter.exts.len);
        const c = try ok(&.{ "-tpy", "needle" });
        try std.testing.expectEqual(@as(usize, 2), c.filter.exts.len);
    }
    {
        // Two `-t` flags union their globs.
        const d = try ok(&.{ "-l", "-t", "rust", "-t", "zig", "needle" });
        try std.testing.expectEqual(@as(usize, 3), d.filter.exts.len); // *.rs + *.zig + *.zon
    }
}

test "classify: an unknown or `all` type declines to cold" {
    // Unknown type: cold emits rg's exit-2 "unrecognized type".
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-t", "nosuchlang", "needle" }));
    // `-t all` (every known type) is outside the flat PathFilter model → cold.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-t", "all", "needle" }));
    // A dangling `-t` with no value.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "needle", "-t" }));
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

test "classify: -q/--quiet is eligible and carried onto the request" {
    // Lane 4: `-q` is an existence-only answer the session serves early-halting,
    // eligible across every mode and composable with the case/word family.
    const bare = try ok(&.{ "-q", "needle" });
    try std.testing.expectEqual(request.Mode.lines, bare.mode);
    try std.testing.expect(bare.quiet);
    const long = try ok(&.{ "--quiet", "needle" });
    try std.testing.expect(long.quiet);
    const with_l = try ok(&.{ "-q", "-l", "needle" });
    try std.testing.expect(with_l.quiet and with_l.mode == .files);
    const with_c = try ok(&.{ "-q", "-c", "needle" });
    try std.testing.expect(with_c.quiet and with_c.mode == .count);
    const composed = try ok(&.{ "-q", "-w", "-i", "-F", "needle" });
    try std.testing.expect(composed.quiet and composed.word and composed.ignore_case and composed.fixed);
    // Absent ⇒ false, and max_count stays unset.
    const none = try ok(&.{ "-l", "needle" });
    try std.testing.expect(!none.quiet);
    try std.testing.expectEqual(@as(?u64, null), none.max_count);
}

test "classify: -m N/--max-count parses the cap; non-numeric and dangling fall to cold" {
    // Lane 4: the four documented spellings, each parsing the SAME decimal the
    // cold `-m` parser would (a divergent parse is worse than a cold fallback).
    inline for (.{
        [_][]const u8{ "-m", "5", "needle" },
        [_][]const u8{ "-m5", "needle" }, // rg's glued short form
        [_][]const u8{ "-m=5", "needle" },
        [_][]const u8{ "--max-count", "5", "needle" },
        [_][]const u8{ "--max-count=5", "needle" },
    }) |argv| {
        const r = try ok(&argv);
        try std.testing.expectEqual(@as(?u64, 5), r.max_count);
    }
    // -m0 is explicit "match nothing" — eligible, distinguished from unset.
    const zero = try ok(&.{ "-m", "0", "needle" });
    try std.testing.expectEqual(@as(?u64, 0), zero.max_count);
    try std.testing.expect(zero.matchNothing());
    // A non-decimal or missing value is not the fast path's to reinterpret —
    // decline so cold parses (and diagnoses) it, never crash.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-m", "abc", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--max-count=x", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-m", "needle" })); // the value consumes the pattern, but parsing "needle" as a count fails first
}

test "classify: -v/--invert-match is eligible and carried onto the request" {
    // Lane 3b: warm `-v` answers by set-complement (`lines(f) − matches(f)`),
    // sound under the trigram index, so it routes warm across all three answer
    // shapes and composes with the case/word/fixed/cap family.
    const a = try ok(&.{ "-l", "-v", "needle" });
    try std.testing.expectEqual(request.Mode.files, a.mode);
    try std.testing.expect(a.invert);
    const b = try ok(&.{ "-c", "--invert-match", "needle" });
    try std.testing.expectEqual(request.Mode.count, b.mode);
    try std.testing.expect(b.invert);
    const c = try ok(&.{ "-v", "needle" }); // bare lines invert
    try std.testing.expectEqual(request.Mode.lines, c.mode);
    try std.testing.expect(c.invert);
    // Composes with -F, the case family, -w, and -m N.
    const d = try ok(&.{ "-v", "-F", "-i", "-w", "-m", "3", "needle" });
    try std.testing.expect(d.invert and d.fixed and d.ignore_case and d.word);
    try std.testing.expectEqual(@as(?u64, 3), d.max_count);
    // Absent ⇒ false.
    const e = try ok(&.{ "-l", "needle" });
    try std.testing.expect(!e.invert);
}

test "classify: any unrecognized flag hands the whole request to cold" {
    for ([_][]const []const u8{
        &.{ "-l", "-U", "needle" }, // multiline (whole-buffer emit — cold only)
        &.{ "-l", "--json", "needle" }, // structured output
        &.{ "-l", "--iglob", "*.zig", "needle" }, // case-insensitive glob (not the includes model)
        &.{ "-l", "--hidden", "needle" }, // hidden files
    }) |argv| {
        try std.testing.expectError(request.ClassifyError.Unsupported, ok(argv));
    }
}

test "classify: conflicting modes and duplicate patterns are ineligible" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-c", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-e", "a", "-e", "b" }));
    // A bare token after an `-e` pattern is now a scope root, not a second
    // pattern: `gist -e a b` == pattern `a` under path `b` (rg parity).
    {
        const a = try ok(&.{ "-l", "-e", "a", "b" });
        try std.testing.expectEqualStrings("a", a.pattern);
        try std.testing.expectEqualStrings("b", a.filter.roots[0]);
    }
    {
        const b = try ok(&.{ "-l", "--regexp=a", "b" });
        try std.testing.expectEqualStrings("a", b.pattern);
        try std.testing.expectEqualStrings("b", b.filter.roots[0]);
    }
}

test "classify: a dangling -e and empty patterns fail closed" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "-e" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "--regexp=" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-l", "" }));
}

test "classify: --rank[=N] is eligible with a regex pattern, case, and PATH roots" {
    // Bare `--rank` ⇒ the default-top-20 sentinel (0), mode stays .lines.
    const bare = try ok(&.{ "--rank", "WalletService" });
    try std.testing.expectEqual(@as(?usize, 0), bare.rank_k);
    try std.testing.expectEqual(request.Mode.lines, bare.mode);
    try std.testing.expectEqualStrings("WalletService", bare.pattern);
    // `--rank=N` carries the explicit top-k.
    const n = try ok(&.{ "--rank=5", "needle" });
    try std.testing.expectEqual(@as(?usize, 5), n.rank_k);
    // Composes with the case family and a clean PATH root (the whole warm-rank
    // surface: pattern + case + roots).
    {
        const scoped = try ok(&.{ "--rank=3", "-i", "needle", "services/ai" });
        try std.testing.expectEqual(@as(?usize, 3), scoped.rank_k);
        try std.testing.expect(scoped.ignore_case);
        try std.testing.expectEqualStrings("services/ai", scoped.filter.roots[0]);
    }
    // Absent ⇒ null (not a rank query).
    const none = try ok(&.{"needle"});
    try std.testing.expectEqual(@as(?usize, null), none.rank_k);
    // A non-decimal top-k is cold's to diagnose.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--rank=x", "needle" }));
}

test "classify: --rank declines every richer combo to cold" {
    // Cold `--rank` ignores `-F`/`-w`/`-v`/`-q`/`-l`/`-c`/`-n`/`-m` and its index
    // path even bypasses `-g`/`-t`; rather than mirror those quirks, the warm
    // classifier admits only the clean rank surface and hands each of these to
    // cold, which owns its own index-vs-live rank behavior.
    for ([_][]const []const u8{
        &.{ "--rank", "-F", "needle" },
        &.{ "--rank", "-w", "needle" },
        &.{ "--rank", "-v", "needle" },
        &.{ "--rank", "-q", "needle" },
        &.{ "--rank", "-l", "needle" },
        &.{ "--rank", "-c", "needle" },
        &.{ "--rank", "-n", "needle" },
        &.{ "--rank", "-m", "3", "needle" },
        &.{ "--rank", "-g", "*.zig", "needle" },
        &.{ "--rank", "-t", "py", "needle" },
        &.{ "--rank", "-C", "2", "needle" }, // a window has no meaning in the ranked view
        &.{ "--rank", "-P", "needle" }, // --rank is linear-only; PCRE2 declines
    }) |argv| {
        try std.testing.expectError(request.ClassifyError.Unsupported, ok(argv));
    }
}

test "classify: -P/--pcre2/--engine=pcre2 select the warm PCRE2 engine" {
    // Every spelling of the PCRE2 selector sets `pcre`; it composes with modes,
    // case, `-w`, `-n`, context, and a clean PATH scope.
    try std.testing.expect((try ok(&.{ "-P", "foo(?=bar)" })).pcre);
    try std.testing.expect((try ok(&.{ "--pcre2", "foo(?=bar)" })).pcre);
    try std.testing.expect((try ok(&.{ "--engine=pcre2", "foo(?=bar)" })).pcre);
    try std.testing.expect((try ok(&.{ "--engine", "pcre2", "foo(?=bar)" })).pcre);
    // `--engine=default` stays on the linear engine (pcre unset).
    try std.testing.expect(!(try ok(&.{ "--engine=default", "needle" })).pcre);
    // A plain (non-`-P`) request never sets it.
    try std.testing.expect(!(try ok(&.{"needle"})).pcre);
    // Composes with the eligible surface.
    {
        const a = try ok(&.{ "-c", "-P", "-i", "(\\w+)\\s+\\1", "services/ai" });
        try std.testing.expect(a.pcre and a.ignore_case);
        try std.testing.expectEqual(request.Mode.count, a.mode);
        try std.testing.expectEqualStrings("services/ai", a.filter.roots[0]);
    }
}

test "classify: --engine auto / unknown decline to cold (linear-first escalation is cold's)" {
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--engine", "auto", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--engine=auto", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--engine=bogus", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--auto-hybrid-regex", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--engine", "needle" })); // missing value consumes the pattern-ish, non-value declines
}

test "classify: -A/-B/-C context windows are eligible and fold like cold" {
    // Separate-token and glued short forms both parse.
    {
        const a = try ok(&.{ "-A", "3", "needle" });
        try std.testing.expectEqual(@as(u64, 0), a.before);
        try std.testing.expectEqual(@as(u64, 3), a.after);
    }
    {
        const b = try ok(&.{ "-B2", "needle" });
        try std.testing.expectEqual(@as(u64, 2), b.before);
        try std.testing.expectEqual(@as(u64, 0), b.after);
    }
    // `-C` fills both sides; the long forms parse identically.
    {
        const c = try ok(&.{ "--context=4", "needle" });
        try std.testing.expectEqual(@as(u64, 4), c.before);
        try std.testing.expectEqual(@as(u64, 4), c.after);
    }
    // An explicit `-A`/`-B` outranks `-C` on its own side regardless of order
    // (cold's fold: `after = a ?? c`, `before = b ?? c`).
    {
        const mix = try ok(&.{ "-C", "5", "-A", "1", "needle" });
        try std.testing.expectEqual(@as(u64, 5), mix.before);
        try std.testing.expectEqual(@as(u64, 1), mix.after);
    }
    {
        const mix2 = try ok(&.{ "-A1", "-C5", "needle" });
        try std.testing.expectEqual(@as(u64, 5), mix2.before);
        try std.testing.expectEqual(@as(u64, 1), mix2.after);
    }
    // A non-decimal / missing window value is cold's to diagnose.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-A", "x", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-C", "needle" })); // "needle" isn't a number, then no pattern
}

test "classify: the genus flags reach the filter, in both polarities" {
    const genus = @import("../../../corpus/scope/genus.zig");
    {
        const d = try ok(&.{ "--docs", "needle" });
        try std.testing.expect(d.filter.genera.has(.docs));
        try std.testing.expect(!d.filter.genera.has(.code));
        try std.testing.expect(!d.filter.neg_genera.any());
    }
    {
        const n = try ok(&.{ "--no-docs", "needle" });
        try std.testing.expect(n.filter.neg_genera.has(.docs));
        try std.testing.expect(!n.filter.genera.any());
    }
    // Selections union, so `--docs --code` is both — the same rule as a repeated
    // `-t`, and the reason the field is a set rather than one genus.
    {
        const u = try ok(&.{ "--docs", "--code", "needle" });
        try std.testing.expect(u.filter.genera.has(.docs) and u.filter.genera.has(.code));
        try std.testing.expect(!u.filter.genera.has(.data));
    }
    // `-t <genus>` is the same request by its other spelling.
    inline for (.{ "docs", "code", "data" }) |name| {
        const viaT = try ok(&.{ "-t", name, "needle" });
        const g = genus.named(name).?;
        try std.testing.expectEqual(g, viaT.filter.genera);
        // …including glued `-tdocs` and `--type=docs`.
        try std.testing.expectEqual(g, (try ok(&.{ "-t" ++ name, "needle" })).filter.genera);
        try std.testing.expectEqual(g, (try ok(&.{ "--type=" ++ name, "needle" })).filter.genera);
    }
    // A genus name resolves to a genus, never to the glob set of a language
    // type — `exts` must stay empty or the AND/OR guard below would misjudge.
    try std.testing.expectEqual(@as(usize, 0), (try ok(&.{ "--docs", "needle" })).filter.exts.len);
}

test "classify: a genus filter makes the request scoped, so it rides query_ext" {
    // The routing predicate is `filter.isEmpty()`. A genus-only filter MUST read
    // as non-empty, or the client would send the classic `query` opcode — which
    // has no trailer — and the daemon would answer the unfiltered query.
    try std.testing.expect(!(try ok(&.{ "--docs", "needle" })).filter.isEmpty());
    try std.testing.expect(!(try ok(&.{ "--no-code", "needle" })).filter.isEmpty());
    try std.testing.expect((try ok(&.{"needle"})).filter.isEmpty());
}

test "classify: a positive genus declines beside another positive family" {
    // Cold ORs a genus with `-t`/`-g` includes; `PathFilter` ANDs its sets. Warm
    // may only serve the requests where those two rules agree.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--docs", "-t", "py", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "-t", "docs", "-t", "py", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--docs", "-g", "*.py", "needle" }));
    // A NEGATIVE genus is a veto on both paths, so it composes with anything.
    _ = try ok(&.{ "--no-docs", "-t", "py", "needle" });
    _ = try ok(&.{ "--no-docs", "-g", "*.py", "needle" });
    // An exclude glob is also a veto on both paths.
    _ = try ok(&.{ "--docs", "-g", "!*.md", "needle" });
    // Roots gate independently of genus, so they compose.
    _ = try ok(&.{ "--docs", "needle", "libs" });
    // `--rank` admits only its clean surface, and a genus is not part of it.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--rank", "--docs", "needle" }));
}

test "classify: a genus ALIAS is not a flag, and an unknown --no- word declines" {
    // `-t prose` is a valid type name, but there is no `--prose` flag row, so
    // warm must decline rather than admit a spelling cold would reject.
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--prose", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--source", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--no-prose", "needle" }));
    try std.testing.expectError(request.ClassifyError.Unsupported, ok(&.{ "--docsx", "needle" }));
    // …while `-t prose` (the type spelling) is served, as the docs genus.
    try std.testing.expect((try ok(&.{ "-t", "prose", "needle" })).filter.genera.has(.docs));
    // After `--`, a genus flag is a PATH, not a flag (rg's end-of-flags rule) —
    // so it must scope the search rather than partition it.
    const after = try ok(&.{ "needle", "--", "--docs" });
    try std.testing.expect(!after.filter.genera.any());
    try std.testing.expectEqualStrings("--docs", after.filter.roots[0]);
}
