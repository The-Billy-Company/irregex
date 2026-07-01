//! gist grep argv parser — the ripgrep-compatible flag surface an agent's
//! muscle memory actually types. Split out of `lines.zig` so the emit/verify
//! loop stays lean and the (larger) compatibility table lives on its own.
//!
//! WHY THIS SHAPE, DOGFOODED: gist's goal is to *replace* ripgrep in an agent
//! loop, so the parser must accept the invocations an agent reflexively writes,
//! not a hand-picked subset. Racing gist against `rg` as the agent surfaced
//! three silent/loud failures that each broke a reflexive call:
//!
//!   1. **Positional PATH args were dropped** — `grep WalletService services/`
//!      searched the *whole repo* while the agent believed it scoped to
//!      `services/` (a wrong-but-confident result, the worst agent failure).
//!      Now every non-flag token after the pattern is a path root, AND-ed into
//!      the `PathFilter` and pruned before any read — gist's structural edge.
//!   2. **Bundled short flags failed loud** — `-ln`, `-rn`, `-in`, `-nw` errored
//!      as "unknown flag" though each is a POSIX cluster. Now a `-xyz` cluster
//!      is decomposed left-to-right; the first *value* flag consumes the rest of
//!      the cluster as its argument (`-nC3` ⇒ `-n -C 3`, `-tgo` ⇒ `-t go`).
//!   3. **Harmless rg flags failed loud** — `-n`, `--no-heading`, `-H`, `-R`
//!      are all no-ops under gist's fixed `path:line:text` model, yet errored.
//!      Now they're accepted as no-ops so the reflexive `rg -n` just works, and
//!      `-N`/`--no-line-number` + `-S`/`--smart-case` are honored for real.
//!   4. **`-r`/`--replace` was mis-listed as a valueless no-op** — but rg's `-r`
//!      *consumes a value* (the replacement). Treating it as a boolean silently
//!      shifted argv: `grep -r X pat` parsed `X` as the pattern and `pat` as a
//!      path root — a wrong-but-confident empty result. It is now a value flag
//!      (`opts.replace`), the one landmine class this parser exists to kill.
//!   5. **Inline flag groups `(?i)` / `(?-u)` failed loud** — an agent pastes
//!      rg patterns carrying a leading global flag group reflexively. gist now
//!      honors the ones it can (`i`→caseless; `m`/`u`/`U`/`-…` no-op) and fails
//!      loud only on the ones it genuinely can't (`s` dotall, `x` extended),
//!      instead of rejecting the whole (legal-to-rg) pattern.
//!
//! Fail-loud is preserved for genuinely unknown flags (a silent empty result is
//! the worst failure) — the error now lists the full supported surface.

const std = @import("std");
const pathfilter = @import("pathfilter.zig");

pub const Options = struct {
    caseless: bool = false,
    /// Cap rows emitted per file (0 = unbounded). Mirrors `rg -m`; an agent
    /// rarely needs the 800th hit in a generated file and pays tokens for each.
    max_per_file: usize = 0,
    /// `--count-matches`: emit `path:N` where N is the number of individual
    /// (non-overlapping) match spans — distinct from `-c`/`--count`, which
    /// counts matching *lines*. Aliasing the two (the pre-fix bug) is a
    /// silent-wrong result on any line with >1 match (`e` → 165 lines vs 988
    /// matches); count-matches counts spans via the leftmost-first span engine.
    count_matches: bool = false,
    before: usize = 0, // `-B`/`-C`: context lines before each match
    after: usize = 0, // `-A`/`-C`: context lines after each match
    word: bool = false, // `-w`: wrap the pattern in `\b(…)\b`
    fixed: bool = false, // `-F`: treat the pattern as a literal (escape metachars)
    files_only: bool = false, // `-l`: emit matching paths only
    count_only: bool = false, // `-c`: emit `path:count`
    invert: bool = false, // `-v`: emit non-matching lines (forces seed-all)
    no_line_num: bool = false, // `-N`/`--no-line-number`: emit `path:text` (drop col)
    smart_case: bool = false, // `-S`: caseless iff the pattern has no uppercase
    only_matching: bool = false, // `-o`/`--only-matching`: emit each match span, not the line
    files_list: bool = false, // `--files`: list candidate files (no pattern, no read)
    /// `-r`/`--replace`: rewrite each match with this template before emit. `$0`
    /// / `${0}` / `$&` expand to the whole match, `$$` is a literal `$`. null ⇒
    /// no replacement. rg's `-r` *takes a value*, so leaving it a boolean no-op
    /// silently mis-parsed the replacement as the pattern (see parser note).
    replace: ?[]const u8 = null,
    filter: pathfilter.PathFilter = .{},

    pub fn wantsContext(self: Options) bool {
        return self.before > 0 or self.after > 0;
    }
};

pub const Parsed = struct {
    pattern: []const u8,
    opts: Options,
    // gpa-owned backing arrays for the filter; elements are borrowed (static
    // extension strings / argv glob + path slices), so only the arrays are freed.
    exts: []const []const u8,
    incs: []const []const u8,
    excs: []const []const u8,
    roots: []const []const u8,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        if (self.exts.len > 0) gpa.free(self.exts);
        if (self.incs.len > 0) gpa.free(self.incs);
        if (self.excs.len > 0) gpa.free(self.excs);
        if (self.roots.len > 0) gpa.free(self.roots);
    }
};

fn parseUsize(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn badVal(flag: []const u8) ?Parsed {
    std.debug.print("flag {s} needs a value\n", .{flag});
    return null;
}

const supported =
    "supported flags: -i -w -F -l -c -v -o -n -N -S -H -u -m N -A N -B N -C N " ++
    "-r <template> -t <lang> -g <glob> -e <pat> --  ·  long: --ignore-case --word-regexp " ++
    "--fixed-strings --files-with-matches --count --count-matches --invert-match --only-matching " ++
    "--no-line-number --smart-case --files --no-heading --color[=X] --replace=<template> " ++
    "--after/before/context=N --max-count=N --type=<lang> --glob=<glob> --regexp=<pat> " ++
    " ·  no-ops (gist already does): --hidden --no-ignore[-vcs/-parent/-dot] -u/--unrestricted --sort <key>" ++
    " ·  positional PATH args scope the search  ·  leading inline flags (?i)/(?-u)/(?m) honored";

/// The mutable parse state threaded through both the short-cluster and long-flag
/// handlers, so each flag setter is a single line at the call site.
const Sink = struct {
    gpa: std.mem.Allocator,
    opts: *Options,
    pattern: *?[]const u8,
    exts: *std.ArrayList([]const u8),
    incs: *std.ArrayList([]const u8),
    excs: *std.ArrayList([]const u8),

    fn setType(self: Sink, name: []const u8) !bool {
        const e = pathfilter.extsForType(name) orelse {
            std.debug.print("unknown type '{s}' for -t (try go/py/rust/ts/js/swift/zig/sql/proto/md/json/yaml/toml/sh)\n", .{name});
            return false;
        };
        try self.exts.appendSlice(self.gpa, e);
        return true;
    }
    fn addGlob(self: Sink, g: []const u8) !void {
        if (g.len > 0 and g[0] == '!') try self.excs.append(self.gpa, g[1..]) else try self.incs.append(self.gpa, g);
    }
    fn setPattern(self: Sink, p: []const u8) void {
        if (self.pattern.* == null) self.pattern.* = p;
    }
};

/// Decompose one `-xyz` short cluster. Each char is a boolean flag until the
/// first *value* flag, which consumes the cluster remainder (`-nC3` ⇒ n, C=3)
/// or, if it sits at the cluster end, the next argv token (`-C 3`). Returns
/// false on an unknown short flag or a missing value (fail loud).
fn parseShortCluster(sink: Sink, arg: []const u8, i: *usize, all: []const []const u8) !bool {
    var j: usize = 1; // past the leading '-'
    while (j < arg.len) : (j += 1) {
        const c = arg[j];
        // The value for a value-flag: the cluster tail if any, else next token.
        const takeVal = struct {
            fn get(a: []const u8, k: usize, idx: *usize, tokens: []const []const u8) ?[]const u8 {
                if (k + 1 < a.len) return a[k + 1 ..];
                if (idx.* + 1 < tokens.len) {
                    idx.* += 1;
                    return tokens[idx.*];
                }
                return null;
            }
        }.get;
        switch (c) {
            // ── boolean flags ──
            'i' => sink.opts.caseless = true,
            'w' => sink.opts.word = true,
            'F' => sink.opts.fixed = true,
            'l' => sink.opts.files_only = true,
            'c' => sink.opts.count_only = true,
            'v' => sink.opts.invert = true,
            'o' => sink.opts.only_matching = true,
            'N' => sink.opts.no_line_num = true,
            'S' => sink.opts.smart_case = true,
            // no-ops: gist's fixed `path:line:text` model already implies these.
            'n', 'H', 'R', 's' => {},
            // `-u`/`-uu` (`--unrestricted`): rg widens its corpus toward gist's
            // policy (search `.gitignore`d + hidden files). gist ALREADY does
            // this (its corpus ignores `.gitignore` and includes dotfiles — see
            // README "Scope vs ripgrep"), so the flag is a no-op, not an error.
            'u' => {},
            // recognized-but-unsupportable short flags: fail loud with the why.
            'P' => return unsupported("-P", why_pcre),
            'U' => return unsupported("-U", why_multiline),
            // ── value flags: consume the rest of the cluster (or next token) ──
            'r' => {
                sink.opts.replace = takeVal(arg, j, i, all) orelse return valErr("-r");
                return true;
            },
            'A' => {
                sink.opts.after = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-A")) orelse return valErr("-A");
                return true;
            },
            'B' => {
                sink.opts.before = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-B")) orelse return valErr("-B");
                return true;
            },
            'C' => {
                const n = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-C")) orelse return valErr("-C");
                sink.opts.before = n;
                sink.opts.after = n;
                return true;
            },
            'm' => {
                sink.opts.max_per_file = parseUsize(takeVal(arg, j, i, all) orelse return valErr("-m")) orelse return valErr("-m");
                return true;
            },
            't' => {
                if (!try sink.setType(takeVal(arg, j, i, all) orelse return valErr("-t"))) return false;
                return true;
            },
            'g' => {
                try sink.addGlob(takeVal(arg, j, i, all) orelse return valErr("-g"));
                return true;
            },
            'e' => {
                sink.setPattern(takeVal(arg, j, i, all) orelse return valErr("-e"));
                return true;
            },
            else => {
                std.debug.print("unknown flag '-{c}' in '{s}' — {s}\n", .{ c, arg, supported });
                return false;
            },
        }
    }
    return true;
}

fn valErr(flag: []const u8) bool {
    std.debug.print("flag {s} needs a value\n", .{flag});
    return false;
}

/// A flag gist *recognizes* but genuinely cannot honor (a different engine or
/// output model). Fail LOUD with the specific reason + the `rg` fallback — never
/// a silent wrong result, and never the generic "unknown flag" dump that leaves
/// an agent guessing whether it typo'd or hit a real limit. Returns false so the
/// caller bubbles the fail-loud exit.
fn unsupported(flag: []const u8, why: []const u8) bool {
    std.debug.print("flag {s} unsupported — {s}\n", .{ flag, why });
    return false;
}
const why_pcre = "gist runs a linear-time RE2-style engine (no backreferences or lookaround); use `rg -P <pat>` for a PCRE2 pattern";
const why_multiline = "gist matches per line (byte-oriented); use `rg -U <pat>` for a pattern that must span line boundaries";
const why_structured = "gist emits fixed `path:line:text` rows; use `rg --json`/`--vimgrep` for a structured or column-annotated format";

/// Split a `--name=value` long flag; `.val` is null for the bare `--name`.
const Long = struct { name: []const u8, val: ?[]const u8 };
fn splitLong(arg: []const u8) Long {
    const body = arg[2..];
    if (std.mem.indexOfScalar(u8, body, '=')) |eq|
        return .{ .name = body[0..eq], .val = body[eq + 1 ..] };
    return .{ .name = body, .val = null };
}

/// Handle one `--long` flag (with `=value` or a following token). Returns false
/// on an unknown flag or a missing value (fail loud).
fn parseLong(sink: Sink, arg: []const u8, i: *usize, all: []const []const u8) !bool {
    const lf = splitLong(arg);
    const nextTok = struct {
        fn get(idx: *usize, tokens: []const []const u8) ?[]const u8 {
            if (idx.* + 1 < tokens.len) {
                idx.* += 1;
                return tokens[idx.*];
            }
            return null;
        }
    }.get;
    const val = struct {
        fn get(lfv: ?[]const u8, idx: *usize, tokens: []const []const u8, nt: anytype) ?[]const u8 {
            return lfv orelse nt(idx, tokens);
        }
    }.get;

    const eq = std.mem.eql;
    if (eq(u8, lf.name, "ignore-case")) sink.opts.caseless = true else if (eq(u8, lf.name, "word-regexp")) sink.opts.word = true else if (eq(u8, lf.name, "fixed-strings")) sink.opts.fixed = true else if (eq(u8, lf.name, "files-with-matches")) sink.opts.files_only = true else if (eq(u8, lf.name, "count")) sink.opts.count_only = true else if (eq(u8, lf.name, "count-matches")) sink.opts.count_matches = true else if (eq(u8, lf.name, "invert-match")) sink.opts.invert = true else if (eq(u8, lf.name, "only-matching")) sink.opts.only_matching = true else if (eq(u8, lf.name, "files")) sink.opts.files_list = true else if (eq(u8, lf.name, "no-line-number")) sink.opts.no_line_num = true else if (eq(u8, lf.name, "smart-case")) sink.opts.smart_case = true else if (eq(u8, lf.name, "line-number") or eq(u8, lf.name, "no-heading") or eq(u8, lf.name, "heading") or eq(u8, lf.name, "with-filename") or eq(u8, lf.name, "no-filename") or eq(u8, lf.name, "recursive") or eq(u8, lf.name, "case-sensitive") or eq(u8, lf.name, "color") or
        // Corpus-policy no-ops: rg flags that widen its default corpus toward
        // what gist ALREADY searches — `.gitignore`d files, hidden dotfiles (see
        // README "Scope vs ripgrep"). gist's corpus is a superset, so asking for
        // these is asking for what it already does. An agent pastes them
        // reflexively; erroring forced a fallback to rg. (`-uuu`'s extra
        // "search binary files too" is the one documented divergence — gist
        // skips NUL-bearing files, same as its indexer.)
        eq(u8, lf.name, "hidden") or eq(u8, lf.name, "no-ignore") or eq(u8, lf.name, "no-ignore-vcs") or eq(u8, lf.name, "no-ignore-parent") or eq(u8, lf.name, "no-ignore-dot") or eq(u8, lf.name, "no-ignore-global") or eq(u8, lf.name, "no-ignore-files") or eq(u8, lf.name, "unrestricted") or eq(u8, lf.name, "one-file-system") or eq(u8, lf.name, "stats"))
    {
        // no-ops (gist has one fixed output model / already-superset corpus).
        // `--color[=X]` swallows an X.
        if (lf.val == null and eq(u8, lf.name, "color")) _ = nextTok(i, all);
    } else if (eq(u8, lf.name, "sort") or eq(u8, lf.name, "sortr")) {
        // gist emits results **path-ascending** already (a stable, deterministic
        // order — see runGrep's `cmpBlocks` sort). `--sort path` is exactly that,
        // so it's a no-op; other keys (`modified`/`created`/`accessed`) and
        // `--sortr` reverse can't be honored from the index, but path order is
        // the overwhelmingly common agent request. Swallow the value, keep going.
        _ = val(lf.val, i, all, nextTok) orelse return valErr("--sort");
    } else if (eq(u8, lf.name, "pcre2") or eq(u8, lf.name, "auto-hybrid-regex")) {
        return unsupported(arg, why_pcre);
    } else if (eq(u8, lf.name, "multiline") or eq(u8, lf.name, "multiline-dotall")) {
        return unsupported(arg, why_multiline);
    } else if (eq(u8, lf.name, "json") or eq(u8, lf.name, "vimgrep") or eq(u8, lf.name, "column")) {
        return unsupported(arg, why_structured);
    } else if (eq(u8, lf.name, "after-context")) {
        sink.opts.after = parseUsize(val(lf.val, i, all, nextTok) orelse return valErr("--after-context")) orelse return valErr("--after-context");
    } else if (eq(u8, lf.name, "before-context")) {
        sink.opts.before = parseUsize(val(lf.val, i, all, nextTok) orelse return valErr("--before-context")) orelse return valErr("--before-context");
    } else if (eq(u8, lf.name, "context")) {
        const n = parseUsize(val(lf.val, i, all, nextTok) orelse return valErr("--context")) orelse return valErr("--context");
        sink.opts.before = n;
        sink.opts.after = n;
    } else if (eq(u8, lf.name, "max-count")) {
        sink.opts.max_per_file = parseUsize(val(lf.val, i, all, nextTok) orelse return valErr("--max-count")) orelse return valErr("--max-count");
    } else if (eq(u8, lf.name, "type")) {
        if (!try sink.setType(val(lf.val, i, all, nextTok) orelse return valErr("--type"))) return false;
    } else if (eq(u8, lf.name, "glob")) {
        try sink.addGlob(val(lf.val, i, all, nextTok) orelse return valErr("--glob"));
    } else if (eq(u8, lf.name, "regexp")) {
        sink.setPattern(val(lf.val, i, all, nextTok) orelse return valErr("--regexp"));
    } else if (eq(u8, lf.name, "replace")) {
        sink.opts.replace = val(lf.val, i, all, nextTok) orelse return valErr("--replace");
    } else {
        std.debug.print("unknown flag '{s}' — {s}\n", .{ arg, supported });
        return false;
    }
    return true;
}

/// Parse `gist grep` argv (the tokens AFTER the `grep` verb). Returns null after
/// printing guidance on any error or a missing pattern. On success the caller
/// owns `Parsed` and must `deinit` it. Non-flag tokens: the first is the
/// pattern, every later one is a positional PATH root that scopes the search.
pub fn parseGrep(gpa: std.mem.Allocator, args: []const []const u8) !?Parsed {
    var opts: Options = .{};
    var pattern: ?[]const u8 = null;
    var exts: std.ArrayList([]const u8) = .empty;
    var incs: std.ArrayList([]const u8) = .empty;
    var excs: std.ArrayList([]const u8) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        exts.deinit(gpa);
        incs.deinit(gpa);
        excs.deinit(gpa);
        roots.deinit(gpa);
    }
    const sink = Sink{ .gpa = gpa, .opts = &opts, .pattern = &pattern, .exts = &exts, .incs = &incs, .excs = &excs };

    var i: usize = 0;
    var flags_done = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_flag = !flags_done and arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "--");
        if (!flags_done and std.mem.eql(u8, arg, "--")) {
            flags_done = true;
        } else if (is_flag and arg[1] == '-') {
            if (!try parseLong(sink, arg, &i, args)) return errClean(gpa, &exts, &incs, &excs, &roots);
        } else if (is_flag) {
            if (!try parseShortCluster(sink, arg, &i, args)) return errClean(gpa, &exts, &incs, &excs, &roots);
        } else if (pattern == null) {
            pattern = arg; // first non-flag is the pattern
        } else {
            try roots.append(gpa, pathfilter.normalizeRoot(arg)); // later non-flags scope
        }
    }

    // `--files` lists candidate files and takes no pattern (rg's `rg --files
    // [PATH…]`). Any token parsed as the "pattern" is really a path root, so
    // fold it back into the root set and run with an empty pattern.
    if (opts.files_list) {
        if (pattern) |p| try roots.append(gpa, pathfilter.normalizeRoot(p));
        pattern = "";
    }

    var pat = pattern orelse {
        std.debug.print("usage: grep [flags] <pattern> [PATH...]  (or --files [PATH...])\n{s}\n", .{supported});
        exts.deinit(gpa);
        incs.deinit(gpa);
        excs.deinit(gpa);
        roots.deinit(gpa);
        return null;
    };

    // `-S` smart-case: fold only when the pattern carries no uppercase (rg's
    // rule). `-i` always wins if also given. Resolved here so runGrep is unaware.
    if (opts.smart_case and !opts.caseless and !hasUpper(pat)) opts.caseless = true;

    // A leading inline flag group `(?i)`/`(?-u)`/`(?m)` (rg syntax) is honored
    // where gist can and rejected loud where it can't — but only when the
    // pattern is a regex: under `-F` the whole thing is a literal string, so
    // `(?i)` there is data, not a flag. Runs after smart-case so `(?i)` can win.
    if (!opts.fixed) {
        pat = applyInlineFlags(pat, &opts) orelse return errClean(gpa, &exts, &incs, &excs, &roots);
    }
    // Validate the `-r` template up front (fail loud, never mid-emit): only the
    // whole-match refs gist's span engine can honor are allowed.
    if (opts.replace) |tmpl| {
        if (!validReplaceTemplate(tmpl)) return errClean(gpa, &exts, &incs, &excs, &roots);
    }

    const exts_s = try exts.toOwnedSlice(gpa);
    const incs_s = try incs.toOwnedSlice(gpa);
    const excs_s = try excs.toOwnedSlice(gpa);
    const roots_s = try roots.toOwnedSlice(gpa);
    opts.filter = .{ .exts = exts_s, .includes = incs_s, .excludes = excs_s, .roots = roots_s };
    return .{ .pattern = pat, .opts = opts, .exts = exts_s, .incs = incs_s, .excs = excs_s, .roots = roots_s };
}

fn hasUpper(s: []const u8) bool {
    for (s) |c| if (c >= 'A' and c <= 'Z') return true;
    return false;
}

/// Strip a leading GLOBAL inline-flag group `(?flags)` (rg syntax), applying it
/// to `opts`, and return the pattern with the group removed (a borrowed
/// sub-slice, no alloc). rg lets a pattern begin with `(?i)`, `(?-u)`, `(?im)`,
/// … and an agent pastes them reflexively; rejecting the whole pattern forced a
/// fallback to rg. Flag map — each honored soundly or a documented no-op:
///   • `i` → caseless ASCII fold (the whole engine folds via `-i`); `-i` clears.
///   • `m` → no-op: gist matches per line, which *is* rg's default `^`/`$` mode.
///   • `u`/`U` (and any `-…` form) → no-op: gist is byte-oriented (== rg `(?-u)`);
///     `(?u)` differs only on non-ASCII, which byte-mode approximates.
/// Rejected LOUD (returns null after guidance — never a silent mis-match):
///   • `s` dotall (`.` spanning newlines) — gist is line-oriented and cannot;
///   • `x` extended/whitespace-insensitive — unsupported by the parser.
/// A non-flag `(?` — `(?:…)` non-capturing, `(?=…)` lookahead, `(?<name>…)` — is
/// left untouched for the regex compiler to accept or reject on its own terms.
fn applyInlineFlags(pat: []const u8, opts: *Options) ?[]const u8 {
    if (!std.mem.startsWith(u8, pat, "(?")) return pat;
    var negate = false;
    var j: usize = 2;
    while (j < pat.len) : (j += 1) {
        switch (pat[j]) {
            ')' => return pat[j + 1 ..], // consumed a handled global flag group
            ':' => return pat, // `(?flags:…)` scoped group — leave to the compiler
            '-' => negate = true,
            'i' => opts.caseless = !negate,
            'm', 'u', 'U' => {}, // no-ops (see doc)
            's', 'x' => |c| {
                if (negate) continue; // `(?-s)`/`(?-x)` turn OFF ⇒ already gist's default
                std.debug.print("inline flag '(?{c}…)' unsupported — gist is line-oriented, ASCII byte-mode (drop it, or use rg for a true dotall/extended pattern)\n", .{c});
                return null;
            },
            else => return pat, // not a recognized flag char ⇒ not a flag group
        }
    }
    return pat; // ran off the end with no ')' ⇒ not a valid group; let the compiler report it
}

/// A `-r` replacement template may only reference the whole match (`$0`, `${0}`,
/// `$&`) or an escaped literal `$` (`$$`), because gist's span engine tracks the
/// whole-match extent but not per-group captures. A numbered group ref (`$1`,
/// `${2}`, …) or a named ref is rejected LOUD here so the failure surfaces at
/// parse time, not as a silently dropped substitution mid-stream.
fn validReplaceTemplate(t: []const u8) bool {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '$') continue;
        if (i + 1 >= t.len) return true; // trailing '$' is a literal
        const n = t[i + 1];
        if (n == '$' or n == '&' or n == '0') {
            i += 1;
            continue;
        }
        if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, t, i + 2, '}') orelse {
                std.debug.print("bad -r template: unterminated '${{' in \"{s}\"\n", .{t});
                return false;
            };
            const name = t[i + 2 .. close];
            if (std.mem.eql(u8, name, "0")) {
                i = close;
                continue;
            }
            std.debug.print("-r group reference \"${{{s}}}\" unsupported — gist tracks the whole match only; use $0/${{0}}/$& (or rg for capture-group rewrites)\n", .{name});
            return false;
        }
        std.debug.print("-r group reference \"${c}\" unsupported — gist tracks the whole match only; use $0/${{0}}/$& (or rg for capture-group rewrites)\n", .{n});
        return false;
    }
    return true;
}

/// Free the filter arrays and return null — the fail-loud exit after a flag
/// handler already printed its diagnostic.
fn errClean(gpa: std.mem.Allocator, exts: *std.ArrayList([]const u8), incs: *std.ArrayList([]const u8), excs: *std.ArrayList([]const u8), roots: *std.ArrayList([]const u8)) ?Parsed {
    exts.deinit(gpa);
    incs.deinit(gpa);
    excs.deinit(gpa);
    roots.deinit(gpa);
    return null;
}
