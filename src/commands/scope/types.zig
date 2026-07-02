//! Language → glob table — the `-t <lang>` scope an agent types.
//!
//! Split from the glob matcher (`glob.zig`) because it is a pure data concern:
//! a comptime table mapping a type name to the globs that recognize it, plus
//! two trivial lookups over it. This is gist's own registry: every mainstream
//! language, build system, config format, doc convention, and archive kind,
//! organized by domain below so it reads as a single coherent system, not a
//! grab-bag. Nothing here is specific to any one codebase — every row is a
//! type any project could hit. Every row is matched with the
//! exact same engine `-g`/`--glob` uses (`glob.globApplies` — basename match
//! when a glob has no `/`), so bare filenames (`Makefile.*`, `Kconfig`,
//! `COPYING[.-]*`), character classes (`*.[chH]`), and "contains" globs
//! (`*Dockerfile*`) all just work with no bespoke suffix comparator.
//!
//! Multiple names that resolve to the same recognition rule (`py`/`python`,
//! `rust`/`rs`, `ts`/`typescript`, `docker`/`dockerfile`, `config`/`ini`, …)
//! share one glob slice on one row — comptime-deduplicated, never
//! copy-pasted, so the aliases can never drift apart. A name the table
//! doesn't know is a hard error at the caller's parse time (fail loud — a
//! silent empty result is the worst agent failure).

const std = @import("std");
const glob = @import("glob.zig");

pub const TypeRow = struct { names: []const []const u8, globs: []const []const u8 };

pub const type_table = [_]TypeRow{
    // ── Systems & compiled ──
    .{ .names = &.{"ada"}, .globs = &.{ "*.adb", "*.ads" } },
    .{ .names = &.{"asm"}, .globs = &.{ "*.asm", "*.s", "*.S" } },
    .{ .names = &.{"ats"}, .globs = &.{ "*.ats", "*.dats", "*.sats", "*.hats" } },
    .{ .names = &.{"c"}, .globs = &.{ "*.[chH]", "*.[chH].in", "*.cats" } },
    .{ .names = &.{"carp"}, .globs = &.{"*.carp"} },
    .{ .names = &.{"cpp"}, .globs = &.{
        "*.[ChH]",     "*.cc",        "*.[ch]pp", "*.[ch]xx", "*.hh",  "*.inl", "*.[ChH].in", "*.cc.in",
        "*.[ch]pp.in", "*.[ch]xx.in", "*.hh.in",  "*.c++",    "*.h++", "*.ipp",
    } },
    .{ .names = &.{"crystal"}, .globs = &.{ "Projectfile", "*.cr", "*.ecr", "shard.yml" } },
    .{ .names = &.{"cuda"}, .globs = &.{ "*.cu", "*.cuh" } },
    .{ .names = &.{"d"}, .globs = &.{"*.d"} },
    .{ .names = &.{"fortran"}, .globs = &.{
        "*.f",   "*.F", "*.f77", "*.F77", "*.pfo", "*.f90", "*.F90", "*.f95", "*.F95", "*.for",
        "*.f03",
    } },
    .{ .names = &.{"go"}, .globs = &.{ "*.go", "go.mod", "go.sum" } },
    .{ .names = &.{"gprbuild"}, .globs = &.{"*.gpr"} },
    .{ .names = &.{"h"}, .globs = &.{ "*.h", "*.hh", "*.hpp" } },
    .{ .names = &.{"hare"}, .globs = &.{"*.ha"} },
    .{ .names = &.{"llvm"}, .globs = &.{"*.ll"} },
    .{ .names = &.{"nim"}, .globs = &.{ "*.nim", "*.nimf", "*.nimble", "*.nims" } },
    .{ .names = &.{"objc"}, .globs = &.{ "*.h", "*.m" } },
    .{ .names = &.{"objcpp"}, .globs = &.{ "*.h", "*.mm" } },
    .{ .names = &.{"pascal"}, .globs = &.{ "*.pas", "*.dpr", "*.lpr", "*.pp", "*.inc" } },
    .{ .names = &.{"qml"}, .globs = &.{"*.qml"} },
    .{ .names = &.{"qrc"}, .globs = &.{"*.qrc"} },
    .{ .names = &.{"qui"}, .globs = &.{"*.ui"} },
    .{ .names = &.{ "rust", "rs" }, .globs = &.{"*.rs"} },
    .{ .names = &.{"solidity"}, .globs = &.{"*.sol"} },
    .{ .names = &.{"sv"}, .globs = &.{ "*.v", "*.vg", "*.sv", "*.svh", "*.h" } },
    .{ .names = &.{"swift"}, .globs = &.{"*.swift"} },
    .{ .names = &.{"swig"}, .globs = &.{ "*.def", "*.i" } },
    .{ .names = &.{"v"}, .globs = &.{ "*.v", "*.vsh" } },
    .{ .names = &.{"vala"}, .globs = &.{"*.vala"} },
    .{ .names = &.{"verilog"}, .globs = &.{ "*.v", "*.vh", "*.sv", "*.svh" } },
    .{ .names = &.{"vhdl"}, .globs = &.{ "*.vhd", "*.vhdl" } },
    .{ .names = &.{"yacc"}, .globs = &.{"*.y"} },
    .{ .names = &.{"zig"}, .globs = &.{ "*.zig", "*.zon" } },
    // ── Proof & formal methods ──
    .{ .names = &.{"agda"}, .globs = &.{ "*.agda", "*.lagda" } },
    .{ .names = &.{"coq"}, .globs = &.{"*.v"} },
    .{ .names = &.{"idris"}, .globs = &.{ "*.idr", "*.lidr" } },
    .{ .names = &.{"lean"}, .globs = &.{"*.lean"} },
    .{ .names = &.{"purs"}, .globs = &.{"*.purs"} },
    .{ .names = &.{"spark"}, .globs = &.{"*.spark"} },
    // ── JVM & .NET ──
    .{ .names = &.{"ceylon"}, .globs = &.{"*.ceylon"} },
    .{ .names = &.{"clojure"}, .globs = &.{ "*.clj", "*.cljc", "*.cljs", "*.cljx" } },
    .{ .names = &.{ "cs", "csharp" }, .globs = &.{ "*.cs", "*.csx" } },
    .{ .names = &.{"cshtml"}, .globs = &.{"*.cshtml"} },
    .{ .names = &.{"csproj"}, .globs = &.{"*.csproj"} },
    .{ .names = &.{"fsharp"}, .globs = &.{ "*.fs", "*.fsx", "*.fsi" } },
    .{ .names = &.{"groovy"}, .globs = &.{ "*.groovy", "*.gradle" } },
    .{ .names = &.{"java"}, .globs = &.{ "*.java", "*.jsp", "*.jspx", "*.properties" } },
    .{ .names = &.{"kotlin"}, .globs = &.{ "*.kt", "*.kts" } },
    .{ .names = &.{"msbuild"}, .globs = &.{
        "*.csproj", "*.fsproj", "*.vcxproj", "*.proj", "*.props", "*.targets", "*.sln", "*.slnf",
    } },
    .{ .names = &.{"scala"}, .globs = &.{ "*.scala", "*.sbt", "*.sc" } },
    .{ .names = &.{"vb"}, .globs = &.{"*.vb"} },
    // ── Web & app scripting ──
    .{ .names = &.{"asp"}, .globs = &.{
        "*.aspx", "*.aspx.cs", "*.aspx.vb", "*.ascx", "*.ascx.cs", "*.ascx.vb", "*.asp",
    } },
    .{ .names = &.{"cfml"}, .globs = &.{ "*.cfc", "*.cfm" } },
    .{ .names = &.{"coffeescript"}, .globs = &.{"*.coffee"} },
    .{ .names = &.{"cython"}, .globs = &.{ "*.pyx", "*.pxi", "*.pxd" } },
    .{ .names = &.{"dart"}, .globs = &.{"*.dart"} },
    .{ .names = &.{"elisp"}, .globs = &.{"*.el"} },
    .{ .names = &.{"elixir"}, .globs = &.{ "*.ex", "*.eex", "*.exs", "*.heex", "*.leex", "*.livemd" } },
    .{ .names = &.{"elm"}, .globs = &.{"*.elm"} },
    .{ .names = &.{"erlang"}, .globs = &.{ "*.erl", "*.hrl" } },
    .{ .names = &.{"fennel"}, .globs = &.{"*.fnl"} },
    .{ .names = &.{"fut"}, .globs = &.{"*.fut"} },
    .{ .names = &.{"gap"}, .globs = &.{ "*.g", "*.gap", "*.gi", "*.gd", "*.tst" } },
    .{ .names = &.{ "gdscript", "gd" }, .globs = &.{"*.gd"} },
    .{ .names = &.{"gleam"}, .globs = &.{"*.gleam"} },
    .{ .names = &.{"gn"}, .globs = &.{ "*.gn", "*.gni" } },
    .{ .names = &.{"haskell"}, .globs = &.{ "*.hs", "*.lhs", "*.cpphs", "*.c2hs", "*.hsc" } },
    .{ .names = &.{"hs"}, .globs = &.{ "*.hs", "*.lhs" } },
    .{ .names = &.{"hy"}, .globs = &.{"*.hy"} },
    .{ .names = &.{"janet"}, .globs = &.{"*.janet"} },
    .{ .names = &.{ "js", "javascript" }, .globs = &.{ "*.js", "*.jsx", "*.vue", "*.cjs", "*.mjs" } },
    .{ .names = &.{"jsx"}, .globs = &.{"*.jsx"} },
    .{ .names = &.{ "julia", "jl" }, .globs = &.{"*.jl"} },
    .{ .names = &.{"lisp"}, .globs = &.{ "*.el", "*.jl", "*.lisp", "*.lsp", "*.sc", "*.scm" } },
    .{ .names = &.{"lua"}, .globs = &.{"*.lua"} },
    .{ .names = &.{"matlab"}, .globs = &.{"*.m"} },
    .{ .names = &.{"mint"}, .globs = &.{"*.mint"} },
    .{ .names = &.{"ml"}, .globs = &.{"*.ml"} },
    .{ .names = &.{"motoko"}, .globs = &.{"*.mo"} },
    .{ .names = &.{"ocaml"}, .globs = &.{ "*.ml", "*.mli", "*.mll", "*.mly" } },
    .{ .names = &.{"perl"}, .globs = &.{ "*.perl", "*.pl", "*.PL", "*.plh", "*.plx", "*.pm", "*.t" } },
    .{ .names = &.{"php"}, .globs = &.{
        "*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml",
    } },
    .{ .names = &.{"prolog"}, .globs = &.{ "*.pl", "*.pro", "*.prolog", "*.P" } },
    .{ .names = &.{ "py", "python" }, .globs = &.{ "*.py", "*.pyi" } },
    .{ .names = &.{"r"}, .globs = &.{ "*.R", "*.r", "*.Rmd", "*.rmd", "*.Rnw", "*.rnw" } },
    .{ .names = &.{"racket"}, .globs = &.{"*.rkt"} },
    .{ .names = &.{"raku"}, .globs = &.{
        "*.raku", "*.rakumod", "*.rakudoc", "*.rakutest", "*.p6", "*.pl6", "*.pm6",
    } },
    .{ .names = &.{"reasonml"}, .globs = &.{ "*.re", "*.rei" } },
    .{ .names = &.{"red"}, .globs = &.{ "*.r", "*.red", "*.reds" } },
    .{ .names = &.{"rescript"}, .globs = &.{ "*.res", "*.resi" } },
    .{ .names = &.{"robot"}, .globs = &.{"*.robot"} },
    .{ .names = &.{"ruby"}, .globs = &.{
        "config.ru", "Gemfile", ".irbrc", "Rakefile", "*.gemspec", "*.rb", "*.rbw", "*.rake",
    } },
    .{ .names = &.{"scdoc"}, .globs = &.{ "*.scd", "*.scdoc" } },
    .{ .names = &.{"sml"}, .globs = &.{ "*.sml", "*.sig" } },
    .{ .names = &.{"svelte"}, .globs = &.{ "*.svelte", "*.svelte.ts" } },
    .{ .names = &.{"tcl"}, .globs = &.{"*.tcl"} },
    .{ .names = &.{ "ts", "typescript" }, .globs = &.{ "*.ts", "*.tsx", "*.cts", "*.mts" } },
    .{ .names = &.{"tsx"}, .globs = &.{"*.tsx"} },
    .{ .names = &.{"typst"}, .globs = &.{"*.typ"} },
    .{ .names = &.{ "vim", "vimscript" }, .globs = &.{
        "*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc",
    } },
    .{ .names = &.{"vue"}, .globs = &.{"*.vue"} },
    .{ .names = &.{"wgsl"}, .globs = &.{"*.wgsl"} },
    // ── Shell, build & packaging ──
    .{ .names = &.{"alire"}, .globs = &.{"alire.toml"} },
    .{ .names = &.{"amake"}, .globs = &.{ "*.mk", "*.bp" } },
    .{ .names = &.{"awk"}, .globs = &.{"*.awk"} },
    .{ .names = &.{"bash"}, .globs = &.{ "*.sh", "*.bash" } },
    .{ .names = &.{ "bat", "batch" }, .globs = &.{"*.bat"} },
    .{ .names = &.{"bazel"}, .globs = &.{
        "*.bazel",         "*.bzl",            "*.BUILD", "*.bazelrc", "BUILD", "MODULE.bazel", "WORKSPACE",
        "WORKSPACE.bazel", "WORKSPACE.bzlmod",
    } },
    .{ .names = &.{"bitbake"}, .globs = &.{ "*.bb", "*.bbappend", "*.bbclass", "*.conf", "*.inc" } },
    .{ .names = &.{"buildstream"}, .globs = &.{"*.bst"} },
    .{ .names = &.{"cabal"}, .globs = &.{"*.cabal"} },
    .{ .names = &.{"cmake"}, .globs = &.{ "*.cmake", "CMakeLists.txt" } },
    .{ .names = &.{"cmd"}, .globs = &.{ "*.bat", "*.cmd" } },
    .{ .names = &.{"dvc"}, .globs = &.{ "Dvcfile", "*.dvc" } },
    .{ .names = &.{"ebuild"}, .globs = &.{ "*.ebuild", "*.eclass" } },
    .{ .names = &.{"fish"}, .globs = &.{"*.fish"} },
    .{ .names = &.{"gradle"}, .globs = &.{
        "*.gradle",    "*.gradle.kts", "gradle.properties", "gradle-wrapper.*", "gradlew",
        "gradlew.bat",
    } },
    .{ .names = &.{"kconfig"}, .globs = &.{ "Kconfig", "Kconfig.*" } },
    .{ .names = &.{"m4"}, .globs = &.{ "*.ac", "*.m4" } },
    .{ .names = &.{"make"}, .globs = &.{
        "[Gg][Nn][Uu]makefile",    "[Mm]akefile",    "[Gg][Nn][Uu]makefile.am", "[Mm]akefile.am",
        "[Gg][Nn][Uu]makefile.in", "[Mm]akefile.in", "Makefile.*",              "*.mk",
        "*.mak",
    } },
    .{ .names = &.{"meson"}, .globs = &.{ "meson.build", "meson_options.txt", "meson.options" } },
    .{ .names = &.{"mk"}, .globs = &.{"mkfile"} },
    .{ .names = &.{"nix"}, .globs = &.{"*.nix"} },
    .{ .names = &.{"pants"}, .globs = &.{"BUILD"} },
    .{ .names = &.{ "ps", "powershell", "ps1" }, .globs = &.{
        "*.cdxml", "*.ps1", "*.ps1xml", "*.psd1", "*.psm1",
    } },
    .{ .names = &.{"qmake"}, .globs = &.{ "*.pro", "*.pri", "*.prf" } },
    .{ .names = &.{"seed7"}, .globs = &.{ "*.sd7", "*.s7i" } },
    .{ .names = &.{"sh"}, .globs = &.{
        ".env",         ".login",      ".logout",       ".profile",     "profile",   ".bash_login", "bash_login",
        ".bash_logout", "bash_logout", ".bash_profile", "bash_profile", ".bashrc",   "bashrc",      "*.bashrc",
        ".cshrc",       "*.cshrc",     ".kshrc",        "*.kshrc",      ".tcshrc",   ".zshenv",     "zshenv",
        ".zlogin",      "zlogin",      ".zlogout",      "zlogout",      ".zprofile", "zprofile",    ".zshrc",
        "zshrc",        "*.bash",      "*.csh",         "*.env",        "*.ksh",     "*.sh",        "*.tcsh",
        "*.zsh",        "*.ash",       "*.dash",
    } },
    .{ .names = &.{"zsh"}, .globs = &.{
        ".zshenv", "zshenv", ".zlogin", "zlogin", ".zlogout", "zlogout", ".zprofile", "zprofile",
        ".zshrc",  "zshrc",  "*.zsh",
    } },
    // ── Containers & infrastructure ──
    .{ .names = &.{"container"}, .globs = &.{ "*Containerfile*", "*Dockerfile*" } },
    .{ .names = &.{ "docker", "dockerfile" }, .globs = &.{"*Dockerfile*"} },
    .{ .names = &.{"dockercompose"}, .globs = &.{ "docker-compose.yml", "docker-compose.*.yml" } },
    .{ .names = &.{"puppet"}, .globs = &.{ "*.epp", "*.erb", "*.pp", "*.rb" } },
    .{ .names = &.{"systemd"}, .globs = &.{
        "*.automount", "*.conf",  "*.device", "*.link", "*.mount",  "*.path",  "*.scope",
        "*.service",   "*.slice", "*.socket", "*.swap", "*.target", "*.timer",
    } },
    .{ .names = &.{ "tf", "terraform" }, .globs = &.{
        "*.tf",   "*.tf.json",            "*.tfvars", "*.tfvars.json", "*.terraformrc", "terraform.rc",
        "*.tfrc", "*.terraform.lock.hcl",
    } },
    .{ .names = &.{"vcl"}, .globs = &.{"*.vcl"} },
    // ── Data & interchange formats ──
    .{ .names = &.{"aidl"}, .globs = &.{"*.aidl"} },
    .{ .names = &.{"avro"}, .globs = &.{ "*.avdl", "*.avpr", "*.avsc" } },
    .{ .names = &.{"boxlang"}, .globs = &.{ "*.bx", "*.bxm", "*.bxs" } },
    .{ .names = &.{"candid"}, .globs = &.{"*.did"} },
    .{ .names = &.{"cbor"}, .globs = &.{"*.cbor"} },
    .{ .names = &.{"cml"}, .globs = &.{"*.cml"} },
    .{ .names = &.{ "config", "ini" }, .globs = &.{ "*.cfg", "*.conf", "*.config", "*.ini" } },
    .{ .names = &.{"csv"}, .globs = &.{ "*.csv", "*.tsv" } },
    .{ .names = &.{"dhall"}, .globs = &.{"*.dhall"} },
    .{ .names = &.{"edn"}, .globs = &.{"*.edn"} },
    .{ .names = &.{"fidl"}, .globs = &.{"*.fidl"} },
    .{ .names = &.{"flatbuffers"}, .globs = &.{"*.fbs"} },
    .{ .names = &.{"graphql"}, .globs = &.{ "*.graphql", "*.graphqls", "*.gql" } },
    .{ .names = &.{"hcl"}, .globs = &.{"*.hcl"} },
    .{ .names = &.{"hurl"}, .globs = &.{"*.hurl"} },
    .{ .names = &.{"json"}, .globs = &.{
        "*.json", "composer.lock", "*.sarif", "*.jsonc", "*.json5", "*.ndjson",
    } },
    .{ .names = &.{"jsonl"}, .globs = &.{"*.jsonl"} },
    .{ .names = &.{"k"}, .globs = &.{"*.k"} },
    .{ .names = &.{"plist"}, .globs = &.{ "*.plist", "*.entitlements" } },
    .{ .names = &.{ "protobuf", "proto" }, .globs = &.{"*.proto"} },
    .{ .names = &.{"sql"}, .globs = &.{ "*.sql", "*.psql" } },
    .{ .names = &.{"thrift"}, .globs = &.{"*.thrift"} },
    .{ .names = &.{"toml"}, .globs = &.{ "*.toml", "Cargo.lock" } },
    .{ .names = &.{"usd"}, .globs = &.{ "*.usd", "*.usda", "*.usdc" } },
    .{ .names = &.{"webidl"}, .globs = &.{ "*.idl", "*.webidl", "*.widl" } },
    .{ .names = &.{"xml"}, .globs = &.{
        "*.xml",   "*.xml.dist", "*.dtd", "*.xsl", "*.xslt", "*.xsd", "*.xjb", "*.rng", "*.sch",
        "*.xhtml",
    } },
    .{ .names = &.{"yaml"}, .globs = &.{ "*.yaml", "*.yml" } },
    .{ .names = &.{"yang"}, .globs = &.{"*.yang"} },
    // ── Docs, license & prose ──
    .{ .names = &.{"asciidoc"}, .globs = &.{ "*.adoc", "*.asc", "*.asciidoc" } },
    .{ .names = &.{"creole"}, .globs = &.{"*.creole"} },
    .{ .names = &.{"diff"}, .globs = &.{ "*.patch", "*.diff" } },
    .{ .names = &.{"dita"}, .globs = &.{ "*.dita", "*.ditamap", "*.ditaval" } },
    .{ .names = &.{"jupyter"}, .globs = &.{ "*.ipynb", "*.jpynb" } },
    .{ .names = &.{"license"}, .globs = &.{
        "COPYING",      "COPYING[.-]*", "COPYRIGHT",    "COPYRIGHT[.-]*",  "EULA",              "EULA[.-]*",
        "licen[cs]e",   "licen[cs]e.*", "LICEN[CS]E",   "LICEN[CS]E[.-]*", "*[.-]LICEN[CS]E*",  "NOTICE",
        "NOTICE[.-]*",  "PATENTS",      "PATENTS[.-]*", "UNLICEN[CS]E",    "UNLICEN[CS]E[.-]*", "agpl[.-]*",
        "gpl[.-]*",     "lgpl[.-]*",    "AGPL-*[0-9]*", "APACHE-*[0-9]*",  "BSD-*[0-9]*",       "CC-BY-*",
        "GFDL-*[0-9]*", "GNU-*[0-9]*",  "GPL-*[0-9]*",  "LGPL-*[0-9]*",    "MIT-*[0-9]*",       "MPL-*[0-9]*",
        "OFL-*[0-9]*",
    } },
    .{ .names = &.{"lilypond"}, .globs = &.{ "*.ly", "*.ily" } },
    .{ .names = &.{"lock"}, .globs = &.{ "*.lock", "package-lock.json" } },
    .{ .names = &.{"log"}, .globs = &.{"*.log"} },
    .{ .names = &.{"man"}, .globs = &.{ "*.[0-9lnpx]", "*.[0-9][cEFMmpSx]" } },
    .{ .names = &.{ "markdown", "md" }, .globs = &.{
        "*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx",
    } },
    .{ .names = &.{"org"}, .globs = &.{ "*.org", "*.org_archive" } },
    .{ .names = &.{"po"}, .globs = &.{"*.po"} },
    .{ .names = &.{"pod"}, .globs = &.{"*.pod"} },
    .{ .names = &.{"postscript"}, .globs = &.{ "*.eps", "*.ps" } },
    .{ .names = &.{"rdoc"}, .globs = &.{"*.rdoc"} },
    .{ .names = &.{"readme"}, .globs = &.{ "README*", "*README" } },
    .{ .names = &.{"rst"}, .globs = &.{"*.rst"} },
    .{ .names = &.{"spec"}, .globs = &.{"*.spec"} },
    .{ .names = &.{"ssa"}, .globs = &.{"*.ssa"} },
    .{ .names = &.{"taskpaper"}, .globs = &.{"*.taskpaper"} },
    .{ .names = &.{"tex"}, .globs = &.{ "*.tex", "*.ltx", "*.cls", "*.sty", "*.bib", "*.dtx", "*.ins" } },
    .{ .names = &.{"texinfo"}, .globs = &.{"*.texi"} },
    .{ .names = &.{"textile"}, .globs = &.{"*.textile"} },
    .{ .names = &.{"txt"}, .globs = &.{ "*.txt", "*.text" } },
    .{ .names = &.{"wiki"}, .globs = &.{ "*.mediawiki", "*.wiki" } },
    // ── Web styling & templates ──
    .{ .names = &.{"css"}, .globs = &.{ "*.css", "*.scss" } },
    .{ .names = &.{"erb"}, .globs = &.{"*.erb"} },
    .{ .names = &.{"haml"}, .globs = &.{"*.haml"} },
    .{ .names = &.{ "hbs", "handlebars" }, .globs = &.{"*.hbs"} },
    .{ .names = &.{"html"}, .globs = &.{ "*.htm", "*.html", "*.ejs" } },
    .{ .names = &.{"jinja"}, .globs = &.{ "*.j2", "*.jinja", "*.jinja2" } },
    .{ .names = &.{"less"}, .globs = &.{"*.less"} },
    .{ .names = &.{"mako"}, .globs = &.{ "*.mako", "*.mao" } },
    .{ .names = &.{"minified"}, .globs = &.{ "*.min.html", "*.min.css", "*.min.js" } },
    .{ .names = &.{"sass"}, .globs = &.{ "*.sass", "*.scss" } },
    .{ .names = &.{"slim"}, .globs = &.{ "*.skim", "*.slim", "*.slime" } },
    .{ .names = &.{"smarty"}, .globs = &.{"*.tpl"} },
    .{ .names = &.{"soy"}, .globs = &.{"*.soy"} },
    .{ .names = &.{"stylus"}, .globs = &.{"*.styl"} },
    .{ .names = &.{"svg"}, .globs = &.{"*.svg"} },
    .{ .names = &.{"twig"}, .globs = &.{"*.twig"} },
    .{ .names = &.{"typoscript"}, .globs = &.{ "*.typoscript", "*.ts" } },
    // ── Archives & binary encodings ──
    .{ .names = &.{"brotli"}, .globs = &.{"*.br"} },
    .{ .names = &.{"bzip2"}, .globs = &.{ "*.bz2", "*.tbz2" } },
    .{ .names = &.{"gzip"}, .globs = &.{ "*.gz", "*.tgz" } },
    .{ .names = &.{"lz4"}, .globs = &.{"*.lz4"} },
    .{ .names = &.{"lzma"}, .globs = &.{"*.lzma"} },
    .{ .names = &.{"pdf"}, .globs = &.{"*.pdf"} },
    .{ .names = &.{"xz"}, .globs = &.{ "*.xz", "*.txz" } },
    .{ .names = &.{"z"}, .globs = &.{"*.Z"} },
    .{ .names = &.{"zstd"}, .globs = &.{ "*.zst", "*.zstd" } },
    // ── Hardware & embedded ──
    .{ .names = &.{"devicetree"}, .globs = &.{ "*.dts", "*.dtsi", "*.dtso" } },
    .{ .names = &.{"dts"}, .globs = &.{ "*.dts", "*.dtsi" } },
    // ── Policy & rules-as-code ──
    .{ .names = &.{"cedar"}, .globs = &.{"*.cedar"} },
    .{ .names = &.{"mdc"}, .globs = &.{"*.mdc"} },
    .{ .names = &.{"rego"}, .globs = &.{"*.rego"} },
};

/// The glob list for a type name, or null if unknown (caller errors). Linear
/// over a ~230-row comptime table — trivially cheap and run once per `-t`
/// flag at parse time.
pub fn extsForType(name: []const u8) ?[]const []const u8 {
    for (type_table) |row| for (row.names) |n| if (std.mem.eql(u8, n, name)) return row.globs;
    return null;
}

/// Does `path` match any glob of any built-in type? Backs `-t all` / `-T all`
/// (match/exclude every recognized source type).
pub fn isKnownType(path: []const u8) bool {
    for (type_table) |row| for (row.globs) |g| if (glob.globApplies(g, path)) return true;
    return false;
}
