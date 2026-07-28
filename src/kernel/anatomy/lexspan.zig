//! Comment/code/string span lexing — the one parser-free lexer both the region
//! extractor and the comment-scoped matcher ride.
//!
//! `regions.zig` walks source with a small lexical state machine so a `{` or a
//! `def` inside a string or comment never opens a false function; the blast
//! radius and `gist --in-comments`/`--in-code` need the INVERSE of the same
//! knowledge — which bytes ARE comments. Rather than fork two drifting copies
//! of the string/comment rules, the state machine lives here once:
//!
//!   • `lexByte` — advance the lexical state one byte; `true` iff the byte is
//!     code punctuation (a `{`/`}` the brace walk should count). Consumed by
//!     `regions.zig`'s function extraction.
//!   • `commentMask` — a per-byte boolean map, `true` where a byte falls inside
//!     a line (`//`, `#`) or block (`/* … */`) comment, string literals skipped.
//!     Consumed by the comment-scoped matcher and the blast comments section.
//!   • `commentOnly` — whether a trimmed line STARTS as a comment (the cheap
//!     line-granularity test `regions.select` uses to skip comment-only lines).
//!
//! Language is inferred from byte shape, never a language table — the same
//! covenant the silhouette scanner keeps: `#`/`//` open a line comment, `/* */`
//! a block, and `'`/`"`/`` ` `` a string. A heuristic by design (a `#` inside
//! a C `#include` reads as a comment here, as it does corpus-wide), it only ever
//! reorders/filters — it can never hide a real match from the exact engine.

const std = @import("std");

/// The lexer's state: plain code, one of three string bodies, or a line/block
/// comment. `regions.zig` and `commentMask` share this exact vocabulary so a
/// brace walk and a comment map can never disagree on where a string ends.
pub const Lex = enum { code, single, double, backtick, line_comment, block_comment };

/// Advance lexical state across byte `i`; returns `true` when byte `i` is code
/// punctuation (not inside a string or comment) — the signal `regions.zig`'s
/// brace/def walk gates its `{`/`}` bookkeeping on. May advance `i` past the
/// second byte of a two-byte token (`//`, `/*`, `*/`). `escaped` carries the
/// in-string backslash state across calls.
pub fn lexByte(bytes: []const u8, i: *usize, state: *Lex, escaped: *bool) bool {
    const c = bytes[i.*];
    switch (state.*) {
        .code => {
            if (c == '/' and i.* + 1 < bytes.len and bytes[i.* + 1] == '/') {
                state.* = .line_comment;
                i.* += 1;
            } else if (c == '/' and i.* + 1 < bytes.len and bytes[i.* + 1] == '*') {
                state.* = .block_comment;
                i.* += 1;
            } else if (c == '#') {
                state.* = .line_comment;
            } else if (c == '\'') {
                state.* = .single;
            } else if (c == '"') {
                state.* = .double;
            } else if (c == '`') {
                state.* = .backtick;
            } else return true;
        },
        .single, .double, .backtick => {
            if (escaped.*) {
                escaped.* = false;
            } else if (c == '\\') {
                escaped.* = true;
            } else if ((state.* == .single and c == '\'') or (state.* == .double and c == '"') or
                (state.* == .backtick and c == '`')) state.* = .code;
        },
        .line_comment => if (c == '\n') {
            state.* = .code;
        },
        .block_comment => if (c == '*' and i.* + 1 < bytes.len and bytes[i.* + 1] == '/') {
            state.* = .code;
            i.* += 1;
        },
    }
    return false;
}

/// Does a line, once leading whitespace is trimmed, BEGIN as a comment? The
/// cheap line-granularity predicate `regions.select` uses to skip a
/// comment-only line before it runs the exact matcher (a mid-line `// …` tail
/// is still real code, so this is deliberately start-anchored).
pub fn commentOnly(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#") or
        std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*") or
        std.mem.startsWith(u8, trimmed, "\\\\");
}

/// A per-byte comment map: `out[i]` is `true` iff `bytes[i]` falls inside a
/// line (`//`, `#`) or block (`/* … */`) comment. String literals are skipped
/// so a `//` or `#` inside a string never reads as a comment. Caller owns the
/// returned slice (`bytes.len` long). This is the exact inverse of the
/// string/comment DROP the silhouette scanner performs, so a comment-scoped
/// match and a structure sketch agree on what "comment" means byte-for-byte.
pub fn commentMask(gpa: std.mem.Allocator, bytes: []const u8) ![]bool {
    const out = try gpa.alloc(bool, bytes.len);
    @memset(out, false);
    const n = bytes.len;
    var i: usize = 0;
    while (i < n) {
        const c = bytes[i];
        if (c == '"' or c == '\'' or c == '`') { // string literal — never a comment
            const q = c;
            i += 1;
            while (i < n and bytes[i] != q) i += if (bytes[i] == '\\') @as(usize, 2) else 1;
            i = @min(i + 1, n);
        } else if ((c == '/' and i + 1 < n and bytes[i + 1] == '/') or c == '#') { // line comment
            const end = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse n;
            @memset(out[i..end], true);
            i = end;
        } else if (c == '/' and i + 1 < n and bytes[i + 1] == '*') { // block comment
            const rel = std.mem.indexOfPos(u8, bytes, i + 2, "*/");
            const end = if (rel) |e| e + 2 else n;
            @memset(out[i..end], true);
            i = end;
        } else i += 1;
    }
    return out;
}

test "commentMask marks line and block comments, skips strings" {
    const gpa = std.testing.allocator;
    const src =
        "let x = 1; // tail comment\n" ++
        "const s = \"// not a comment\";\n" ++
        "/* block\n   spanning */ code\n" ++
        "# python line\n";
    const mask = try commentMask(gpa, src);
    defer gpa.free(mask);

    // The `// tail comment` bytes are comment; the code before them is not.
    const tail = std.mem.indexOf(u8, src, "// tail").?;
    try std.testing.expect(mask[tail]);
    try std.testing.expect(!mask[0]); // `let`

    // The `//` INSIDE the string literal is code, not a comment.
    const in_str = std.mem.indexOf(u8, src, "// not").?;
    try std.testing.expect(!mask[in_str]);

    // Block comment interior (including across the newline) is comment; the
    // `code` after `*/` is not.
    const blk = std.mem.indexOf(u8, src, "block").?;
    try std.testing.expect(mask[blk]);
    const after = std.mem.indexOf(u8, src, "code").?;
    try std.testing.expect(!mask[after]);

    // Python `#` opens a line comment.
    const py = std.mem.indexOf(u8, src, "python").?;
    try std.testing.expect(mask[py]);
}

test "commentOnly is start-anchored" {
    try std.testing.expect(commentOnly("   // leading"));
    try std.testing.expect(commentOnly("# hash"));
    try std.testing.expect(commentOnly("* doc continuation"));
    try std.testing.expect(!commentOnly("code(); // trailing"));
    try std.testing.expect(!commentOnly("value = 3"));
}
