//! gist `rg` — the argv → `Opts` driver + short-flag lowering.
//!
//! Split from `args.zig`: the option schema lives in `opts.zig`, the mutable
//! parse state + value primitives in `builder.zig`, and the `--long-flag`
//! catalog in `longopts.zig`. This module is the entry point that ties them
//! together — `parseArgv` walks the argv (dispatching each token to `parseShort`
//! here or `longopts.parseLong`) and finalizes the `Builder` into a `Parsed` —
//! plus `parseShort`, ripgrep's short-flag bundling (`-A/-B` precedence over
//! `-C`, the `-u/-uu` unrestrict tiers, `-t/-T/-g`), which FAILS LOUD (exit 2)
//! on any short flag gist can't honor by design (`-U`, `-P`, `-z`), so the
//! differential harness scores those N/A rather than silently wrong.
//! `args.zig` re-exports `parseArgv` + `looksLikeRegex`.

const std = @import("std");
const opts = @import("opts.zig");
const die = opts.die;
const Parsed = opts.Parsed;
const builder = @import("builder.zig");
const Builder = builder.Builder;
const takeVal = builder.takeVal;
const toU = builder.toU;
const parseLong = @import("longopts.zig").parseLong;

fn hasUpper(s: []const u8) bool {
    for (s) |c| if (c >= 'A' and c <= 'Z') return true;
    return false;
}

/// RE2 metacharacters: a pattern containing any of these is a regex, otherwise
/// it's a plain literal an SIMD substring scan can serve directly. `-F`/`--fixed`
/// forces literal regardless (the whole string is data), so callers check that
/// before this — see `collect.zig`'s `literalGate`, the one caller.
pub fn looksLikeRegex(pat: []const u8) bool {
    for (pat) |c| switch (c) {
        '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => return true,
        else => {},
    };
    return false;
}

fn parseShort(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    var j: usize = 1;
    while (j < arg.len) : (j += 1) {
        switch (arg[j]) {
            'i' => b.o.caseless = true,
            's' => b.o.caseless = false,
            'S' => b.o.smart_case = true,
            'w' => b.o.word = true,
            'F' => b.o.fixed = true,
            'v' => b.o.invert = true,
            'o' => b.o.only_matching = true,
            'n' => b.o.line_num = true,
            'N' => b.o.line_num = false,
            'H' => b.o.filename = .always,
            'I' => b.o.filename = .never,
            'l' => b.o.files_only = true,
            'c' => b.o.count_only = true,
            'a' => b.o.text = true,
            'u' => b.urestrict += 1,
            'x' => b.o.line_regexp = true,
            'q' => b.o.quiet = true,
            'b' => b.o.byte_offset = true,
            '0' => b.o.null_sep = true,
            'L' => b.o.follow = true,
            'r' => {
                b.o.replace = takeVal(arg, j, i, all);
                return;
            },
            'f' => {
                b.pat_files.append(b.a, takeVal(arg, j, i, all)) catch die("oom\n", .{});
                return;
            },
            'A' => {
                b.a_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            'B' => {
                b.b_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            'C' => {
                b.c_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            'm' => {
                b.o.max_per_file = toU(takeVal(arg, j, i, all));
                return;
            },
            'M' => {
                b.o.max_cols = toU(takeVal(arg, j, i, all));
                return;
            },
            'e' => {
                b.addPat(takeVal(arg, j, i, all));
                return;
            },
            't' => {
                b.addType(takeVal(arg, j, i, all), false);
                return;
            },
            'T' => {
                b.addType(takeVal(arg, j, i, all), true);
                return;
            },
            'g' => {
                b.addGlob(takeVal(arg, j, i, all), false);
                return;
            },
            'j' => {
                _ = takeVal(arg, j, i, all);
                return;
            }, // --threads: accepted, single-shot walk ignores it
            'U' => b.o.multiline = true,
            'P' => die("-P unsupported — gist runs a linear-time RE2 engine (no PCRE2)\n", .{}),
            'z' => die("-z (search-zip) unsupported in gist rg-compat\n", .{}),
            else => die("unknown flag -{c}\n", .{arg[j]}),
        }
    }
}

/// Parse a full `rg [flags] <pattern> [PATH...]` argv into a `Parsed`. Fails loud
/// (exit 2) on a missing pattern, a bad numeric value, or an unsupported flag.
pub fn parseArgv(a: std.mem.Allocator, argv: []const []const u8) Parsed {
    var b = Builder{ .a = a };
    var flags_done = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!flags_done and std.mem.eql(u8, arg, "--")) {
            flags_done = true;
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            parseLong(&b, arg, &i, argv);
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-') {
            parseShort(&b, arg, &i, argv);
        } else if (b.pat == null and b.pat_files.items.len == 0) {
            // First bare arg is the pattern — unless a pattern source already
            // exists (`-f FILE`), in which case every positional is a PATH.
            b.pat = arg;
        } else {
            b.roots.append(a, arg) catch die("oom\n", .{});
        }
    }
    // --files / --type-list take no pattern; a stray "pattern" is actually a path.
    if (b.o.noPattern()) {
        if (b.pat) |p0| {
            b.roots.insert(a, 0, p0) catch die("oom\n", .{});
            b.pat = null;
        }
    } else if (b.pat == null and b.pat_files.items.len == 0) {
        die("usage: rg [flags] <pattern> [PATH...]\n", .{});
    }
    // Assemble the in-argv patterns (bare / -e / --regexp); pattern FILES are read
    // later by the caller (needs IO) and appended there.
    var pats: std.ArrayList([]const u8) = .empty;
    if (b.pat) |p0| pats.append(a, p0) catch die("oom\n", .{});
    pats.appendSlice(a, b.extra_pats.items) catch die("oom\n", .{});
    // -A/-B take precedence over -C regardless of order (ripgrep's rule).
    b.o.after = b.a_val orelse b.c_val orelse 0;
    b.o.before = b.b_val orelse b.c_val orelse 0;
    // -u = --no-ignore, -uu = +hidden. -uuu adds ripgrep's --binary (search binary
    // files, print "binary file matches") — gist is text/source-oriented and skips
    // binary, so that tier fails loud.
    if (b.urestrict >= 1) b.o.no_ignore = true;
    if (b.urestrict >= 2) b.o.hidden = true;
    if (b.urestrict >= 3) die("-uuu (--binary) unsupported — gist is text/source-oriented\n", .{});
    if (b.o.smart_case and !b.o.caseless) {
        var any_upper = false;
        for (pats.items) |pp| {
            if (hasUpper(pp)) {
                any_upper = true;
                break;
            }
        }
        if (!any_upper) b.o.caseless = true;
    }
    // --glob-case-insensitive: fold case-sensitive includes into the iglob set.
    if (b.glob_ci) {
        b.iglobs.appendSlice(a, b.includes.items) catch die("oom\n", .{});
        b.includes.clearRetainingCapacity();
    }
    b.o.filter = .{
        .exts = b.exts.toOwnedSlice(a) catch die("oom\n", .{}),
        .neg_exts = b.neg_exts.toOwnedSlice(a) catch die("oom\n", .{}),
        .includes = b.includes.toOwnedSlice(a) catch die("oom\n", .{}),
        .iglobs = b.iglobs.toOwnedSlice(a) catch die("oom\n", .{}),
        .excludes = b.excludes.toOwnedSlice(a) catch die("oom\n", .{}),
        .type_all = b.type_all,
        .ntype_all = b.ntype_all,
    };
    b.o.ignore_files = b.ignore_files.toOwnedSlice(a) catch die("oom\n", .{});
    return .{
        .patterns = pats.toOwnedSlice(a) catch die("oom\n", .{}),
        .opts = b.o,
        .roots = b.roots.toOwnedSlice(a) catch die("oom\n", .{}),
        .pattern_files = b.pat_files.toOwnedSlice(a) catch die("oom\n", .{}),
    };
}
