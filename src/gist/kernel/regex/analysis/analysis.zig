//! gist — regex *static analysis*: sound, read-only visitors that feed the
//! scanner's accelerators. Every one is conservative (a wrong "don't know" only
//! costs a full scan, never a missed match). Two layers:
//!   • AST visitors over `syntax.zig` — required-literal extraction for the T0
//!     trigram prefilter (the literal half of Cox's regexp→trigram analysis) and
//!     the anchored-start predicate that lets the scanner seed only at line
//!     position 0.
//!   • compiled-NFA visitors over the `State` program — the first-byte set
//!     (`analyzeFirst`, feeding `prefilter.zig`) and the zero-width end-of-line
//!     reachability (`reachesMatchEol`).
//! Split out from the parser so `syntax.zig` is pure syntax (types + recursive
//! descent), `compile.zig` is pure lowering, and this is the analysis on its own.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const Node = syn.Node;
const State = syn.State;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

/// The literal facts provable about an AST node, feeding the trigram prefilter
/// and the pure-literal fast path. All fields are conservative under-claims.
pub const LitInfo = struct {
    exact: ?[]const u8, // node matches EXACTLY this literal and nothing else
    prefix: []const u8, // every match must START with this literal run
    suffix: []const u8, // every match must END with this literal run
    best: []const u8, // longest literal that MUST appear (contiguously) in every match
};

fn longer(a: []const u8, b: []const u8) []const u8 {
    return if (a.len >= b.len) a else b;
}

/// The UTF-8 bytes of a single-codepoint `uclass` (a non-ASCII literal), or null
/// for a wider codepoint class — so a `uclass` literal feeds the same prefilter /
/// pure-literal machinery as an ASCII `class` singleton.
fn uclassLiteral(arena: std.mem.Allocator, ranges: []const [2]u21) ParseError!?[]const u8 {
    if (ranges.len != 1 or ranges[0][0] != ranges[0][1]) return null;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ranges[0][0], &buf) catch return null;
    return try arena.dupe(u8, buf[0..n]);
}

/// Compute a literal that must appear in every match (`best`). Sound: if it
/// can't prove one, `best` is "" (caller scans all docs). Mirrors the literal
/// half of Cox's regexp→trigram analysis, conservatively.
pub fn literalInfo(arena: std.mem.Allocator, node: *Node) ParseError!LitInfo {
    switch (node.*) {
        // Zero-width: matches the empty string at a position. exact="" lets a
        // mandatory literal run span the anchor (e.g. `^func` ⇒ required "func",
        // `\bfunc\b` ⇒ "func" — the word boundaries are zero-width too).
        .empty, .anchor_start, .anchor_end, .anchor_buf_start, .anchor_buf_end, .word_boundary, .not_word_boundary, .word_start, .word_end => return .{ .exact = "", .prefix = "", .suffix = "", .best = "" },
        .class => |set| {
            // A singleton class is an exact literal; anything wider proves nothing.
            if (set.only()) |b| {
                const lit = try arena.dupe(u8, &[_]u8{b});
                return .{ .exact = lit, .prefix = lit, .suffix = lit, .best = lit };
            }
            return .{ .exact = null, .prefix = "", .suffix = "", .best = "" };
        },
        // A single-codepoint `uclass` (a non-ASCII literal) is exact — its UTF-8
        // bytes feed the trigram prefilter exactly like an ASCII literal. A wider
        // codepoint class (`\w`, `[é-ÿ]`) proves no literal.
        .uclass => |ranges| {
            if (try uclassLiteral(arena, ranges)) |l|
                return .{ .exact = l, .prefix = l, .suffix = l, .best = l };
            return .{ .exact = null, .prefix = "", .suffix = "", .best = "" };
        },
        .concat => |ab| {
            const x = try literalInfo(arena, ab[0]);
            const y = try literalInfo(arena, ab[1]);
            // Both sides exact ⇒ the concat is itself exact.
            var exact: ?[]const u8 = null;
            if (x.exact) |xe| if (y.exact) |ye| {
                exact = try std.mem.concat(arena, u8, &.{ xe, ye });
            };
            // A mandatory prefix run extends through x into y only when x is fully
            // exact; symmetrically the suffix extends back through y into x. The
            // boundary run — x's mandatory suffix immediately followed by y's
            // mandatory prefix — is itself mandatory AND contiguous. That span is
            // what recovers the trailing literal a non-exact prefix would
            // otherwise hide (`a*function` ⇒ "function", not "f").
            const prefix = if (x.exact) |xe| try std.mem.concat(arena, u8, &.{ xe, y.prefix }) else x.prefix;
            const suffix = if (y.exact) |ye| try std.mem.concat(arena, u8, &.{ x.suffix, ye }) else y.suffix;
            const span = try std.mem.concat(arena, u8, &.{ x.suffix, y.prefix });
            var best = longer(longer(x.best, y.best), span);
            if (exact) |e| best = longer(best, e);
            return .{ .exact = exact, .prefix = prefix, .suffix = suffix, .best = best };
        },
        .plus => |r| {
            // Content occurs ≥ once, so its prefix/suffix/best are mandatory; but
            // the minimum is a single iteration, so there is no cross-iteration
            // run and the whole is not exact.
            const xi = try literalInfo(arena, r.node);
            return .{ .exact = null, .prefix = xi.prefix, .suffix = xi.suffix, .best = xi.best };
        },
        // A capture is transparent — its literal info is exactly its child's.
        .capture => |g| return literalInfo(arena, g.child),
        // Optional / alternation: nothing is guaranteed to appear.
        .star, .quest, .alt => return .{ .exact = null, .prefix = "", .suffix = "", .best = "" },
    }
}

/// True iff every match must begin at the start of a line — the pattern's first
/// consumable step is preceded by `^` on every alternation branch. Lets the
/// scanner seed only at line position 0 (no per-byte unanchored re-seed) and bail
/// the instant the thread list empties. Conservative: only the `^` node anchors,
/// so an un-anchored branch makes the whole alternation un-anchored.
pub fn startsAnchored(node: *Node) bool {
    return switch (node.*) {
        .anchor_start => true,
        .concat => |ab| startsAnchored(ab[0]),
        .alt => |ab| startsAnchored(ab[0]) and startsAnchored(ab[1]),
        .plus => |r| startsAnchored(r.node), // `(^x)+` still starts anchored
        .capture => |g| startsAnchored(g.child), // transparent
        else => false,
    };
}

/// Cap on an alternation cover-set — a huge `a|b|c|…` union would issue one
/// trigram query per branch; past this a full scan is cheaper, so we bail to it.
const max_cover: usize = 32;

/// A set of ≥3-byte literals such that EVERY match contains at least one of them
/// — so the UNION of their trigram-candidate sets is a sound superset (no false
/// negative). Returns null when none is provable (caller full-scans). This is the
/// multi-literal counterpart to `literalInfo.best`: where `best` needs ONE literal
/// mandatory across the whole pattern, this admits alternations — `foo|bar` ⇒
/// {foo, bar} — but only when EVERY branch yields a ≥3 literal (else that branch's
/// matches could carry none of the set, and filtering would wrongly drop them).
pub fn requiredAny(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    // A single mandatory ≥3 literal is the most selective filter — prefer it.
    const li = try literalInfo(arena, node);
    if (li.best.len >= 3) return try arena.dupe([]const u8, &.{li.best});
    switch (node.*) {
        .alt => |ab| {
            const sa = try requiredAny(arena, ab[0]) orelse return null;
            const sb = try requiredAny(arena, ab[1]) orelse return null;
            if (sa.len + sb.len > max_cover) return null;
            return try std.mem.concat(arena, []const u8, &.{ sa, sb });
        },
        // In a concat both sides are mandatory, so either side's cover set is
        // sound for the whole match — take the first side that yields one.
        .concat => |ab| {
            if (try requiredAny(arena, ab[0])) |sa| return sa;
            return try requiredAny(arena, ab[1]);
        },
        .plus => |r| return try requiredAny(arena, r.node),
        .capture => |g| return try requiredAny(arena, g.child), // transparent
        // multi-byte class, star, quest (match empty), empty, anchors ⇒ no cover.
        else => return null,
    }
}

/// Cap on a pure-literal alternation set — each literal costs one SIMD
/// `contains` pass over the whole body, so past a handful the DFA scan wins.
const max_lits: usize = 8;

/// The EXACT literal this node matches — and nothing else — or null. Stricter
/// than `LitInfo.exact`: zero-width nodes (anchors, `\b`, `.empty`) are REJECTED
/// rather than treated as "", because the caller uses these literals as a
/// match-equivalence (not just containment): `pattern matches line` ⟺ `line
/// contains one of the literals`. An anchor would break that equivalence
/// (`^panic` contains-hits mid-line), so purity must exclude all assertions.
fn pureLit(arena: std.mem.Allocator, node: *Node) ParseError!?[]const u8 {
    switch (node.*) {
        .class => |set| {
            const b = set.only() orelse return null;
            return try arena.dupe(u8, &[_]u8{b});
        },
        .uclass => |ranges| return uclassLiteral(arena, ranges),
        .concat => |ab| {
            const x = (try pureLit(arena, ab[0])) orelse return null;
            const y = (try pureLit(arena, ab[1])) orelse return null;
            return try std.mem.concat(arena, u8, &.{ x, y });
        },
        .capture => |g| return pureLit(arena, g.child), // transparent
        else => return null,
    }
}

/// If the whole pattern is EXACTLY an alternation of pure literals (`panic|0x`,
/// `foo`, `a|b|c`), return them; else null. This is a match-EQUIVALENCE, not a
/// mere containment gate: a line matches ⟺ it contains one of the literals —
/// which lets `-l` answer a whole file with one SIMD `contains` per literal and
/// no regex engine run. Literals carrying `\n` (can't sit inside one line) or
/// NUL (binary semantics) are rejected; so is an empty literal (matches
/// everywhere — the `eol_empty` machinery owns that case).
pub fn pureLiterals(arena: std.mem.Allocator, node: *Node) ParseError!?[]const []const u8 {
    switch (node.*) {
        .alt => |ab| {
            const sa = (try pureLiterals(arena, ab[0])) orelse return null;
            const sb = (try pureLiterals(arena, ab[1])) orelse return null;
            if (sa.len + sb.len > max_lits) return null;
            return try std.mem.concat(arena, []const u8, &.{ sa, sb });
        },
        .capture => |g| return pureLiterals(arena, g.child), // transparent
        else => {
            const lit = (try pureLit(arena, node)) orelse return null;
            if (lit.len == 0) return null;
            if (std.mem.indexOfAny(u8, lit, "\n\x00") != null) return null;
            return try arena.dupe([]const u8, &.{lit});
        },
    }
}

/// Iterative DFS over NFA-state indices, each enqueued at most once. Bounds
/// stack depth under `{n}`-expanded programs (where recursion would blow up).
const Worklist = struct {
    visited: []bool,
    stack: []u32,
    sp: usize,

    fn init(gpa: std.mem.Allocator, n: usize, start: u32) ParseError!Worklist {
        const visited = try gpa.alloc(bool, n);
        @memset(visited, false);
        const stack = try gpa.alloc(u32, n);
        visited[start] = true;
        stack[0] = start;
        return .{ .visited = visited, .stack = stack, .sp = 1 };
    }
    fn deinit(self: *Worklist, gpa: std.mem.Allocator) void {
        gpa.free(self.visited);
        gpa.free(self.stack);
    }
    fn pop(self: *Worklist) ?u32 {
        if (self.sp == 0) return null;
        self.sp -= 1;
        return self.stack[self.sp];
    }
    fn push(self: *Worklist, t: u32) void {
        if (self.visited[t]) return;
        self.visited[t] = true;
        self.stack[self.sp] = t;
        self.sp += 1;
    }
};

/// Collect every byte that can be the FIRST consumed byte of a match at SOME
/// position — a sound superset that lets the scanner skip spans containing
/// none of them. `^` (assert_start) is *traversed*, not blocked: it holds at
/// line starts where the scanner seeds (with the right `at_start` flag), so a
/// `^p…` branch's `p` must be reachable — at a mid-line `p` the seeded thread
/// just dies on the failed assertion, never a false positive. `$` (assert_end)
/// is blocked: no byte is consumed after the line ends.
pub fn analyzeFirst(gpa: std.mem.Allocator, states: []const State, start: u32, out: *ByteSet) ParseError!void {
    var wl = try Worklist.init(gpa, states.len, start);
    defer wl.deinit(gpa);
    while (wl.pop()) |s| switch (states[s]) {
        .consume => |cn| out.unionWith(cn.set),
        .split => |spl| {
            wl.push(spl.a);
            wl.push(spl.b);
        },
        .assert_start => |o| wl.push(o), // holds at line start
        .assert_buf_start => |o| wl.push(o), // holds at buffer start (same soundness)
        // A word-context assertion (`\b` `\B` `\<` `\>`) can hold at SOME
        // position, so the byte it gates is reachable as a first byte — traverse
        // it (sound superset; a seeded thread at a position where the boundary
        // fails just dies, never a false positive).
        .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end => |o| wl.push(o),
        .assert_end, .assert_buf_end, .match => {}, // `$`/`\z`: no byte follows; match: zero-width
    };
}

/// Does the start epsilon-reach `match` at end-of-line (`at_start=false`,
/// `at_end=true`)? True only for a nullable prefix flowing into `$`/`match`
/// without consuming a byte (`\d*$`, `a*`, `x|$`) — matches the zero-width end
/// of every line. `^`-anchored programs return false (`assert_start` blocked
/// at non-start).
pub fn reachesMatchEol(gpa: std.mem.Allocator, states: []const State, start: u32) ParseError!bool {
    var wl = try Worklist.init(gpa, states.len, start);
    defer wl.deinit(gpa);
    while (wl.pop()) |s| switch (states[s]) {
        .match => return true,
        .split => |spl| {
            wl.push(spl.a);
            wl.push(spl.b);
        },
        .assert_end => |o| wl.push(o), // `$` holds at EOL
        .assert_start, .consume => {}, // at_start=false blocks `^`; consume isn't zero-width
        // A word-context assertion (`\b` `\B` `\<` `\>`) at EOL is
        // content-dependent (the last byte's word-ness), so we can't statically
        // prove a zero-width EOL match — don't traverse. Same for the buffer
        // anchors: an arbitrary line's EOL is not provably the buffer edge.
        // Conservative: only ever suppresses the `eol_empty` shortcut, never a match.
        .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end, .assert_buf_start, .assert_buf_end => {},
    };
    return false;
}

/// Can the start reach `match` through only zero-width edges — ε/`split` plus ANY
/// assertion (`^` `$` `\b` `\B`)? True ⇒ the pattern can match the *empty string*
/// at some position, with the exact positions decided at run time by the
/// content-dependent assertions (`\bcat` is not nullable — `c` is mandatory — but
/// `\b{2,}$`, `\B{2}`, `x|\b$` are).
///
/// Why the scanner needs this: the first-byte `.skip` search seeds a start only at
/// line position 0 and immediately *before* a byte in the first-set; it NEVER
/// seeds at a bare boundary gap or at end-of-line. That is sound for a match that
/// must consume a first byte, but a nullable branch can match with no consumed
/// byte at a position the skip never visits (the `\b{4,6}$` / `\B{2}` fuzz
/// divergences). `reachesMatchEol` can't catch these — it deliberately won't cross
/// a word boundary — so this broader predicate routes nullable patterns to the
/// `.plain` search (which seeds every position, EOL included). Conservative: a
/// false "yes" only forgoes the skip optimization, never a match.
pub fn reachesMatchZeroWidth(gpa: std.mem.Allocator, states: []const State, start: u32) ParseError!bool {
    var wl = try Worklist.init(gpa, states.len, start);
    defer wl.deinit(gpa);
    while (wl.pop()) |s| switch (states[s]) {
        .match => return true,
        .split => |spl| {
            wl.push(spl.a);
            wl.push(spl.b);
        },
        .assert_start, .assert_end, .assert_buf_start, .assert_buf_end, .assert_word_b, .assert_not_word_b, .assert_word_start, .assert_word_end => |o| wl.push(o),
        .consume => {}, // consumes a byte ⇒ this path is not zero-width
    };
    return false;
}
