//! The ripgrep flag surface, declared once.
//!
//! `flag_catalog` is a table, not code: one row per flag, naming its spellings,
//! its parse effect, and its compatibility claim. Two consumers read it and
//! neither may disagree with the other — `grammar.zig` builds the short/long
//! dispatch maps from it, and `face/gist/schema/` renders `gist --schema` from
//! it. A flag cannot therefore be accepted by the parser while the machine-
//! readable manifest calls it unsupported, or vice versa; that drift used to be
//! a prose-versus-behavior bug waiting to happen.
//!
//! Most rows are purely declarative: `.set`/`.unset`/`.set_num`/`.set_str` name
//! the `Opts` field they drive, and the `comptime` block below *proves* each
//! named field has the type its action assumes, so a typo'd or retyped field is
//! a compile error rather than an unreachable branch at runtime. Only the rows
//! that genuinely need behavior (precedence, multi-value accumulation, optional
//! inline values) carry a named action for `grammar.apply` to interpret.

const std = @import("std");
const answer = @import("answer.zig");
const intent = @import("intent.zig");

const Opts = intent.Opts;
const Filename = intent.Filename;
const Engine = intent.Engine;

/// The `Opts` field a declarative catalog row drives, by name.
pub const OptField = std.meta.FieldEnum(Opts);

/// A flag's parse effect. Most flags declaratively set or clear one `Opts`
/// bool — `.set`/`.unset` carry the exact field the catalog row drives (the
/// comptime block below proves each names a bool). Everything value-taking or
/// compound keeps a named action handled in `apply`.
pub const Act = union(enum) {
    set: OptField, // set the named Opts bool
    unset: OptField, // clear it (the --no-X / undo spellings)
    set_many: []const OptField, // set several Opts bools at once
    filename: Filename, // -H/--with-filename, -I/--no-filename
    case: enum { icase, scase, smart }, // -i / -s / -S
    // `-n`/`-N`/`--column`/`--no-column` record an EXPLICIT answer; the
    // `--vimgrep`/`--column` implications are applied once at seal, so an
    // implication can never overwrite one. See `answer.Locus`.
    locate: enum { line_on, line_off, column_on, column_off },
    boundary: answer.Boundary, // -w / -x — one choice, last spelling wins
    // Every flag that competes for the one answer shape (`answer.Mode`): the
    // enumeration modes, `--json`, and the two non-search walk modes. They
    // resolve through `Mode.update`, so precedence is the enum's law rather
    // than the order these rows happen to appear in.
    mode: answer.Mode,
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
pub fn setVal(o: *Opts, f: OptField, v: anytype) void {
    switch (f) {
        // zlinter-disable-next-line no_swallow_error - comptime type guard, not an error union: `inline else` expands every field, and the non-matching expansions are the ones this branch discards
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
    .{ .short = 'w', .longs = &.{"word-regexp"}, .action = .{ .boundary = .word }, .compatibility = .supported, .note = "-w and regex \\b/\\w use Unicode word characters by default (rg parity); (?-u)/--no-unicode selects ASCII byte word chars" },
    .{ .short = 'F', .longs = &.{"fixed-strings"}, .action = .{ .set = .fixed }, .compatibility = .supported },
    .{ .short = 'v', .longs = &.{"invert-match"}, .action = .{ .set = .invert }, .compatibility = .supported },
    .{ .short = 'o', .longs = &.{"only-matching"}, .action = .{ .set = .only_matching }, .compatibility = .supported },
    .{ .short = 'n', .longs = &.{"line-number"}, .action = .{ .locate = .line_on }, .compatibility = .supported },
    .{ .short = 'N', .longs = &.{"no-line-number"}, .action = .{ .locate = .line_off }, .compatibility = .supported },
    .{ .short = 'H', .longs = &.{"with-filename"}, .action = .{ .filename = .always }, .compatibility = .supported },
    .{ .short = 'I', .longs = &.{"no-filename"}, .action = .{ .filename = .never }, .compatibility = .supported },
    .{ .short = 'l', .longs = &.{"files-with-matches"}, .action = .{ .mode = .files_with_matches }, .compatibility = .supported },
    .{ .longs = &.{"files-without-match"}, .action = .{ .mode = .files_without_match }, .compatibility = .supported },
    .{ .short = 'c', .longs = &.{"count"}, .action = .{ .mode = .count }, .compatibility = .supported },
    .{ .longs = &.{"count-matches"}, .action = .{ .mode = .count_matches }, .compatibility = .supported },
    .{ .longs = &.{"include-zero"}, .action = .{ .set = .include_zero }, .compatibility = .supported, .note = "in a count mode, print a path:0 line for every searched file with no match (exit code unchanged)" },
    .{ .longs = &.{"no-include-zero"}, .action = .{ .unset = .include_zero }, .compatibility = .supported },
    .{ .longs = &.{"hidden"}, .action = .{ .set = .hidden }, .compatibility = .supported },
    .{ .short = 'a', .longs = &.{"text"}, .action = .{ .set = .text }, .compatibility = .supported },
    .{ .longs = &.{"binary"}, .action = .{ .set = .binary }, .compatibility = .improvement, .note = "improvement: a code locator searches a NUL-bearing file in full and prints every matching line, rather than rg's opaque 'binary file matches' summary that suppresses the lines and stops" },
    .{ .short = 'u', .longs = &.{"unrestricted"}, .action = .unrestrict, .compatibility = .supported, .note = "-u=--no-ignore, -uu adds hidden, -uuu adds --binary; the ignore/hidden ladder is rg-identical, -uuu inherits the --binary improvement" },
    .{ .longs = &.{"column"}, .action = .{ .locate = .column_on }, .compatibility = .supported },
    .{ .longs = &.{"no-column"}, .action = .{ .locate = .column_off }, .compatibility = .supported },
    .{ .short = 'b', .longs = &.{"byte-offset"}, .action = .{ .set = .byte_offset }, .compatibility = .supported },
    .{ .longs = &.{"vimgrep"}, .action = .{ .set = .vimgrep }, .compatibility = .supported },
    .{ .longs = &.{"heading"}, .action = .{ .set = .heading }, .compatibility = .supported },
    .{ .longs = &.{"no-heading"}, .action = .{ .unset = .heading }, .compatibility = .supported },
    .{ .longs = &.{"trim"}, .action = .{ .set = .trim }, .compatibility = .supported },
    .{ .short = '0', .longs = &.{"null"}, .action = .{ .set = .null_sep }, .compatibility = .supported },
    .{ .longs = &.{"null-data"}, .action = .{ .set = .null_data }, .compatibility = .supported },
    .{ .short = 'x', .longs = &.{"line-regexp"}, .action = .{ .boundary = .line }, .compatibility = .supported },
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
    .{ .longs = &.{"json"}, .action = .{ .mode = .json }, .compatibility = .supported },
    .{ .longs = &.{"files"}, .action = .{ .mode = .files }, .compatibility = .supported },
    .{ .longs = &.{"type-list"}, .action = .{ .mode = .types }, .compatibility = .improvement, .note = "improvement: rg-sorted, rg-framed output over a strict SUPERSET of rg's type registry (rg's rows byte-identical; the rest richer, plus gist-only types)" },
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

pub const long_map = std.StaticStringMap(usize).initComptime(blk: {
    var pairs: []const struct { []const u8, usize } = &.{};
    for (flag_catalog, 0..) |spec, spec_i| for (spec.longs) |name| {
        pairs = pairs ++ .{.{ name, spec_i }};
    };
    break :blk pairs;
});
pub const short_map: [256]?usize = blk: {
    var map: [256]?usize = @splat(null);
    for (flag_catalog, 0..) |spec, spec_i| if (spec.short) |short| {
        if (map[short] != null) @compileError("duplicate short flag in flag_catalog");
        map[short] = spec_i;
    };
    break :blk map;
};

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
