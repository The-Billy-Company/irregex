//! gist path scoping — the `rg -t <lang>` / `rg -g <glob>` an agent reaches for
//! to confine a search to one language or subtree. This is the second-most-used
//! ripgrep affordance after `-n` itself, and the one place gist can be *faster*
//! than rg rather than merely matching it: rg applies a type/glob filter while
//! walking the whole tree, but gist already holds the full path list, so it
//! prunes candidate ids *before* touching disk — a `-t go` query reads only the
//! Go files, not all 18k candidates then 169 survivors.
//!
//! Two orthogonal constraints, AND-combined (each is a no-op when empty):
//!   • type set   (`-t go -t rust`)  — OR over a language→extension table
//!   • glob set   (`-g '*.ts' -g '!**_test*'`) — OR over include globs, with any
//!                 `!`-prefixed glob an exclude that vetoes a path outright
//! The glob dialect is gitignore/rg-shaped: a pattern with no `/` matches the
//! **basename** at any depth (`*.go`), one with a `/` matches the **full path**;
//! `*` spans a single path segment, `**` spans `/` boundaries, `?` is one
//! non-`/` byte, and `[...]` is a (negatable, range-aware) character class.

const std = @import("std");

/// Language → extension/filename suffixes, mirroring `rg --type-list` names so
/// `gist grep -t <name>` accepts the same `<name>` an agent already types at rg.
/// This is intentionally **codebase-agnostic** — gist is a general locator, not a
/// Billy-only tool, so the table spans the mainstream language ecosystem (not
/// just the monorepo's seven), and the `match` test is a plain suffix so a row
/// may list a bare filename (`Makefile`, `Dockerfile`, `go.mod`) as well as a
/// dotted extension. A name the table doesn't know is a hard error at parse time
/// (fail loud — a silent empty result is the worst agent failure). Aliases that
/// rg recognizes (`py`↔`python`, `rust`↔`rs`, `ts`↔`typescript`, …) are listed
/// as their own rows so either spelling resolves.
const TypeRow = struct { name: []const u8, exts: []const []const u8 };
const type_table = [_]TypeRow{
    // ── systems / compiled ──
    .{ .name = "go", .exts = &.{ ".go", "go.mod", "go.sum" } },
    .{ .name = "rust", .exts = &.{".rs"} },
    .{ .name = "rs", .exts = &.{".rs"} },
    .{ .name = "zig", .exts = &.{ ".zig", ".zon" } },
    .{ .name = "c", .exts = &.{ ".c", ".h" } },
    .{ .name = "cpp", .exts = &.{ ".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".inl", ".ipp" } },
    .{ .name = "cuda", .exts = &.{ ".cu", ".cuh" } },
    .{ .name = "objc", .exts = &.{ ".m", ".mm" } },
    .{ .name = "swift", .exts = &.{".swift"} },
    .{ .name = "d", .exts = &.{".d"} },
    .{ .name = "nim", .exts = &.{".nim"} },
    .{ .name = "crystal", .exts = &.{".cr"} },
    .{ .name = "fortran", .exts = &.{ ".f", ".for", ".f90", ".f95", ".f03" } },
    .{ .name = "ada", .exts = &.{ ".adb", ".ads" } },
    .{ .name = "asm", .exts = &.{ ".s", ".S", ".asm" } },
    .{ .name = "vala", .exts = &.{".vala"} },
    // ── JVM / .NET ──
    .{ .name = "java", .exts = &.{".java"} },
    .{ .name = "kotlin", .exts = &.{ ".kt", ".kts" } },
    .{ .name = "scala", .exts = &.{ ".scala", ".sc" } },
    .{ .name = "groovy", .exts = &.{ ".groovy", ".gradle" } },
    .{ .name = "clojure", .exts = &.{ ".clj", ".cljc", ".cljs", ".cljx", ".edn" } },
    .{ .name = "cs", .exts = &.{ ".cs", ".csx" } },
    .{ .name = "csharp", .exts = &.{ ".cs", ".csx" } },
    .{ .name = "fsharp", .exts = &.{ ".fs", ".fsi", ".fsx" } },
    .{ .name = "vb", .exts = &.{".vb"} },
    // ── web / scripting ──
    .{ .name = "ts", .exts = &.{ ".ts", ".tsx", ".mts", ".cts" } },
    .{ .name = "typescript", .exts = &.{ ".ts", ".tsx", ".mts", ".cts" } },
    .{ .name = "js", .exts = &.{ ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte" } },
    .{ .name = "javascript", .exts = &.{ ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte" } },
    .{ .name = "py", .exts = &.{ ".py", ".pyi", ".pyx", ".pxd", ".pxi" } },
    .{ .name = "python", .exts = &.{ ".py", ".pyi", ".pyx", ".pxd", ".pxi" } },
    .{ .name = "ruby", .exts = &.{ ".rb", ".rake", ".gemspec", "Gemfile", "Rakefile" } },
    .{ .name = "php", .exts = &.{ ".php", ".phtml", ".php3", ".php4", ".php5" } },
    .{ .name = "perl", .exts = &.{ ".pl", ".pm", ".t" } },
    .{ .name = "lua", .exts = &.{".lua"} },
    .{ .name = "r", .exts = &.{ ".r", ".R", ".Rmd" } },
    .{ .name = "julia", .exts = &.{".jl"} },
    .{ .name = "dart", .exts = &.{".dart"} },
    .{ .name = "elixir", .exts = &.{ ".ex", ".exs" } },
    .{ .name = "erlang", .exts = &.{ ".erl", ".hrl" } },
    .{ .name = "elm", .exts = &.{".elm"} },
    .{ .name = "haskell", .exts = &.{ ".hs", ".lhs" } },
    .{ .name = "ocaml", .exts = &.{ ".ml", ".mli" } },
    .{ .name = "coffeescript", .exts = &.{".coffee"} },
    // ── shell / config / build ──
    .{ .name = "sh", .exts = &.{ ".sh", ".bash", ".zsh", ".ksh", ".ash", ".dash" } },
    .{ .name = "bash", .exts = &.{ ".sh", ".bash" } },
    .{ .name = "fish", .exts = &.{".fish"} },
    .{ .name = "ps1", .exts = &.{ ".ps1", ".psm1", ".psd1" } },
    .{ .name = "powershell", .exts = &.{ ".ps1", ".psm1", ".psd1" } },
    .{ .name = "bat", .exts = &.{ ".bat", ".cmd" } },
    .{ .name = "make", .exts = &.{ ".mk", ".mak", "Makefile", "makefile", "GNUmakefile" } },
    .{ .name = "cmake", .exts = &.{ ".cmake", "CMakeLists.txt" } },
    .{ .name = "bazel", .exts = &.{ ".bzl", ".bazel", "BUILD", "WORKSPACE" } },
    .{ .name = "dockerfile", .exts = &.{ "Dockerfile", ".dockerfile" } },
    .{ .name = "docker", .exts = &.{ "Dockerfile", ".dockerfile" } },
    .{ .name = "terraform", .exts = &.{ ".tf", ".tfvars" } },
    .{ .name = "nix", .exts = &.{".nix"} },
    // ── data / markup / docs ──
    .{ .name = "sql", .exts = &.{".sql"} },
    .{ .name = "proto", .exts = &.{".proto"} },
    .{ .name = "graphql", .exts = &.{ ".graphql", ".gql" } },
    .{ .name = "thrift", .exts = &.{".thrift"} },
    .{ .name = "json", .exts = &.{ ".json", ".jsonc", ".json5", ".ndjson" } },
    .{ .name = "yaml", .exts = &.{ ".yaml", ".yml" } },
    .{ .name = "toml", .exts = &.{".toml"} },
    .{ .name = "xml", .exts = &.{ ".xml", ".xsd", ".xsl", ".xslt", ".svg" } },
    .{ .name = "csv", .exts = &.{ ".csv", ".tsv" } },
    .{ .name = "ini", .exts = &.{ ".ini", ".cfg", ".conf", ".config" } },
    .{ .name = "md", .exts = &.{ ".md", ".markdown", ".mdx" } },
    .{ .name = "markdown", .exts = &.{ ".md", ".markdown", ".mdx" } },
    .{ .name = "rst", .exts = &.{".rst"} },
    .{ .name = "tex", .exts = &.{ ".tex", ".sty", ".cls" } },
    .{ .name = "txt", .exts = &.{ ".txt", ".text" } },
    .{ .name = "asciidoc", .exts = &.{ ".adoc", ".asciidoc" } },
    .{ .name = "org", .exts = &.{".org"} },
    // ── web styling / templates ──
    .{ .name = "html", .exts = &.{ ".html", ".htm", ".xhtml" } },
    .{ .name = "css", .exts = &.{ ".css", ".scss", ".sass", ".less" } },
    .{ .name = "jinja", .exts = &.{ ".jinja", ".jinja2", ".j2" } },
    .{ .name = "handlebars", .exts = &.{ ".hbs", ".handlebars" } },
    // ── misc ──
    .{ .name = "solidity", .exts = &.{".sol"} },
    .{ .name = "protobuf", .exts = &.{".proto"} },
    .{ .name = "vim", .exts = &.{ ".vim", ".vimrc" } },
    .{ .name = "gd", .exts = &.{".gd"} }, // GDScript (Godot)
};

/// The extension/filename-suffix list for a type name, or null if unknown
/// (caller errors). Linear over a ~75-row comptime table — trivially cheap and
/// run once per `-t` flag at parse time.
pub fn extsForType(name: []const u8) ?[]const []const u8 {
    for (type_table) |row| if (std.mem.eql(u8, row.name, name)) return row.exts;
    return null;
}

/// The basename (final `/`-delimited component) of a path.
fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
}

/// Match a `[...]` class at `pat[0]=='['` against byte `c`. Returns the verdict
/// and the bytes consumed (through the closing `]`), or null when the class is
/// unterminated — the caller then treats `[` as a literal byte (rg does too).
/// Supports a leading `!`/`^` negation, `a-z` ranges, and a literal `]` only as
/// the first class member. A class never matches `/` (gitignore semantics).
const ClassHit = struct { matched: bool, len: usize };
fn matchClass(pat: []const u8, c: u8) ?ClassHit {
    var i: usize = 1; // past '['
    var neg = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        neg = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) {
            if (c == '/') return .{ .matched = false, .len = i + 1 };
            return .{ .matched = matched != neg, .len = i + 1 };
        }
        first = false;
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (c >= pat[i] and c <= pat[i + 2]) matched = true;
            i += 3;
        } else {
            if (pat[i] == c) matched = true;
            i += 1;
        }
    }
    return null; // no closing ']' ⇒ '[' is literal
}

/// gitignore/rg-shaped glob match of `pat` against `str`. `*` spans one segment
/// (stops at `/`), `**` spans `/`, `?` is one non-`/` byte, `[...]` a class.
/// Recursive with backtracking at each star; paths are short so this is cheap.
pub fn globMatch(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < pat.len) {
        switch (pat[pi]) {
            '*' => {
                if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                    var rest = pi + 2; // `**` spans '/'; absorb a trailing '/' so it may match zero dirs
                    if (rest < pat.len and pat[rest] == '/') rest += 1;
                    var k = si;
                    while (true) : (k += 1) {
                        if (globMatch(pat[rest..], str[k..])) return true;
                        if (k >= str.len) return false;
                    }
                }
                const rest = pat[pi + 1 ..]; // single `*` cannot cross '/'
                var k = si;
                while (true) : (k += 1) {
                    if (globMatch(rest, str[k..])) return true;
                    if (k >= str.len or str[k] == '/') return false;
                }
            },
            '?' => {
                if (si >= str.len or str[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                if (si >= str.len) return false;
                if (matchClass(pat[pi..], str[si])) |hit| {
                    if (!hit.matched) return false;
                    pi += hit.len;
                    si += 1;
                } else { // unterminated class ⇒ literal '['
                    if (str[si] != '[') return false;
                    pi += 1;
                    si += 1;
                }
            },
            else => {
                if (si >= str.len or str[si] != pat[pi]) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == str.len;
}

/// A glob applies to the basename when it has no `/`, else the full path — the
/// rule that lets `*.go` match at any depth while `services/**/*.go` is rooted.
fn globApplies(pat: []const u8, path: []const u8) bool {
    return if (std.mem.indexOfScalar(u8, pat, '/') == null)
        globMatch(pat, basename(path))
    else
        globMatch(pat, path);
}

/// A resolved set of path constraints. All slices are caller-owned (they alias
/// argv / a small arena built at parse time); `PathFilter` only borrows them.
pub const PathFilter = struct {
    exts: []const []const u8 = &.{}, // union of every `-t` type's extensions
    includes: []const []const u8 = &.{}, // `-g <glob>` (OR); empty ⇒ no constraint
    excludes: []const []const u8 = &.{}, // `-g !<glob>` (any match vetoes the path)

    pub fn isEmpty(self: PathFilter) bool {
        return self.exts.len == 0 and self.includes.len == 0 and self.excludes.len == 0;
    }

    /// Does `path` survive the filter? An exclude veto wins; then the path must
    /// satisfy each *non-empty* constraint set (type ∧ include), each OR-internal.
    pub fn admits(self: PathFilter, path: []const u8) bool {
        for (self.excludes) |g| if (globApplies(g, path)) return false;
        if (self.exts.len > 0) {
            var ok = false;
            for (self.exts) |e| if (std.mem.endsWith(u8, path, e)) {
                ok = true;
                break;
            };
            if (!ok) return false;
        }
        if (self.includes.len > 0) {
            for (self.includes) |g| if (globApplies(g, path)) return true;
            return false;
        }
        return true;
    }

    /// Keep only the candidate ids whose path the filter admits, in place.
    /// Returns the surviving prefix. A no-op filter returns `ids` untouched, so
    /// the unscoped path pays nothing.
    pub fn prune(self: PathFilter, paths: []const []const u8, ids: []u32) []u32 {
        if (self.isEmpty()) return ids;
        var w: usize = 0;
        for (ids) |d| if (self.admits(paths[d])) {
            ids[w] = d;
            w += 1;
        };
        return ids[0..w];
    }
};
