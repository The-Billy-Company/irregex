//! Language → extension/filename table — the `-t <lang>` scope an agent types.
//!
//! Split from the glob matcher (`glob.zig`) because it is a pure data concern:
//! a comptime table mapping a ripgrep `--type-list` name to the file suffixes
//! that language uses, plus two trivial lookups over it. Intentionally
//! **codebase-agnostic** — gist is a general locator, not a Billy-only tool, so
//! the table spans the mainstream language ecosystem (not just the monorepo's
//! seven), and the `match` test is a plain suffix so a row may list a bare
//! filename (`Makefile`, `Dockerfile`, `go.mod`) as well as a dotted extension.
//! A name the table doesn't know is a hard error at the caller's parse time
//! (fail loud — a silent empty result is the worst agent failure). Aliases rg
//! recognizes (`py`↔`python`, `rust`↔`rs`, `ts`↔`typescript`, …) are their own
//! rows so either spelling resolves.

const std = @import("std");

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
    .{ .name = "tsx", .exts = &.{".tsx"} }, // agents reflexively type `-t tsx`; rg has no such row
    .{ .name = "js", .exts = &.{ ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte" } },
    .{ .name = "javascript", .exts = &.{ ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte" } },
    .{ .name = "jsx", .exts = &.{".jsx"} },
    .{ .name = "vue", .exts = &.{".vue"} },
    .{ .name = "svelte", .exts = &.{".svelte"} },
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
    .{ .name = "rego", .exts = &.{".rego"} }, // OPA policy (Cedar/Rego trust plane)
    .{ .name = "mdc", .exts = &.{".mdc"} }, // Cursor rule docs
    .{ .name = "cedar", .exts = &.{".cedar"} }, // Cedar authz policy
};

/// The extension/filename-suffix list for a type name, or null if unknown
/// (caller errors). Linear over a ~75-row comptime table — trivially cheap and
/// run once per `-t` flag at parse time.
pub fn extsForType(name: []const u8) ?[]const []const u8 {
    for (type_table) |row| if (std.mem.eql(u8, row.name, name)) return row.exts;
    return null;
}

/// Does `path` carry an extension/filename any built-in type recognizes? Backs
/// `rg -t all` / `-T all` (match/exclude every recognized source type).
pub fn isKnownType(path: []const u8) bool {
    for (type_table) |row| for (row.exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}
