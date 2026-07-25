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
const glob = @import("../../../../corpus/scope/glob.zig");
const paths = @import("../../../../corpus/scope/paths.zig");
const types = @import("../../../../corpus/scope/types.zig");
const uni = @import("../../../../kernel/match/regex/unicode/tables.zig");
const udec = @import("../../../../kernel/match/regex/unicode/decode.zig");
const encoding = @import("../read/encoding.zig");
const color = @import("../emit/color.zig");
const assay = @import("../../../../assay/assay.zig");

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
/// opt-in vendored PCRE2 JIT backend (`kernel/match/regex/pcre2/backend.zig`) for the constructs
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
    // Was --max-count/-m given? Distinguishes an explicit `-m0` (ripgrep's
    // "match nothing" — search short-circuits before emitting/counting a single
    // hit, exit 1, no output, in EVERY mode) from the unset default where 0 is
    // the "unlimited" sentinel the per-file emit guards read. Mirrors
    // `max_cols_set` below.
    max_per_file_set: bool = false,
    count_only: bool = false,
    count_matches: bool = false,
    // --include-zero / --no-include-zero (rg default OFF, last-wins): in a count
    // mode, emit a `path:0` line for every searched file with no match instead of
    // suppressing it. The exit code is unchanged (0 matches ⇒ exit 1) — only the
    // per-file zero line is added. Forces the serial engine and disables the
    // whole-file literal gate + index elision so every searched file is counted.
    include_zero: bool = false,
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
    // The regex `m` flag, resolved after leading `(?m)`/`(?-m)` directives. Base
    // = `multiline` (rg's `-U` default is `m` ON); `(?-m)` clears it so `^`/`$`
    // anchor only at the buffer ends while the whole-buffer search stays live.
    // Threaded into the matcher compile (`line_anchors`); inert in per-line mode.
    re_line_anchors: bool = false,
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
    sorted: bool = false, // any explicit ordering active (forces the deterministic sorted walk)
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
    // --uncap: lift the soft output budget (the ~25k-token agent-context guard,
    // corpus.zig) for THIS query — the agent deliberately wants the full result.
    // The hard OOM ceiling still applies. `GIST_UNCAP=1` is the env equivalent
    // (what the bench harness sets to keep rg byte-parity exact).
    uncap: bool = false,
    // --in-comments / --in-code: gist-native match SCOPING built on the shared
    // comment/code span lexer (kernel/compose/lexspan.zig). `--in-comments`
    // keeps only matches whose span begins inside a `//`/`#`/`/* */` comment
    // (doc mentions, TODOs, stale-invariant surface); `--in-code` keeps only
    // matches OUTSIDE any comment. Mutually exclusive. They select an early
    // native view (like `--rank`) rather than threading through the certified
    // rg-parity per-line engine, so ripgrep parity is untouched.
    in_comments: bool = false,
    in_code: bool = false,
    filter: Filter = .{},
    pub fn wantsContext(self: Opts) bool {
        return self.before > 0 or self.after > 0;
    }
    /// The line terminator byte: NUL under `--null-data`, else newline. Governs
    /// both how the input is split into lines and how each emitted line ends.
    pub fn term(self: Opts) u8 {
        return if (self.null_data) 0 else '\n';
    }
    /// The terminator the PRINTER appends to every line it emits (match/context
    /// bodies, `-l` paths, `-c` counts, headings, `--` separators). Under
    /// `--crlf` ripgrep's printer writes `\r\n` — its own output adopts the
    /// CRLF convention, not just the input split — while the INPUT terminator
    /// (`term()`, above) stays `\n` with the `\r` folded into the match view.
    /// A line body's own trailing `\r` is stripped before this is appended
    /// (`Emitter.emitBody`), mirroring rg's `trim_line_terminator`.
    pub fn outTerm(self: Opts) []const u8 {
        return if (self.null_data) "\x00" else if (self.crlf) "\r\n" else "\n";
    }
    /// The single-byte reconstruction terminator for a body line that WAS
    /// terminated in the file: the emitter's line slices keep any `\r` but
    /// drop the split byte, so appending this re-materializes the original
    /// bytes exactly (dos `…\r`+`\n`, unix `…`+`\n`) — rg writes such lines
    /// verbatim and only falls back to `outTerm()` when one is missing.
    pub fn termStr(self: Opts) []const u8 {
        return if (self.null_data) "\x00" else "\n";
    }
    /// True for the two "no pattern needed" modes.
    pub fn noPattern(self: Opts) bool {
        return self.files_list or self.type_list;
    }
    /// The compact per-file ENUMERATION modes: one short line per file — a path
    /// (`-l`, `--files-without-match`, `--files`) or a count (`-c`,
    /// `--count-matches`). A partial answer here is misleading, and on the
    /// unordered parallel engine a soft-cap cut yields a nondeterministic SUBSET
    /// run-to-run; these are exempted from the soft context cap
    /// (`corpus.exemptSoftCap`) so the SET is complete and reproducible. The
    /// full-content modes (default, `-o`, context, `--json`) keep the cap — their
    /// volume is the reason it exists, and their truncation is already ordered.
    pub fn enumeration(self: Opts) bool {
        return self.files_only or self.files_without or self.count_only or self.count_matches or self.files_list;
    }
};

pub const Parsed = struct { patterns: [][]const u8, opts: Opts, roots: [][]const u8, pattern_files: [][]const u8 = &.{} };

/// A `--type-add name:...` definition, resolved to the globs `-t name` scopes by.
const CustomType = struct { name: []const u8, globs: []const []const u8 };

/// Fatal exit with ripgrep's error code (2). Shared by the parser and the shell.
/// Routed through `assay.diag` so a `dark` sink stays silent and a `buffer`
/// sink captures the message for the client (ADR-373 law 6) — same reason
/// `outcome.fatal` takes this path.
pub fn die(comptime msg: []const u8, args: anytype) noreturn {
    assay.diag(msg, args);
    std.process.exit(2);
}

/// The one OOM exit — sugar for the ubiquitous `… catch oom()`,
/// which is this CLI's contract for allocation failure (fail loud, exit 2).
/// Message is shared with `paths.allocFailure` (`paths.oom_notice`).
pub fn oom() noreturn {
    die(paths.oom_notice, .{});
}

/// Does the pattern carry an uppercase letter? Codepoint-aware for smart-case
/// (`-S`): any Unicode uppercase (`Ä`, `Σ`, …) — not just ASCII `A-Z` — disables
/// the automatic fold, matching rg's Unicode default. Ill-formed bytes are
/// skipped (never counted as uppercase). Public so the no-match hint module
/// (`emit/hints.zig`) shares the exact detection smart-case uses.
pub fn hasUpper(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            if (s[i] >= 'A' and s[i] <= 'Z') return true;
            i += 1;
        } else if (udec.decode(s[i..])) |d| {
            if (uni.isUpper(d.cp)) return true;
            i += d.len;
        } else i += 1;
    }
    return false;
}

// The shared ASCII case fold (`paths.zig`) — one definition for the caseless
// glob path here and ignore.zig's git config-key folding.
const lowerDup = paths.lowerDup;
fn globAppliesCI(a: std.mem.Allocator, pat: []const u8, path: []const u8) bool {
    return glob.globApplies(lowerDup(a, pat), lowerDup(a, path));
}

/// A leading `/` anchors a gitignore-style glob to the search root; gist already
/// matches such (slash-bearing) globs against the full path, so dropping the
/// anchor byte yields the same root-relative semantics.
fn stripAnchor(g: []const u8) []const u8 {
    return if (g.len > 0 and g[0] == '/') g[1..] else g;
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
        if (self.pat == null) self.pat = p else self.extra_pats.append(self.a, p) catch oom();
    }
    fn addType(self: *Builder, name: []const u8, negate: bool) void {
        if (std.mem.eql(u8, name, "all")) {
            (if (negate) &self.ntype_all else &self.type_all).* = true;
            // A user-defined `--type-add` type resolves to include/exclude globs; a
            // built-in resolves to its own glob set (scope/types.zig).
        } else if (self.customGlobs(name)) |globs| {
            (if (negate) &self.excludes else &self.includes).appendSlice(self.a, globs) catch oom();
        } else {
            const e = types.extsForType(name) orelse die("unrecognized type: {s}\n", .{name});
            (if (negate) &self.neg_exts else &self.exts).appendSlice(self.a, e) catch oom();
        }
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
            while (it.next()) |ty| {
                if (self.customGlobs(ty)) |g| {
                    globs.appendSlice(self.a, g) catch oom();
                } else if (types.extsForType(ty)) |exts| {
                    // A built-in type's rows are already valid globs (scope/types.zig),
                    // so they slot straight into the `include:` union with no conversion.
                    globs.appendSlice(self.a, exts) catch oom();
                } else die("unrecognized type: {s}\n", .{ty});
            }
        } else {
            globs.append(self.a, rest) catch oom();
        }
        self.custom_types.append(self.a, .{ .name = name, .globs = globs.toOwnedSlice(self.a) catch oom() }) catch oom();
    }
    /// The accumulated globs for a user-defined type, or null if `name` is not one.
    fn customGlobs(self: *Builder, name: []const u8) ?[]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (self.custom_types.items) |ct| if (std.mem.eql(u8, ct.name, name)) {
            out.appendSlice(self.a, ct.globs) catch oom();
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
            self.pre_excludes.append(self.a, stripAnchor(g[1..])) catch oom();
        } else self.pre_globs.append(self.a, stripAnchor(g)) catch oom();
    }
    fn addGlobOne(self: *Builder, g: []const u8, insensitive: bool) void {
        const neg = g.len > 0 and g[0] == '!';
        const core = stripAnchor(if (neg) g[1..] else g);
        // An explicit `-g`/`--glob` compiles strictly (rg's `Glob::new`): an
        // unclosed `[` character class is an error, not the literal `[` a lenient
        // gitignore line would treat it as. Fail loud (exit 2) here, at the seam.
        if (glob.unterminatedClass(core))
            die("gist: error parsing glob '{s}': unclosed character class; missing ']'\n", .{g});
        const list = if (neg) &self.excludes else if (insensitive) &self.iglobs else &self.includes;
        list.append(self.a, core) catch oom();
    }
};

/// Expand glob `{a,b,c}` alternations into every concrete pattern (cartesian
/// product across groups, nesting-aware). A pattern with no brace group yields
/// itself; an unbalanced `{` is left literal.
fn braceExpand(a: std.mem.Allocator, pat: []const u8, out: *std.ArrayList([]const u8)) void {
    // Find the first balanced `{…}` group; no group (or an unbalanced `{`) ⇒
    // the pattern is emitted literally.
    const grp: ?[2]usize = blk: {
        const open = std.mem.indexOfScalar(u8, pat, '{') orelse break :blk null;
        var depth: usize = 0;
        for (open..pat.len) |i| {
            if (pat[i] == '{') depth += 1 else if (pat[i] == '}') {
                depth -= 1;
                if (depth == 0) break :blk .{ open, i };
            }
        }
        break :blk null;
    };
    const open, const c = grp orelse {
        out.append(a, a.dupe(u8, pat) catch oom()) catch oom();
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
            const combined = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, inner[start..j], suffix }) catch oom();
            braceExpand(a, combined, out); // recurse to expand any remaining groups
            start = j + 1;
        }
    }
}

fn toU(s: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch die("bad number '{s}'\n", .{s});
}

/// Resolve a value to its enum member, or fail loud with the flag's own
/// message — the shared back end of `--color`/`--engine`/`--sort`/`--sortr`.
fn enumOrDie(comptime T: type, comptime fmt: []const u8, s: []const u8) T {
    return std.meta.stringToEnum(T, s) orelse die(fmt, .{s});
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
            out.append(a, s[i]) catch oom();
            continue;
        }
        i += 1;
        out.append(a, switch (s[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '\\' => '\\',
            'x' => blk: {
                if (i + 2 >= s.len) die("bad \\x escape\n", .{});
                defer i += 2;
                break :blk std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch die("bad \\x escape\n", .{});
            },
            else => |c| blk: {
                out.append(a, '\\') catch oom();
                break :blk c;
            },
        }) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

/// Parse a `--max-filesize` value: a decimal with an optional `K`/`M`/`G` (1024-
/// based) suffix, e.g. `50`, `4K`, `1M` (ripgrep's grammar). A value that
/// overflows `usize` after applying the suffix fails loud (exit 2) exactly like
/// ripgrep — `34359738368G` names ~2^65 bytes, which cannot be represented, and
/// silently wrapping it into a tiny cap would drop files the user meant to keep.
fn toBytes(s: []const u8) usize {
    if (s.len == 0) die("bad size ''\n", .{});
    const mult: usize = switch (s[s.len - 1]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    return std.math.mul(usize, toU(digits), mult) catch
        die("invalid --max-filesize: {s} overflows the maximum representable size\n", .{s});
}

/// The `Opts` field a declarative catalog row drives, by name.
const OptField = std.meta.FieldEnum(Opts);

/// A flag's parse effect. Most flags declaratively set or clear one `Opts`
/// bool — `.set`/`.unset` carry the exact field the catalog row drives (the
/// comptime block below proves each names a bool). Everything value-taking or
/// compound keeps a named action handled in `apply`.
const Act = union(enum) {
    set: OptField, // set the named Opts bool
    unset: OptField, // clear it (the --no-X / undo spellings)
    set_many: []const OptField, // set several Opts bools at once
    filename: Filename, // -H/--with-filename, -I/--no-filename
    case: enum { icase, scase, smart }, // -i / -s / -S
    unrestrict,
    passthru,
    sort_files,
    sort: bool, // --sort (false) / --sortr (true = descending)
    glob_ci, // value-taking below
    ctx_at: enum { after, before, ctx },
    regexp,
    typ: bool, // -t/--type (false) / -T/--type-not (true = negate)
    glob: bool, // -g/--glob (false) / --iglob (true = case-insensitive)
    num_set: [2]OptField, // set the named usize field from a decimal value + its was-set marker
    set_num: OptField, // set the named usize field from a decimal value
    set_str: OptField, // set the named string field from the raw value
    sep: OptField, // as .set_str, but through the C-escape decoder
    maxfsize,
    no_ctxsep,
    replace,
    file,
    ignore_file,
    type_add,
    color,
    encoding,
    pre_glob,
    rank,
    // -P/--pcre2: select the PCRE2 backend
    // --auto-hybrid-regex: rg's deprecated spelling of --engine auto
    engine_is: Engine, // the fixed-backend spellings above, by target backend
    engine, // --engine=<default|pcre2|auto>: select the match backend by name
    noop,
    noop_val,
    colors, // --colors: validate the spec's syntax (fail loud), then discard it
    unsupported,
};

// Every declarative `.set`/`.unset` row must name a bool field — proven here
// at comptime so `setBool`'s non-bool arm is genuinely unreachable.
// (setBool has since been generalized into `setVal`; the same proof now also
// covers the `.set_num`/`.set_str`/`.sep` rows and their field types.)
comptime {
    for (flag_catalog) |spec| switch (spec.action) {
        .set, .unset => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == bool),
        .set_many => |fs| for (fs) |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == bool),
        .set_num => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == usize),
        .num_set => |p| std.debug.assert(@FieldType(Opts, @tagName(p[0])) == usize and @FieldType(Opts, @tagName(p[1])) == bool),
        .set_str, .sep => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == []const u8 or
            @FieldType(Opts, @tagName(f)) == ?[]const u8),
        else => {},
    };
}

/// Assign the named `Opts` bool — the back end of `.set`/`.unset`.
/// Generalized over the value's type: the same inline dispatch also lands the
/// `.set_num` (usize) and `.set_str`/`.sep` (plain or optional string) rows.
fn setVal(o: *Opts, f: OptField, v: anytype) void {
    switch (f) {
        inline else => |ff| if (@FieldType(Opts, @tagName(ff)) == @TypeOf(v) or
            @FieldType(Opts, @tagName(ff)) == ?@TypeOf(v))
        {
            @field(o, @tagName(ff)) = v;
        } else unreachable, // comptime-verified: catalog rows only name bools
    }
}

/// Public compatibility buckets emitted by `gist --schema`. `.native` rows are
/// gist additions, emitted separately from the four-bucket ripgrep matrix.
/// `.improvement` is a flag whose result is identical-or-superset to ripgrep's
/// yet strictly better in behavior, performance, or robustness — never a
/// regression. Where gist differs from rg it is an improvement or it is a bug.
pub const Compatibility = enum {
    supported,
    improvement,
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
    .{ .short = 'i', .longs = &.{"ignore-case"}, .action = .{ .case = .icase }, .compatibility = .supported, .note = "Unicode case folding by default (full simple case-fold orbits); (?-u)/--no-unicode selects ASCII folding" },
    .{ .short = 's', .longs = &.{"case-sensitive"}, .action = .{ .case = .scase }, .compatibility = .supported },
    .{ .short = 'S', .longs = &.{"smart-case"}, .action = .{ .case = .smart }, .compatibility = .supported, .note = "codepoint-aware uppercase detection and Unicode folding by default; (?-u)/--no-unicode selects ASCII" },
    .{ .short = 'w', .longs = &.{"word-regexp"}, .action = .{ .set = .word }, .compatibility = .supported, .note = "-w and regex \\b/\\w use Unicode word characters by default (rg parity); (?-u)/--no-unicode selects ASCII byte word chars" },
    .{ .short = 'F', .longs = &.{"fixed-strings"}, .action = .{ .set = .fixed }, .compatibility = .supported },
    .{ .short = 'v', .longs = &.{"invert-match"}, .action = .{ .set = .invert }, .compatibility = .supported },
    .{ .short = 'o', .longs = &.{"only-matching"}, .action = .{ .set = .only_matching }, .compatibility = .supported },
    .{ .short = 'n', .longs = &.{"line-number"}, .action = .{ .set = .line_num }, .compatibility = .supported },
    .{ .short = 'N', .longs = &.{"no-line-number"}, .action = .{ .unset = .line_num }, .compatibility = .supported },
    .{ .short = 'H', .longs = &.{"with-filename"}, .action = .{ .filename = .always }, .compatibility = .supported },
    .{ .short = 'I', .longs = &.{"no-filename"}, .action = .{ .filename = .never }, .compatibility = .supported },
    .{ .short = 'l', .longs = &.{"files-with-matches"}, .action = .{ .set = .files_only }, .compatibility = .supported },
    .{ .longs = &.{"files-without-match"}, .action = .{ .set = .files_without }, .compatibility = .supported },
    .{ .short = 'c', .longs = &.{"count"}, .action = .{ .set = .count_only }, .compatibility = .supported },
    .{ .longs = &.{"count-matches"}, .action = .{ .set = .count_matches }, .compatibility = .supported },
    .{ .longs = &.{"include-zero"}, .action = .{ .set = .include_zero }, .compatibility = .supported, .note = "in a count mode, print a path:0 line for every searched file with no match (exit code unchanged)" },
    .{ .longs = &.{"no-include-zero"}, .action = .{ .unset = .include_zero }, .compatibility = .supported },
    .{ .longs = &.{"hidden"}, .action = .{ .set = .hidden }, .compatibility = .supported },
    .{ .short = 'a', .longs = &.{"text"}, .action = .{ .set = .text }, .compatibility = .supported },
    .{ .longs = &.{"binary"}, .action = .{ .set = .binary }, .compatibility = .improvement, .note = "improvement: a code locator searches a NUL-bearing file in full and prints every matching line, rather than rg's opaque 'binary file matches' summary that suppresses the lines and stops" },
    .{ .short = 'u', .longs = &.{"unrestricted"}, .action = .unrestrict, .compatibility = .supported, .note = "-u=--no-ignore, -uu adds hidden, -uuu adds --binary; the ignore/hidden ladder is rg-identical, -uuu inherits the --binary improvement" },
    .{ .longs = &.{"column"}, .action = .{ .set_many = &.{ .column, .line_num } }, .compatibility = .supported },
    .{ .longs = &.{"no-column"}, .action = .{ .unset = .column }, .compatibility = .supported },
    .{ .short = 'b', .longs = &.{"byte-offset"}, .action = .{ .set = .byte_offset }, .compatibility = .supported },
    .{ .longs = &.{"vimgrep"}, .action = .{ .set_many = &.{ .vimgrep, .column, .line_num } }, .compatibility = .supported },
    .{ .longs = &.{"heading"}, .action = .{ .set = .heading }, .compatibility = .supported },
    .{ .longs = &.{"no-heading"}, .action = .{ .unset = .heading }, .compatibility = .supported },
    .{ .longs = &.{"trim"}, .action = .{ .set = .trim }, .compatibility = .supported },
    .{ .short = '0', .longs = &.{"null"}, .action = .{ .set = .null_sep }, .compatibility = .supported },
    .{ .longs = &.{"null-data"}, .action = .{ .set = .null_data }, .compatibility = .supported },
    .{ .short = 'x', .longs = &.{"line-regexp"}, .action = .{ .set = .line_regexp }, .compatibility = .supported },
    .{ .short = 'q', .longs = &.{"quiet"}, .action = .{ .set = .quiet }, .compatibility = .supported },
    .{ .longs = &.{"stats"}, .action = .{ .set = .stats }, .compatibility = .supported },
    .{ .longs = &.{"stop-on-nonmatch"}, .action = .{ .set = .stop_on_nonmatch }, .compatibility = .supported },
    .{ .longs = &.{ "passthru", "passthrough" }, .action = .passthru, .compatibility = .supported },
    .{ .longs = &.{"max-columns-preview"}, .action = .{ .set = .max_cols_preview }, .compatibility = .supported },
    .{ .longs = &.{"field-match-separator"}, .action = .{ .sep = .field_match_sep }, .compatibility = .supported },
    .{ .longs = &.{"field-context-separator"}, .action = .{ .sep = .field_ctx_sep }, .compatibility = .supported },
    .{ .longs = &.{"crlf"}, .action = .{ .set = .crlf }, .compatibility = .supported },
    .{ .short = 'U', .longs = &.{"multiline"}, .action = .{ .set = .multiline }, .compatibility = .supported },
    .{ .longs = &.{"multiline-dotall"}, .action = .{ .set_many = &.{ .multiline, .multiline_dotall } }, .compatibility = .supported },
    .{ .longs = &.{"json"}, .action = .{ .set = .json }, .compatibility = .supported },
    .{ .longs = &.{"files"}, .action = .{ .set = .files_list }, .compatibility = .supported },
    .{ .longs = &.{"type-list"}, .action = .{ .set = .type_list }, .compatibility = .improvement, .note = "improvement: rg-sorted, rg-framed output over a strict SUPERSET of rg's type registry (rg's rows byte-identical; the rest richer, plus gist-only types)" },
    .{ .short = 'L', .longs = &.{"follow"}, .action = .{ .set = .follow }, .compatibility = .supported },
    .{ .longs = &.{"no-follow"}, .action = .{ .unset = .follow }, .compatibility = .supported },
    .{ .longs = &.{"sort-files"}, .action = .sort_files, .compatibility = .supported, .note = "deprecated rg spelling of --sort=path" },
    .{ .longs = &.{"sort"}, .action = .{ .sort = false }, .compatibility = .improvement, .note = "improvement: path/modified/accessed/created, ascending; final ordering is rg-identical but produced over a parallel read (rg single-threads sort), and created falls back to ctime where the platform lacks birth time (rg cannot sort at all)" },
    .{ .longs = &.{"sortr"}, .action = .{ .sort = true }, .compatibility = .improvement, .note = "improvement: as --sort but descending; same rg-identical ordering over a parallel read and the same created→ctime robustness fallback" },
    .{ .longs = &.{"glob-case-insensitive"}, .action = .glob_ci, .compatibility = .supported },
    .{ .short = 'A', .longs = &.{"after-context"}, .action = .{ .ctx_at = .after }, .compatibility = .supported },
    .{ .short = 'B', .longs = &.{"before-context"}, .action = .{ .ctx_at = .before }, .compatibility = .supported },
    .{ .short = 'C', .longs = &.{"context"}, .action = .{ .ctx_at = .ctx }, .compatibility = .supported },
    .{ .short = 'm', .longs = &.{"max-count"}, .action = .{ .num_set = .{ .max_per_file, .max_per_file_set } }, .compatibility = .supported },
    .{ .short = 'e', .longs = &.{"regexp"}, .action = .regexp, .compatibility = .supported },
    .{ .short = 't', .longs = &.{"type"}, .action = .{ .typ = false }, .compatibility = .supported },
    .{ .short = 'T', .longs = &.{"type-not"}, .action = .{ .typ = true }, .compatibility = .supported },
    .{ .short = 'g', .longs = &.{"glob"}, .action = .{ .glob = false }, .compatibility = .supported },
    .{ .longs = &.{"iglob"}, .action = .{ .glob = true }, .compatibility = .supported },
    .{ .short = 'M', .longs = &.{"max-columns"}, .action = .{ .num_set = .{ .max_cols, .max_cols_set } }, .compatibility = .supported },
    .{ .longs = &.{"path-separator"}, .action = .{ .set_str = .path_sep }, .compatibility = .supported },
    .{ .longs = &.{ "max-depth", "maxdepth" }, .action = .{ .set_num = .max_depth }, .compatibility = .supported },
    .{ .longs = &.{"max-filesize"}, .action = .maxfsize, .compatibility = .supported },
    .{ .longs = &.{"context-separator"}, .action = .{ .sep = .ctx_sep }, .compatibility = .supported },
    .{ .longs = &.{"no-context-separator"}, .action = .no_ctxsep, .compatibility = .supported },
    .{ .short = 'r', .longs = &.{"replace"}, .action = .replace, .compatibility = .supported },
    .{ .short = 'f', .longs = &.{"file"}, .action = .file, .compatibility = .supported },
    .{ .longs = &.{"type-add"}, .action = .type_add, .compatibility = .supported },
    .{ .longs = &.{"color"}, .action = .color, .compatibility = .supported },
    // Ignore-rule controls honored by the in-tree .gitignore/.ignore engine.
    .{ .longs = &.{"no-ignore"}, .action = .{ .set = .no_ignore }, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-vcs"}, .action = .{ .set = .no_ignore_vcs }, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-dot"}, .action = .{ .set = .no_ignore_dot }, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-parent"}, .action = .{ .set = .no_ignore_parent }, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-exclude"}, .action = .{ .set = .no_ignore_exclude }, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-files"}, .action = .{ .set = .no_ignore_files }, .compatibility = .supported },
    // --ignore-files re-enables --ignore-file sources after --no-ignore-files.
    .{ .longs = &.{"ignore-files"}, .action = .{ .unset = .no_ignore_files }, .compatibility = .supported },
    .{ .longs = &.{"no-require-git"}, .action = .{ .set = .no_require_git }, .compatibility = .supported },
    // --require-git undoes an earlier --no-require-git.
    .{ .longs = &.{"require-git"}, .action = .{ .unset = .no_require_git }, .compatibility = .supported },
    .{ .longs = &.{"ignore-file-case-insensitive"}, .action = .{ .set = .ignore_case_insensitive }, .compatibility = .supported },
    .{ .longs = &.{"ignore-file"}, .action = .ignore_file, .compatibility = .supported },
    .{ .longs = &.{"no-ignore-global"}, .action = .{ .set = .no_ignore_global }, .compatibility = .supported, .note = "git core.excludesFile ($HOME/.gitconfig or $XDG_CONFIG_HOME/git/config → default $XDG_CONFIG_HOME/git/ignore) is read by default in a repo; this disables that global tier only" },
    // Gist-native index controls are not ripgrep compatibility claims.
    .{ .longs = &.{"no-index"}, .action = .{ .set = .no_index }, .compatibility = .native },
    .{ .longs = &.{"index"}, .action = .{ .unset = .no_index }, .compatibility = .native },
    .{ .longs = &.{"rank"}, .action = .rank, .compatibility = .native },
    // --uncap: lift the soft output budget (hard OOM ceiling still applies).
    .{ .longs = &.{"uncap"}, .action = .{ .set = .uncap }, .compatibility = .native, .note = "lift the ~25k-token soft output cap for this query; the hard OOM ceiling still applies (GIST_UNCAP=1 is the env form)" },
    // --in-comments / --in-code: native comment/code match scoping (lexspan.zig).
    .{ .longs = &.{"in-comments"}, .action = .{ .set = .in_comments }, .compatibility = .native, .note = "keep only matches whose span begins inside a //, #, or /* */ comment (native span-lexed view; mutually exclusive with --in-code)" },
    .{ .longs = &.{"in-code"}, .action = .{ .set = .in_code }, .compatibility = .native, .note = "keep only matches OUTSIDE any comment (native span-lexed view; mutually exclusive with --in-comments)" },
    // Accepted spellings whose requested behavior is intentionally not applied.
    .{ .longs = &.{ "mmap", "no-mmap" }, .action = .noop, .compatibility = .accepted_but_ignored },
    .{ .longs = &.{"one-file-system"}, .action = .{ .set = .one_file_system }, .compatibility = .supported },
    // --unicode / --no-unicode: linear-engine Unicode mode on (rg default) / off (byte/ASCII).
    .{ .longs = &.{"unicode"}, .action = .{ .set = .unicode }, .compatibility = .supported, .note = "linear-engine Unicode mode (rg default): full case-fold orbits, codepoint \\w/\\d/\\s/./\\p{…}, and Unicode \\b/\\B/\\<\\>/-w" },
    .{ .longs = &.{"no-unicode"}, .action = .{ .unset = .unicode }, .compatibility = .supported, .note = "byte/ASCII mode: single-byte classes and ASCII \\w/\\b (equivalent to a leading (?-u))" },
    .{ .longs = &.{"no-stats"}, .action = .{ .unset = .stats }, .compatibility = .supported },
    .{ .longs = &.{"no-trim"}, .action = .{ .unset = .trim }, .compatibility = .supported },
    .{ .longs = &.{"colors"}, .action = .colors, .compatibility = .accepted_but_ignored },
    .{ .short = 'j', .longs = &.{"threads"}, .action = .{ .set_num = .threads }, .compatibility = .supported, .note = "caps the work-stealing worker pool at N (0 = gist's own topology), the same bound rg's -j sets; results are identical" },
    // Match-backend selection. `--engine default` is the linear engine; `--engine
    // auto` compiles linear and escalates to the PCRE2 backend only for a pattern
    // the linear engine declines; `--engine pcre2` / `-P` select PCRE2 outright.
    .{ .longs = &.{"engine"}, .action = .engine, .compatibility = .supported, .note = "default/auto/pcre2 select the engine exactly as rg: default = linear RE2/Pike, auto escalates to PCRE2 only for lookaround/backreferences the linear engine declines, pcre2 selects PCRE2 outright (the gist-native --rank is linear-only)" },
    // PCRE2 Unicode (UTF+UCP) mode — effective under -P / escalated auto; inert
    // under the linear default, which is always ASCII-byte based.
    .{ .longs = &.{"pcre2-unicode"}, .action = .{ .set = .pcre_unicode }, .compatibility = .supported, .note = "PCRE2 UTF+UCP mode (rg's -P default); as in rg it governs the PCRE2 backend, effective under -P/auto and inert under gist's extra linear default" },
    .{ .longs = &.{"no-pcre2-unicode"}, .action = .{ .unset = .pcre_unicode }, .compatibility = .supported, .note = "PCRE2 raw-byte/ASCII mode; as in rg it governs the PCRE2 backend, effective under -P/auto and inert under gist's extra linear default" },
    .{ .longs = &.{ "dfa-size-limit", "regex-size-limit" }, .action = .noop_val, .compatibility = .accepted_but_ignored },
    // The opt-in PCRE2 JIT backend (vendored 10.47) and rg's deprecated hybrid alias.
    .{ .short = 'P', .longs = &.{"pcre2"}, .action = .{ .engine_is = .pcre2 }, .compatibility = .improvement, .note = "improvement: the vendored PCRE2 JIT backend (lookaround, backreferences, Unicode properties) yields rg's exact -P match set, but trigram-prefiltered like the linear engine — the only INDEXED PCRE search in the field (the gist-native --rank is linear-only)" },
    .{ .longs = &.{"auto-hybrid-regex"}, .action = .{ .engine_is = .auto }, .compatibility = .supported, .note = "rg's own deprecated spelling of --engine auto; escalates to PCRE2 only for a pattern the linear engine declines" },
    // Content-transform flags: decompression + preprocessing + transcoding. The
    // common compressed formats decode in-process (no fork) — see `ingest.zig`.
    .{ .short = 'z', .longs = &.{"search-zip"}, .action = .{ .set = .search_zip }, .compatibility = .improvement, .note = "improvement: identical results to rg across every codec, but gzip/zlib/zstd/xz decode IN-PROCESS (no per-file `gzip -dc` fork); bzip2/lz4/brotli/lzma/.Z shell the standard tool exactly as rg does" },
    .{ .longs = &.{"pre"}, .action = .{ .set_str = .pre }, .compatibility = .supported, .note = "rg parity: the command receives the file path as argv[1] AND the file's bytes on stdin; a non-zero exit is an error (exit 2)" },
    .{ .longs = &.{"pre-glob"}, .action = .pre_glob, .compatibility = .supported },
    .{ .short = 'E', .longs = &.{"encoding"}, .action = .encoding, .compatibility = .supported, .note = "auto/none + the full WHATWG label table (rg's encoding_rs set): UTF-8/16, the single-byte pages, and CJK gb18030/GBK, Big5, EUC-JP, Shift_JIS, EUC-KR, ISO-2022-JP; an unrecognized label fails loud" },
};

const long_map = std.StaticStringMap(usize).initComptime(blk: {
    var pairs: []const struct { []const u8, usize } = &.{};
    for (flag_catalog, 0..) |spec, spec_i| for (spec.longs) |name| {
        pairs = pairs ++ .{.{ name, spec_i }};
    };
    break :blk pairs;
});
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
    assay.diag(
        "gist: note: '-r{s}' parses as --replace={s} (ripgrep semantics: -r takes a value; recursion is already the default). Spell flags separately (e.g. -n), or use --replace to silence this note.\n",
        .{ v, v },
    );
}

/// Where a flag's value comes from: a short bundle's tail / next argv token,
/// or a long flag's inline `=value` / next argv token. `take` consumes it;
/// `consumed` tells the short-bundle loop the value ate the rest of the token.
const ValSrc = struct {
    mode: enum { short, long },
    i: *usize,
    all: []const []const u8,
    arg: []const u8 = "", // short mode: the whole `-abc` token
    j: usize = 0, // short mode: index of the current flag char
    name: []const u8 = "", // long mode: the flag name (for error text)
    inl: ?[]const u8 = null, // long mode: the inline `=value`, if any
    consumed: bool = false,

    fn take(self: *ValSrc) []const u8 {
        self.consumed = true;
        switch (self.mode) {
            .short => if (self.j + 1 < self.arg.len) return self.arg[self.j + 1 ..] else if (self.i.* + 1 >= self.all.len) die("flag -{c} needs a value\n", .{self.arg[self.j]}),
            .long => if (self.inl) |x| return x else if (self.i.* + 1 >= self.all.len) die("flag needs a value\n", .{}),
        }
        self.i.* += 1;
        return self.all[self.i.*];
    }
};

/// Apply one catalog action to the parse state — the single dispatch behind
/// both the short-bundle and long-flag paths.
fn apply(b: *Builder, action: Act, v: *ValSrc) void {
    const o = &b.o;
    switch (action) {
        .set => |f| setVal(o, f, true),
        .unset => |f| setVal(o, f, false),
        // --column implies line numbers; --vimgrep implies both. Setting them here
        // (not at finalize) lets a later -N / --no-column override, matching rg's
        // left-to-right resolution.
        .set_many => |fs| for (fs) |f| setVal(o, f, true),
        .set_num => |f| setVal(o, f, toU(v.take())),
        .set_str => |f| setVal(o, f, v.take()),
        .sep => |f| setVal(o, f, unescape(b.a, v.take())),
        .filename => |f| o.filename = f,
        // Case mode is last-wins across -i/-s/-S (ripgrep resolves the three
        // to a single final state): each spelling clears the other two, so
        // `-S -s` ends case-sensitive (not smart) and `-i -s` ends sensitive.
        .case => |c| {
            o.caseless, o.smart_case = .{ c == .icase, c == .smart };
        },
        .unrestrict => b.urestrict += 1,
        // --passthru and -A/-B/-C are mutually overriding — the last one on the
        // argv wins (ripgrep writes the same context setting). Reset any pending
        // context here; the context actions reset passthru symmetrically.
        .passthru => {
            o.passthru, b.a_val, b.b_val, b.c_val = .{ true, null, null, null };
        },
        // --sort-files is rg's deprecated alias for --sort=path. --sort/--sortr
        // take a key; `none` clears the ordering (back to the fast discovery
        // order). `sorted` mirrors "any explicit order" for the deterministic walk.
        .sort_files => {
            o.sort_key, o.sort_reverse, o.sorted = .{ .path, false, true };
        },
        .sort => |desc| {
            o.sort_key = enumOrDie(SortKey, "bad --sort value: {s} (expected none, path, modified, accessed, or created)\n", v.take());
            o.sort_reverse, o.sorted = .{ desc and o.sort_key != .none, o.sort_key != .none };
        },
        .glob_ci => b.glob_ci = true,
        // -A/-B/-C record into a_val/b_val/c_val so -A/-B outrank -C at
        // finalize regardless of argv order; each resets a pending --passthru.
        .ctx_at => |which| {
            const n = toU(v.take());
            (switch (which) {
                .after => &b.a_val,
                .before => &b.b_val,
                .ctx => &b.c_val,
            }).* = n;
            o.passthru = false;
        },
        .num_set => |pair| {
            setVal(o, pair[0], toU(v.take()));
            setVal(o, pair[1], true);
        },
        .regexp => b.addPat(v.take()),
        .typ => |negate| b.addType(v.take(), negate),
        .glob => |insensitive| b.addGlob(v.take(), insensitive),
        .maxfsize => o.max_filesize = toBytes(v.take()),
        .no_ctxsep => o.ctx_sep = null,
        // The `-rn` grep-ism note fires only when the value was bundled into the
        // same short token (taken from this token, not the next argv).
        .replace => {
            const bundled = v.mode == .short and v.j + 1 < v.arg.len;
            o.replace = v.take();
            if (bundled) noteGrepStyleReplace(o.replace.?);
        },
        .file => b.pat_files.append(b.a, v.take()) catch oom(),
        .ignore_file => b.ignore_files.append(b.a, v.take()) catch oom(),
        .type_add => b.addTypeDef(v.take()),
        // --color WHEN: resolved to an actual go/no-go (stdout tty + env) by
        // `color.zig` at emit time — this just records the requested mode.
        .color => o.color = enumOrDie(ColorChoice, "bad --color value: {s}\n", v.take()),
        .encoding => {
            const label = v.take();
            o.encoding = encodingFromLabel(label) orelse switch (v.mode) {
                .short => die("bad -E/--encoding value\n", .{}),
                .long => die("bad --encoding value: {s}\n", .{label}),
            };
        },
        .pre_glob => b.addPreGlob(v.take()),
        // --rank takes an OPTIONAL inline count only (`--rank=N`); a bare `--rank`
        // must not swallow the following token — that's the pattern (`gist --rank foo`).
        .rank => {
            o.rank, o.rank_k = .{ true, if (v.inl) |x| toU(x) else o.rank_k };
        },
        .engine_is => |e| o.engine = e,
        .engine => o.engine = enumOrDie(Engine, "bad --engine value: {s} (expected default, pcre2, or auto)\n", v.take()),
        .noop => {},
        .noop_val => _ = v.take(),
        .colors => if (color.validateColorSpec(v.take())) |msg|
            die("gist: error parsing flag --colors: {s}\n", .{msg}),
        .unsupported => switch (v.mode) {
            .short => die("-{c} unsupported by design — use ripgrep for this\n", .{v.arg[v.j]}),
            .long => die("--{s} unsupported by design — use ripgrep for this\n", .{v.name}),
        },
    }
}

fn parseShort(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    var j: usize = 1;
    while (j < arg.len) : (j += 1) {
        const spec = flag_catalog[short_map[arg[j]] orelse die("unknown flag -{c}\n", .{arg[j]})];
        var v = ValSrc{ .mode = .short, .i = i, .all = all, .arg = arg, .j = j };
        apply(b, spec.action, &v);
        if (v.consumed) return; // the value ate the rest of the bundle (or the next argv)
    }
}

fn parseLong(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = body[0 .. eq orelse body.len];
    const spec = flag_catalog[long_map.get(name) orelse die("unknown flag --{s}\n", .{name})];
    var v = ValSrc{ .mode = .long, .i = i, .all = all, .name = name, .inl = if (eq) |e| body[e + 1 ..] else null };
    apply(b, spec.action, &v);
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
            b.roots.append(a, arg) catch oom();
        }
    }
    // --files / --type-list take no pattern; a stray "pattern" is actually a path.
    if (b.o.noPattern()) {
        if (b.pat) |p0| {
            b.roots.insert(a, 0, p0) catch oom();
            b.pat = null;
        }
    } else if (b.pat == null and b.pat_files.items.len == 0) {
        die("usage: rg [flags] <pattern> [PATH...]\n", .{});
    }
    // Assemble the in-argv patterns (bare / -e / --regexp); pattern FILES are read
    // later by the caller (needs IO) and appended there.
    var pats: std.ArrayList([]const u8) = .empty;
    if (b.pat) |p0| pats.append(a, p0) catch oom();
    pats.appendSlice(a, b.extra_pats.items) catch oom();
    // -A/-B take precedence over -C regardless of order (ripgrep's rule).
    b.o.after = b.a_val orelse b.c_val orelse 0;
    b.o.before = b.b_val orelse b.c_val orelse 0;
    // -u = --no-ignore, -uu = +hidden, -uuu = +--binary (rg's tiers). gist's
    // --binary searches binary files in full (see Opts.binary), so -uuu brings the
    // whole tree — ignored, hidden, and binary — online.
    if (b.urestrict >= 1) b.o.no_ignore = true;
    if (b.urestrict >= 2) b.o.hidden = true;
    if (b.urestrict >= 3) b.o.binary = true;
    if (b.o.smart_case and !b.o.caseless) b.o.caseless = for (pats.items) |pp| {
        if (hasUpper(pp)) break false;
    } else true;
    // --glob-case-insensitive: fold case-sensitive includes into the iglob set.
    if (b.glob_ci) {
        b.iglobs.appendSlice(a, b.includes.items) catch oom();
        b.includes.clearRetainingCapacity();
    }
    inline for (.{ "exts", "neg_exts", "includes", "iglobs", "excludes" }) |f|
        @field(b.o.filter, f) = @field(b, f).toOwnedSlice(a) catch oom();
    b.o.filter.type_all, b.o.filter.ntype_all = .{ b.type_all, b.ntype_all };
    inline for (.{ "ignore_files", "pre_globs", "pre_excludes" }) |f|
        @field(b.o, f) = @field(b, f).toOwnedSlice(a) catch oom();
    return .{
        .patterns = pats.toOwnedSlice(a) catch oom(),
        .opts = b.o,
        .roots = b.roots.toOwnedSlice(a) catch oom(),
        .pattern_files = b.pat_files.toOwnedSlice(a) catch oom(),
    };
}

// Test-plane shorthand: `parseArgv` borrows from a caller-owned parse-time
// arena by contract, so the tests lean on the process-lifetime page allocator
// instead of re-declaring a per-test arena (nothing to free before exit).
const t = std.testing;
const ta = std.heap.page_allocator;

test "sort modes preserve ripgrep walker semantics" {
    const sorted = parseArgv(ta, &.{ "--sort", "path", "needle", "root-a", "root-b" });
    try t.expect(sorted.opts.sorted);
    try t.expectEqual(SortKey.path, sorted.opts.sort_key);
    try t.expect(!sorted.opts.sort_reverse);

    const unsorted = parseArgv(ta, &.{ "--sort=none", "needle", "root-a", "root-b" });
    try t.expect(!unsorted.opts.sorted);
    try t.expectEqual(SortKey.none, unsorted.opts.sort_key);
}

test "sort key + direction: every rg key, ascending and reversed" {

    // --sort <key> is ascending; --sortr <key> flips only the direction bit.
    inline for (.{ "modified", "accessed", "created", "path" }) |k| {
        const asc = parseArgv(ta, &.{ "--sort", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, asc.opts.sort_key);
        try t.expect(!asc.opts.sort_reverse and asc.opts.sorted);
        const desc = parseArgv(ta, &.{ "--sortr", k, "needle" });
        try t.expectEqual(std.meta.stringToEnum(SortKey, k).?, desc.opts.sort_key);
        try t.expect(desc.opts.sort_reverse and desc.opts.sorted);
    }
    // --sort-files is rg's deprecated alias for --sort=path (ascending).
    const sf = parseArgv(ta, &.{ "--sort-files", "needle" });
    try t.expectEqual(SortKey.path, sf.opts.sort_key);
    try t.expect(sf.opts.sorted and !sf.opts.sort_reverse);
    // `--sortr none` collapses to no ordering (reverse of nothing is nothing).
    const rnone = parseArgv(ta, &.{ "--sortr=none", "needle" });
    try t.expect(!rnone.opts.sorted and !rnone.opts.sort_reverse);
    try t.expectEqual(SortKey.none, rnone.opts.sort_key);
}

test "-j/--threads caps the worker pool; both spellings, inline + spaced" {
    try t.expectEqual(@as(usize, 3), parseArgv(ta, &.{ "-j3", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 4), parseArgv(ta, &.{ "-j", "4", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 8), parseArgv(ta, &.{ "--threads=8", "needle" }).opts.threads);
    try t.expectEqual(@as(usize, 0), parseArgv(ta, &.{"needle"}).opts.threads); // unset = adaptive
}

test "negation flags are last-wins toggles, not default-state no-ops" {

    // Each --no-X genuinely undoes an earlier --X (ripgrep's left-to-right rule),
    // and a later --X wins again.
    try t.expect(!parseArgv(ta, &.{ "--heading", "--no-heading", "x" }).opts.heading);
    try t.expect(parseArgv(ta, &.{ "--no-heading", "--heading", "x" }).opts.heading);
    try t.expect(!parseArgv(ta, &.{ "--trim", "--no-trim", "x" }).opts.trim);
    try t.expect(!parseArgv(ta, &.{ "--stats", "--no-stats", "x" }).opts.stats);
    try t.expect(!parseArgv(ta, &.{ "-L", "--no-follow", "x" }).opts.follow);
    try t.expect(parseArgv(ta, &.{ "--no-follow", "-L", "x" }).opts.follow);
}

test "--one-file-system records the device-boundary intent" {
    try t.expect(parseArgv(ta, &.{ "--one-file-system", "x" }).opts.one_file_system);
    try t.expect(!parseArgv(ta, &.{"x"}).opts.one_file_system);
}

test "-rn keeps ripgrep replace semantics but is flagged as a grep-ism" {

    // Parity is sacred: `-rn` must still parse as --replace=n, exactly like rg.
    const p = parseArgv(ta, &.{ "-rn", "needle", "root" });
    try t.expectEqualStrings("n", p.opts.replace.?);
    try t.expect(!p.opts.line_num);

    // The stderr note fires only for bundle-shaped values, never for real
    // replacement templates or an unbundled `-r VALUE`.
    try t.expect(looksLikeFlagBundle("n"));
    try t.expect(looksLikeFlagBundle("ni"));
    try t.expect(!looksLikeFlagBundle("$1"));
    try t.expect(!looksLikeFlagBundle("REDACTED"));
    try t.expect(!looksLikeFlagBundle(""));
    const spaced = parseArgv(ta, &.{ "-r", "n", "needle", "root" });
    try t.expectEqualStrings("n", spaced.opts.replace.?);
}

test "flag catalog is the parser compatibility source of truth" {
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
            .improvement => bucket_counts[1] += 1,
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
    // Bucket 1 is now `improvement` (proven-better wins): every flag that once
    // diverged is either a documented improvement or was reconciled to parity.
    try t.expect(bucket_counts[0] > 0 and bucket_counts[1] > 0 and bucket_counts[2] > 0);
    try t.expectEqual(@as(usize, 0), bucket_counts[3]);
    // -i/-S/-w reached rg parity (Unicode by default), and --unicode/--no-unicode
    // are genuine toggles rather than accepted-but-ignored no-ops.
    try t.expect(i_supported and word_supported and smart_supported);
    try t.expect(unicode_supported and no_unicode_supported);
}

test "content-transform flags parse into Opts" {
    const z = parseArgv(ta, &.{ "-z", "needle", "logs" });
    try t.expect(z.opts.search_zip);

    const e = parseArgv(ta, &.{ "-E", "utf-16le", "needle", "f" });
    try t.expectEqual(Encoding.utf16le, e.opts.encoding);
    // WHATWG folds latin1 into windows-1252 (encoding_rs parity), and the CJK
    // labels the pitch names explicitly now resolve rather than failing loud.
    const e2 = parseArgv(ta, &.{ "--encoding=latin1", "needle", "f" });
    try t.expectEqual(Encoding.windows_1252, e2.opts.encoding);
    try t.expectEqual(Encoding.shift_jis, parseArgv(ta, &.{ "-E", "sjis", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.gb18030, parseArgv(ta, &.{ "-E", "gbk", "needle", "f" }).opts.encoding);
    try t.expectEqual(Encoding.euc_jp, parseArgv(ta, &.{ "--encoding=euc-jp", "needle", "f" }).opts.encoding);

    const pre = parseArgv(ta, &.{ "--pre", "/bin/cat", "--pre-glob", "*.gz", "--pre-glob", "!*.tmp", "needle", "d" });
    try t.expectEqualStrings("/bin/cat", pre.opts.pre.?);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_globs.len);
    try t.expectEqualStrings("*.gz", pre.opts.pre_globs[0]);
    try t.expectEqual(@as(usize, 1), pre.opts.pre_excludes.len);
    try t.expectEqualStrings("*.tmp", pre.opts.pre_excludes[0]);

    // -uuu now brings the whole tree online: --no-ignore + hidden + --binary.
    const uuu = parseArgv(ta, &.{ "-uuu", "needle", "d" });
    try t.expect(uuu.opts.no_ignore and uuu.opts.hidden and uuu.opts.binary);
}

test "enumeration() marks every compact per-file mode, and no content mode" {
    // The set exempted from the soft context cap (`corpus.exemptSoftCap`): each
    // must classify as enumeration so its result SET stays complete + reproducible
    // rather than a soft-cap-truncated, order-dependent subset.
    for ([_][]const []const u8{
        &.{ "-l", "needle", "d" }, // --files-with-matches
        &.{ "--files-without-match", "needle", "d" },
        &.{ "-c", "needle", "d" }, // --count
        &.{ "--count-matches", "needle", "d" },
        &.{"--files"}, // pattern-free listing
    }) |argv| try t.expect(parseArgv(ta, argv).opts.enumeration());

    // Content/structured modes carry real volume — the cap is theirs to keep,
    // and their truncation is already ordered/deterministic.
    for ([_][]const []const u8{
        &.{ "needle", "d" }, // default line search
        &.{ "-o", "needle", "d" }, // only-matching
        &.{ "-C", "2", "needle", "d" }, // context
        &.{ "--json", "needle", "d" },
    }) |argv| try t.expect(!parseArgv(ta, argv).opts.enumeration());
}
