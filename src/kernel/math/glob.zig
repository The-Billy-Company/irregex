//! The gitignore/rg-shaped **glob matcher** — pure pattern-vs-string math,
//! no filesystem and no corpus. Glob dialect: a pattern with no `/` matches
//! the **basename** at any depth (`*.go`), one with a `/` matches the **full
//! path**; `*` spans a single path segment, `**` spans `/` boundaries, `?` is
//! one non-`/` byte, and `[...]` is a (negatable, range-aware) character
//! class. The corpus-side constraint set built on this matcher is
//! `corpus/scope/filter.zig`.
//!
//! Brace alternation (`*.{js,ts}`) lives here too, at the bottom of the file,
//! even though the matcher never sees a `{`: a group is not a matching rule but
//! a REWRITE of one glob into several, and it has to happen before anything
//! matches. It sat in the argv value grammar until it was needed by a second
//! caller, which is one caller too late — see `braceExpand`.

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

// ── brace alternation: one glob becomes N, before any matching happens ───────

/// The default ceiling on one glob's expansion, in concrete patterns.
///
/// `{a,b}{c,d}{e,f}…` MULTIPLIES, so a sixty-byte pattern names millions of
/// globs and a host that accepted one from a stranger accepted an OOM. A
/// thousand is three orders of magnitude past anything a person writes
/// (`*.{js,jsx,ts,tsx,mjs,cjs}` is six), which is what makes it a hostility
/// ceiling rather than a limit somebody meets by accident.
pub const brace_cap: usize = 1024;

/// How many nested or sequential groups one glob may carry.
///
/// A second ceiling because there is a second way to be hostile and the first
/// cannot see it: `{a}{a}{a}…` has a product of ONE and recurses once per
/// group, so a long enough pattern exhausts the stack while expanding to a
/// single term. Sixty-four is already past absurd — `{a,b}` sixty-four times
/// names 2^64 patterns, which `brace_cap` refuses long before this fires — and
/// it keeps the recursion's depth a property of this module instead of of
/// whatever stack the host happened to call in on.
pub const brace_group_cap: usize = 64;

/// Expansion finished, or a ceiling stopped it. `BudgetExceeded` is the
/// taxonomy's name for the CALLER's own limit being reached rather than the
/// machine's, and it is a fault rather than a declinature because there is no
/// slower tier for someone who asked to be stopped: the remedy is a bigger
/// ceiling, which only the caller can grant.
pub const BraceError = error{ OutOfMemory, BudgetExceeded };

/// The first balanced `{…}` group in `pat` as `[open, close]` byte indices, or
/// null when there is none — no `{` at all, or one that is never closed.
///
/// One scan, read by both the expander and the well-formedness probe below, so
/// the group an expansion splits and the group a caller calls well-formed
/// cannot come apart.
fn firstGroup(pat: []const u8) ?[2]usize {
    const open = std.mem.indexOfScalar(u8, pat, '{') orelse return null;
    var depth: usize = 0;
    for (open..pat.len) |i| {
        if (pat[i] == '{') depth += 1 else if (pat[i] == '}') {
            depth -= 1;
            if (depth == 0) return .{ open, i };
        }
    }
    return null;
}

/// Does `g` open a `{` alternation that is never closed by `}`?
///
/// The brace twin of `unterminatedClass`, and it exists for the same reason: an
/// explicit `-g` compiles strictly, so `*.{c,h` is an error rather than the
/// literal braces a lenient `.gitignore` line reads it as. `braceExpand`
/// deliberately emits an unbalanced pattern verbatim — that lenient reading is
/// what the command line has always done — so a caller that must REFUSE one
/// asks here first rather than trying to infer it from an expansion that looks
/// like it worked.
pub fn unterminatedBrace(g: []const u8) bool {
    var i: usize = 0;
    while (i < g.len) {
        const grp = firstGroup(g[i..]) orelse
            return std.mem.indexOfScalarPos(u8, g, i, '{') != null;
        i += grp[1] + 1;
    }
    return false;
}

/// Expand glob `{a,b,c}` alternations into every concrete pattern (cartesian
/// product across groups, nesting-aware). A pattern with no brace group yields
/// itself; an unbalanced `{` is left literal.
///
/// `cap` bounds how many concrete patterns THIS call may append (`brace_cap` is
/// the package's own answer). Reaching it is `error.BudgetExceeded` and never a
/// shorter list: a truncated expansion answers about a smaller corpus than the
/// one asked about, and a glob is the least visible place in a search for that
/// to happen.
///
/// **Fallible rather than fatal, which is the whole reason it lives here.** It
/// used to sit in the argv value grammar and call the CLI's `oom()` at both of
/// its allocation sites, so a command line was the only thing that could call
/// it — a function that may end its host's process is not one a library path
/// may reach, and the corpus-eligibility seam therefore refused every brace
/// glob rather than expanding it. The decision to exit belongs to `main()`;
/// `intent.Builder.addGlob` still makes it, at the CLI seam.
pub fn braceExpand(
    a: std.mem.Allocator,
    pat: []const u8,
    out: *std.ArrayList([]const u8),
    cap: usize,
) BraceError!void {
    return expand(a, pat, out, out.items.len +| cap, 0);
}

fn expand(
    a: std.mem.Allocator,
    pat: []const u8,
    out: *std.ArrayList([]const u8),
    ceiling: usize,
    depth: usize,
) BraceError!void {
    // `depth` is groups already consumed, so the guard admits a glob carrying
    // exactly `brace_group_cap` of them and refuses the next one.
    if (depth > brace_group_cap) return error.BudgetExceeded;
    // No group (or an unbalanced `{`) ⇒ the pattern is emitted literally.
    const open, const c = firstGroup(pat) orelse {
        if (out.items.len >= ceiling) return error.BudgetExceeded;
        try out.append(a, try a.dupe(u8, pat));
        return;
    };
    const prefix = pat[0..open];
    const suffix = pat[c + 1 ..];
    const inner = pat[open + 1 .. c];
    var start: usize = 0;
    var d: usize = 0;
    var j: usize = 0;
    while (j <= inner.len) : (j += 1) {
        const at_end = j == inner.len;
        if (!at_end and inner[j] == '{') d += 1 else if (!at_end and inner[j] == '}') d -= 1;
        if (at_end or (inner[j] == ',' and d == 0)) {
            const combined = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, inner[start..j], suffix });
            try expand(a, combined, out, ceiling, depth + 1); // recurse to expand any remaining groups
            start = j + 1;
        }
    }
}
