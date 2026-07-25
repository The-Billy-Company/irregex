//! gist — compilation: pattern text ⇒ the immutable `Regex` handle. Parse to an
//! AST (`regex/syntax/`), case-fold it if `-i`, lower it to a Thompson NFA
//! (`regex/compile/`), then run every verify-time analysis the scanner will consult
//! — required literal, alternation cover, pure-literal equivalence, first-byte
//! prefilter, zero-width reachability — and choose which engines to build: the
//! SIMD class-run kernel, and the byte-class DFA unless a stronger reduction
//! already answers finally or the powerset blows past its cap.
//!
//! Order is load-bearing: folding happens BEFORE any analysis so prefilter and
//! match engines agree on the same classes, and everything an analysis needs
//! lives in an arena that dies with this frame — only the owned copies survive
//! into the handle (`freeAlts` is the other half of that contract, called by
//! `Regex.deinit`).

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const analysis = @import("../../analysis/analysis.zig");
const compile_mod = @import("../../compile/compile.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dfa_mod = @import("../dfa/dfa.zig");
const powerset = @import("../dfa/powerset.zig");
const classrun_mod = @import("../../../scan/classrun.zig");
const core = @import("core.zig");

const ByteSet = syn.ByteSet;
const Node = syn.Node;
const State = syn.State;
const ParseError = syn.ParseError;
const Regex = core.Regex;

/// Compile-time knobs. `caseless` ASCII-folds every consuming class so the
/// match is case-insensitive (the `-i` flag) — see `syn.foldCaseAst`.
/// `multiline` (`-U`) matches the whole buffer as one haystack — a match may
/// span `\n`, and `^`/`$` become line-boundary anchors (rg's `-U` default).
/// `dotall` (`(?s)`) additionally lets `.` match `\n` (only meaningful with
/// `multiline`). Both default off ⇒ the per-line model, byte-for-byte unchanged.
/// `unicode` (rg default; `(?-u)`/`--no-unicode` clears it) makes the parser
/// codepoint-aware: non-ASCII literals, `.`, `\w`/`\d`/`\s`, `\p{…}`, and
/// non-ASCII `[…]` lower to a `uclass` (UTF-8 byte sub-automaton). Cleared, the
/// engine is a pure byte matcher (today's `(?-u)` behavior, byte-for-byte).
/// `line_anchors` decouples the regex `m` flag from `-U`: `^`/`$` anchor at
/// every `\n` (true) or only the buffer ends (false). `null` inherits
/// `multiline` — rg's `-U` default is `m` ON, and `(?-m)` clears it while the
/// whole-buffer search stays live (`multiline` unchanged). Per-line mode
/// (`multiline == false`) is unaffected: a single-line haystack's edges ARE
/// its line boundaries either way.
/// `force_dfa` builds the byte-class DFA even when a byte-exact class-run
/// kernel makes it dead weight for every production path — the hook the
/// determinizer's own proof harness (powerset/dfa tests) uses to keep
/// exercising subset construction on class-shaped patterns.
pub const Options = struct { caseless: bool = false, multiline: bool = false, dotall: bool = false, unicode: bool = false, line_anchors: ?bool = null, force_dfa: bool = false };

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
    return compileOpts(allocator, pattern, .{});
}

pub fn compileOpts(allocator: std.mem.Allocator, pattern: []const u8, opts: Options) ParseError!Regex {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = syn.Parser{ .src = pattern, .arena = arena, .dotall = opts.dotall, .multiline = opts.multiline, .unicode = opts.unicode };
    const ast = try parser.parseAlt();
    if (parser.pos != pattern.len) return ParseError.BadPattern;
    // Fold BEFORE every downstream analysis (required-literal, cover, first-set,
    // DFA) so prefilter and match engines agree on the case-insensitive class.
    if (opts.caseless) try syn.foldCaseAst(arena, ast, opts.unicode);

    var c = compile_mod.Compiler{ .gpa = allocator };
    errdefer c.states.deinit(allocator);
    const match_idx = try c.push(.match);
    const start = try c.compileNode(ast, match_idx);

    const req = try analysis.literalInfo(arena, ast);
    const required = try allocator.dupe(u8, req.best);
    errdefer allocator.free(required);
    const alts = try dupeCover(allocator, arena, ast, req.best);
    errdefer freeAlts(allocator, alts);
    const lits = try dupeLits(allocator, arena, ast, opts.multiline);
    errdefer freeAlts(allocator, lits);

    const states = try c.states.toOwnedSlice(allocator);
    errdefer allocator.free(states);
    const anchored = analysis.startsAnchored(ast);
    const eol_empty = try analysis.reachesMatchEol(allocator, states, start);
    const nullable = try analysis.reachesMatchZeroWidth(allocator, states, start);
    var first_set: ByteSet = .{};
    if (!anchored) try analysis.analyzeFirst(allocator, states, start, &first_set);

    // Byte-class DFA, the primary engine: determinizes the Thompson program
    // (anchors and all); null only on powerset blow-up, when the Pike VM serves.
    // Multiline resolves `^`/`$` per-position against `\n` adjacency (a match
    // spans lines), which the eager BOL/EOL determinization can't encode — so an
    // assertion-BEARING multiline regex runs the Pike whole-buffer scan and
    // needs no DFA. An assertion-FREE multiline pattern (`import \([\s\S]*?\)`,
    // the whole `-U` bench class) has no positional predicate at all: its
    // determinization is exact over any haystack, so `bufMatch` gets the same
    // O(1)/byte floor the per-line model enjoys instead of the O(states)/byte
    // Pike re-seed rg's lazy DFA was beating.
    const assert_free = assertFree(states);

    // SIMD class-run reduction (post-fold, so `-i` classes are final). In
    // the per-line model a haystack line never contains `\n`, so dropping
    // it from the set is an identity there — and it makes every run
    // provably line-local, licensing the one-pass whole-buffer `docMatch`.
    // Multiline keeps the set verbatim: the buffer IS the haystack.
    // A codepoint class whose full ranges survived the AST algebra hands
    // them (gpa-duped; the arena dies with this frame) to the kernel,
    // whose scalar UTF-8 resolver then settles high bytes itself.
    const cr: ?classrun_mod.ClassRun = if (analysis.classRunShape(ast)) |shape| blk: {
        var set = shape.set;
        if (!opts.multiline) set.remove('\n');
        const cp: ?[]const [2]u21 = if (shape.cp) |r|
            if (classrun_mod.ClassRun.cpResolvable(r)) try allocator.dupe([2]u21, r) else null
        else
            null;
        var run = classrun_mod.ClassRun.build(set.bits, shape.min, shape.exact, cp) orelse {
            if (cp) |r| allocator.free(r);
            break :blk null;
        };
        // Span-exactness is a strictly stronger recognizer (window rule,
        // not just existence) — when it accepts, its leaves are the same
        // ones the boolean algebra folded, so set/min/exact agree; the
        // guard is pure paranoia. `max`/`lazy` arm `nextSpan`'s chunking.
        if (analysis.classSpanShape(ast)) |sp| {
            if (sp.min == shape.min and sp.exact == shape.exact and std.mem.eql(u64, &sp.set.bits, &shape.set.bits)) {
                run.span = true;
                run.max = sp.max;
                run.lazy = sp.lazy;
            }
        }
        break :blk run;
    } else null;
    errdefer if (cr) |run| if (run.cp) |r| allocator.free(r);

    // A byte-exact class run — or a codepoint one whose full ranges the
    // kernel holds — answers every boolean entry point finally (the
    // kernel never defers), and the span path is the kernel window walk
    // (span-exact shapes) or the Pike VM (the rest) — never the DFA, so
    // it would be dead weight. Skipping determinization here is a pure
    // compile-time win: measured 77–178 ms on `(?-u)\w{3}`…`\w{3,8}`
    // (the `{n,m}` expansion clones the class sub-automaton per copy),
    // and ~168 ms on Unicode `\w{3,8}`, whose codepoint lowering makes
    // the powerset step the whole cost of compilation. Only a projection
    // WITHOUT carried ranges keeps the DFA: its `.unproven` verdicts on
    // high-byte haystacks land there.
    const kernel_final = if (cr) |run| run.exact or run.cp != null else false;
    const dfa: ?*dfa_mod.Dfa = if (opts.multiline and !assert_free)
        null
    else if (kernel_final and !opts.force_dfa)
        null
    else
        try powerset.build(allocator, states, start, anchored, opts.unicode);
    errdefer if (dfa) |d| d.deinit();

    return .{
        .states = states,
        .start = start,
        .required = required,
        .alts = alts,
        .lits = lits,
        .anchored = anchored,
        .eol_empty = eol_empty,
        .nullable = nullable,
        .first = prefilter.Prefilter.init(first_set),
        .dfa = dfa,
        .classrun = cr,
        .assert_free = assert_free,
        .multiline = opts.multiline,
        .line_anchors = opts.line_anchors orelse opts.multiline,
        .unicode = opts.unicode,
        .allocator = allocator,
    };
}

/// No zero-width assertion instruction anywhere in the program — the
/// compiled-program (not AST) answer, so every lowering (case fold, uclass
/// expansion) is already reflected. Powers the multiline DFA admission.
fn assertFree(states: []const State) bool {
    for (states) |st| switch (st) {
        .consume, .split, .match => {},
        else => return false,
    };
    return true;
}

/// Own a copy of the alternation cover set (empty when a single-literal
/// prefilter already applies, i.e. `best` ≥ 3, or none is provable).
fn dupeCover(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, best: []const u8) ParseError![]const []const u8 {
    if (best.len >= 3) return &.{}; // single-literal prefilter wins
    const cover = (try analysis.requiredAny(arena, ast)) orelse return &.{};
    return dupeAll(gpa, cover);
}

/// Own a copy of the pure-literal equivalence set (`analysis.pureLiterals`),
/// or empty. Multiline (`-U`) changes the match model (a match may cross
/// `\n`), so the per-line equivalence claim doesn't hold there — skip it.
fn dupeLits(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, multiline: bool) ParseError![]const []const u8 {
    if (multiline) return &.{};
    const lits = (try analysis.pureLiterals(arena, ast)) orelse return &.{};
    return dupeAll(gpa, lits);
}

/// Own a heap copy of an arena-backed literal set (shared by the two above).
fn dupeAll(gpa: std.mem.Allocator, src: []const []const u8) ParseError![]const []const u8 {
    if (src.len == 0) return &.{};
    const dst = try gpa.alloc([]const u8, src.len);
    var n: usize = 0;
    errdefer {
        for (dst[0..n]) |s| gpa.free(s);
        gpa.free(dst);
    }
    for (src) |s| {
        dst[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return dst;
}

/// Free an owned cover set (its members then its backing slice). No-op on the
/// empty comptime literal, which has no heap backing.
pub fn freeAlts(gpa: std.mem.Allocator, alts: []const []const u8) void {
    for (alts) |s| gpa.free(s);
    if (alts.len > 0) gpa.free(alts);
}
