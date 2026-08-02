//! What KIND of file this is — the corpus partition behind `--docs` / `--code`.
//!
//! `types.zig` answers "which language is this?" (223 rows, one per language).
//! That is the wrong grain for the question an agent actually asks, which is
//! never "is this reStructuredText" but "am I reading the paper trail, or am I
//! reading the implementation?". Answering it with `-t` means naming a dozen
//! types and still missing the extensionless `CHANGELOG`; answering it with
//! `-g` means hand-assembling twenty-nine globs that no longer say what they
//! were for. So the classification is a first-class corpus axis instead:
//!
//!   docs   prose you read to understand      (markdown, rst, man, LICENSE, …)
//!   data   payload you read to configure     (json, yaml, toml, csv, lockfiles)
//!   code   everything else — the DEFAULT
//!
//! Three genera, total and disjoint: every path is exactly one, so `--docs` and
//! `--no-docs` are exact complements and no file can fall through the partition.
//!
//! ## Code is the default, and that direction is load-bearing
//!
//! `docs` and `data` are the sets that must be recognized; `code` is what is
//! left. The asymmetry is deliberate — an unfamiliar extension, a generated
//! blob, a file with no extension at all lands in `code`, so the worst a
//! misclassification can do to `--code` is show one line too many. The
//! alternative default (a fourth `unknown` genus excluded from `--code`) would
//! turn every gap in the table into a SILENT MISS, which is the one failure
//! mode an agent cannot detect or recover from.
//!
//! The same asymmetry decides the one hard case. A documentation LOCATION or
//! NAME (`docs/`, `man/`, `CHANGELOG`) only promotes a path that nothing else
//! recognized — so `docs/notes.md` and `docs/CONVENTIONS` are docs, while
//! `docs/conf.py` and a Docusaurus site's `docs/**/*.tsx` stay code. Spelling
//! decides first; location only speaks for the unclaimed.
//!
//! ## Prior art
//!
//! The taxonomy is GitHub Linguist's (`languages.yml` types `programming` /
//! `markup` / `prose` / `data`), and the documentation-path rules are ported
//! from its `lib/linguist/documentation.yml`. Two deliberate divergences, both
//! because Linguist computes language STATISTICS while this decides RETRIEVAL:
//!
//!   * Linguist root-anchors most doc directories (`^[Dd]ocs?/`), so in a
//!     monorepo `services/ai/docs/` is not documentation. Here a doc directory
//!     counts at any depth, which is the only reading that survives a repo
//!     with two hundred packages.
//!   * Linguist also excludes `examples/`, `demos/`, and `samples/`. Those hold
//!     real, searchable source — for statistics dropping them is harmless, for
//!     a code search it is a silent miss — so they are NOT doc paths here.
//!
//! Linguist splits `markup` across both sides of the question (CSS, Vue,
//! Svelte, HTML and Jinja sit in the same category as TeX and Roff), so that
//! category is curated apart rather than adopted: the authoring languages go to
//! `docs`, the UI ones to `code`. `prose` and `data` are adopted wholesale.
//!
//! No grep-class tool ships this axis. ripgrep has 13 prose-adjacent types and
//! no aggregate over them (its one reserved name, `all`, means "any recognized
//! type"), and its type globs are basename-only, so a `docs/` rule is not
//! expressible there even by hand — ripgrep#3339, still open. ugrep's `text`
//! type (`-O text,txt,TXT,md,rst,adoc`) is the field's only bundled prose
//! aggregate: extension-only, five extensions, and with no code counterpart.
//! zoekt links go-enry, which exposes `Prose`/`Markup`/`Programming`/`Data`,
//! and never calls it. GitHub code search ships `is:vendored` and
//! `is:generated` from Linguist's path classifiers and skips the documentation
//! one.
//!
//! ## Extending it
//!
//! Nothing here is repo-specific, and it needs no new configuration key: a
//! genus name is a type name, so `--type-add 'docs:notes/**'` extends the docs
//! genus for one run and `types = ["docs:notes/**"]` in `.irregex.toml`
//! extends it for the tree (`charter.zig`, ceilinged at `Reach.corpus` — which
//! is exactly what this is). That is the per-path escape hatch Linguist spells
//! `linguist-documentation` in `.gitattributes`.

const std = @import("std");
const glob = @import("../../kernel/math/glob.zig");
const types = @import("types.zig");

/// The partition. Total and disjoint over every path; see the module header for
/// why `code` is the default rather than a fourth `unknown` member.
pub const Genus = enum {
    code,
    docs,
    data,

    /// The `-t <name>` spelling, which is also the `--<name>` flag spelling.
    pub fn label(self: Genus) []const u8 {
        return @tagName(self);
    }

    /// What an agent is choosing when it names this genus. Lives here rather
    /// than in the manifest so `--schema`, the man page, and the completions
    /// all quote one sentence instead of three that can drift apart.
    pub fn blurb(self: Genus) []const u8 {
        return switch (self) {
            .code => "the implementation — every language type, plus anything unrecognized",
            .docs => "the paper trail you read to understand: markdown, rst, man, org, TeX, LICENSE/README, and CHANGELOG-class files with no extension at all",
            .data => "the payload you read to configure: json, yaml, toml, csv, plists, lockfiles, logs, diffs, and the compressed encodings",
        };
    }
};

/// A chosen subset of the partition — what `-t docs -t data` accumulates into.
/// A bitset rather than a single `Genus` because the selection unions, exactly
/// as ripgrep's repeated `-t` does, and because the negative (`-T docs`) is the
/// same shape aimed the other way.
pub const Set = packed struct(u8) {
    code: bool = false,
    docs: bool = false,
    data: bool = false,
    _pad: u5 = 0,

    pub const empty: Set = .{};

    pub fn one(g: Genus) Set {
        var s: Set = .{};
        s.add(g);
        return s;
    }
    pub fn add(self: *Set, g: Genus) void {
        switch (g) {
            .code => self.code = true,
            .docs => self.docs = true,
            .data => self.data = true,
        }
    }
    /// Union in another selection — what a repeated `-t`/`--docs` accumulates.
    pub fn merge(self: *Set, other: Set) void {
        self.code = self.code or other.code;
        self.docs = self.docs or other.docs;
        self.data = self.data or other.data;
    }
    pub fn has(self: Set, g: Genus) bool {
        return switch (g) {
            .code => self.code,
            .docs => self.docs,
            .data => self.data,
        };
    }
    pub fn any(self: Set) bool {
        return self.code or self.docs or self.data;
    }

    /// One byte, one bit per genus, in declaration order. Spelled out rather
    /// than `@bitCast` so the resident session's wire format is this module's
    /// stated contract instead of Zig's packed-struct layout.
    pub fn bits(self: Set) u8 {
        var b: u8 = 0;
        inline for (comptime std.enums.values(Genus), 0..) |g, i|
            if (self.has(g)) {
                b |= @as(u8, 1) << @intCast(i);
            };
        return b;
    }
    /// The inverse, or null if the byte sets a bit no genus owns — a frame from
    /// a peer that knows a genus this build does not, which must fail closed
    /// (decline → cold) rather than silently drop the constraint.
    pub fn fromBits(b: u8) ?Set {
        var s: Set = .{};
        inline for (comptime std.enums.values(Genus), 0..) |g, i|
            if (b & (@as(u8, 1) << @intCast(i)) != 0) s.add(g);
        return if (s.bits() == b) s else null;
    }
};

/// The genus names a `-t`/`-T` accepts, aliases included. Null for every other
/// name, which is what tells the caller to go on to the language table — so a
/// genus name shadows nothing and costs an unrecognized type nothing.
///
/// `prose` and `source` are here because they are what the neighbors call
/// these sets (Linguist's `prose`, ripgrep's `--type-list` docs section), and a
/// name an agent guesses correctly is worth more than a name it has to learn.
pub const spellings = [_]struct { name: []const u8, genus: Genus }{
    .{ .name = "code", .genus = .code },  .{ .name = "source", .genus = .code },
    .{ .name = "docs", .genus = .docs },  .{ .name = "doc", .genus = .docs },
    .{ .name = "prose", .genus = .docs }, .{ .name = "data", .genus = .data },
};

pub fn named(name: []const u8) ?Set {
    inline for (spellings) |row| if (std.mem.eql(u8, name, row.name)) return Set.one(row.genus);
    return null;
}

// A genus name must never collide with a language type, or `-t docs` would be
// ambiguous and which reading won would depend on lookup order.
comptime {
    @setEvalBranchQuota(200_000);
    for (spellings) |s| if (types.extsForType(s.name) != null)
        @compileError("genus name collides with a language type: " ++ s.name);
    // Every genus is reachable by its own label, or a flag row could name a
    // partition member that `-t` cannot express.
    for (std.enums.values(Genus)) |g| if (named(@tagName(g)) == null)
        @compileError("genus has no spelling: " ++ @tagName(g));
}

// ── The classification ──────────────────────────────────────────────────────
//
// One line per language type in `types.zig`, by that row's canonical (first)
// name. Grouped so the taxonomy is readable as a set rather than reconstructed
// by scanning 223 rows for an annotation — you can see the whole of `docs` at
// once, which is the thing anyone editing this needs to see.
//
// The comptime proof below is exhaustive in both directions: every canonical
// name appears in exactly one list, and every name listed exists in the table.
// A new `-t` type is therefore a COMPILE ERROR until it is classified, and a
// renamed one is a compile error until the rename lands here too.

/// Prose. Adopted from Linguist's `type: prose`, plus the authoring languages
/// its `markup` category mixes in with CSS and Vue (TeX, Roff, Texinfo), plus
/// the document formats (PDF, PostScript) and the license/readme conventions.
const docs_types = [_][]const u8{
    "asciidoc", "creole", "dita",  "license", "lilypond",  "man",        "markdown",
    "mdc",      "org",    "po",    "pdf",     "pod",       "postscript", "rdoc",
    "readme",   "rst",    "scdoc", "ssa",     "taskpaper", "tex",        "texinfo",
    "textile",  "txt",    "typst", "wiki",
};

/// Payload. Adopted from Linguist's `type: data`: serialization formats,
/// configuration, tabular data, lockfiles, logs, patches, and the compressed
/// or binary encodings, which are data about bytes.
const data_types = [_][]const u8{
    "alire", "cbor",  "cml",  "config", "csv",   "diff", "dvc",     "edn",
    "json",  "jsonl", "lock", "log",    "plist", "svg",  "systemd", "toml",
    "usd",   "xml",   "yaml",
    // Compressed and binary encodings.
    "brotli", "bzip2", "gzip", "lz4",     "lzma",
    "xz",    "z",     "zstd",
};

/// Everything else. Spelled out rather than left implicit: `code` is the
/// runtime DEFAULT, but the proof needs a total assignment, and an explicit
/// list is what makes "a new type must be classified" a compile error instead
/// of a silent fall-through into code.
///
/// The judgment calls, since they are the rows a reader will question: the
/// interface definition languages (`protobuf`, `thrift`, `graphql`, `avro`,
/// `aidl`, `fidl`, `candid`, `webidl`, `flatbuffers`, `yang`) are code because
/// they are compiled into it and are grepped as source; `dhall` and `hcl` are
/// code because they have functions where `toml` and `yaml` have only values;
/// `systemd` is data for the mirror-image reason (its units are INI); `spec`
/// and `ebuild` are build recipes; `jupyter` is code because that is what a
/// notebook's cells hold.
const code_types = [_][]const u8{
    // Systems & compiled.
    "ada",          "asm",      "ats",       "c",       "carp",          "cpp",         "crystal",  "cuda",     "d",
    "fortran",      "go",       "gprbuild",  "h",       "hare",          "llvm",        "mojo",     "nim",      "objc",
    "objcpp",       "pascal",   "qml",       "qrc",     "qui",           "rust",        "solidity", "sv",       "swift",
    "swig",         "v",        "vala",      "verilog", "vhdl",          "yacc",        "zig",
    // Proof & formal methods.
         "agda",     "coq",
    "idris",        "lean",     "purs",      "spark",
    // JVM & .NET.
      "ceylon",        "clojure",     "cs",       "cshtml",   "csproj",
    "fsharp",       "groovy",   "java",      "kotlin",  "msbuild",       "scala",       "vb",
    // Web & app scripting.
          "asp",      "cfml",
    "coffeescript", "cython",   "dart",      "elisp",   "elixir",        "elm",         "erlang",   "fennel",   "fut",
    "gap",          "gdscript", "gleam",     "gn",      "haskell",       "hs",          "hy",       "janet",    "js",
    "jsx",          "julia",    "lisp",      "lua",     "matlab",        "mint",        "ml",       "motoko",   "ocaml",
    "perl",         "php",      "prolog",    "py",      "r",             "racket",      "raku",     "reasonml", "red",
    "rescript",     "robot",    "ruby",      "sml",     "svelte",        "tcl",         "ts",       "tsx",      "vim",
    "vue",          "wgsl",
    // Shell, build & packaging.
        "amake",     "awk",     "bash",          "bat",         "bazel",    "bitbake",  "buildstream",
    "cabal",        "cmake",    "cmd",       "ebuild",  "fish",          "gradle",      "kconfig",  "m4",       "make",
    "meson",        "mk",       "nix",       "pants",   "pkgbuild",      "ps",          "qmake",    "seed7",    "sh",
    "spec",         "zsh",
    // Containers & infrastructure.
         "container", "docker",  "dockercompose", "puppet",      "tf",       "vcl",
    // Interface definitions & queries.
         "aidl",
    "avro",         "boxlang",  "candid",    "dhall",   "fidl",          "flatbuffers", "graphql",  "hcl",      "hurl",
    "jupyter",      "k",        "protobuf",  "sql",     "thrift",        "webidl",      "yang",
    // Web styling & templates — Linguist's `markup`, the UI half.
        "css",      "erb",
    "haml",         "hbs",      "html",      "jinja",   "less",          "mako",        "minified", "sass",     "slim",
    "smarty",       "soy",      "stylus",    "twig",    "typoscript",
    // Hardware, and policy as code.
       "devicetree",  "dts",      "cedar",    "rego",
};

fn listed(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Which genus a `-t` type is DECLARED as, by canonical name — the lists above
/// read back out. Null only for a name that is not a type at all; the comptime
/// proof below forbids a type from having no declaration. Exists so the test
/// oracle can compare `of`'s answer against the declaration instead of against
/// itself, and so `--schema` can publish the classification per type.
pub fn declaredFor(name: []const u8) ?Genus {
    if (listed(&docs_types, name)) return .docs;
    if (listed(&data_types, name)) return .data;
    if (listed(&code_types, name)) return .code;
    return null;
}

/// Which type rows a `--type-list` narrowed to `only` may show — the answer to
/// "what counts as docs here?", asked of the binary instead of of this file.
/// Null for an empty selection, which is the unnarrowed rg-parity listing.
///
/// A plain function pointer cannot carry the selection, so one predicate is
/// minted per possible subset at comptime and the wire bits index it. The
/// partition is three genera wide, so that is eight of them.
///
/// A name the table never declared answers `code`, the same direction `of` sends
/// an unrecognized path: an overlay type invented for one run is implementation
/// until someone says otherwise, and no listing can leave it out of every genus.
pub fn listingFor(only: Set) ?types.RowAdmits {
    return if (only.any()) admitters[only.bits()] else null;
}

fn admitter(comptime selection: u8) types.RowAdmits {
    return struct {
        fn admits(canonical: []const u8) bool {
            const want = comptime Set.fromBits(selection).?;
            return want.has(declaredFor(canonical) orelse .code);
        }
    }.admits;
}

const admitters = build: {
    const width = 1 << @typeInfo(Genus).@"enum".fields.len;
    var table: [width]types.RowAdmits = undefined;
    for (0..width) |selection| table[selection] = admitter(@intCast(selection));
    break :build table;
};

comptime {
    @setEvalBranchQuota(200_000);
    // Every language type is classified exactly once.
    for (types.type_table) |row| {
        const name = row.names[0];
        var seen: usize = 0;
        for ([_][]const []const u8{ &docs_types, &data_types, &code_types }) |list| {
            if (listed(list, name)) seen += 1;
        }
        if (seen == 0) @compileError("unclassified -t type (add it to genus.zig): " ++ name);
        if (seen > 1) @compileError("-t type classified into two genera: " ++ name);
    }
    // …and every classification names a type that still exists.
    for ([_][]const []const u8{ &docs_types, &data_types, &code_types }) |list| {
        for (list) |name| {
            const row = for (types.type_table) |r| {
                if (std.mem.eql(u8, r.names[0], name)) break r;
            } else @compileError("genus.zig classifies a type that no longer exists: " ++ name);
            // Keyed on the CANONICAL name, so an alias cannot be classified
            // apart from the row it shares its globs with.
            if (!std.mem.eql(u8, row.names[0], name))
                @compileError("classify a type by its canonical name, not an alias: " ++ name);
        }
    }
}

// ── The recognition sets, derived ───────────────────────────────────────────
//
// Only `docs` and `data` need recognizing; `code` is the default, so the common
// case has to be a fast *miss* rather than a slow match. Two structures, both
// derived from `types.zig` at comptime so there is no second table to drift:
//
//   `extensions`  a bare single extension (`.md`, `.json`) → genus. One map
//                 lookup, and it holds only the ~90 extensions docs and data
//                 claim, so a `.zig` path leaves in a hash and a compare.
//   `specifics`   every richer spelling, in specificity order: exact filenames
//                 (`Dvcfile`), multi-component suffixes (`*.tf.json`), and the
//                 character-class and contains globs (`*.[0-9lnpx]`,
//                 `COPYING[.-]*`) that keep the real matcher.
//
// A specific spelling outranks a bare extension. That rule is what keeps
// `CMakeLists.txt` a build recipe rather than prose, and the SHADOW SET it
// needs — the code globs a docs/data extension would otherwise swallow — is
// computed here rather than listed, so it cannot fall out of date when either
// side of the collision moves. Today it derives seven: `CMakeLists.txt`,
// `meson_options.txt`, `shard.yml`, `docker-compose.yml`,
// `docker-compose.*.yml`, `*.tf.json`, `*.tfvars.json`.

const Claim = struct { glob: []const u8, genus: Genus };

fn pureLiteral(s: []const u8) bool {
    for (s) |c| switch (c) {
        '*', '?', '[', ']', '{', '}' => return false,
        else => {},
    };
    return true;
}

/// The bare extension a glob ends in (`*.tf.json` → `json`, `CMakeLists.txt` →
/// `txt`), or null when its tail is not a plain literal. Used to spot which
/// code globs collide with a docs/data extension, and to key the map itself.
fn tailExtension(g: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, g, '.') orelse return null;
    const tail = g[dot + 1 ..];
    return if (tail.len > 0 and pureLiteral(tail)) tail else null;
}

/// Is this glob just `*.<literal>` with a single component — the shape the
/// extension map holds, as opposed to a specific spelling?
fn bareExtension(g: []const u8) ?[]const u8 {
    if (g.len < 3 or g[0] != '*' or g[1] != '.') return null;
    const tail = g[2..];
    if (!pureLiteral(tail) or std.mem.indexOfScalar(u8, tail, '.') != null) return null;
    return tail;
}

fn globsOf(comptime list: []const []const u8, comptime g: Genus, comptime want_bare: bool) []const Claim {
    @setEvalBranchQuota(400_000);
    comptime var out: []const Claim = &.{};
    inline for (list) |name| {
        inline for (comptime types.extsForType(name).?) |pat| {
            if ((comptime bareExtension(pat) != null) == want_bare)
                out = out ++ .{Claim{ .glob = pat, .genus = g }};
        }
    }
    return out;
}

/// Docs/data extensions, deduplicated with the first claim winning.
const extensions = std.StaticStringMap(Genus).initComptime(blk: {
    @setEvalBranchQuota(400_000);
    var kvs: []const struct { []const u8, Genus } = &.{};
    for (globsOf(&data_types, .data, true) ++ globsOf(&docs_types, .docs, true)) |c| {
        const ext = bareExtension(c.glob).?;
        const dupe = for (kvs) |kv| {
            if (std.mem.eql(u8, kv[0], ext)) break true;
        } else false;
        // A docs/data collision would make the partition depend on table order,
        // which is not a fact anyone should have to know. There is none today.
        if (dupe) {
            for (kvs) |kv| if (std.mem.eql(u8, kv[0], ext) and kv[1] != c.genus)
                @compileError("extension claimed by two genera: " ++ ext);
        } else kvs = kvs ++ .{.{ ext, c.genus }};
    }
    break :blk kvs;
});

/// The code globs a docs/data extension would otherwise swallow — derived, so
/// a new collision on either side is picked up without anyone noticing it.
const shadows = blk: {
    @setEvalBranchQuota(400_000);
    var out: []const Claim = &.{};
    for (globsOf(&code_types, .code, false)) |c| {
        const ext = tailExtension(c.glob) orelse continue;
        if (extensions.get(ext) != null) out = out ++ .{c};
    }
    break :blk out;
};

/// Every non-bare-extension spelling, in the order it is consulted: the derived
/// code shadows first (narrowest and deliberate), then the docs/data specifics.
const specifics = shadows ++ globsOf(&docs_types, .docs, false) ++ globsOf(&data_types, .data, false);

/// The path's own extension: after the last dot of the BASENAME, so a dotted
/// directory (`v1.2/Makefile`) never lends its tail to the file inside it.
fn extensionOf(path: []const u8) ?[]const u8 {
    const base = path[(if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0)..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    return if (dot + 1 < base.len) base[dot + 1 ..] else null;
}

/// Which genus does the path's SPELLING claim, if any? Null hands the question
/// on to the location rule, and then to the `code` default.
fn spelled(path: []const u8) ?Genus {
    for (specifics) |c| if (glob.globApplies(c.glob, path)) return c.genus;
    return extensions.get(extensionOf(path) orelse return null);
}

// ── Documentation by location, and by name ──────────────────────────────────

/// Directory components that make their contents documentation, at any depth.
/// Linguist's `documentation.yml` directory rules, minus `examples`/`demos`/
/// `samples` and un-anchored for monorepos — see the module header for both.
const doc_dirs = [_][]const u8{
    "doc", "docs", "documentation", "man", "manual", "javadoc", "groovydoc",
};

/// Basename stems that make a file documentation on their own. Linguist's
/// `documentation.yml` file rules (`CITATION`, `CHANGE(S|LOG)`, `CONTRIBUTING`,
/// `INSTALL`) plus the rest of the conventional root paper trail. `README`,
/// `LICENSE`, `COPYING`, and `NOTICE` are absent on purpose: the `readme` and
/// `license` types already carry them, with ripgrep's exact globs.
const doc_stems = [_][]const u8{
    "acknowledgments", "acknowledgements", "authors",      "changelog",    "changes",
    "citation",        "code_of_conduct",  "contributing", "contributors", "credits",
    "faq",             "governance",       "hacking",      "history",      "install",
    "maintainers",     "news",             "roadmap",      "security",     "thanks",
    "todo",
};

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Does the path's LOCATION or NAME declare it documentation? Case-insensitive
/// so `Docs/`, `doc/`, and `Changelog` all land, as Linguist's `[Dd]ocs?`
/// character classes do.
fn documentation(path: []const u8) bool {
    var rest = path;
    while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const component = rest[0..slash];
        for (doc_dirs) |d| if (eqlFold(component, d)) return true;
        rest = rest[slash + 1 ..];
    }
    // `rest` is now the basename; a stem is everything before its first dot,
    // so `CHANGELOG.old` reads as a changelog and `changes.html` does not
    // (it never reaches here — `isKnownType` speaks for it first).
    const stem = rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse rest.len];
    for (doc_stems) |s| if (eqlFold(stem, s)) return true;
    return false;
}

/// Which genus is this path? Spelling first, then location, then code.
///
/// The `isKnownType` guard on the location rule is the whole safety argument
/// (module header): a documentation directory promotes only what no language
/// type claimed, so `docs/conf.py` and `docs/site/App.tsx` stay code and
/// `--code` cannot silently hide a source file because of where it sits.
/// It is also why that scan's cost is confined to paths under a doc directory
/// rather than paid by the whole corpus.
pub fn of(path: []const u8) Genus {
    if (spelled(path)) |g| return g;
    if (documentation(path) and !types.isKnownType(path)) return .docs;
    return .code;
}
