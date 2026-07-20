//! gist ranking signals — the language-agnostic, byte-level heuristics the T4
//! ranker (sibling `rank.zig`) consumes as `Doc` features. Two questions,
//! answered from raw bytes with no parser:
//!
//!   • **`definesNeedle`** — does this line *define* the needle (vs use it)? The
//!     definition boost is the agent win `grep` can't express: a symbol's decl
//!     outranks its call sites.
//!   • **`isGenerated`** — is this file codegen output? Generated files win both
//!     lexical density and the def boost (their boilerplate stubs parse as
//!     decls) yet are almost never an agent's edit target, so the ranker demotes
//!     them.
//!
//! Both are deliberately **cross-language, not Billy-specific**.
//! `declarationConfidence` reads geometry rather than a language catalogue:
//! identifier boundaries, delimiter nesting, assignment, and body-opening
//! punctuation. `shapeFingerprint` applies relate's model-free normalization
//! idea to one match line (query identifier → Q, other identifiers → I,
//! strings → S, numbers → N), letting the ranker price repeated use shapes
//! below rarer explanatory shapes. `isGenerated` trusts universal header
//! markers first and filename conventions only when bytes are unavailable.
//! Every signal only reorders results; none can hide a match.

const std = @import("std");

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isComment(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "/*") or std.mem.startsWith(u8, t, "*") or
        std.mem.startsWith(u8, t, "<!--");
}

fn nextWhole(hay: []const u8, needle: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| : (i = pos + 1) {
        const end = pos + needle.len;
        if ((pos == 0 or !isIdentByte(hay[pos - 1])) and
            (end == hay.len or !isIdentByte(hay[end]))) return pos;
    }
    return null;
}

const Geometry = struct {
    identifiers: u8 = 0,
    parens: i16 = 0,
    brackets: i16 = 0,
    braces: i16 = 0,
    disqualifying: bool = false,
};

/// Shape of the prefix before a query identifier. Balanced groups are allowed
/// (Go receivers); an unmatched group means the query is an argument, generic,
/// import member, or collection element rather than the name being introduced.
fn prefixGeometry(prefix: []const u8) Geometry {
    var g: Geometry = .{};
    var i: usize = 0;
    while (i < prefix.len) {
        const c = prefix[i];
        if (c == '"' or c == '\'' or c == '`') {
            g.disqualifying = true;
            break;
        }
        if (isIdentByte(c) and !std.ascii.isDigit(c)) {
            g.identifiers +|= 1;
            i += 1;
            while (i < prefix.len and isIdentByte(prefix[i])) i += 1;
            continue;
        }
        switch (c) {
            '(' => g.parens += 1,
            ')' => g.parens -= 1,
            '[' => g.brackets += 1,
            ']' => g.brackets -= 1,
            '{' => g.braces += 1,
            '}' => g.braces -= 1,
            '=', ',', ';' => {
                if (g.parens == 0 and g.brackets == 0 and g.braces == 0)
                    g.disqualifying = true;
            },
            else => {},
        }
        i += 1;
    }
    return g;
}

fn nonSpaceBefore(s: []const u8) ?u8 {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] != ' ' and s[i] != '\t') return s[i];
    }
    return null;
}

fn bodyAfterCall(s: []const u8) bool {
    var depth: usize = 0;
    var quote: ?u8 = null;
    for (s, 0..) |c, i| {
        if (quote) |q| {
            if (c == q and (i == 0 or s[i - 1] != '\\')) quote = null;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
        } else if (c == '(') {
            depth += 1;
        } else if (c == ')' and depth > 0) {
            depth -= 1;
        } else if (depth == 0 and (c == '{' or c == ':' or
            (c == '=' and i + 1 < s.len and s[i + 1] == '>')))
        {
            return true;
        }
    }
    return false;
}

fn singleIdentifier(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r;");
    if (t.len == 0 or std.ascii.isDigit(t[0])) return false;
    for (t) |c| if (!isIdentByte(c)) return false;
    return true;
}

/// Parser-free declaration evidence, 0 (use) through 3 (body/value-bearing
/// definition). No declaration words or language/file tables are consulted.
/// The distinction matters: `let target: typeof import(...)` introduces a
/// name, but should rank below `function target(...) { ... }`.
pub fn declarationConfidence(line: []const u8, needle: []const u8) u8 {
    if (needle.len == 0 or isComment(line)) return 0;
    const t = std.mem.trimStart(u8, line, " \t");
    var from: usize = 0;
    var best: u8 = 0;
    while (nextWhole(t, needle, from)) |pos| {
        from = pos + 1;
        const before = t[0..pos];
        const g = prefixGeometry(before);
        if (g.disqualifying or g.parens != 0 or g.brackets != 0 or g.braces != 0) continue;
        if (nonSpaceBefore(before)) |c| if (c == '.' or c == ':' or c == '>' or c == '@') continue;

        const rest = std.mem.trimStart(u8, t[pos + needle.len ..], " \t");
        if (rest.len == 0) continue;
        if (rest[0] == '=') {
            best = @max(best, 3);
        } else if (rest[0] == '{') {
            best = @max(best, 3);
        } else if (rest[0] == ':') {
            const annotation = std.mem.trim(u8, rest[1..], " \t\r;");
            const confidence: u8 = if (annotation.len == 0) 3 else if (std.mem.indexOfScalar(u8, annotation, '=') != null) 2 else 1;
            best = @max(best, confidence);
        } else if (rest[0] == '(' or rest[0] == '<') {
            if (bodyAfterCall(rest)) best = @max(best, 3) else if (g.identifiers > 0) best = @max(best, 2);
        } else if (g.identifiers > 0 and singleIdentifier(rest)) {
            best = @max(best, 1);
        }
    }
    return best;
}

pub fn definesNeedle(line: []const u8, needle: []const u8) bool {
    return declarationConfidence(line, needle) > 0;
}

fn hashByte(h: *u64, b: u8) void {
    h.* = (h.* ^ b) *% 1099511628211;
}

/// Relate-style normalized shape of a matching line. Unlike silhouette's
/// file-level sketch this is allocation-free and keeps no keyword shelf.
pub fn shapeFingerprint(line: []const u8, needle: []const u8) u64 {
    if (needle.len == 0 or isComment(line)) return 0;
    var h: u64 = 14695981039346656037;
    var found = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/' or c == '#') break;
        if (c == '"' or c == '\'' or c == '`') {
            hashByte(&h, 'S');
            const q = c;
            i += 1;
            while (i < line.len and line[i] != q) i += if (line[i] == '\\') 2 else 1;
            i = @min(i + 1, line.len);
        } else if (std.ascii.isDigit(c)) {
            hashByte(&h, 'N');
            i += 1;
            while (i < line.len and (isIdentByte(line[i]) or line[i] == '.')) i += 1;
        } else if (isIdentByte(c) and !std.ascii.isDigit(c)) {
            var end = i + 1;
            while (end < line.len and isIdentByte(line[end])) end += 1;
            if (std.mem.eql(u8, line[i..end], needle)) {
                hashByte(&h, 'Q');
                found = true;
            } else hashByte(&h, 'I');
            i = end;
        } else {
            i += 1;
            if (c == ' ' or c == '\t' or c == '\r') continue;
            hashByte(&h, c);
        }
    }
    return if (found) h else 0;
}

/// Known generated-filename suffixes across ecosystems (protoc/Connect/sqlc
/// conventions + the common protobuf/Dart/C#/minified outputs). Path-suffix
/// first (no bytes needed); the marker sniff below catches everything else.
const gen_suffixes = [_][]const u8{
    // protoc / Connect-RPC / sqlc / *.gen.* codegen conventions
    ".pb.go",        ".pb.gw.go", ".connect.go",   ".sql.go",          ".gen.go",      "_gen.go",
    "_pb2.py",       "_pb2.pyi",  "_pb2_grpc.pyi", ".gen.py",          "_gen.py",      ".pb.swift",
    ".gen.swift",    "_pb.ts",    "_connect.ts",   "_connectquery.ts", ".gen.ts",      ".gen.tsx",
    ".generated.ts", "_gen.rs",   ".gen.json",
    // wider ecosystem: protobuf (C++/Python-grpc/Dart), Dart codegen, C#, minified
        ".pb.cc",           ".pb.h",        "_pb2_grpc.py",
    ".pb.dart",      ".g.dart",   ".freezed.dart", ".g.cs",            ".designer.cs", ".min.js",
    ".min.css",      "_pb.d.ts",
};
/// First-line markers — the *universal* generated signal, language-independent
/// and far more reliable than any suffix list. Checked only on the first line
/// (the conventional codegen header), so a body mention can't false-trip it.
const gen_markers = [_][]const u8{
    "code generated", "generated by",  "@generated",        "do not edit",
    "auto-generated", "autogenerated", "machine generated",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i|
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

fn generatedHeaderLine(line: []const u8) bool {
    var text = std.mem.trim(u8, line, " \t\r");
    for ([_][]const u8{ "//", "--", "#", "/*", "*", "<!--" }) |prefix| if (std.mem.startsWith(u8, text, prefix)) {
        text = std.mem.trimStart(u8, text[prefix.len..], " \t");
        break;
    };
    for (gen_markers) |m| if (text.len >= m.len and std.ascii.eqlIgnoreCase(text[0..m.len], m)) return true;
    return containsIgnoreCase(text, "generated") and containsIgnoreCase(text, "do not edit");
}

/// The path-only half of the codegen signal: a known generated-filename suffix.
/// Callers that hold no file bytes (e.g. the atlas-warm kinship verbs) use this
/// to demote codegen from a path alone — it misses only marker-headed files
/// with an unconventional name, a liberal-by-design gap that just reorders.
pub fn isGeneratedPath(path: []const u8) bool {
    for (gen_suffixes) |s| if (std.mem.endsWith(u8, path, s)) return true;
    return false;
}

/// Is this a codegen artifact? A known generated filename suffix, or a generated
/// marker on the first line. Liberal by design — a false demote only reorders a
/// match, never drops it (same contract the repo's shape gates use).
pub fn isGenerated(path: []const u8, buf: []const u8) bool {
    if (isGeneratedPath(path)) return true;
    const head = buf[0..@min(buf.len, 2048)];
    var lines = std.mem.splitScalar(u8, head, '\n');
    var seen: usize = 0;
    while (seen < 8) : (seen += 1) {
        const line = lines.next() orelse break;
        if (generatedHeaderLine(line)) return true;
    }
    return false;
}
