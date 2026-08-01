//! gist ranking signals — the language-agnostic, byte-level heuristics the T4
//! ranker (sibling `rank.zig`) consumes as `Doc` features. Three questions,
//! answered from raw bytes with no parser:
//!
//!   • **`definesNeedle`** — does this line *define* the needle (vs use it)? The
//!     definition boost is the agent win `grep` can't express: a symbol's decl
//!     outranks its call sites.
//!   • **`isGenerated`** — is this file codegen output? Generated files win both
//!     lexical density and the def boost (their boilerplate stubs parse as
//!     decls) yet are almost never an agent's edit target, so the ranker demotes
//!     them.
//!   • **`shapeFingerprint`** — what remains of a matching line after vocabulary
//!     is erased, so repeated use geometry carries less information.
//!
//! Both are deliberately **cross-language, not host-specific**.
//! `declarationConfidence` reads Unicode word boundaries and geometry rather
//! than a language catalogue: delimiter nesting, labels, equations, prefix
//! forms, and body-opening punctuation. `shapeFingerprint` applies relate's
//! model-free normalization idea to one match line (query identifier → Q,
//! other identifiers → I, strings → S, numbers → N), letting the ranker price
//! repeated use shapes below rarer explanatory shapes. `isGenerated` trusts
//! universal header markers first and filename conventions only when bytes are
//! unavailable. Every signal only reorders results; none can hide a match.

const std = @import("std");
const decode = @import("../regex/regex.zig").decode;
const unicode = @import("../regex/regex.zig").unicode;

fn wordLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (bytes[0] < 0x80)
        return @intFromBool(std.ascii.isAlphanumeric(bytes[0]) or bytes[0] == '_');
    const scalar = decode.decode(bytes) orelse return 0;
    return if (unicode.isWord(scalar.cp)) scalar.len else 0;
}

fn isWordBefore(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes[bytes.len - 1] < 0x80)
        return std.ascii.isAlphanumeric(bytes[bytes.len - 1]) or bytes[bytes.len - 1] == '_';
    const scalar = decode.decodeLast(bytes) orelse return false;
    return unicode.isWord(scalar.cp);
}

fn isWordAfter(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes[0] < 0x80)
        return std.ascii.isAlphanumeric(bytes[0]) or bytes[0] == '_';
    const scalar = decode.decode(bytes) orelse return false;
    return unicode.isWord(scalar.cp);
}

fn wordEnd(bytes: []const u8, start: usize) usize {
    var end = start;
    while (end < bytes.len) {
        const len = wordLen(bytes[end..]);
        if (len == 0) break;
        end += len;
    }
    return end;
}

fn isComment(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "/*") or std.mem.startsWith(u8, t, "*") or
        std.mem.startsWith(u8, t, "<!--");
}

fn nextWhole(hay: []const u8, needle: []const u8, from: usize) ?usize {
    var i = from;
    const left_word = isWordAfter(needle);
    const right_word = isWordBefore(needle);
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| : (i = pos + 1) {
        const end = pos + needle.len;
        if ((!left_word or !isWordBefore(hay[0..pos])) and
            (!right_word or !isWordAfter(hay[end..]))) return pos;
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
        if (wordLen(prefix[i..]) > 0) {
            g.identifiers +|= 1;
            i = wordEnd(prefix, i);
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
        } else if (depth == 0 and (c == '{' or bodyOperatorAt(s, i) or (c == ':' and
            (i + 1 >= s.len or s[i + 1] != ':') and (i == 0 or s[i - 1] != ':'))))
        {
            return true;
        }
    }
    return false;
}

/// A bracketed type-parameter list on a declaration head, where the other
/// syntax families write `<T>`: PEP 695 `def f[T](…)` and `class C[T]:`. An
/// indexed call — `handlers[name](req)` — closes its parens and carries no
/// body, so it stays a use.
fn genericHead(rest: []const u8) bool {
    const tail = afterBrackets(rest) orelse return false;
    return bodyAfterCall(tail) or openCall(tail);
}

/// A parameter list that opens here and never closes on this line — the shape
/// of a signature head whose parameters continue onto the lines below.
fn openCall(s: []const u8) bool {
    if (s.len == 0 or s[0] != '(') return false;
    var depth: usize = 0;
    for (s) |c| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        else => {},
    };
    return depth > 0;
}

/// What follows a leading balanced `[…]` group, or null when it never closes.
fn afterBrackets(s: []const u8) ?[]const u8 {
    var depth: usize = 0;
    for (s, 0..) |c, i| switch (c) {
        '[' => depth += 1,
        ']' => {
            depth -= 1;
            if (depth == 0) return std.mem.trimStart(u8, s[i + 1 ..], " \t");
        },
        else => {},
    };
    return null;
}

fn singleIdentifier(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r;");
    return t.len > 0 and wordEnd(t, 0) == t.len;
}

fn hasBodyTail(s: []const u8) bool {
    const brace = std.mem.indexOfScalar(u8, s, '{') orelse return false;
    const lead = s[0..brace];
    for ([_]u8{ '=', ',', ';', '"', '\'', '`' }) |c|
        if (std.mem.indexOfScalar(u8, lead, c) != null) return false;
    return true;
}

fn bodyOperatorAt(s: []const u8, i: usize) bool {
    if (i + 1 >= s.len) return false;
    return (s[i] == '=' and s[i + 1] == '>') or
        (s[i] == '-' and s[i + 1] == '>') or
        (s[i] == ':' and (s[i + 1] == '-' or s[i + 1] == '='));
}

fn topLevelAssignment(s: []const u8) bool {
    var round: i16 = 0;
    var square: i16 = 0;
    var curly: i16 = 0;
    var quote: ?u8 = null;
    for (s, 0..) |c, i| {
        if (quote) |q| {
            if (c == q and (i == 0 or s[i - 1] != '\\')) quote = null;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            continue;
        }
        switch (c) {
            '(' => round += 1,
            ')' => round -= 1,
            '[' => square += 1,
            ']' => square -= 1,
            '{' => curly += 1,
            '}' => curly -= 1,
            '=' => if (round == 0 and square == 0 and curly == 0 and
                (i == 0 or (s[i - 1] != '=' and s[i - 1] != '!' and s[i - 1] != '<' and s[i - 1] != '>')) and
                (i + 1 == s.len or (s[i + 1] != '=' and s[i + 1] != '>'))) return true,
            else => {},
        }
    }
    return false;
}

fn prefixForm(g: Geometry, before: []const u8, rest: []const u8) u8 {
    if (g.disqualifying or g.identifiers != 1 or g.brackets != 0 or g.braces != 0 or
        g.parens < 1 or g.parens > 2) return 0;
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, before, " \t"), "(")) return 0;
    const prior = nonSpaceBefore(before) orelse return 0;
    if (rest.len == 0) return 0;
    if (g.parens == 2 and prior == '(') return 2;
    return if (rest[0] == '(' or rest[0] == '[' or rest[0] == '{') 2 else 1;
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
        const rest = std.mem.trimStart(u8, t[pos + needle.len ..], " \t");
        if (rest.len == 0) continue;
        // A dotted continuation names a member of the needle, not the needle:
        // `React.KeyboardEvent` uses React, it never declares it.
        if (rest[0] == '.') continue;
        const prefix_form = prefixForm(g, before, rest);
        if (prefix_form > 0) {
            best = @max(best, prefix_form);
            continue;
        }
        if (g.disqualifying or g.parens != 0 or g.brackets != 0 or g.braces != 0) continue;
        if (nonSpaceBefore(before)) |c| {
            if (c == ':' and std.mem.eql(u8, std.mem.trim(u8, before, " \t"), ":")) {
                if (std.mem.endsWith(u8, std.mem.trim(u8, rest, " \t\r"), ";")) best = @max(best, 3);
                continue;
            }
            if (c == '.' or c == ':' or c == '<' or c == '>' or c == '@') continue;
            // A return type sits between the parameter list and the body, so
            // `) usize {` names a type the signature uses. Go's balanced
            // receiver keeps its `) Charge(` shape — that rest opens a list.
            if (c == ')' and rest[0] == '{') continue;
        }

        if (rest[0] == '=') {
            const confidence: u8 = if (g.identifiers > 0) 3 else 1;
            best = @max(best, confidence);
        } else if (rest[0] == '{' or hasBodyTail(rest)) {
            best = @max(best, 3);
        } else if (rest[0] == ':') {
            if (rest.len > 1 and rest[1] == ':') continue;
            const annotation = std.mem.trim(u8, rest[1..], " \t\r;");
            const confidence: u8 = if (annotation.len == 0) 3 else if (std.mem.indexOfScalar(u8, annotation, '=') != null) 2 else 1;
            best = @max(best, confidence);
        } else if (rest[0] == '(' or rest[0] == '<') {
            if (bodyAfterCall(rest)) best = @max(best, 3);
        } else if (g.identifiers > 0 and rest[0] == '[' and genericHead(rest)) {
            best = @max(best, 3);
        } else if (topLevelAssignment(rest)) {
            best = @max(best, 3);
        } else if (singleIdentifier(rest)) {
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
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) i += 1;
        } else if (wordLen(line[i..]) > 0) {
            const end = wordEnd(line, i);
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

/// Compact filename grammar for conventional generated names. Most formats
/// collapse to a handful of separators (`.gen.`, `_pb2.`, `.min.`); only
/// conventions without a stable generator token need an exact suffix.
const gen_fragments = [_][]const u8{
    ".generated.",    ".gen.", "_gen.", "_generated.", ".min.",
    ".pb.",           "_pb.",  "_pb2.", "_pb2_",       "_connect.",
    "_connectquery.",
};
const gen_exact_suffixes = [_][]const u8{
    ".sql.go", ".g.dart", ".freezed.dart", ".g.cs", ".designer.cs",
};
/// Header markers — the universal generated signal, language-independent and
/// more reliable than filename inference. Only the first eight lines count.
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
    const name = std.fs.path.basename(path);
    for (gen_fragments) |fragment| if (std.mem.indexOf(u8, name, fragment) != null) return true;
    for (gen_exact_suffixes) |suffix| if (std.mem.endsWith(u8, name, suffix)) return true;
    return false;
}

/// Is this a codegen artifact? A conventional generated name, or a generated
/// marker in the header. Liberal by design: a false demote only reorders.
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
