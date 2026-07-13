//! gist glob matching + path scoping — the `rg -g <glob>` / positional-`PATH`
//! affordance an agent reaches for to confine a search to a subtree. This is the
//! one place gist can be *faster* than rg rather than merely matching it: rg
//! applies a glob filter while walking the whole tree, but gist already holds the
//! full path list, so it prunes candidate ids *before* touching disk — a
//! `-g '*.go'` query reads only the Go files, not all 18k candidates.
//!
//! This module owns the gitignore/rg-shaped **glob matcher** and the resolved
//! `PathFilter` (the grep verb's AND-combined constraint set); the language
//! `-t <lang>` type table is the sibling `types.zig` (a pure data concern).
//! Glob dialect: a pattern with no `/` matches the **basename** at any depth
//! (`*.go`), one with a `/` matches the **full path**; `*` spans a single path
//! segment, `**` spans `/` boundaries, `?` is one non-`/` byte, and `[...]` is a
//! (negatable, range-aware) character class.

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

/// Normalize a positional path arg to the corpus's repo-root-relative shape:
/// strip a leading `./` and any trailing `/` so `./services/` and `services`
/// both scope to the same prefix. Returned slice aliases the input (no alloc).
pub fn normalizeRoot(arg: []const u8) []const u8 {
    var s = arg;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

/// Is `path` at, or under, the directory/file `root`? `.`/`""` is the whole
/// corpus (matches all). An exact-length equality is a file arg; otherwise the
/// root must be a *directory* prefix (`services` admits `services/x.go` but not
/// `services_old/x.go`, hence the mandatory `/` boundary).
fn underRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or (root.len == 1 and root[0] == '.')) return true;
    if (path.len == root.len) return std.mem.eql(u8, path, root);
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// A resolved set of path constraints. All slices are caller-owned (they alias
/// argv / a small arena built at parse time); `PathFilter` only borrows them.
pub const PathFilter = struct {
    exts: []const []const u8 = &.{}, // union of every `-t` type's globs (see scope/types.zig)
    includes: []const []const u8 = &.{}, // `-g <glob>` (OR); empty ⇒ no constraint
    excludes: []const []const u8 = &.{}, // `-g !<glob>` (any match vetoes the path)
    roots: []const []const u8 = &.{}, // positional PATH args (OR); empty ⇒ whole corpus

    pub fn isEmpty(self: PathFilter) bool {
        return self.exts.len == 0 and self.includes.len == 0 and
            self.excludes.len == 0 and self.roots.len == 0;
    }

    /// Does `path` survive the filter? An exclude veto wins; then the path must
    /// satisfy each *non-empty* constraint set (root ∧ type ∧ include), each
    /// OR-internal. Positional roots gate first — an agent's `grep pat dir/`.
    pub fn admits(self: PathFilter, path: []const u8) bool {
        for (self.excludes) |g| if (globApplies(g, path)) return false;
        if (self.roots.len > 0) {
            var ok = false;
            for (self.roots) |r| if (underRoot(path, r)) {
                ok = true;
                break;
            };
            if (!ok) return false;
        }
        if (self.exts.len > 0) {
            var ok = false;
            for (self.exts) |e| if (globApplies(e, path)) {
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
