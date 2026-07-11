//! gist `rg` — the resolved option schema (`Opts`) and type/glob `Filter`.
//!
//! Split from `args.zig`: this is the pure result the argv lowering
//! (`flags.zig`) produces and every downstream engine reads. It owns no IO and
//! no parsing — just the record types (`Opts`, `Filter`, `Parsed`), the small
//! enums that shape them, the fatal-exit helper `die` (ripgrep's error code 2,
//! shared by parser and shell), and the glob-application logic the `Filter`
//! needs. `args.zig` re-exports every public name here, so `args.Opts` /
//! `args.Filter` / `args.die` call sites are unchanged.

const std = @import("std");
const glob = @import("../scope/glob.zig");
const types = @import("../scope/types.zig");

pub const Filename = enum { auto, always, never };

/// `--color`: `auto` (the default) colorizes iff stdout is a real terminal and
/// the environment doesn't opt out (`NO_COLOR`, `TERM=dumb`); `always`/`ansi`
/// force it on regardless of destination or environment; `never` forces it
/// off. Resolved against stdout + the environment in `color.zig`.
pub const ColorChoice = enum { auto, always, never, ansi };

/// Fatal exit with ripgrep's error code (2). Shared by the parser and the shell.
pub fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.process.exit(2);
}

fn lowerDup(a: std.mem.Allocator, s: []const u8) []u8 {
    const o = a.alloc(u8, s.len) catch die("oom\n", .{});
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}
fn globAppliesCI(a: std.mem.Allocator, pat: []const u8, path: []const u8) bool {
    return glob.globApplies(lowerDup(a, pat), lowerDup(a, path));
}

/// Resolved type/glob scope (`-t/-T/-g/--glob/--iglob`), AND-combined; each set
/// is a no-op when empty. Borrows caller-owned slices (a parse-time arena).
pub const Filter = struct {
    exts: []const []const u8 = &.{}, // -t (union of type globs, see scope/types.zig)
    neg_exts: []const []const u8 = &.{}, // -T
    includes: []const []const u8 = &.{}, // -g/--glob (case-sensitive)
    iglobs: []const []const u8 = &.{}, // --iglob (case-insensitive)
    excludes: []const []const u8 = &.{}, // -g '!…' / --glob '!…'
    type_all: bool = false, // -t all
    ntype_all: bool = false, // -T all

    pub fn hasInclude(self: Filter) bool {
        return self.exts.len > 0 or self.includes.len > 0 or self.iglobs.len > 0 or self.type_all;
    }
    pub fn admits(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        for (self.excludes) |g| if (glob.globApplies(g, path)) return false;
        for (self.neg_exts) |e| if (glob.globApplies(e, path)) return false;
        if (self.ntype_all and types.isKnownType(path)) return false;
        if (!self.hasInclude()) return true;
        for (self.exts) |e| if (glob.globApplies(e, path)) return true;
        if (self.type_all and types.isKnownType(path)) return true;
        for (self.includes) |g| if (glob.globApplies(g, path)) return true;
        for (self.iglobs) |g| if (globAppliesCI(a, g, path)) return true;
        return false;
    }
    /// ripgrep `Override` whitelist: does an explicit `-g`/`--glob`/`--iglob` glob
    /// force this path IN, OVERRIDING the hidden/ignore filters (`Match::Whitelist`
    /// short-circuit)? ONLY `-g`/`--iglob` form the override — `-t`/`-T` type
    /// filters do NOT bypass ignore, they layer on top of it. A `-g '!…'` exclude
    /// vetoes; empty include sets ⇒ no override (normal hidden/ignore stands).
    pub fn whitelists(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        if (self.includes.len == 0 and self.iglobs.len == 0) return false;
        for (self.excludes) |g| if (glob.globApplies(g, path)) return false;
        for (self.includes) |g| if (glob.globApplies(g, path)) return true;
        for (self.iglobs) |g| if (globAppliesCI(a, g, path)) return true;
        return false;
    }
    /// Does any include whitelist UN-HIDE this path (bypass the dotfile skip)? A
    /// `-g`/`--iglob` override does (via `whitelists`), and so does a `-t`/`-t all`
    /// TYPE match — ripgrep un-hides a dotfile that a type filter selects, even
    /// though a type filter never bypasses gitignore (that stays `whitelists`).
    pub fn whitelistsHidden(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        if (self.whitelists(a, path)) return true;
        for (self.exts) |e| if (glob.globApplies(e, path)) return true;
        return self.type_all and types.isKnownType(path);
    }
    /// True when any set constrains the file list (lets the caller skip the walk
    /// filter entirely on an unscoped query).
    pub fn active(self: Filter) bool {
        return self.hasInclude() or self.neg_exts.len > 0 or self.excludes.len > 0 or self.ntype_all;
    }
};

pub const Opts = struct {
    caseless: bool = false,
    smart_case: bool = false,
    word: bool = false,
    fixed: bool = false,
    invert: bool = false,
    only_matching: bool = false,
    line_num: bool = false,
    filename: Filename = .auto,
    before: usize = 0,
    after: usize = 0,
    max_per_file: usize = 0,
    count_only: bool = false,
    count_matches: bool = false,
    files_only: bool = false,
    files_without: bool = false,
    hidden: bool = false,
    text: bool = false,
    max_cols: usize = 0,
    max_cols_preview: bool = false, // --max-columns-preview
    passthru: bool = false, // --passthru (print every line)
    field_match_sep: []const u8 = ":", // --field-match-separator
    field_ctx_sep: []const u8 = "-", // --field-context-separator
    path_sep: ?[]const u8 = null,
    // presentation / locator flags
    column: bool = false, // --column
    byte_offset: bool = false, // -b/--byte-offset
    vimgrep: bool = false, // --vimgrep
    heading: bool = false, // --heading
    trim: bool = false, // --trim
    null_sep: bool = false, // --null/-0 (NUL after path)
    line_regexp: bool = false, // -x/--line-regexp
    quiet: bool = false, // -q/--quiet
    stats: bool = false, // --stats
    stop_on_nonmatch: bool = false, // --stop-on-nonmatch
    crlf: bool = false, // --crlf
    null_data: bool = false, // --null-data (NUL line terminator)
    multiline: bool = false, // -U/--multiline
    multiline_dotall: bool = false, // --multiline-dotall
    json: bool = false, // --json
    replace: ?[]const u8 = null, // -r/--replace
    // walk-scope flags
    files_list: bool = false, // --files (list, no pattern)
    type_list: bool = false, // --type-list (dump types, no pattern)
    follow: bool = false, // -L/--follow symlinks
    max_depth: usize = 0, // --max-depth/--maxdepth (0 = unlimited)
    max_filesize: usize = 0, // --max-filesize (bytes, 0 = unlimited)
    // ignore-rule flags (.gitignore/.ignore/.rgignore + --ignore-file); see rgignore.zig
    no_ignore: bool = false, // --no-ignore / -u (disable every ignore source)
    no_ignore_vcs: bool = false, // --no-ignore-vcs (.gitignore + exclude off)
    no_ignore_dot: bool = false, // --no-ignore-dot (.ignore/.rgignore off)
    no_ignore_parent: bool = false, // --no-ignore-parent (ancestors above CWD off)
    no_ignore_exclude: bool = false, // --no-ignore-exclude (.git/info/exclude off)
    no_ignore_files: bool = false, // --no-ignore-files (--ignore-file sources off)
    no_require_git: bool = false, // --no-require-git (honor .gitignore w/o a repo)
    ignore_case_insensitive: bool = false, // --ignore-file-case-insensitive
    ignore_files: []const []const u8 = &.{}, // --ignore-file <path> (ordered)
    // ctx_sep: null = suppressed line (--no-context-separator); else the string.
    ctx_sep: ?[]const u8 = "--",
    color: ColorChoice = .auto, // --color auto|always|never|ansi
    // --no-index: never consult the persisted trigram index — always live-read
    // every walked file. Default (false) auto-detects an index and uses it purely
    // to SKIP reading files it proves can't match (unchanged since the build and
    // not a trigram candidate); the walk + output stay byte-identical either way.
    // `--index` is the explicit opt-in spelling of that default (undo a prior
    // `--no-index`); neither ever changes results, only how many files are opened.
    no_index: bool = false,
    // --rank[=N]: gist-native ranked view (no rg equivalent) — definition-first
    // RRF over the indexed candidate set, top-K rows (`rank.zig`). `rank_k` = 0
    // means the default 20. Requires a persisted index (that's what it reads).
    rank: bool = false,
    rank_k: usize = 0,
    filter: Filter = .{},
    pub fn wantsContext(self: Opts) bool {
        return self.before > 0 or self.after > 0;
    }
    /// The line terminator byte: NUL under `--null-data`, else newline. Governs
    /// both how the input is split into lines and how each emitted line ends.
    pub fn term(self: Opts) u8 {
        return if (self.null_data) 0 else '\n';
    }
    /// True for the two "no pattern needed" modes.
    pub fn noPattern(self: Opts) bool {
        return self.files_list or self.type_list;
    }
};

pub const Parsed = struct { patterns: [][]const u8, opts: Opts, roots: [][]const u8, pattern_files: [][]const u8 = &.{} };
