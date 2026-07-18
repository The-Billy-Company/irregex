// MONOLITHIC: one argv grammar lowers the complete rg-compatible flag matrix into a single precedence-sensitive Opts state
//! gist `rg` — the ripgrep-compatible CLI flag surface (parsing only).
//!
//! Split from `run.zig` (the walk + match + emit shell) the same way the grep
//! verb's `args.zig` splits from its `emit.zig`: this module owns the argv → `Opts`
//! lowering and the type/glob `Filter`, and nothing about IO or matching. It
//! implements ripgrep's DEFAULT flag semantics — short-flag bundling, `--flag`
//! and `--flag=value`, `-A/-B` precedence over `-C`, the `-u/-uu` unrestrict
//! tiers, `-t/-T/-g/--glob/--iglob` scoping with `!`-exclude + leading-`/`
//! anchoring — and FAILS LOUD (exit 2) on any flag gist can't honor by design
//! (`-P`, `--binary`, `--encoding`, …), so the differential harness scores
//! those N/A rather than silently wrong. `flag_catalog` below is the parser and
//! `--schema` compatibility source of truth.

const std = @import("std");
const builtin = @import("builtin");
const glob = @import("../scope/glob.zig");
const types = @import("../scope/types.zig");
const uni = @import("../../regex/unicode/tables.zig");
const udec = @import("../../regex/unicode/decode.zig");
const encoding = @import("encoding.zig");

pub const Filename = enum { auto, always, never };

/// `--color`: `auto` (the default) colorizes iff stdout is a real terminal and
/// the environment doesn't opt out (`NO_COLOR`, `TERM=dumb`); `always`/`ansi`
/// force it on regardless of destination or environment; `never` forces it
/// off. Resolved against stdout + the environment in `color.zig`.
pub const ColorChoice = enum { auto, always, never, ansi };

/// `-E`/`--encoding`: the source encoding to transcode to UTF-8 before matching.
/// `auto` (the default) is BOM sniffing (UTF-8 BOM stripped, UTF-16 BOM
/// transcoded); `none` disables even that; the explicit labels force a transcode
/// regardless of any BOM. The enum and its full WHATWG label resolver live in
/// `encoding.zig` (which also owns the legacy-code-page decoders); `ingest.zig`
/// keeps the `auto`/`none`/UTF fast paths and delegates the rest there. Re-exported
/// here so the flag surface stays the one place argv semantics are read.
pub const Encoding = encoding.Encoding;

/// Resolve an `--encoding` label to the enum, or null for an unrecognized one
/// (the caller fails loud). The full WHATWG label table (`encoding_rs::for_label`,
/// which rg rides) plus gist's `auto`/`none` spellings — see `encoding.fromLabel`.
pub const encodingFromLabel = encoding.fromLabel;

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

/// Which match backend realizes the pattern (`-P`/`--pcre2`, `--engine=<name>`).
/// `default` is gist's linear-time RE2/Pike engine — no backtracking, no
/// lookaround/backreferences, safe over an adversarial tree. `pcre2` is the
/// opt-in vendored PCRE2 JIT backend (`../../regex/pcre2.zig`) for the constructs
/// the linear engine can't express. `auto` is ripgrep's hybrid: `run.zig` compiles
/// the linear engine first (its speed + trigram AST) and only escalates to PCRE2
/// for a pattern the linear engine declines (lookaround / backreferences). Both
/// backends are live and trigram-prefiltered; the choice is resolved and executed
/// in `run.zig`.
pub const Engine = enum { default, pcre2, auto };

/// `--sort`/`--sortr`/`--sort-files` ordering key. `none` (the default) leaves
/// gist free to stream in the fastest work-stealing discovery order; any other
/// key forces a globally ordered result. `path` sorts by the display path;
/// `modified`/`accessed`/`created` sort by the file's mtime/atime/birth time.
/// ripgrep abandons parallelism entirely when a sort is requested — gist keeps
/// its parallel *reads* and only orders the final emit, so an ordered gist run
/// still beats rg's single-threaded sort walk.
pub const SortKey = enum { none, path, modified, accessed, created };

fn parseSortKey(v: []const u8) SortKey {
    return std.meta.stringToEnum(SortKey, v) orelse
        die("bad --sort value: {s} (expected none, path, modified, accessed, or created)\n", .{v});
}

pub const Opts = struct {
    caseless: bool = false,
    smart_case: bool = false,
    // --unicode / --no-unicode (rg default ON). Governs the LINEAR engine's
    // Unicode mode: case folding over full case-fold orbits, `\w`/`\d`/`\s`/`.`
    // and `\p{…}` over codepoints, and Unicode `\b`/`\B`/`\<`/`\>`/`-w`. Cleared
    // (`(?-u)`/`--no-unicode`), the engine is a pure byte/ASCII matcher. `(?u)`/
    // `(?-u)` leading directives flip it per run. PCRE2 has its own `pcre_unicode`.
    unicode: bool = true,
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
    text: bool = false, // -a/--text: disable binary detection, search as text
    // --binary / -uuu: search binary files in full (never quit at the first NUL).
    // gist's flavor searches the whole file and prints every matching line — a
    // superset that never drops a match — rather than rg's binary-summary
    // suppression (documented divergence; both stop treating a NUL as a wall).
    binary: bool = false,
    // -z/--search-zip: transparently decompress by extension before searching
    // (gzip/zlib/zstd/xz in-process, the rest via the standard external tool).
    search_zip: bool = false,
    // --pre <cmd> (+ --pre-glob): run a preprocessor over each selected file and
    // search its stdout; overrides --search-zip. See `ingest.zig`.
    pre: ?[]const u8 = null,
    pre_globs: []const []const u8 = &.{}, // --pre-glob includes (empty ⇒ all)
    pre_excludes: []const []const u8 = &.{}, // --pre-glob '!…'
    encoding: Encoding = .auto, // -E/--encoding source encoding (transcode → UTF-8)
    max_cols: usize = 0,
    // Was --max-columns/-M given on the argv? Distinguishes an explicit `-M0`
    // (opt out of any cap) from the unset default, so the TTY-only long-line
    // guard (`run.zig`) applies only when the user expressed no preference.
    max_cols_set: bool = false,
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
    // Match-backend selection (-P/--pcre2, --engine, --auto-hybrid-regex).
    // `default` = the linear RE2/Pike engine; `pcre2` routes to the vendored
    // PCRE2 JIT backend; `auto` compiles linear and escalates to PCRE2 only for a
    // pattern the linear engine declines (run.zig resolves + executes the choice).
    engine: Engine = .default,
    pcre_unicode: bool = true, // --pcre2-unicode / --no-pcre2-unicode (PCRE2 Unicode mode)
    json: bool = false, // --json
    replace: ?[]const u8 = null, // -r/--replace
    // walk-scope flags
    files_list: bool = false, // --files (list, no pattern)
    type_list: bool = false, // --type-list (dump types, no pattern)
    follow: bool = false, // -L/--follow symlinks
    sorted: bool = false, // any explicit ordering active (drives rg's ignore-walker reanchor)
    sort_key: SortKey = .none, // --sort/--sortr key; .none = fastest discovery order
    sort_reverse: bool = false, // --sortr: descending instead of ascending
    threads: usize = 0, // -j/--threads: 0 = gist picks its topology; N caps the worker pool
    one_file_system: bool = false, // --one-file-system: never descend into another device
    max_depth: usize = 0, // --max-depth/--maxdepth (0 = unlimited)
    max_filesize: usize = 0, // --max-filesize (bytes, 0 = unlimited)
    // ignore-rule flags (.gitignore/.ignore/.rgignore + --ignore-file); see rgignore.zig
    no_ignore: bool = false, // --no-ignore / -u (disable every ignore source)
    no_ignore_vcs: bool = false, // --no-ignore-vcs (.gitignore + exclude off)
    no_ignore_dot: bool = false, // --no-ignore-dot (.ignore/.rgignore off)
    no_ignore_parent: bool = false, // --no-ignore-parent (ancestors above CWD off)
    no_ignore_exclude: bool = false, // --no-ignore-exclude (.git/info/exclude off)
    no_ignore_global: bool = false, // --no-ignore-global (git core.excludesFile off)
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
    // RRF over indexed candidates when available, else the live walk. `rank_k`
    // = 0 means the default 20; --no-index explicitly selects live ranking.
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

/// A `--type-add name:...` definition, resolved to the globs `-t name` scopes by.
const CustomType = struct { name: []const u8, globs: []const []const u8 };

/// Fatal exit with ripgrep's error code (2). Shared by the parser and the shell.
pub fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.process.exit(2);
}

/// Does the pattern carry an uppercase letter? Codepoint-aware for smart-case
/// (`-S`): any Unicode uppercase (`Ä`, `Σ`, …) — not just ASCII `A-Z` — disables
/// the automatic fold, matching rg's Unicode default. Ill-formed bytes are
/// skipped (never counted as uppercase).
fn hasUpper(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            if (s[i] >= 'A' and s[i] <= 'Z') return true;
            i += 1;
            continue;
        }
        const d = udec.decode(s[i..]) orelse {
            i += 1;
            continue;
        };
        if (uni.isUpper(d.cp)) return true;
        i += d.len;
    }
    return false;
}

fn lowerDup(a: std.mem.Allocator, s: []const u8) []u8 {
    const o = a.alloc(u8, s.len) catch die("oom\n", .{});
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}
fn globAppliesCI(a: std.mem.Allocator, pat: []const u8, path: []const u8) bool {
    return glob.globApplies(lowerDup(a, pat), lowerDup(a, path));
}

/// A leading `/` anchors a gitignore-style glob to the search root; gist already
/// matches such (slash-bearing) globs against the full path, so dropping the
/// anchor byte yields the same root-relative semantics.
fn stripAnchor(g: []const u8) []const u8 {
    return if (g.len > 0 and g[0] == '/') g[1..] else g;
}

/// RE2 metacharacters: a pattern containing any of these is a regex, otherwise
/// it's a plain literal an SIMD substring scan can serve directly. `-F`/`--fixed`
/// forces literal regardless (the whole string is data), so callers check that
/// before this — see `run.zig`'s `literalGate`, the one caller.
pub fn looksLikeRegex(pat: []const u8) bool {
    for (pat) |c| switch (c) {
        '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => return true,
        else => {},
    };
    return false;
}

/// Mutable parse state: resolves flags into Opts, collects type/glob sets, and
/// records -A/-B/-C values so -A/-B can take precedence over -C regardless of
/// argv order (ripgrep's rule), plus the `-u` repetition level.
const Builder = struct {
    a: std.mem.Allocator,
    o: Opts = .{},
    pat: ?[]const u8 = null,
    roots: std.ArrayList([]const u8) = .empty,
    exts: std.ArrayList([]const u8) = .empty,
    neg_exts: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    iglobs: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    pat_files: std.ArrayList([]const u8) = .empty, // -f/--file
    pre_globs: std.ArrayList([]const u8) = .empty, // --pre-glob includes
    pre_excludes: std.ArrayList([]const u8) = .empty, // --pre-glob '!…'
    extra_pats: std.ArrayList([]const u8) = .empty, // 2nd+ -e/--regexp
    ignore_files: std.ArrayList([]const u8) = .empty, // --ignore-file
    custom_types: std.ArrayList(CustomType) = .empty, // --type-add
    type_all: bool = false,
    ntype_all: bool = false,
    glob_ci: bool = false, // --glob-case-insensitive
    a_val: ?usize = null,
    b_val: ?usize = null,
    c_val: ?usize = null,
    urestrict: u8 = 0,

    /// Accumulate a pattern from `-e/--regexp` (or a bare pattern arg). The first
    /// becomes `pat`; each subsequent one is OR-combined at finalize (ripgrep ORs
    /// multiple `-e`). A literal (`-F`) alternation is handled downstream.
    fn addPat(self: *Builder, p: []const u8) void {
        if (self.pat == null) self.pat = p else self.extra_pats.append(self.a, p) catch die("oom\n", .{});
    }
    fn addType(self: *Builder, name: []const u8, negate: bool) void {
        if (std.mem.eql(u8, name, "all")) {
            if (negate) self.ntype_all = true else self.type_all = true;
            return;
        }
        // A user-defined `--type-add` type resolves to include/exclude globs; a
        // built-in resolves to its own glob set (scope/types.zig).
        if (self.customGlobs(name)) |globs| {
            (if (negate) &self.excludes else &self.includes).appendSlice(self.a, globs) catch die("oom\n", .{});
            return;
        }
        const e = types.extsForType(name) orelse die("unrecognized type: {s}\n", .{name});
        (if (negate) &self.neg_exts else &self.exts).appendSlice(self.a, e) catch die("oom\n", .{});
    }
    /// Register a `--type-add` spec: `name:glob` appends a glob to `name`; the
    /// `name:include:t1,t2` form aliases `name` to the union of other types.
    fn addTypeDef(self: *Builder, spec: []const u8) void {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse die("invalid --type-add: {s}\n", .{spec});
        const name = spec[0..colon];
        const rest = spec[colon + 1 ..];
        var globs: std.ArrayList([]const u8) = .empty;
        if (std.mem.startsWith(u8, rest, "include:")) {
            var it = std.mem.splitScalar(u8, rest["include:".len..], ',');
            while (it.next()) |t| {
                if (self.customGlobs(t)) |g| {
                    globs.appendSlice(self.a, g) catch die("oom\n", .{});
                } else if (types.extsForType(t)) |exts| {
                    // A built-in type's rows are already valid globs (scope/types.zig),
                    // so they slot straight into the `include:` union with no conversion.
                    globs.appendSlice(self.a, exts) catch die("oom\n", .{});
                } else die("unrecognized type: {s}\n", .{t});
            }
        } else {
            globs.append(self.a, rest) catch die("oom\n", .{});
        }
        self.custom_types.append(self.a, .{ .name = name, .globs = globs.toOwnedSlice(self.a) catch die("oom\n", .{}) }) catch die("oom\n", .{});
    }
    /// The accumulated globs for a user-defined type, or null if `name` is not one.
    fn customGlobs(self: *Builder, name: []const u8) ?[]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (self.custom_types.items) |ct| if (std.mem.eql(u8, ct.name, name)) {
            out.appendSlice(self.a, ct.globs) catch die("oom\n", .{});
            found = true;
        };
        return if (found) out.items else null;
    }
    fn addGlob(self: *Builder, g: []const u8, insensitive: bool) void {
        // `{a,b,c}` alternation (ripgrep/git glob): expand into the cartesian
        // product of every brace group up front, then register each variant.
        var variants: std.ArrayList([]const u8) = .empty;
        braceExpand(self.a, g, &variants);
        for (variants.items) |v| self.addGlobOne(v, insensitive);
    }
    /// `--pre-glob <g>`: which files `--pre` is fed. A leading `!` marks an
    /// exclude (vetoes), else an include; the leading `/` anchor is stripped the
    /// same way `-g` globs are, so both match against the full display path.
    fn addPreGlob(self: *Builder, g: []const u8) void {
        if (g.len > 0 and g[0] == '!') {
            self.pre_excludes.append(self.a, stripAnchor(g[1..])) catch die("oom\n", .{});
        } else {
            self.pre_globs.append(self.a, stripAnchor(g)) catch die("oom\n", .{});
        }
    }
    fn addGlobOne(self: *Builder, g: []const u8, insensitive: bool) void {
        if (g.len > 0 and g[0] == '!') {
            self.excludes.append(self.a, stripAnchor(g[1..])) catch die("oom\n", .{});
        } else if (insensitive) {
            self.iglobs.append(self.a, stripAnchor(g)) catch die("oom\n", .{});
        } else {
            self.includes.append(self.a, stripAnchor(g)) catch die("oom\n", .{});
        }
    }
};

/// Expand glob `{a,b,c}` alternations into every concrete pattern (cartesian
/// product across groups, nesting-aware). A pattern with no brace group yields
/// itself; an unbalanced `{` is left literal.
fn braceExpand(a: std.mem.Allocator, pat: []const u8, out: *std.ArrayList([]const u8)) void {
    const open = std.mem.indexOfScalar(u8, pat, '{') orelse {
        out.append(a, a.dupe(u8, pat) catch die("oom\n", .{})) catch die("oom\n", .{});
        return;
    };
    var depth: usize = 0;
    var close: ?usize = null;
    var i = open;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '{') depth += 1 else if (pat[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const c = close orelse {
        out.append(a, a.dupe(u8, pat) catch die("oom\n", .{})) catch die("oom\n", .{});
        return;
    };
    const prefix = pat[0..open];
    const suffix = pat[c + 1 ..];
    const inner = pat[open + 1 .. c];
    var start: usize = 0;
    var d: usize = 0;
    var j: usize = 0;
    while (j <= inner.len) : (j += 1) {
        const at_end = j == inner.len;
        if (!at_end and inner[j] == '{') d += 1 else if (!at_end and inner[j] == '}') d -= 1;
        if (at_end or (inner[j] == ',' and d == 0)) {
            const combined = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, inner[start..j], suffix }) catch die("oom\n", .{});
            braceExpand(a, combined, out); // recurse to expand any remaining groups
            start = j + 1;
        }
    }
}

fn takeVal(a: []const u8, k: usize, i: *usize, all: []const []const u8) []const u8 {
    if (k + 1 < a.len) return a[k + 1 ..];
    if (i.* + 1 < all.len) {
        i.* += 1;
        return all[i.*];
    }
    die("flag -{c} needs a value\n", .{a[k]});
}
fn nextTok(i: *usize, all: []const []const u8) []const u8 {
    if (i.* + 1 < all.len) {
        i.* += 1;
        return all[i.*];
    }
    die("flag needs a value\n", .{});
}
fn toU(s: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch die("bad number '{s}'\n", .{s});
}

/// Decode ripgrep's C-style escapes in a separator value (`--field-*-separator`,
/// `--context-separator`): `\n \r \t \0 \\` and `\xNN`. Anything else after a
/// backslash is kept verbatim (rg's lenient rule). Returns `s` unchanged when it
/// has no backslash (the common case).
fn unescape(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            out.append(a, s[i]) catch die("oom\n", .{});
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => out.append(a, '\n') catch die("oom\n", .{}),
            'r' => out.append(a, '\r') catch die("oom\n", .{}),
            't' => out.append(a, '\t') catch die("oom\n", .{}),
            '0' => out.append(a, 0) catch die("oom\n", .{}),
            '\\' => out.append(a, '\\') catch die("oom\n", .{}),
            'x' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch die("bad \\x escape\n", .{});
                    out.append(a, hi) catch die("oom\n", .{});
                    i += 2;
                } else die("bad \\x escape\n", .{});
            },
            else => {
                out.append(a, '\\') catch die("oom\n", .{});
                out.append(a, s[i]) catch die("oom\n", .{});
            },
        }
    }
    return out.toOwnedSlice(a) catch die("oom\n", .{});
}

/// Parse a `--max-filesize` value: a decimal with an optional `K`/`M`/`G` (1024-
/// based) suffix, e.g. `50`, `4K`, `1M` (ripgrep's grammar).
fn toBytes(s: []const u8) usize {
    if (s.len == 0) die("bad size ''\n", .{});
    const mult: usize = switch (s[s.len - 1]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    return toU(digits) * mult;
}

const Act = enum {
    icase,
    scase,
    smart,
    word,
    fixed,
    invert,
    only,
    lnum,
    no_lnum,
    with_fn,
    no_fn,
    fwm,
    fwithout,
    count,
    cmatches,
    hidden,
    text,
    binary,
    search_zip,
    pre,
    pre_glob,
    encoding,
    unrestrict,
    column,
    no_column,
    byteoff,
    vimgrep,
    heading,
    no_heading,
    trim,
    nul,
    nul_data,
    xline,
    quiet,
    stats,
    passthru,
    maxcols_preview,
    stop_nonmatch,
    crlf,
    ml,
    ml_dotall,
    json,
    files,
    type_list,
    follow,
    no_follow,
    threads,
    one_file_system,
    no_stats,
    no_trim,
    sort_files,
    sort,
    sortr,
    glob_ci, // value-taking below
    no_ignore,
    no_ignore_vcs,
    no_ignore_dot,
    no_ignore_parent,
    no_ignore_exclude,
    no_ignore_global,
    no_ignore_files,
    ignore_files,
    no_require_git,
    require_git,
    ignore_file_ci,
    after,
    before,
    ctx,
    maxcount,
    regexp,
    typ,
    typ_not,
    glob,
    iglob,
    maxcols,
    pathsep,
    maxdepth,
    maxfsize,
    ctxsep,
    no_ctxsep,
    fieldmsep,
    fieldcsep,
    replace,
    file,
    ignore_file,
    type_add,
    color,
    no_index,
    index,
    rank,
    pcre, // -P/--pcre2: select the PCRE2 backend
    engine, // --engine=<default|pcre2|auto>: select the match backend by name
    auto_hybrid, // --auto-hybrid-regex: rg's deprecated spelling of --engine auto
    pcre_unicode, // --pcre2-unicode: PCRE2 Unicode mode on
    no_pcre_unicode, // --no-pcre2-unicode: PCRE2 Unicode mode off
    unicode, // --unicode: linear-engine Unicode mode on (rg default)
    no_unicode, // --no-unicode: linear-engine Unicode mode off (byte/ASCII)
    noop,
    noop_val,
    unsupported,
};

/// Public compatibility buckets emitted by `gist --schema`. `.native` rows are
/// gist additions, emitted separately from the four-bucket ripgrep matrix.
pub const Compatibility = enum {
    supported,
    supported_with_differences,
    accepted_but_ignored,
    unsupported_fail_loud,
    native,
};

/// One declarative parser row. Both argv dispatch maps and `--schema` derive
/// from this catalog, so accepting, ignoring, or rejecting a flag cannot drift
/// from the machine-readable contract.
pub const FlagSpec = struct {
    short: ?u8 = null,
    longs: []const []const u8 = &.{},
    action: Act,
    compatibility: Compatibility,
    note: ?[]const u8 = null,
};

pub const flag_catalog = [_]FlagSpec{
    .{ .short = 'i', .longs = &.{"ignore-case"}, .action = .icase, .compatibility = .supported, .note = "Unicode case folding by default (full simple case-fold orbits); (?-u)/--no-unicode selects ASCII folding" },
    .{ .short = 's', .longs = &.{"case-sensitive"}, .action = .scase, .compatibility = .supported },
    .{ .short = 'S', .longs = &.{"smart-case"}, .action = .smart, .compatibility = .supported, .note = "codepoint-aware uppercase detection and Unicode folding by default; (?-u)/--no-unicode selects ASCII" },
    .{ .short = 'w', .longs = &.{"word-regexp"}, .action = .word, .compatibility = .supported, .note = "-w and regex \\b/\\w use Unicode word characters by default (rg parity); (?-u)/--no-unicode selects ASCII byte word chars" },
    .{ .short = 'F', .longs = &.{"fixed-strings"}, .action = .fixed, .compatibility = .supported },
    .{ .short = 'v', .longs = &.{"invert-match"}, .action = .invert, .compatibility = .supported },
    .{ .short = 'o', .longs = &.{"only-matching"}, .action = .only, .compatibility = .supported },
    .{ .short = 'n', .longs = &.{"line-number"}, .action = .lnum, .compatibility = .supported },
    .{ .short = 'N', .longs = &.{"no-line-number"}, .action = .no_lnum, .compatibility = .supported },
    .{ .short = 'H', .longs = &.{"with-filename"}, .action = .with_fn, .compatibility = .supported },
    .{ .short = 'I', .longs = &.{"no-filename"}, .action = .no_fn, .compatibility = .supported },
    .{ .short = 'l', .longs = &.{"files-with-matches"}, .action = .fwm, .compatibility = .supported },
    .{ .longs = &.{"files-without-match"}, .action = .fwithout, .compatibility = .supported },
    .{ .short = 'c', .longs = &.{"count"}, .action = .count, .compatibility = .supported },
    .{ .longs = &.{"count-matches"}, .action = .cmatches, .compatibility = .supported },
    .{ .longs = &.{"hidden"}, .action = .hidden, .compatibility = .supported },
    .{ .short = 'a', .longs = &.{"text"}, .action = .text, .compatibility = .supported },
    .{ .longs = &.{"binary"}, .action = .binary, .compatibility = .supported_with_differences, .note = "searches binary files in full and prints every matching line (a superset), rather than rg's binary-summary suppression" },
    .{ .short = 'u', .longs = &.{"unrestricted"}, .action = .unrestrict, .compatibility = .supported_with_differences, .note = "-u=--no-ignore, -uu adds hidden, -uuu adds --binary (search binary files in full)" },
    .{ .longs = &.{"column"}, .action = .column, .compatibility = .supported },
    .{ .longs = &.{"no-column"}, .action = .no_column, .compatibility = .supported },
    .{ .short = 'b', .longs = &.{"byte-offset"}, .action = .byteoff, .compatibility = .supported },
    .{ .longs = &.{"vimgrep"}, .action = .vimgrep, .compatibility = .supported },
    .{ .longs = &.{"heading"}, .action = .heading, .compatibility = .supported },
    .{ .longs = &.{"no-heading"}, .action = .no_heading, .compatibility = .supported },
    .{ .longs = &.{"trim"}, .action = .trim, .compatibility = .supported },
    .{ .short = '0', .longs = &.{"null"}, .action = .nul, .compatibility = .supported },
    .{ .longs = &.{"null-data"}, .action = .nul_data, .compatibility = .supported },
    .{ .short = 'x', .longs = &.{"line-regexp"}, .action = .xline, .compatibility = .supported },
    .{ .short = 'q', .longs = &.{"quiet"}, .action = .quiet, .compatibility = .supported },
    .{ .longs = &.{"stats"}, .action = .stats, .compatibility = .supported },
    .{ .longs = &.{"stop-on-nonmatch"}, .action = .stop_nonmatch, .compatibility = .supported },
    .{ .longs = &.{ "passthru", "passthrough" }, .action = .passthru, .compatibility = .supported },
    .{ .longs = &.{"max-columns-preview"}, .action = .maxcols_preview, .compatibility = .supported },
    .{ .longs = &.{"field-match-separator"}, .action = .fieldmsep, .compatibility = .supported },
    .{ .longs = &.{"field-context-separator"}, .action = .fieldcsep, .compatibility = .supported },
    .{ .longs = &.{"crlf"}, .action = .crlf, .compatibility = .supported },
    .{ .short = 'U', .longs = &.{"multiline"}, .action = .ml, .compatibility = .supported },
    .{ .longs = &.{"multiline-dotall"}, .action = .ml_dotall, .compatibility = .supported },
    .{ .longs = &.{"json"}, .action = .json, .compatibility = .supported },
    .{ .longs = &.{"files"}, .action = .files, .compatibility = .supported },
    .{ .longs = &.{"type-list"}, .action = .type_list, .compatibility = .supported_with_differences, .note = "rg-sorted, rg-framed output over a strict SUPERSET of rg's type registry (most rows byte-identical; the rest richer, plus gist-only types)" },
    .{ .short = 'L', .longs = &.{"follow"}, .action = .follow, .compatibility = .supported },
    .{ .longs = &.{"no-follow"}, .action = .no_follow, .compatibility = .supported },
    .{ .longs = &.{"sort-files"}, .action = .sort_files, .compatibility = .supported, .note = "deprecated rg spelling of --sort=path" },
    .{ .longs = &.{"sort"}, .action = .sort, .compatibility = .supported_with_differences, .note = "path/modified/accessed/created, ascending; gist orders a parallel read (rg single-threads sort). created falls back to ctime where the platform lacks birth time" },
    .{ .longs = &.{"sortr"}, .action = .sortr, .compatibility = .supported_with_differences, .note = "as --sort but descending; same parallel-read ordering and created fallback" },
    .{ .longs = &.{"glob-case-insensitive"}, .action = .glob_ci, .compatibility = .supported },
    .{ .short = 'A', .longs = &.{"after-context"}, .action = .after, .compatibility = .supported },
    .{ .short = 'B', .longs = &.{"before-context"}, .action = .before, .compatibility = .supported },
    .{ .short = 'C', .longs = &.{"context"}, .action = .ctx, .compatibility = .supported },
    .{ .short = 'm', .longs = &.{"max-count"}, .action = .maxcount, .compatibility = .supported },
    .{ .short = 'e', .longs = &.{"regexp"}, .action = .regexp, .compatibility = .supported },
    .{ .short = 't', .longs = &.{"type"}, .action = .typ, .compatibility = .supported },
    .{ .short = 'T', .longs = &.{"type-not"}, .action = .typ_not, .compatibility = .supported },
    .{ .short = 'g', .longs = &.{"glob"}, .action = .glob, .compatibility = .supported },
    .{ .longs = &.{"iglob"}, .action = .iglob, .compatibility = .supported },
    .{ .short = 'M', .longs = &.{"max-columns"}, .action = .maxcols, .compatibility = .supported },
    .{ .longs = &.{"path-separator"}, .action = .pathsep, .compatibility = .supported },
    .{ .longs = &.{ "max-depth", "maxdepth" }, .action = .maxdepth, .compatibility = .supported },
    .{ .longs = &.{"max-filesize"}, .action = .maxfsize, .compatibility = .supported },
    .{ .longs = &.{"context-separator"}, .action = .ctxsep, .compatibility = .supported },
    .{ .longs = &.{"no-context-separator"}, .action = .no_ctxsep, .compatibility = .supported },
    .{ .short = 'r', .longs = &.{"replace"}, .action = .replace, .compatibility = .supported },
    .{ .short = 'f', .longs = &.{"file"}, .action = .file, .compatibility = .supported },
    .{ .longs = &.{"type-add"}, .action = .type_add, .compatibility = .supported },
    .{ .longs = &.{"color"}, .action = .color, .compatibility = .supported },
    // Ignore-rule controls honored by the in-tree .gitignore/.ignore engine.
    .{ .longs = &.{"no-ignore"}, .action = .no_ignore, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-vcs"}, .action = .no_ignore_vcs, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-dot"}, .action = .no_ignore_dot, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-parent"}, .action = .no_ignore_parent, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-exclude"}, .action = .no_ignore_exclude, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-files"}, .action = .no_ignore_files, .compatibility = .supported },
    .{ .longs = &.{"ignore-files"}, .action = .ignore_files, .compatibility = .supported },
    .{ .longs = &.{"no-require-git"}, .action = .no_require_git, .compatibility = .supported },
    .{ .longs = &.{"require-git"}, .action = .require_git, .compatibility = .supported },
    .{ .longs = &.{"ignore-file-case-insensitive"}, .action = .ignore_file_ci, .compatibility = .supported },
    .{ .longs = &.{"ignore-file"}, .action = .ignore_file, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-global"}, .action = .no_ignore_global, .compatibility = .supported, .note = "git core.excludesFile ($HOME/.gitconfig or $XDG_CONFIG_HOME/git/config → default $XDG_CONFIG_HOME/git/ignore) is read by default in a repo; this disables that global tier only" },
    // Gist-native index controls are not ripgrep compatibility claims.
    .{ .longs = &.{"no-index"}, .action = .no_index, .compatibility = .native },
    .{ .longs = &.{"index"}, .action = .index, .compatibility = .native },
    .{ .longs = &.{"rank"}, .action = .rank, .compatibility = .native },
    // Accepted spellings whose requested behavior is intentionally not applied.
    .{ .longs = &.{ "mmap", "no-mmap" }, .action = .noop, .compatibility = .accepted_but_ignored },
    .{ .longs = &.{"one-file-system"}, .action = .one_file_system, .compatibility = .supported },
    .{ .longs = &.{"unicode"}, .action = .unicode, .compatibility = .supported, .note = "linear-engine Unicode mode (rg default): full case-fold orbits, codepoint \\w/\\d/\\s/./\\p{…}, and Unicode \\b/\\B/\\<\\>/-w" },
    .{ .longs = &.{"no-unicode"}, .action = .no_unicode, .compatibility = .supported, .note = "byte/ASCII mode: single-byte classes and ASCII \\w/\\b (equivalent to a leading (?-u))" },
    .{ .longs = &.{"no-stats"}, .action = .no_stats, .compatibility = .supported },
    .{ .longs = &.{"no-trim"}, .action = .no_trim, .compatibility = .supported },
    .{ .longs = &.{"colors"}, .action = .noop_val, .compatibility = .accepted_but_ignored },
    .{ .short = 'j', .longs = &.{"threads"}, .action = .threads, .compatibility = .supported_with_differences, .note = "caps the work-stealing worker pool at N (0 = gist's own topology); rg's thread count is advisory here since gist adapts workers to scan breadth" },
    // Match-backend selection. `--engine default` is the linear engine; `--engine
    // auto` compiles linear and escalates to the PCRE2 backend only for a pattern
    // the linear engine declines; `--engine pcre2` / `-P` select PCRE2 outright.
    .{ .longs = &.{"engine"}, .action = .engine, .compatibility = .supported_with_differences, .note = "default = linear RE2/Pike engine; auto escalates to PCRE2 only for lookaround/backreferences the linear engine declines; pcre2 selects PCRE2 outright. --rank is linear-only" },
    // PCRE2 Unicode (UTF+UCP) mode — effective under -P / escalated auto; inert
    // under the linear default, which is always ASCII-byte based.
    .{ .longs = &.{"pcre2-unicode"}, .action = .pcre_unicode, .compatibility = .supported_with_differences, .note = "PCRE2 UTF+UCP mode (rg's -P default); effective under -P/auto, inert under the linear default" },
    .{ .longs = &.{"no-pcre2-unicode"}, .action = .no_pcre_unicode, .compatibility = .supported_with_differences, .note = "PCRE2 raw-byte/ASCII mode; effective under -P/auto, inert under the linear default" },
    .{ .longs = &.{ "dfa-size-limit", "regex-size-limit" }, .action = .noop_val, .compatibility = .accepted_but_ignored },
    // The opt-in PCRE2 JIT backend (vendored 10.47) and rg's deprecated hybrid alias.
    .{ .short = 'P', .longs = &.{"pcre2"}, .action = .pcre, .compatibility = .supported_with_differences, .note = "selects the vendored PCRE2 JIT backend (lookaround, backreferences, Unicode properties); trigram-prefiltered like the linear engine, so it is the only indexed PCRE search in the field. --rank is linear-only" },
    .{ .longs = &.{"auto-hybrid-regex"}, .action = .auto_hybrid, .compatibility = .supported_with_differences, .note = "rg's deprecated spelling of --engine auto; escalates to PCRE2 only for a pattern the linear engine declines" },
    // Content-transform flags: decompression + preprocessing + transcoding. The
    // common compressed formats decode in-process (no fork) — see `ingest.zig`.
    .{ .short = 'z', .longs = &.{"search-zip"}, .action = .search_zip, .compatibility = .supported_with_differences, .note = "gzip/zlib/zstd/xz decode in-process (faster than rg's per-file fork); bzip2/lz4/brotli/lzma/.Z shell the standard tool" },
    .{ .longs = &.{"pre"}, .action = .pre, .compatibility = .supported_with_differences, .note = "the command receives the file path as argv[1] (stdin is closed); a non-zero exit is an error (exit 2)" },
    .{ .longs = &.{"pre-glob"}, .action = .pre_glob, .compatibility = .supported },
    .{ .short = 'E', .longs = &.{"encoding"}, .action = .encoding, .compatibility = .supported, .note = "auto/none + the full WHATWG label table (rg's encoding_rs set): UTF-8/16, the single-byte pages, and CJK gb18030/GBK, Big5, EUC-JP, Shift_JIS, EUC-KR, ISO-2022-JP; an unrecognized label fails loud" },
};

const LongPair = struct { []const u8, usize };

fn longPairCount() usize {
    var count: usize = 0;
    for (flag_catalog) |spec| count += spec.longs.len;
    return count;
}

fn makeLongPairs() [longPairCount()]LongPair {
    var pairs: [longPairCount()]LongPair = undefined;
    var n: usize = 0;
    for (flag_catalog, 0..) |spec, spec_i| for (spec.longs) |name| {
        pairs[n] = .{ name, spec_i };
        n += 1;
    };
    return pairs;
}

const long_map = std.StaticStringMap(usize).initComptime(makeLongPairs());
const short_map: [256]?usize = blk: {
    var map: [256]?usize = @splat(null);
    for (flag_catalog, 0..) |spec, spec_i| if (spec.short) |short| {
        if (map[short] != null) @compileError("duplicate short flag in flag_catalog");
        map[short] = spec_i;
    };
    break :blk map;
};

/// The `-rn` footgun: grep muscle memory reads `-rn` as "recursive + line
/// numbers", but rg short-flag bundling (which gist matches byte-for-byte)
/// parses it as `--replace=n` — every match silently rewritten to `n`, output
/// that looks mangled rather than wrong. True iff a bundled `-r` value is a
/// short string made entirely of known short flags (`n`, `ni`, `l`, …), i.e.
/// almost certainly an intended flag bundle. Replacement templates (`$1`,
/// `${name}`) and longer text never qualify.
fn looksLikeFlagBundle(v: []const u8) bool {
    if (v.len == 0 or v.len > 3) return false;
    for (v) |c| if (short_map[c] == null) return false;
    return true;
}

/// Emit the `-rn` grep-ism note on stderr. Behavior stays rg-identical (parity
/// is sacred and the differential harness compares stdout only) — this only
/// tells the user what actually happened so an agent doesn't misread replaced
/// output as a display bug.
fn noteGrepStyleReplace(v: []const u8) void {
    if (!looksLikeFlagBundle(v)) return;
    // Silent under `zig build test`: the unit test parses "-rn" on purpose, and
    // stderr from a passing test binary makes the build runner print a spurious
    // "failed command:" banner. The note is user-guidance, not behavior.
    if (builtin.is_test) return;
    std.debug.print(
        "gist: note: '-r{s}' parses as --replace={s} (ripgrep semantics: -r takes a value; recursion is already the default). Spell flags separately (e.g. -n), or use --replace to silence this note.\n",
        .{ v, v },
    );
}

fn parseShort(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    var j: usize = 1;
    while (j < arg.len) : (j += 1) {
        const spec = flag_catalog[short_map[arg[j]] orelse die("unknown flag -{c}\n", .{arg[j]})];
        switch (spec.action) {
            .icase => b.o.caseless = true,
            .scase => b.o.caseless = false,
            .smart => b.o.smart_case = true,
            .word => b.o.word = true,
            .fixed => b.o.fixed = true,
            .invert => b.o.invert = true,
            .only => b.o.only_matching = true,
            .lnum => b.o.line_num = true,
            .no_lnum => b.o.line_num = false,
            .with_fn => b.o.filename = .always,
            .no_fn => b.o.filename = .never,
            .fwm => b.o.files_only = true,
            .count => b.o.count_only = true,
            .text => b.o.text = true,
            .binary => b.o.binary = true,
            .search_zip => b.o.search_zip = true,
            .encoding => {
                b.o.encoding = encodingFromLabel(takeVal(arg, j, i, all)) orelse die("bad -E/--encoding value\n", .{});
                return;
            },
            .unrestrict => b.urestrict += 1,
            .xline => b.o.line_regexp = true,
            .quiet => b.o.quiet = true,
            .byteoff => b.o.byte_offset = true,
            .nul => b.o.null_sep = true,
            .follow => b.o.follow = true,
            .replace => {
                const bundled = j + 1 < arg.len; // value taken from this token, not the next argv
                b.o.replace = takeVal(arg, j, i, all);
                if (bundled) noteGrepStyleReplace(b.o.replace.?);
                return;
            },
            .file => {
                b.pat_files.append(b.a, takeVal(arg, j, i, all)) catch die("oom\n", .{});
                return;
            },
            .after => {
                b.a_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            .before => {
                b.b_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            .ctx => {
                b.c_val = toU(takeVal(arg, j, i, all));
                b.o.passthru = false;
                return;
            },
            .maxcount => {
                b.o.max_per_file = toU(takeVal(arg, j, i, all));
                return;
            },
            .maxcols => {
                b.o.max_cols = toU(takeVal(arg, j, i, all));
                b.o.max_cols_set = true;
                return;
            },
            .regexp => {
                b.addPat(takeVal(arg, j, i, all));
                return;
            },
            .typ => {
                b.addType(takeVal(arg, j, i, all), false);
                return;
            },
            .typ_not => {
                b.addType(takeVal(arg, j, i, all), true);
                return;
            },
            .glob => {
                b.addGlob(takeVal(arg, j, i, all), false);
                return;
            },
            .noop_val => {
                _ = takeVal(arg, j, i, all);
                return;
            },
            .threads => {
                b.o.threads = toU(takeVal(arg, j, i, all));
                return;
            },
            .ml => b.o.multiline = true,
            .pcre => b.o.engine = .pcre2,
            .unsupported => die("-{c} unsupported by design — use ripgrep for this\n", .{arg[j]}),
            else => unreachable,
        }
    }
}

fn parseLong(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    const body = arg[2..];
    var name = body;
    var inl: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
        name = body[0..eq];
        inl = body[eq + 1 ..];
    }
    const val = struct {
        fn get(v: ?[]const u8, ii: *usize, aa: []const []const u8) []const u8 {
            return v orelse nextTok(ii, aa);
        }
    }.get;
    const o = &b.o;
    const spec = flag_catalog[long_map.get(name) orelse die("unknown flag --{s}\n", .{name})];
    switch (spec.action) {
        .icase => o.caseless = true,
        .scase => o.caseless = false,
        .smart => o.smart_case = true,
        .word => o.word = true,
        .fixed => o.fixed = true,
        .invert => o.invert = true,
        .only => o.only_matching = true,
        .lnum => o.line_num = true,
        .no_lnum => o.line_num = false,
        .with_fn => o.filename = .always,
        .no_fn => o.filename = .never,
        .fwm => o.files_only = true,
        .fwithout => o.files_without = true,
        .count => o.count_only = true,
        .cmatches => o.count_matches = true,
        .hidden => o.hidden = true,
        .text => o.text = true,
        .binary => o.binary = true,
        .search_zip => o.search_zip = true,
        .pre => o.pre = val(inl, i, all),
        .pre_glob => b.addPreGlob(val(inl, i, all)),
        .encoding => {
            const label = val(inl, i, all);
            o.encoding = encodingFromLabel(label) orelse die("bad --encoding value: {s}\n", .{label});
        },
        .unrestrict => b.urestrict += 1,
        // --column implies line numbers; --vimgrep implies both. Setting them here
        // (not at finalize) lets a later -N / --no-column override, matching rg's
        // left-to-right resolution.
        .column => {
            o.column = true;
            o.line_num = true;
        },
        .no_column => o.column = false,
        .byteoff => o.byte_offset = true,
        .vimgrep => {
            o.vimgrep = true;
            o.line_num = true;
            o.column = true;
        },
        .heading => o.heading = true,
        .no_heading => o.heading = false,
        .trim => o.trim = true,
        .no_trim => o.trim = false,
        .nul => o.null_sep = true,
        .nul_data => o.null_data = true,
        .xline => o.line_regexp = true,
        .quiet => o.quiet = true,
        .stats => o.stats = true,
        .no_stats => o.stats = false,
        // --passthru and -A/-B/-C are mutually overriding — the last one on the
        // argv wins (ripgrep writes the same context setting). Reset any pending
        // context here; the context actions reset passthru symmetrically.
        .passthru => {
            o.passthru = true;
            b.a_val = null;
            b.b_val = null;
            b.c_val = null;
        },
        .maxcols_preview => o.max_cols_preview = true,
        .fieldmsep => o.field_match_sep = unescape(b.a, val(inl, i, all)),
        .fieldcsep => o.field_ctx_sep = unescape(b.a, val(inl, i, all)),
        .stop_nonmatch => o.stop_on_nonmatch = true,
        .crlf => o.crlf = true,
        .ml => o.multiline = true,
        .ml_dotall => {
            o.multiline = true;
            o.multiline_dotall = true;
        },
        .pcre => o.engine = .pcre2,
        .engine => {
            const v = val(inl, i, all);
            o.engine = if (std.mem.eql(u8, v, "default"))
                .default
            else if (std.mem.eql(u8, v, "pcre2"))
                .pcre2
            else if (std.mem.eql(u8, v, "auto"))
                .auto
            else
                die("bad --engine value: {s} (expected default, pcre2, or auto)\n", .{v});
        },
        .auto_hybrid => o.engine = .auto,
        .pcre_unicode => o.pcre_unicode = true,
        .no_pcre_unicode => o.pcre_unicode = false,
        .unicode => o.unicode = true,
        .no_unicode => o.unicode = false,
        .json => o.json = true,
        .files => o.files_list = true,
        .type_list => o.type_list = true,
        .follow => o.follow = true,
        .no_follow => o.follow = false,
        .threads => o.threads = toU(val(inl, i, all)),
        .one_file_system => o.one_file_system = true,
        // --sort-files is rg's deprecated alias for --sort=path. --sort/--sortr
        // take a key; `none` clears the ordering (back to the fast discovery
        // order). `sorted` mirrors "any explicit order" for the ignore reanchor.
        .sort_files => {
            o.sort_key = .path;
            o.sort_reverse = false;
            o.sorted = true;
        },
        .sort => {
            o.sort_key = parseSortKey(val(inl, i, all));
            o.sort_reverse = false;
            o.sorted = o.sort_key != .none;
        },
        .sortr => {
            o.sort_key = parseSortKey(val(inl, i, all));
            o.sort_reverse = o.sort_key != .none;
            o.sorted = o.sort_key != .none;
        },
        .glob_ci => b.glob_ci = true,
        .no_ignore => o.no_ignore = true,
        .no_ignore_vcs => o.no_ignore_vcs = true,
        .no_ignore_dot => o.no_ignore_dot = true,
        .no_ignore_parent => o.no_ignore_parent = true,
        .no_ignore_exclude => o.no_ignore_exclude = true,
        .no_ignore_global => o.no_ignore_global = true,
        .no_ignore_files => o.no_ignore_files = true,
        .ignore_files => o.no_ignore_files = false, // re-enable --ignore-file sources
        .no_require_git => o.no_require_git = true,
        .require_git => o.no_require_git = false, // undo an earlier --no-require-git
        .ignore_file_ci => o.ignore_case_insensitive = true,
        .ignore_file => b.ignore_files.append(b.a, val(inl, i, all)) catch die("oom\n", .{}),
        .no_index => o.no_index = true,
        .index => o.no_index = false,
        // --rank takes an OPTIONAL inline count only (`--rank=N`); a bare `--rank`
        // must not swallow the following token — that's the pattern (`gist --rank foo`).
        .rank => {
            o.rank = true;
            if (inl) |v| o.rank_k = toU(v);
        },
        .type_add => b.addTypeDef(val(inl, i, all)),
        .after => {
            b.a_val = toU(val(inl, i, all));
            o.passthru = false;
        },
        .before => {
            b.b_val = toU(val(inl, i, all));
            o.passthru = false;
        },
        .ctx => {
            b.c_val = toU(val(inl, i, all));
            o.passthru = false;
        },
        .maxcount => o.max_per_file = toU(val(inl, i, all)),
        .regexp => b.addPat(val(inl, i, all)),
        .typ => b.addType(val(inl, i, all), false),
        .typ_not => b.addType(val(inl, i, all), true),
        .glob => b.addGlob(val(inl, i, all), false),
        .iglob => b.addGlob(val(inl, i, all), true),
        .maxcols => {
            o.max_cols = toU(val(inl, i, all));
            o.max_cols_set = true;
        },
        .pathsep => o.path_sep = val(inl, i, all),
        .maxdepth => o.max_depth = toU(val(inl, i, all)),
        .maxfsize => o.max_filesize = toBytes(val(inl, i, all)),
        .ctxsep => o.ctx_sep = unescape(b.a, val(inl, i, all)),
        .no_ctxsep => o.ctx_sep = null,
        .replace => o.replace = val(inl, i, all),
        .file => b.pat_files.append(b.a, val(inl, i, all)) catch die("oom\n", .{}),
        // --color WHEN: resolved to an actual go/no-go (stdout tty + env) by
        // `color.zig` at emit time — this just records the requested mode.
        .color => {
            const c = val(inl, i, all);
            o.color = if (std.mem.eql(u8, c, "never"))
                .never
            else if (std.mem.eql(u8, c, "always"))
                .always
            else if (std.mem.eql(u8, c, "ansi"))
                .ansi
            else if (std.mem.eql(u8, c, "auto"))
                .auto
            else
                die("bad --color value: {s}\n", .{c});
        },
        .noop => {},
        .noop_val => _ = val(inl, i, all),
        .unsupported => die("--{s} unsupported by design — use ripgrep for this\n", .{name}),
    }
}

/// Parse a full `rg [flags] <pattern> [PATH...]` argv into a `Parsed`. Fails loud
/// (exit 2) on a missing pattern, a bad numeric value, or an unsupported flag.
pub fn parseArgv(a: std.mem.Allocator, args: []const []const u8) Parsed {
    var b = Builder{ .a = a };
    var flags_done = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!flags_done and std.mem.eql(u8, arg, "--")) {
            flags_done = true;
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            parseLong(&b, arg, &i, args);
        } else if (!flags_done and arg.len >= 2 and arg[0] == '-') {
            parseShort(&b, arg, &i, args);
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
    // -u = --no-ignore, -uu = +hidden, -uuu = +--binary (rg's tiers). gist's
    // --binary searches binary files in full (see Opts.binary), so -uuu brings the
    // whole tree — ignored, hidden, and binary — online.
    if (b.urestrict >= 1) b.o.no_ignore = true;
    if (b.urestrict >= 2) b.o.hidden = true;
    if (b.urestrict >= 3) b.o.binary = true;
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
    b.o.pre_globs = b.pre_globs.toOwnedSlice(a) catch die("oom\n", .{});
    b.o.pre_excludes = b.pre_excludes.toOwnedSlice(a) catch die("oom\n", .{});
    return .{
        .patterns = pats.toOwnedSlice(a) catch die("oom\n", .{}),
        .opts = b.o,
        .roots = b.roots.toOwnedSlice(a) catch die("oom\n", .{}),
        .pattern_files = b.pat_files.toOwnedSlice(a) catch die("oom\n", .{}),
    };
}

test "sort modes preserve ripgrep walker semantics" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sorted = parseArgv(a, &.{ "--sort", "path", "needle", "root-a", "root-b" });
    try t.expect(sorted.opts.sorted);
    try t.expectEqual(SortKey.path, sorted.opts.sort_key);
    try t.expect(!sorted.opts.sort_reverse);

    const unsorted = parseArgv(a, &.{ "--sort=none", "needle", "root-a", "root-b" });
    try t.expect(!unsorted.opts.sorted);
    try t.expectEqual(SortKey.none, unsorted.opts.sort_key);
}

test "sort key + direction: every rg key, ascending and reversed" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // --sort <key> is ascending; --sortr <key> flips only the direction bit.
    inline for (.{ "modified", "accessed", "created", "path" }) |k| {
        const asc = parseArgv(a, &.{ "--sort", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, asc.opts.sort_key);
        try t.expect(!asc.opts.sort_reverse and asc.opts.sorted);
        const desc = parseArgv(a, &.{ "--sortr", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, desc.opts.sort_key);
        try t.expect(desc.opts.sort_reverse and desc.opts.sorted);
    }
    // --sort-files is rg's deprecated alias for --sort=path (ascending).
    const sf = parseArgv(a, &.{ "--sort-files", "needle" });
    try t.expectEqual(SortKey.path, sf.opts.sort_key);
    try t.expect(sf.opts.sorted and !sf.opts.sort_reverse);
    // `--sortr none` collapses to no ordering (reverse of nothing is nothing).
    const rnone = parseArgv(a, &.{ "--sortr=none", "needle" });
    try t.expect(!rnone.opts.sorted and !rnone.opts.sort_reverse);
    try t.expectEqual(SortKey.none, rnone.opts.sort_key);
}

test "-j/--threads caps the worker pool; both spellings, inline + spaced" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try t.expectEqual(@as(usize, 3), parseArgv(a, &.{ "-j3", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 4), parseArgv(a, &.{ "-j", "4", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 8), parseArgv(a, &.{ "--threads=8", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 0), parseArgv(a, &.{"needle"}).opts.threads); // unset = adaptive
}

test "negation flags are last-wins toggles, not default-state no-ops" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each --no-X genuinely undoes an earlier --X (ripgrep's left-to-right rule),
    // and a later --X wins again.
    try t.expect(!parseArgv(a, &.{ "--heading", "--no-heading", "x" }).opts.heading);
    try t.expect(parseArgv(a, &.{ "--no-heading", "--heading", "x" }).opts.heading);
    try t.expect(!parseArgv(a, &.{ "--trim", "--no-trim", "x" }).opts.trim);
    try t.expect(!parseArgv(a, &.{ "--stats", "--no-stats", "x" }).opts.stats);
    try t.expect(!parseArgv(a, &.{ "-L", "--no-follow", "x" }).opts.follow);
    try t.expect(parseArgv(a, &.{ "--no-follow", "-L", "x" }).opts.follow);
}

test "--one-file-system records the device-boundary intent" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(parseArgv(a, &.{ "--one-file-system", "x" }).opts.one_file_system);
    try t.expect(!parseArgv(a, &.{"x"}).opts.one_file_system);
}

test "-rn keeps ripgrep replace semantics but is flagged as a grep-ism" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parity is sacred: `-rn` must still parse as --replace=n, exactly like rg.
    const p = parseArgv(a, &.{ "-rn", "needle", "root" });
    try t.expectEqualStrings("n", p.opts.replace.?);
    try t.expect(!p.opts.line_num);

    // The stderr note fires only for bundle-shaped values, never for real
    // replacement templates or an unbundled `-r VALUE`.
    try t.expect(looksLikeFlagBundle("n"));
    try t.expect(looksLikeFlagBundle("ni"));
    try t.expect(!looksLikeFlagBundle("$1"));
    try t.expect(!looksLikeFlagBundle("REDACTED"));
    try t.expect(!looksLikeFlagBundle(""));
    const spaced = parseArgv(a, &.{ "-r", "n", "needle", "root" });
    try t.expectEqualStrings("n", spaced.opts.replace.?);
}

test "flag catalog is the parser compatibility source of truth" {
    const t = std.testing;
    var bucket_counts: [4]usize = @splat(0);
    // Post-Unicode-flip: -i/-S/-w are `supported` (rg-parity, Unicode by default),
    // and --unicode/--no-unicode are real `supported` flags (no longer ignored).
    var i_supported = false;
    var word_supported = false;
    var smart_supported = false;
    var unicode_supported = false;
    var no_unicode_supported = false;

    for (flag_catalog, 0..) |spec, spec_i| {
        try t.expect(spec.short != null or spec.longs.len > 0);
        if (spec.short) |short| try t.expectEqual(spec_i, short_map[short].?);
        for (spec.longs) |name| try t.expectEqual(spec_i, long_map.get(name).?);
        switch (spec.compatibility) {
            .supported => bucket_counts[0] += 1,
            .supported_with_differences => bucket_counts[1] += 1,
            .accepted_but_ignored => bucket_counts[2] += 1,
            .unsupported_fail_loud => bucket_counts[3] += 1,
            .native => {},
        }
        if (spec.short == 'i') i_supported = spec.compatibility == .supported;
        if (spec.short == 'w') word_supported = spec.compatibility == .supported;
        if (spec.short == 'S') smart_supported = spec.compatibility == .supported;
        for (spec.longs) |name| {
            if (std.mem.eql(u8, name, "unicode")) unicode_supported = spec.compatibility == .supported;
            if (std.mem.eql(u8, name, "no-unicode")) no_unicode_supported = spec.compatibility == .supported;
        }
    }
    // The three live buckets are populated; the fail-loud bucket is now empty —
    // the content-transform flags (-z/--pre/--binary/-E) that used to fail loud
    // are implemented, so gist accepts or honors the entire rg flag surface.
    try t.expect(bucket_counts[0] > 0 and bucket_counts[1] > 0 and bucket_counts[2] > 0);
    try t.expectEqual(@as(usize, 0), bucket_counts[3]);
    // -i/-S/-w reached rg parity (Unicode by default), and --unicode/--no-unicode
    // are genuine toggles rather than accepted-but-ignored no-ops.
    try t.expect(i_supported and word_supported and smart_supported);
    try t.expect(unicode_supported and no_unicode_supported);
}

test "content-transform flags parse into Opts" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = parseArgv(a, &.{ "-z", "needle", "logs" });
    try t.expect(z.opts.search_zip);

    const e = parseArgv(a, &.{ "-E", "utf-16le", "needle", "f" });
    try t.expectEqual(Encoding.utf16le, e.opts.encoding);
    // WHATWG folds latin1 into windows-1252 (encoding_rs parity), and the CJK
    // labels the pitch names explicitly now resolve rather than failing loud.
    const e2 = parseArgv(a, &.{ "--encoding=latin1", "needle", "f" });
    try t.expectEqual(Encoding.windows_1252, e2.opts.encoding);
    try t.expectEqual(Encoding.shift_jis, parseArgv(a, &.{ "-E", "sjis", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.gb18030, parseArgv(a, &.{ "-E", "gbk", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.euc_jp, parseArgv(a, &.{ "--encoding=euc-jp", "needle", "f" }).opts.encoding);

    const pre = parseArgv(a, &.{ "--pre", "/bin/cat", "--pre-glob", "*.gz", "--pre-glob", "!*.tmp", "needle", "d" });
    try t.expectEqualStrings("/bin/cat", pre.opts.pre.?);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_globs.len);
    try t.expectEqualStrings("*.gz", pre.opts.pre_globs[0]);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_excludes.len);
    try t.expectEqualStrings("*.tmp", pre.opts.pre_excludes[0]);

    // -uuu now brings the whole tree online: --no-ignore + hidden + --binary.
    const uuu = parseArgv(a, &.{ "-uuu", "needle", "d" });
    try t.expect(uuu.opts.no_ignore and uuu.opts.hidden and uuu.opts.binary);
}
