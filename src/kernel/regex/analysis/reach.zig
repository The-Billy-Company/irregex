//! irregex — regex *reachability analysis*: conservative, read-only visitors over
//! the compiled Thompson-NFA `State` program (the execution half a pattern
//! lowers to in `../compile/compile.zig`). Each answers a zero-width
//! reachability question the scanner needs to seed and terminate correctly:
//! the first-byte set (`analyzeFirst`, feeding `prefilter.zig`), the
//! zero-width end-of-line reachability (`reachesMatchEol`), and the broader
//! nullable predicate (`reachesMatchZeroWidth`). Every one is conservative —
//! a wrong "don't know" only costs a full scan, never a missed match.
//!
//! Private sibling of `analysis.zig`, which owns the AST-side literal layer and
//! re-exports these three visitors as its public face; the class-run/span
//! reductions are the third layer in `runs.zig`.

const std = @import("std");
const syn = @import("../syntax/syntax.zig");
const State = syn.State;
const ByteSet = syn.ByteSet;
const ParseError = syn.ParseError;

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
    /// Enqueue both arms of a `split`.
    fn push2(self: *Worklist, a: u32, b: u32) void {
        self.push(a);
        self.push(b);
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
        .split => |spl| wl.push2(spl.a, spl.b),
        .assert_start => |o| wl.push(o), // holds at line start
        .assert_buf_start => |o| wl.push(o), // holds at buffer start (same soundness)
        // A word-context assertion (`\b` `\B` `\<` `\>`) can hold at SOME
        // position, so the byte it gates is reachable as a first byte — traverse
        // it (sound superset; a seeded thread at a position where the boundary
        // fails just dies, never a false positive).
        .assert_word => |w| wl.push(w.out),
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
        .split => |spl| wl.push2(spl.a, spl.b),
        .assert_end => |o| wl.push(o), // `$` holds at EOL
        .assert_start, .consume => {}, // at_start=false blocks `^`; consume isn't zero-width
        // A word-context assertion (`\b` `\B` `\<` `\>`) at EOL is
        // content-dependent (the last byte's word-ness), so we can't statically
        // prove a zero-width EOL match — don't traverse. Same for the buffer
        // anchors: an arbitrary line's EOL is not provably the buffer edge.
        // Conservative: only ever suppresses the `eol_empty` shortcut, never a match.
        .assert_word, .assert_buf_start, .assert_buf_end => {},
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
        .split => |spl| wl.push2(spl.a, spl.b),
        .assert_start, .assert_end, .assert_buf_start, .assert_buf_end => |o| wl.push(o),
        .assert_word => |w| wl.push(w.out),
        .consume => {}, // consumes a byte ⇒ this path is not zero-width
    };
    return false;
}
