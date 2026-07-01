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
//!   3. **Harmless rg flags failed loud** — `-n`, `--no-heading`, `-H`, `-r`
//!      are all no-ops under gist's fixed `path:line:text` model, yet errored.
//!      Now they're accepted as no-ops so the reflexive `rg -n` just works, and
//!      `-N`/`--no-line-number` + `-S`/`--smart-case` are honored for real.
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
    "supported flags: -i -w -F -l -c -v -o -n -N -S -H -r -m N -A N -B N -C N " ++
    "-t <lang> -g <glob> -e <pat> --  ·  long: --ignore-case --word-regexp " ++
    "--fixed-strings --files-with-matches --count --invert-match --only-matching " ++
    "--no-line-number --smart-case --files --no-heading --color[=X] " ++
    "--after/before/context=N --max-count=N --type=<lang> --glob=<glob> --regexp=<pat> " ++
    " ·  positional PATH args scope the search";

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
            'n', 'H', 'r', 'R', 's' => {},
            // ── value flags: consume the rest of the cluster (or next token) ──
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
    if (eq(u8, lf.name, "ignore-case")) sink.opts.caseless = true else if (eq(u8, lf.name, "word-regexp")) sink.opts.word = true else if (eq(u8, lf.name, "fixed-strings")) sink.opts.fixed = true else if (eq(u8, lf.name, "files-with-matches")) sink.opts.files_only = true else if (eq(u8, lf.name, "count") or eq(u8, lf.name, "count-matches")) sink.opts.count_only = true else if (eq(u8, lf.name, "invert-match")) sink.opts.invert = true else if (eq(u8, lf.name, "only-matching")) sink.opts.only_matching = true else if (eq(u8, lf.name, "files")) sink.opts.files_list = true else if (eq(u8, lf.name, "no-line-number")) sink.opts.no_line_num = true else if (eq(u8, lf.name, "smart-case")) sink.opts.smart_case = true else if (eq(u8, lf.name, "line-number") or eq(u8, lf.name, "no-heading") or eq(u8, lf.name, "heading") or eq(u8, lf.name, "with-filename") or eq(u8, lf.name, "no-filename") or eq(u8, lf.name, "recursive") or eq(u8, lf.name, "case-sensitive") or eq(u8, lf.name, "color")) {
        // no-ops (gist has one fixed output model). `--color[=X]` swallows an X.
        if (lf.val == null and eq(u8, lf.name, "color")) _ = nextTok(i, all);
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

    const pat = pattern orelse {
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

/// Free the filter arrays and return null — the fail-loud exit after a flag
/// handler already printed its diagnostic.
fn errClean(gpa: std.mem.Allocator, exts: *std.ArrayList([]const u8), incs: *std.ArrayList([]const u8), excs: *std.ArrayList([]const u8), roots: *std.ArrayList([]const u8)) ?Parsed {
    exts.deinit(gpa);
    incs.deinit(gpa);
    excs.deinit(gpa);
    roots.deinit(gpa);
    return null;
}
