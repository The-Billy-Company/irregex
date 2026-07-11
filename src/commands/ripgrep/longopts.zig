//! gist `rg` — the `--long-flag` catalog and its lowering into `Opts`.
//!
//! Split from `flags.zig`: this is the whole long-option surface — the `Act`
//! vocabulary, the `long_map` name→action table (the single source of truth for
//! which `--flags` gist recognizes), and `parseLong`, the switch that applies
//! each to the shared `Builder`. Short flags stay in `flags.zig`; both fill the
//! same builder. `noop` = accept+ignore (gist already satisfies it, e.g.
//! `--no-ignore-global` since gist reads no global gitignore); `noop_val` = same
//! but swallow the value; `unsupported` = fail loud (a genuine engine/design
//! divergence, so the differential harness scores it N/A rather than wrong).

const std = @import("std");
const opts = @import("opts.zig");
const die = opts.die;
const builder = @import("builder.zig");
const Builder = builder.Builder;
const nextTok = builder.nextTok;
const toU = builder.toU;
const unescape = builder.unescape;
const toBytes = builder.toBytes;

/// Every long flag gist recognizes, mapped to the action the switch takes. This
/// is the single source of truth for the long-flag surface (short flags live in
/// flags.parseShort). `noop` = accept+ignore (gist already satisfies it, e.g.
/// --no-ignore since gist is ignore-agnostic); `noop_val` = same but swallow the
/// value; `unsupported` = fail loud (a genuine engine/design divergence).
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
    sort_files,
    glob_ci, // value-taking below
    no_ignore,
    no_ignore_vcs,
    no_ignore_dot,
    no_ignore_parent,
    no_ignore_exclude,
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
    noop,
    noop_val,
    unsupported,
};

const long_map = std.StaticStringMap(Act).initComptime(.{
    .{ "ignore-case", .icase },                   .{ "case-sensitive", .scase },
    .{ "smart-case", .smart },                    .{ "word-regexp", .word },
    .{ "fixed-strings", .fixed },                 .{ "invert-match", .invert },
    .{ "only-matching", .only },                  .{ "line-number", .lnum },
    .{ "no-line-number", .no_lnum },              .{ "with-filename", .with_fn },
    .{ "no-filename", .no_fn },                   .{ "files-with-matches", .fwm },
    .{ "files-without-match", .fwithout },        .{ "count", .count },
    .{ "count-matches", .cmatches },              .{ "hidden", .hidden },
    .{ "text", .text },                           .{ "unrestricted", .unrestrict },
    .{ "column", .column },                       .{ "no-column", .no_column },
    .{ "byte-offset", .byteoff },                 .{ "vimgrep", .vimgrep },
    .{ "heading", .heading },                     .{ "no-heading", .no_heading },
    .{ "trim", .trim },                           .{ "null", .nul },
    .{ "null-data", .nul_data },                  .{ "line-regexp", .xline },
    .{ "quiet", .quiet },                         .{ "stats", .stats },
    .{ "stop-on-nonmatch", .stop_nonmatch },      .{ "passthru", .passthru },
    .{ "passthrough", .passthru },                .{ "max-columns-preview", .maxcols_preview },
    .{ "field-match-separator", .fieldmsep },     .{ "field-context-separator", .fieldcsep },
    .{ "crlf", .crlf },                           .{ "multiline", .ml },
    .{ "multiline-dotall", .ml_dotall },          .{ "json", .json },
    .{ "files", .files },                         .{ "type-list", .type_list },
    .{ "follow", .follow },                       .{ "sort-files", .sort_files },
    .{ "glob-case-insensitive", .glob_ci },       .{ "after-context", .after },
    .{ "before-context", .before },               .{ "context", .ctx },
    .{ "max-count", .maxcount },                  .{ "regexp", .regexp },
    .{ "type", .typ },                            .{ "type-not", .typ_not },
    .{ "glob", .glob },                           .{ "iglob", .iglob },
    .{ "max-columns", .maxcols },                 .{ "path-separator", .pathsep },
    .{ "max-depth", .maxdepth },                  .{ "maxdepth", .maxdepth },
    .{ "context-separator", .ctxsep },            .{ "no-context-separator", .no_ctxsep },
    .{ "replace", .replace },                     .{ "file", .file },
    // ignore-rule controls — now honored (gist reads .gitignore/.ignore)
    .{ "no-ignore", .no_ignore },                 .{ "no-ignore-vcs", .no_ignore_vcs },
    .{ "no-ignore-parent", .no_ignore_parent },   .{ "no-ignore-dot", .no_ignore_dot },
    .{ "no-ignore-exclude", .no_ignore_exclude }, .{ "no-ignore-files", .no_ignore_files },
    .{ "ignore-files", .ignore_files }, // re-enable after --no-ignore-files
    .{ "no-require-git", .no_require_git },
    .{ "require-git", .require_git },
    .{ "ignore-file-case-insensitive", .ignore_file_ci },
    .{ "no-ignore-global", .noop }, // gist reads no global gitignore → already off
    .{ "ignore-file", .ignore_file },
    // gist-native index controls (no rg equivalent): the persisted trigram index
    // is an acceleration structure only — it never changes results, so both are
    // safe on the rg-compat surface.
    .{ "no-index", .no_index },
    .{ "index", .index },
    .{ "rank", .rank },
    // accept + ignore (gist already satisfies these on an arbitrary tree)
    .{ "mmap", .noop },
    .{ "no-mmap", .noop },
    .{ "one-file-system", .noop },
    .{ "no-follow", .noop },
    .{ "no-unicode", .noop },
    .{ "unicode", .noop },
    .{ "no-stats", .noop },
    .{ "no-trim", .noop },
    // accept + swallow value
    .{ "color", .color },
    .{ "colors", .noop_val },
    .{ "sort", .noop_val },
    .{ "sortr", .noop_val },
    .{ "threads", .noop_val },
    .{ "max-filesize", .maxfsize },
    .{ "engine", .noop_val },
    .{ "dfa-size-limit", .noop_val },
    .{ "regex-size-limit", .noop_val },
    // genuine divergences — fail loud so the harness scores N/A, never wrong
    .{ "pcre2", .unsupported },
    .{ "auto-hybrid-regex", .unsupported },
    .{ "search-zip", .unsupported },
    .{ "pre", .unsupported },
    .{ "binary", .unsupported },
    .{ "type-add", .type_add },
    .{ "encoding", .unsupported },
});

pub fn parseLong(b: *Builder, arg: []const u8, i: *usize, all: []const []const u8) void {
    const body = arg[2..];
    var name = body;
    var inl: ?[]const u8 = null;
    if (std.mem.findScalar(u8, body, '=')) |eq| {
        name = body[0..eq];
        inl = body[eq + 1 ..];
    }
    const val = struct {
        fn get(v: ?[]const u8, ii: *usize, aa: []const []const u8) []const u8 {
            return v orelse nextTok(ii, aa);
        }
    }.get;
    const o = &b.o;
    switch (long_map.get(name) orelse die("unknown flag --{s}\n", .{name})) {
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
        .no_heading => {},
        .trim => o.trim = true,
        .nul => o.null_sep = true,
        .nul_data => o.null_data = true,
        .xline => o.line_regexp = true,
        .quiet => o.quiet = true,
        .stats => o.stats = true,
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
        .json => o.json = true,
        .files => o.files_list = true,
        .type_list => o.type_list = true,
        .follow => o.follow = true,
        .sort_files => {}, // gist already emits path-sorted output
        .glob_ci => b.glob_ci = true,
        .no_ignore => o.no_ignore = true,
        .no_ignore_vcs => o.no_ignore_vcs = true,
        .no_ignore_dot => o.no_ignore_dot = true,
        .no_ignore_parent => o.no_ignore_parent = true,
        .no_ignore_exclude => o.no_ignore_exclude = true,
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
        .maxcols => o.max_cols = toU(val(inl, i, all)),
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
