//! gist ranking signals — the language-agnostic, byte-level heuristics the T4
//! ranker (`src/rank.zig`) consumes as `Doc` features. Two questions, answered
//! from raw bytes with no parser:
//!
//!   • **`definesNeedle`** — does this line *define* the needle (vs use it)? The
//!     definition boost is the agent win `grep` can't express: a symbol's decl
//!     outranks its call sites.
//!   • **`isGenerated`** — is this file codegen output? Generated files win both
//!     lexical density and the def boost (their boilerplate stubs parse as
//!     decls) yet are almost never an agent's edit target, so the ranker demotes
//!     them.
//!
//! Both are deliberately **cross-language, not Billy-specific** (the prior cut
//! hardcoded only the monorepo's seven languages). `definesNeedle` knows the
//! declaration keywords of the mainstream ecosystem, so the def-boost fires on
//! ANY codebase; `isGenerated` leans first on the *universal* `@generated` /
//! `Code generated` / `DO NOT EDIT` header markers (which no ecosystem-specific
//! suffix can match) and keeps a broad suffix table as the fast path. Both
//! signals only ever **reorder** results — a miss or a false positive never
//! drops a match — so being liberal is sound.

const std = @import("std");

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whole-word presence of `w` in `hay` (identifier boundaries on both sides).
fn wholeWordIn(hay: []const u8, w: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, w)) |pos| : (i = pos + 1) {
        const lo_ok = pos == 0 or !isIdentByte(hay[pos - 1]);
        const hi = pos + w.len;
        const hi_ok = hi >= hay.len or !isIdentByte(hay[hi]);
        if (lo_ok and hi_ok) return true;
    }
    return false;
}

/// Declaration-introducing keywords across the mainstream language ecosystem —
/// the word that sits before a freshly-declared name. Kept to genuine decl
/// keywords (never bare modifiers like `static`/`public`/`void`, which would
/// boost every call site). A miss only forgoes a boost, so omissions are cheap;
/// a stray boost only reorders, so liberal inclusion is sound.
const def_kws = [_][]const u8{
    // functions / methods
    "fn",         "func",      "fun",    "def",       "defn",      "defp",
    "defmodule",  "function",  "sub",    "proc",      "procedure", "method",
    "subroutine", "program",
    // types / aggregates
      "class",  "struct",    "interface", "trait",
    "impl",       "protocol",  "actor",  "extension", "object",    "record",
    "type",       "typedef",   "enum",   "union",     "data",      "newtype",
    "template",
    // namespaces / bindings / macros
      "namespace", "module", "package",   "mod",       "const",
    "let",        "var",       "val",    "local",     "macro",
};

/// Cross-language heuristic: does `line` *define* `needle` (vs use it)? True when
/// the needle starts at an identifier boundary and a definition keyword appears
/// as a whole word before it — catches Go/Rust/Zig `fn`/`func`, Python
/// `def`/`class`, Kotlin `fun`, TS `function`, Go methods `func (r T) Name(`,
/// decls `const X =`, `type T struct`. It only ever *boosts*, so a miss costs
/// nothing. A `=`, quote, or comma before the needle means it's a RHS / string /
/// list element — a use, not a decl (`(` stays legal for `func (r T) Name(`).
pub fn definesNeedle(line: []const u8, needle: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    const npos = std.mem.indexOf(u8, t, needle) orelse return false;
    // The needle must be the declared name as a WHOLE word — an identifier
    // boundary on both sides. Without the right-side check, searching `Wallet`
    // would treat `type WalletService struct` as its definition (a prefix hit).
    if (npos > 0 and isIdentByte(t[npos - 1])) return false; // left boundary
    const after = npos + needle.len;
    if (after < t.len and isIdentByte(t[after])) return false; // right boundary
    const before = t[0..npos];
    for ([_]u8{ '=', '"', '\'', ',' }) |c| if (std.mem.indexOfScalar(u8, before, c) != null) return false;
    for (def_kws) |kw| if (wholeWordIn(before, kw)) return true;
    return false;
}

/// Known generated-filename suffixes across ecosystems (Billy's contracts-first
/// codegen + the common protobuf/Dart/C#/minified outputs). Path-suffix first
/// (no bytes needed); the marker sniff below catches everything else.
const gen_suffixes = [_][]const u8{
    // Billy contracts-first codegen
    ".pb.go",   ".pb.gw.go",     ".connect.go",      ".sql.go",      ".gen.go",      "_gen.go",
    "_pb2.py",  "_pb2.pyi",      ".gen.py",          "_gen.py",      ".pb.swift",    ".gen.swift",
    "_pb.ts",   "_connect.ts",   "_connectquery.ts", ".gen.ts",      ".gen.tsx",     ".generated.ts",
    "_gen.rs",  ".gen.json",
    // wider ecosystem: protobuf (C++/Python-grpc/Dart), Dart codegen, C#, minified
        ".pb.cc",           ".pb.h",        "_pb2_grpc.py", ".pb.dart",
    ".g.dart",  ".freezed.dart", ".g.cs",            ".designer.cs", ".min.js",      ".min.css",
    "_pb.d.ts",
};
/// First-line markers — the *universal* generated signal, language-independent
/// and far more reliable than any suffix list. Checked only on the first line
/// (the conventional codegen header), so a body mention can't false-trip it.
const gen_markers = [_][]const u8{
    "Code generated", "Generated by",  "@generated",    "DO NOT EDIT",
    "AUTO-GENERATED", "Autogenerated", "autogenerated", "auto-generated",
};

/// Is this a codegen artifact? A known generated filename suffix, or a generated
/// marker on the first line. Liberal by design — a false demote only reorders a
/// match, never drops it (same contract the repo's shape gates use).
pub fn isGenerated(path: []const u8, buf: []const u8) bool {
    for (gen_suffixes) |s| if (std.mem.endsWith(u8, path, s)) return true;
    const head = buf[0..@min(buf.len, 256)];
    const eol = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    for (gen_markers) |m| if (std.mem.indexOf(u8, head[0..eol], m) != null) return true;
    return false;
}
