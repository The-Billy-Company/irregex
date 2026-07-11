//! gist `rg` — a ripgrep-DEFAULT drop-in over an arbitrary directory tree, and
//! (since the two engines merged) the SOLE search engine gist ships: the same
//! walk-and-emit pipeline backs the bare `gist <pattern> [PATH...]` shorthand
//! (no verb, no index required — the everyday zero-setup front door) and the
//! explicit `gist rg` alias. A persisted trigram index, when it covers the
//! searched roots, is used purely to ELIDE reads of files it proves can't match
//! (`IndexSkip` below) — never to change the file set, ignore semantics,
//! ordering, or output; `--no-index`/`--index` force the pure walk / the
//! accelerated path, and `--rank[=N]` rides the same candidate source into the
//! definition-first RRF view (`rank.zig`). This needs to *prove* gist is a
//! genuine ripgrep drop-in against ripgrep's own integration suite — which
//! creates a throwaway directory, drops in fixtures, and runs `rg` in that CWD —
//! so this module searches an arbitrary tree with ripgrep's DEFAULT presentation:
//!   • filename shown only when recursive or >1 file (a single explicit file
//!     prints no `path:` prefix), `-H` forces it, `--no-filename`/`-I` suppress;
//!   • line numbers OFF by default, `-n` turns them on;
//!   • `:` frames a match line, `-` a context line, `--` separates groups;
//!   • `-t/-T/-g/--glob/--iglob` scope by type/glob (reusing `../scope/`);
//!   • `.gitignore`/`.ignore`/`.rgignore` precedence honored (`ignore.zig`),
//!     byte-identical to `rg`'s own default corpus scope;
//!   • exit 0 = matched, 1 = no match, 2 = error/unsupported (ripgrep's codes).
//! It reuses gist's regex engine verbatim (one linear-time RE2-style matcher, no
//! second code path) — this module is the walk + presentation shell that makes
//! that engine addressable the way `rg` is. `--json`/`--column`/`--vimgrep` ARE
//! honored (`json.zig`, `output.zig`); the genuine divergences that fail LOUD
//! with exit 2 (so the differential harness scores them N/A rather than silently
//! wrong) are `-U`/`--multiline` (per-line by construction) and `-P`/`--pcre2`
//! (a linear-time RE2 engine has no backreferences/lookaround).

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const args = @import("args.zig");
const output = @import("output.zig");
const json = @import("json.zig");
const color = @import("color.zig");
const grepfile = @import("grepfile.zig");
const pipeline = @import("pipeline.zig");
const collect = @import("collect.zig");
const stdin = @import("stdin.zig");
const types = @import("../scope/types.zig");
const rank = @import("rank.zig");
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = args.die;
const Regex = @import("../../regex/core.zig").Regex;
const Captures = @import("../../regex/captures.zig").Captures;
const Dir = std.Io.Dir;

// Per-file semantics (BOM/UTF-16 ingest, rg line split, binary handling, the
// --stats tally) live in `grepfile.zig`, shared verbatim with the parallel
// pipeline so the two engines cannot drift.
const stripBom = grepfile.stripBom;
const collectLines = grepfile.collectLines;
const Stats = grepfile.Stats;
const fileMatchStats = grepfile.fileMatchStats;
const emitStats = grepfile.emitStats;

// The walk (`walk.zig`) → parallel read + index elision + file collection
// (`collect.zig`) → stdin stream search (`stdin.zig`) all split out of this
// module; it keeps the pattern-combination front end and the `run` orchestrator.
const InFile = collect.InFile;
const collectFiles = collect.collectFiles;

fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => out.append(a, '\\') catch die("oom\n", .{}),
            else => {},
        }
        out.append(a, c) catch die("oom\n", .{});
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// A leading `(?flags)` directive (rust-regex/rg syntax) on a pattern, honored
/// where the per-line byte engine genuinely can — the contract is "honored
/// where gist can, loud where it can't", never a silent wrong answer:
///   • `i` / `-i` → ASCII caseless on/off for the WHOLE pattern (gist compiles
///     one global engine, so the directive resolves to the run-wide option;
///     mixed demands across `-e`/`-f` patterns fail loud — rgsuite boundary #5);
///   • `m` `s` (and negations) → inert in the per-line model: `^`/`$` already
///     anchor every line and no line carries a `\n` for `.` to cross;
///   • `-u` → inert: byte/ASCII semantics ARE gist's native behavior;
///   • `u` `x` `U` `R` → semantics the engine can't reproduce → die with the
///     reason and the rg fallback.
/// Anything else after `(?` (lookaround, a scoped `(?i:…)` group, `(?P<…>`) is
/// not a flag directive — returns null and the regex parser decides.
const LeadingFlags = struct { rest: []const u8, caseless: ?bool = null };
fn stripLeadingFlags(pat: []const u8) ?LeadingFlags {
    if (!std.mem.startsWith(u8, pat, "(?")) return null;
    const close = std.mem.findScalar(u8, pat, ')') orelse return null;
    if (close == 2) return null; // `(?)` — empty directive, the parser rejects it
    var caseless: ?bool = null;
    var neg = false;
    for (pat[2..close]) |f| switch (f) {
        '-' => neg = true,
        'i' => caseless = !neg,
        'm', 's' => {},
        'u' => if (!neg) die("(?u) unsupported — gist matches bytes with ASCII case rules, not Unicode; use rg for this\n", .{}),
        'x', 'U', 'R' => die("(?{c}) unsupported by gist's engine — use ripgrep for this\n", .{f}),
        else => return null,
    };
    return .{ .rest = pat[close + 1 ..], .caseless = caseless };
}

/// Combine every pattern source — bare/`-e`/`--regexp` plus each `-f/--file`
/// line — into one regex: `-F` escapes each literal, multiple patterns OR via
/// `(?:…)|(?:…)`, and `-x/--line-regexp` anchors the whole with `^(?:…)$`.
/// Returns null for the "zero patterns" case (an empty `-f` file with no other
/// source) — ripgrep matches nothing (and everything under `-v`); the caller
/// handles that without the engine. An empty pattern LINE is kept (it's a valid
/// empty pattern = match-all), only the phantom line after a trailing `\n` drops.
/// Leading `(?flags)` directives are resolved here (see `stripLeadingFlags`),
/// which may flip `o.caseless` — under `-F` the bytes `(?i)` stay a literal,
/// exactly as in rg.
fn combinePatterns(a: std.mem.Allocator, io: std.Io, parsed: args.Parsed, o: *Opts) ?[]const u8 {
    var pats: std.ArrayList([]const u8) = .empty;
    pats.appendSlice(a, parsed.patterns) catch die("oom\n", .{});
    for (parsed.pattern_files) |pf| {
        const buf = Dir.cwd().readFileAlloc(io, pf, a, .limited(corpus_mod.per_file_cap)) catch
            die("cannot read pattern file: {s}\n", .{pf});
        if (buf.len == 0) continue;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |ln| {
            // The piece after a final '\n' is a phantom (not a pattern); every
            // other line — including a genuinely empty one — is a real pattern.
            if (it.index == null and ln.len == 0) break;
            pats.append(a, std.mem.trimEnd(u8, ln, "\r")) catch die("oom\n", .{});
        }
    }
    if (pats.items.len == 0) return null;
    if (parsed.opts.fixed) {
        for (pats.items) |*p| p.* = escapeLiteral(a, p.*);
    } else {
        // Resolve leading `(?flags)` directives. `demand` is the caseless
        // setting some pattern explicitly asked for; `inherit` marks a pattern
        // riding the CLI's own `-i`/`-s`/resolved `-S` setting. gist compiles
        // one engine, so the two may not disagree (rg scopes flags per branch).
        var demand: ?bool = null;
        var inherit = false;
        for (pats.items) |*p| {
            const sf = stripLeadingFlags(p.*) orelse {
                inherit = true;
                continue;
            };
            p.* = sf.rest;
            if (sf.caseless) |w| {
                if (demand != null and demand.? != w)
                    die("mixed per-pattern (?i) case demands — gist compiles one engine; use rg for this\n", .{});
                demand = w;
            } else inherit = true;
        }
        if (demand) |w| {
            if (inherit and w != o.caseless)
                die("(?i) on some patterns but not others — gist compiles one engine; use rg for this\n", .{});
            o.caseless = w;
        }
    }
    var combined: []const u8 = pats.items[0];
    if (pats.items.len > 1) {
        var buf: std.ArrayList(u8) = .empty;
        for (pats.items, 0..) |p, i| {
            if (i != 0) buf.append(a, '|') catch die("oom\n", .{});
            buf.print(a, "(?:{s})", .{p}) catch die("oom\n", .{});
        }
        combined = buf.toOwnedSlice(a) catch die("oom\n", .{});
    }
    if (parsed.opts.line_regexp) combined = std.fmt.allocPrint(a, "^(?:{s})$", .{combined}) catch die("oom\n", .{});
    return combined;
}

// ─────────────────────────── run ───────────────────────────

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: *const std.process.Environ.Map) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parsed = args.parseArgv(a, argv);
    var o = parsed.opts;
    // Resolved ONCE per run (not per file/emitter): stdout tty + `--color` +
    // env. Every emitter below shares this single yes/no.
    const use_color = color.enabled(o, io, env);

    // Honest deferrals: recognized flags gist doesn't yet emit byte-identically.
    // Failing loud (exit 2) keeps the harness scoring them N/A, never silently
    // wrong — each is a scoped follow-up, not a design divergence.
    deferUnimplemented(o);

    // --type-list: dump every `-t` name and the globs it recognizes, one name
    // per line (aliases repeat their row) — the whole comptime table in
    // `../scope/types.zig`, in the same domain-grouped order it's declared.
    if (o.type_list) {
        var out: std.ArrayList(u8) = .empty;
        for (types.type_table) |row| {
            for (row.names) |name| {
                out.print(a, "{s}: ", .{name}) catch die("oom\n", .{});
                for (row.globs, 0..) |g, i| {
                    out.print(a, "{s}{s}", .{ if (i > 0) ", " else "", g }) catch die("oom\n", .{});
                }
                out.append(a, '\n') catch die("oom\n", .{});
            }
        }
        corpus_mod.emitStdout(out.items);
        std.process.exit(0);
    }

    // --files: list the files that would be searched (no pattern), path-sorted,
    // NUL-terminated under --null. Uses the same gather+filter as the search path.
    if (o.files_list) {
        // The parallel engine never opens a file in --files mode (a listing needs
        // paths, not bytes) — the serial path below reads every body it lists.
        if (pipeline.eligible(io, parsed, o)) pipeline.run(gpa, io, parsed, o, null, use_color, &.{}, null);
        // --files lists every file (no pattern) — nothing to prefilter, so no read
        // elision applies; pass an empty trigram filter.
        const c = collectFiles(a, gpa, io, parsed, &.{});
        if (o.quiet) std.process.exit(if (c.path_error) 2 else if (c.files.len > 0) 0 else 1);
        var out: std.ArrayList(u8) = .empty;
        for (c.files) |f| out.print(a, "{s}{c}", .{ f.path, if (o.null_sep) @as(u8, 0) else '\n' }) catch die("oom\n", .{});
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (c.path_error) 2 else if (c.files.len > 0) 0 else 1);
    }

    // --rank: gist's definition-first ranked view — a distinct output shape from
    // the rg-parity line engine, resolved from the persisted index (which it
    // requires). Dispatch before pattern combination / the walk: it ranks the
    // indexed candidate set for the raw literal, not a compiled line regex.
    if (o.rank) {
        try rank.run(gpa, io, if (parsed.patterns.len > 0) parsed.patterns[0] else "", o.rank_k);
        return;
    }

    // Zero patterns (an empty `-f` file): ripgrep matches nothing — so without
    // `-v` there is no output (exit 1); with `-v` every line is a match. We model
    // the latter as "match-all (empty pattern), un-inverted".
    const eff = combinePatterns(a, io, parsed, &o) orelse blk: {
        if (!o.invert) std.process.exit(1);
        o.invert = false;
        break :blk "";
    };
    var re = Regex.compileOpts(gpa, eff, .{ .caseless = o.caseless }) catch
        die("bad pattern '{s}' — outside gist's linear-time syntax: no lookaround, no backreferences (\\0–\\9; NUL is \\x00), no unrecognized escapes (\\q, \\e, …), no assertion escapes inside [...], no mid-pattern inline flags (--schema lists the surface). Fallback: rg '{s}' (add --pcre2 for backreferences/lookaround)\n", .{ eff, eff });
    defer re.deinit();

    // -r/--replace: build the group-aware capture matcher (same AST, save-carrying
    // Pike VM) once and share it across every emitter for template expansion.
    var caps_store: ?Captures = if (o.replace != null)
        (Captures.compile(gpa, eff, o.caseless) catch die("bad pattern '{s}' — outside gist's linear-time syntax. Fallback: rg '{s}' (add --pcre2 for backreferences/lookaround)\n", .{ eff, eff }))
    else
        null;
    defer if (caps_store) |*cp| cp.deinit();
    const caps: ?*Captures = if (caps_store) |*cp| cp else null;

    // Stdin search (rg parity): with no PATH args and a readable stdin (pipe /
    // regular file), search the piped bytes as one unnamed source — no filename
    // prefix, rg exit codes. A tty or /dev/null stdin falls through to the walk.
    if (parsed.roots.len == 0 and stdin.readable()) {
        const body = stripBom(stdin.read(a));
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        var out0: std.ArrayList(u8) = .empty;
        var em0 = Emitter{ .a = a, .re = &re, .o = o, .show_name = false, .out = &out0, .base = @intFromPtr(body.ptr), .caps = caps, .use_color = use_color };
        const hits = em0.file("<stdin>", lines.items);
        if (o.quiet) std.process.exit(if (hits > 0) 0 else 1);
        corpus_mod.emitStdout(out0.items);
        std.process.exit(if (hits > 0) 0 else 1);
    }

    // The persisted index (when present) accelerates the walk by eliding reads of
    // files that provably can't hold the pattern's required literal — a pure
    // acceleration, output-invisible (see `IndexSkip`). `req_one` backs a possible
    // one-element `{re.required}` filter slice for its lifetime here.
    var req_one: [1][]const u8 = undefined;
    const filters = collect.trigramFilter(o, &re, &req_one);

    // The common recursive-walk case runs on the parallel fused engine
    // (pipeline.zig): work-stealing directory walk, bulk-stat listings, inline
    // index/freshness elision, per-file render on every core — byte-identical
    // output, produced in parallel. Anything it declines (see `eligible`) falls
    // through to this proven serial engine.
    if (pipeline.eligible(io, parsed, o))
        pipeline.run(gpa, io, parsed, o, &re, use_color, filters, collect.literalGate(parsed));

    const c = collectFiles(a, gpa, io, parsed, filters);
    const files = c.files;

    // --json: ripgrep's JSON Lines record stream (own printer, shared engine).
    if (o.json) {
        var jf: std.ArrayList(json.File) = .empty;
        for (files) |f| jf.append(a, .{ .path = f.path, .body = stripBom(f.bytes) }) catch die("oom\n", .{});
        var out: std.ArrayList(u8) = .empty;
        const matched = json.run(a, &out, &re, caps, o, jf.items);
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (c.path_error) 2 else if (matched) 0 else 1);
    }

    const show_name = switch (o.filename) {
        .always => true,
        .never => false,
        .auto => c.recursive or files.len > 1 or parsed.roots.len > 1,
    };

    var out: std.ArrayList(u8) = .empty;
    var em = Emitter{ .a = a, .re = &re, .o = o, .show_name = if (o.heading) false else show_name, .out = &out, .caps = caps, .use_color = use_color, .needle = collect.literalGate(parsed) };

    // --quiet short-circuits on first match — unless --stats is also asked for,
    // which must run the full search to tally (then print only the stats block).
    if (o.quiet and !o.stats) std.process.exit(if (c.path_error) 2 else if (anyMatch(a, &re, o, files)) 0 else 1);

    if (o.files_without) {
        var lsim = Regex.Sim.init(a, &re) catch die("engine init failed\n", .{});
        defer lsim.deinit();
        var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(a, &re) catch null) else null;
        defer if (wss) |*s| s.deinit();
        for (files) |f| {
            const body = stripBom(f.bytes);
            if (body.len > 0 and corpus_mod.isBinary(body) and !o.text) continue;
            var lines: std.ArrayList([]const u8) = .empty;
            collectLines(a, body, o.term(), &lines);
            var any = false;
            for (lines.items) |line| {
                const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
                const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&lsim, mv);
                if (hit) {
                    any = true;
                    break;
                }
            }
            if (!any) out.print(a, "{s}{c}", .{ f.path, if (o.null_sep) @as(u8, 0) else '\n' }) catch die("oom\n", .{});
        }
        corpus_mod.emitStdout(out.items);
        std.process.exit(if (c.path_error) 2 else if (out.items.len > 0) 0 else 1);
    }

    const heading = o.heading and !o.count_only and !o.count_matches and !o.files_only and !o.vimgrep;
    const join_groups = o.wantsContext() and !o.files_only and !o.count_only and !o.count_matches and !heading;
    var matched_files: usize = 0;
    var first = true;
    // -l/--files-with-matches and -q short-circuit on first match (rg prints the
    // path / exits before scanning far enough to detect a NUL), so they treat a
    // binary file as text. Every other mode runs ripgrep's binary detection.
    const binary_detect = !o.text and !o.null_data and !o.files_only;
    var stat = Stats{};
    for (files) |f| {
        const body = stripBom(f.bytes);
        if (body.len == 0) continue;
        if (binary_detect) if (std.mem.findScalar(u8, body, 0)) |nul| {
            em.base = @intFromPtr(body.ptr);
            if (grepfile.handleBinary(a, &re, o, &out, &em, f.path, f.explicit, body, nul, show_name)) matched_files += 1;
            continue;
        };
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        if (o.stats) {
            stat.files_searched += 1;
            const fs = fileMatchStats(&re, a, o, body, lines.items);
            stat.matches += fs.matches;
            stat.matched_lines += fs.lines;
            stat.bytes_searched += fs.bytes;
        }
        const before = out.items.len;
        // --heading: a blank-line-separated group per file, path on its own line.
        if (heading) out.print(a, "{s}{s}\n", .{ if (first) "" else "\n", f.path }) catch die("oom\n", .{});
        em.base = @intFromPtr(body.ptr);
        const hits = em.file(f.path, lines.items);
        if (hits > 0) {
            if (join_groups and !first and out.items.len > before)
                out.insertSlice(a, before, "--\n") catch die("oom\n", .{});
            first = false;
            matched_files += 1;
        } else if (heading) {
            out.shrinkRetainingCapacity(before); // no matches → drop the header we wrote
        }
    }
    if (o.stats) {
        stat.files_with_match = matched_files;
        // --quiet --stats: suppress the match stream, report 0 bytes printed.
        stat.bytes_printed = if (o.quiet) 0 else out.items.len;
        if (o.quiet) out.clearRetainingCapacity();
        emitStats(a, &out, stat);
    }
    corpus_mod.emitStdout(out.items);
    std.process.exit(if (c.path_error) 2 else if (matched_files > 0) 0 else 1);
}

/// Fail loud (exit 2 → harness N/A) for recognized-but-not-yet-emitted flags.
fn deferUnimplemented(o: Opts) void {
    if (o.multiline) die("-U/--multiline not yet implemented in gist rg-compat\n", .{});
}

/// `-q/--quiet`: true as soon as any file has a matching line (short-circuits).
fn anyMatch(a: std.mem.Allocator, re: *const Regex, o: Opts, files: []const InFile) bool {
    var sim = Regex.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Regex.SpanSim = if (o.word) (Regex.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    for (files) |f| {
        const body = stripBom(f.bytes);
        if (body.len == 0 or (corpus_mod.isBinary(body) and !o.text)) continue;
        var lines: std.ArrayList([]const u8) = .empty;
        collectLines(a, body, o.term(), &lines);
        for (lines.items) |line| {
            const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
            const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&sim, mv);
            if (hit != o.invert) return true;
        }
    }
    return false;
}

// The dying arms (`(?u)`, `(?x)`, mixed demands) exit the process by design,
// so tests cover the honor/strip/decline paths; build.zig's black-box guard
// covers the end-to-end exit codes.
test "stripLeadingFlags honors i/-i and strips the directive" {
    const t = std.testing;
    const ci = stripLeadingFlags("(?i)Foo.*bar").?;
    try t.expectEqualStrings("Foo.*bar", ci.rest);
    try t.expectEqual(@as(?bool, true), ci.caseless);
    const cs = stripLeadingFlags("(?-i)Foo").?;
    try t.expectEqualStrings("Foo", cs.rest);
    try t.expectEqual(@as(?bool, false), cs.caseless);
    const both = stripLeadingFlags("(?i-s)x").?; // `-` negates only what follows it
    try t.expectEqual(@as(?bool, true), both.caseless);
    try t.expectEqualStrings("x", both.rest);
}

test "stripLeadingFlags treats m/s/-u as inert, no case demand" {
    const t = std.testing;
    const sf = stripLeadingFlags("(?sm)^func$").?;
    try t.expectEqualStrings("^func$", sf.rest);
    try t.expectEqual(@as(?bool, null), sf.caseless);
    const nu = stripLeadingFlags("(?-u)\\w+").?;
    try t.expectEqualStrings("\\w+", nu.rest);
    try t.expectEqual(@as(?bool, null), nu.caseless);
}

test "stripLeadingFlags declines non-directive groups (parser decides)" {
    const t = std.testing;
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i:foo)bar")); // scoped group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?=foo)")); // lookahead
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?P<n>a)")); // named group
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?)x")); // empty directive
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("foo(?i)")); // not leading
    try t.expectEqual(@as(?LeadingFlags, null), stripLeadingFlags("(?i")); // unclosed
}
