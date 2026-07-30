//! The gitignore/rg-shaped **glob matcher** — pure pattern-vs-string math,
//! no filesystem and no corpus. Glob dialect: a pattern with no `/` matches
//! the **basename** at any depth (`*.go`), one with a `/` matches the **full
//! path**; `*` spans a single path segment, `**` spans `/` boundaries, `?` is
//! one non-`/` byte, and `[...]` is a (negatable, range-aware) character
//! class. The corpus-side constraint set built on this matcher is
//! `corpus/scope/filter.zig`.

const std = @import("std");

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

/// Does `g` open a `[` character class that is never closed by `]`? ripgrep
/// compiles an explicit `-g`/`--glob` pattern strictly and errors on exactly
/// this ("unclosed character class; missing ']'"), whereas an unclosed `[` in a
/// lenient `.gitignore` line is treated as a literal `[` (see `matchClass`).
/// Reuses that same terminator scan (probing with an arbitrary byte, since only
/// the class LENGTH matters here, not the match verdict) so the strict
/// arg-parse validation can never drift from the matcher's own class parsing.
pub fn unterminatedClass(g: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, g, i, '[')) |lb| {
        if (matchClass(g[lb..], 0)) |hit| i = lb + hit.len else return true;
    }
    return false;
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
                    // `**` spans '/'. When it is a *segment token* `**/` — bounded
                    // by the pattern start or a '/' on the left and a '/' on the
                    // right — the continuation must resume only at a path-segment
                    // boundary, because rg/gitignore match whole segments: `**/_pb2*`
                    // excludes a basename that STARTS with `_pb2`, never one that
                    // merely contains it (so `outreach_pb2.pyi` stays in, matching
                    // rg). A `**` that is not a clean segment token keeps the looser
                    // "match at any offset" behavior.
                    const left_edge = pi == 0 or pat[pi - 1] == '/';
                    var rest = pi + 2; // absorb a trailing '/' so `**/` may match zero dirs
                    const seg = left_edge and rest < pat.len and pat[rest] == '/';
                    if (rest < pat.len and pat[rest] == '/') rest += 1;
                    var k = si;
                    while (true) : (k += 1) {
                        const at_boundary = k == si or str[k - 1] == '/';
                        if ((!seg or at_boundary) and globMatch(pat[rest..], str[k..])) return true;
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
/// A trailing `/` makes it a *directory* glob (gitignore semantics): `asdf/`
/// matches the dir `asdf` and everything beneath it, at any depth.
pub fn globApplies(pat: []const u8, path: []const u8) bool {
    if (pat.len > 1 and pat[pat.len - 1] == '/') {
        const core = pat[0 .. pat.len - 1];
        // Match if any ancestor directory of `path` matches the core glob.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            if (globApplies(core, path[0..slash])) return true;
        }
        return false;
    }
    return if (std.mem.indexOfScalar(u8, pat, '/') == null)
        globMatch(pat, basename(path))
    else
        globMatch(pat, path);
}
