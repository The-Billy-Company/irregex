//! gist search argv parser — the NATIVE flag vocabulary (Set B), the primary,
//! documented interface, plus the shared parse types and the orchestration loop.
//!
//! gist isn't grep and it isn't ripgrep — it's a persistent trigram index with
//! its own operations, so its flags say what gist DOES, not which competitor's
//! argv they ape. The native surface is a small, legible vocabulary:
//!
//!   --show <lines|files|count|ranked>   what shape to return (default: lines)
//!   --rank[=N]                          shorthand for --show ranked (top N=20)
//!   --lang <name>   --glob <pattern>    scope by language / path glob
//!   --word  --fixed  --ignore-case  --smart-case  --invert  --only-matching
//!   --before N  --after N  --context N  --limit N  --spans  --replace <tmpl>
//!   --live                              skip the index, scan the tree fresh
//!   --json                              structured records instead of path:line:text
//!   --pattern <pat>   --                explicit pattern / end of flags
//!
//! Every legacy ripgrep/grep spelling still works — that layer lives in the
//! sibling `compat.zig` (Set A), an alias onto exactly one native option, kept
//! separate so the primary vocabulary reads clean. This file owns the native
//! flags + the `Options`/`Parsed`/`Sink` types both sets mutate; `compat.zig`
//! borrows them. The two form a cycle (args ↔ compat) that Zig resolves lazily.

const std = @import("std");
const glob = @import("../scope/glob.zig");
const types = @import("../scope/types.zig");
const compat = @import("compat.zig");

/// What shape `search` returns. `--show <mode>` selects it; the legacy `-l`/`-c`
/// map onto `files`/`count`. `ranked` is the flagship "one best line" surface.
pub const Show = enum { lines, files, count, ranked };

pub const Options = struct {
    caseless: bool = false, // --ignore-case / -i
    /// Cap rows emitted per file (0 = unbounded). `--limit` / `-m`; an agent
    /// rarely needs the 800th hit in a generated file and pays tokens for each.
    max_per_file: usize = 0,
    /// `--spans` / `--count-matches`: with `--show count`, count individual
    /// (non-overlapping) match SPANS rather than matching lines — distinct
    /// results on any line with >1 match (`e` → 165 lines vs 988 spans).
    count_matches: bool = false,
    before: usize = 0, // --before / -B (and --context / -C)
    after: usize = 0, // --after / -A (and --context / -C)
    word: bool = false, // --word / -w: wrap the pattern in `\b(…)\b`
    fixed: bool = false, // --fixed / -F: literal pattern (escape metachars)
    files_only: bool = false, // --show files / -l: matching paths only
    count_only: bool = false, // --show count / -c: `path:count`
    invert: bool = false, // --invert / -v: non-matching lines (forces seed-all)
    no_line_num: bool = false, // -N/--no-line-number: emit `path:text` (drop col)
    smart_case: bool = false, // --smart-case / -S: caseless iff no uppercase
    only_matching: bool = false, // --only-matching / -o: emit each match span
    files_list: bool = false, // --files: list corpus files (no pattern, no read)
    live: bool = false, // --live: skip the index, scan the live tree fresh
    json: bool = false, // --json: emit structured records, not path:line:text
    ranked: bool = false, // --show ranked / --rank: RRF-ordered top-K
    rank_k: usize = 0, // --rank=N cap (0 ⇒ the default 20)
    /// `--replace <template>` / `-r`: rewrite each match before emit. `$0` /
    /// `${0}` / `$&` expand to the whole match, `$$` is a literal `$`. null ⇒ no
    /// replacement (capture-group refs are rejected loud at parse time).
    replace: ?[]const u8 = null,
    filter: glob.PathFilter = .{},

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

// ── shared low-level helpers (used by both the native and legacy handlers) ──

pub fn parseUsize(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

pub fn valErr(flag: []const u8) bool {
    std.debug.print("flag {s} needs a value\n", .{flag});
    return false;
}

/// The next argv token (advancing `i`), or null at the end. The separate-token
/// value source for a long flag / a cluster-terminal short value flag.
pub fn nextTok(i: *usize, all: []const []const u8) ?[]const u8 {
    if (i.* + 1 < all.len) {
        i.* += 1;
        return all[i.*];
    }
    return null;
}

/// A long flag's value: the glued `=value`, else the following token.
pub fn longVal(glued: ?[]const u8, i: *usize, all: []const []const u8) ?[]const u8 {
    return glued orelse nextTok(i, all);
}

/// Split a `--name=value` long flag; `.val` is null for the bare `--name`.
pub const Long = struct { name: []const u8, val: ?[]const u8 };
pub fn splitLong(arg: []const u8) Long {
    const body = arg[2..];
    if (std.mem.indexOfScalar(u8, body, '=')) |eq|
        return .{ .name = body[0..eq], .val = body[eq + 1 ..] };
    return .{ .name = body, .val = null };
}

/// The mutable parse state threaded through the native, short-cluster and legacy
/// long handlers, so each flag setter is a single line at the call site.
pub const Sink = struct {
    gpa: std.mem.Allocator,
    opts: *Options,
    pattern: *?[]const u8,
    exts: *std.ArrayList([]const u8),
    incs: *std.ArrayList([]const u8),
    excs: *std.ArrayList([]const u8),

    pub fn setType(self: Sink, name: []const u8) !bool {
        const e = types.extsForType(name) orelse {
            std.debug.print("unknown language '{s}' for --lang/-t (try go/py/rust/ts/js/swift/zig/sql/proto/md/json/yaml/toml/sh)\n", .{name});
            return false;
        };
        try self.exts.appendSlice(self.gpa, e);
        return true;
    }
    pub fn addGlob(self: Sink, g: []const u8) !void {
        if (g.len > 0 and g[0] == '!') try self.excs.append(self.gpa, g[1..]) else try self.incs.append(self.gpa, g);
    }
    pub fn setPattern(self: Sink, p: []const u8) void {
        if (self.pattern.* == null) self.pattern.* = p;
    }
};

/// Map a `--show <mode>` value onto the output booleans. Returns false (loud) on
/// an unknown mode — a typo'd shape must never silently degrade to lines.
fn setShow(sink: Sink, mode: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, mode, "lines")) {
        // the default; nothing to set
    } else if (eq(u8, mode, "files")) {
        sink.opts.files_only = true;
    } else if (eq(u8, mode, "count")) {
        sink.opts.count_only = true;
    } else if (eq(u8, mode, "ranked")) {
        sink.opts.ranked = true;
    } else {
        std.debug.print("unknown --show mode '{s}' — expected: lines | files | count | ranked\n", .{mode});
        return false;
    }
    return true;
}

/// Handle one `--long` flag. Tries the NATIVE vocabulary (Set B) first; anything
/// it doesn't recognize is delegated to the legacy alias layer (`compat`), which
/// either maps it onto a native option or fails loud as unknown. Returns false on
/// any error (missing value / unknown / unsupported).
pub fn handleLong(sink: Sink, arg: []const u8, i: *usize, all: []const []const u8) !bool {
    const lf = splitLong(arg);
    const eq = std.mem.eql;
    const n = lf.name;
    // ── boolean native flags ──
    if (eq(u8, n, "word")) sink.opts.word = true else if (eq(u8, n, "fixed")) sink.opts.fixed = true else if (eq(u8, n, "ignore-case")) sink.opts.caseless = true else if (eq(u8, n, "smart-case")) sink.opts.smart_case = true else if (eq(u8, n, "invert")) sink.opts.invert = true else if (eq(u8, n, "only-matching")) sink.opts.only_matching = true else if (eq(u8, n, "files")) sink.opts.files_list = true else if (eq(u8, n, "live")) sink.opts.live = true else if (eq(u8, n, "json")) sink.opts.json = true else if (eq(u8, n, "spans")) sink.opts.count_matches = true else if (eq(u8, n, "show")) {
        return setShow(sink, longVal(lf.val, i, all) orelse return valErr("--show"));
    } else if (eq(u8, n, "rank")) {
        // Optional value only via `=` (a separate token would be ambiguous with
        // the pattern). Bare `--rank` ⇒ the default top-K.
        sink.opts.ranked = true;
        if (lf.val) |v| sink.opts.rank_k = parseUsize(v) orelse return valErr("--rank");
    } else if (eq(u8, n, "lang")) {
        if (!try sink.setType(longVal(lf.val, i, all) orelse return valErr("--lang"))) return false;
    } else if (eq(u8, n, "glob")) {
        try sink.addGlob(longVal(lf.val, i, all) orelse return valErr("--glob"));
    } else if (eq(u8, n, "pattern")) {
        sink.setPattern(longVal(lf.val, i, all) orelse return valErr("--pattern"));
    } else if (eq(u8, n, "replace")) {
        sink.opts.replace = longVal(lf.val, i, all) orelse return valErr("--replace");
    } else if (eq(u8, n, "before")) {
        sink.opts.before = parseUsize(longVal(lf.val, i, all) orelse return valErr("--before")) orelse return valErr("--before");
    } else if (eq(u8, n, "after")) {
        sink.opts.after = parseUsize(longVal(lf.val, i, all) orelse return valErr("--after")) orelse return valErr("--after");
    } else if (eq(u8, n, "context")) {
        const k = parseUsize(longVal(lf.val, i, all) orelse return valErr("--context")) orelse return valErr("--context");
        sink.opts.before = k;
        sink.opts.after = k;
    } else if (eq(u8, n, "limit")) {
        sink.opts.max_per_file = parseUsize(longVal(lf.val, i, all) orelse return valErr("--limit")) orelse return valErr("--limit");
    } else {
        // Not a native flag — hand it to the legacy alias layer.
        return compat.longAlias(sink, arg, lf, i, all);
    }
    return true;
}

fn hasUpper(s: []const u8) bool {
    for (s) |c| if (c >= 'A' and c <= 'Z') return true;
    return false;
}

/// Free the filter arrays and return null — the fail-loud exit after a handler
/// already printed its diagnostic.
pub fn errClean(gpa: std.mem.Allocator, exts: *std.ArrayList([]const u8), incs: *std.ArrayList([]const u8), excs: *std.ArrayList([]const u8), roots: *std.ArrayList([]const u8)) ?Parsed {
    exts.deinit(gpa);
    incs.deinit(gpa);
    excs.deinit(gpa);
    roots.deinit(gpa);
    return null;
}

/// Parse `gist search` argv (the tokens AFTER the `search` verb). Returns null
/// after printing guidance on any error or a missing pattern. On success the
/// caller owns `Parsed` and must `deinit` it. Non-flag tokens: the first is the
/// pattern, every later one is a positional PATH root that scopes the search.
pub fn parseSearch(gpa: std.mem.Allocator, argv: []const []const u8) !?Parsed {
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
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const is_flag = !flags_done and arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "--");
        if (!flags_done and std.mem.eql(u8, arg, "--")) {
            flags_done = true;
        } else if (is_flag and arg[1] == '-') {
            if (!try handleLong(sink, arg, &i, argv)) return errClean(gpa, &exts, &incs, &excs, &roots);
        } else if (is_flag) {
            if (!try compat.shortCluster(sink, arg, &i, argv)) return errClean(gpa, &exts, &incs, &excs, &roots);
        } else if (pattern == null) {
            pattern = arg; // first non-flag is the pattern
        } else {
            try roots.append(gpa, glob.normalizeRoot(arg)); // later non-flags scope
        }
    }

    // `--files` lists candidate files and takes no pattern. Any token parsed as
    // the "pattern" is really a path root, so fold it back and run empty.
    if (opts.files_list) {
        if (pattern) |p| try roots.append(gpa, glob.normalizeRoot(p));
        pattern = "";
    }

    var pat = pattern orelse {
        std.debug.print("usage: gist search [flags] <pattern> [PATH...]  (or --files [PATH...])\n{s}\n", .{compat.supported});
        exts.deinit(gpa);
        incs.deinit(gpa);
        excs.deinit(gpa);
        roots.deinit(gpa);
        return null;
    };

    // `--smart-case`: fold only when the pattern carries no uppercase (rg's
    // rule). `--ignore-case` always wins if also given. Resolved here so the
    // engines are unaware.
    if (opts.smart_case and !opts.caseless and !hasUpper(pat)) opts.caseless = true;

    // A leading inline flag group `(?i)`/`(?-u)`/`(?m)` (rg syntax) is honored
    // where gist can and rejected loud where it can't — but only when the
    // pattern is a regex: under `--fixed` the whole thing is a literal string, so
    // `(?i)` there is data. Runs after smart-case so `(?i)` can win.
    if (!opts.fixed) {
        pat = compat.applyInlineFlags(pat, &opts) orelse return errClean(gpa, &exts, &incs, &excs, &roots);
    }
    // Validate the `--replace` template up front (fail loud, never mid-emit).
    if (opts.replace) |tmpl| {
        if (!compat.validReplaceTemplate(tmpl)) return errClean(gpa, &exts, &incs, &excs, &roots);
    }

    const exts_s = try exts.toOwnedSlice(gpa);
    const incs_s = try incs.toOwnedSlice(gpa);
    const excs_s = try excs.toOwnedSlice(gpa);
    const roots_s = try roots.toOwnedSlice(gpa);
    opts.filter = .{ .exts = exts_s, .includes = incs_s, .excludes = excs_s, .roots = roots_s };
    return .{ .pattern = pat, .opts = opts, .exts = exts_s, .incs = incs_s, .excs = excs_s, .roots = roots_s };
}
