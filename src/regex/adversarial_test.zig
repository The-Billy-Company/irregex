//! gist T2 regex — ADVERSARIAL differential tests against an INDEPENDENT oracle.
//!
//! The `dfa_test.zig` fuzz checks the DFA against the Pike VM — but the Pike VM
//! is its own reference, so a bug shared by both survives, and its generator
//! uses a tiny newline-free alphabet with no negated/sparse classes, no high
//! bytes, and only small `{n,m}` counts. This file closes those gaps:
//!
//!   • `Oracle` — a from-scratch backtracking matcher over the AST (reuses ONLY
//!     `syntax.zig`'s parser, never `compile.zig`/Pike/`dfa.zig`/`prefilter.zig`).
//!     It computes, by fixpoint over reachable end-positions, whether the pattern
//!     matches ANY substring of a line under gist's documented semantics
//!     (unanchored search, `^`/`$` line anchors, `.`/negated-class exclude `\n`).
//!     Truly independent ground truth: a shared engine bug cannot hide.
//!   • The engine is checked on BOTH paths — `lineMatch` (DFA primary) AND
//!     `lineMatchPike` (forces the Pike + `prefilter` skip path for every
//!     pattern, so the SIMD first-byte scanner gets adversarial coverage even
//!     when a DFA exists).
//!   • Soundness of the prefilter analyses: whenever the oracle says a line
//!     matches, the line MUST contain `re.required` (the trigram literal) and,
//!     when present, at least one `re.alts` member — else the T0 prefilter would
//!     drop a real match.
//!   • `prefilter.Prefilter.nextStart` is checked against a brute-force scan over
//!     adversarial byte sets (empty, singleton, full, negated, >max_ranges
//!     sparse, byte 0/255) and lines straddling the SIMD width.
//!   • A doc-level oracle (`docMatchOracle`) drives a multi-line `docMatch`
//!     differential — the DFA fused scan AND the `dfa==null` Pike per-line
//!     fallback (forced via a powerset blow-up) — over the line-boundary corners
//!     (empty doc, bare/leading/trailing `\n`, empty lines, `^$`/`$`/`.` seams).
//!
//! This differential CAUGHT a real bug: `docMatch` returned `true` for an empty
//! document (zero lines) whenever the pattern was nullable (`a*`, `\d*$`, `x|$`),
//! because the `eol_empty` short-circuit conflated "every line matches" with
//! "some line matches" — vacuously true for zero lines. rg disagrees (an empty
//! input never matches). Fixed in `core.zig` (`return doc.len > 0`); the curated
//! boundary-doc cases below lock the regression.

const std = @import("std");
const regex = @import("core.zig");
const syn = @import("syntax.zig");
const prefilter = @import("prefilter.zig");
const Regex = regex.Regex;
const Node = syn.Node;
const ByteSet = syn.ByteSet;

// ───────────────────────────── independent oracle ─────────────────────────────

/// Backtracking matcher over the parsed AST. `matchAt(n, pos)` returns the bitset
/// of end-positions reachable by matching `n` starting exactly at `pos`; bit `p`
/// set ⇔ some way to match `n` over `line[pos..p]`. Substring search ORs a start
/// seed at every position. Lines are capped < 64 bytes so a `u64` indexes them.
const Key = struct { n: usize, pos: u32 };
const Memo = std.AutoHashMap(Key, u64);

const Oracle = struct {
    line: []const u8,
    memo: *Memo,

    inline fn bit(p: usize) u64 {
        return @as(u64, 1) << @intCast(p);
    }

    /// ASCII word byte (`[0-9A-Za-z_]`) — gist's `\w` / rg `--no-unicode` class.
    fn isWord(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }
    /// Independent `\b` predicate at gap `pos`: a boundary iff exactly one of the
    /// straddling bytes is a word byte (BOL/EOL count as non-word).
    fn wordBoundary(o: Oracle, pos: usize) bool {
        const left = pos > 0 and isWord(o.line[pos - 1]);
        const right = pos < o.line.len and isWord(o.line[pos]);
        return left != right;
    }

    /// Memoized by `(node, pos)`. The `{n,m}` desugaring shares one atom pointer
    /// across copies (the AST is a DAG), so without memoization a nested
    /// `(x{0,2}){3,5}` recomputes the same subtree exponentially. Keyed on the
    /// node identity + position; `line` is fixed per Oracle.
    fn matchAt(o: Oracle, n: *const Node, pos: usize) u64 {
        const key = Key{ .n = @intFromPtr(n), .pos = @as(u32, @intCast(pos)) };
        if (o.memo.get(key)) |v| return v;
        const res: u64 = switch (n.*) {
            .empty => bit(pos),
            .anchor_start => if (pos == 0) bit(pos) else 0,
            .anchor_end => if (pos == o.line.len) bit(pos) else 0,
            .word_boundary => if (o.wordBoundary(pos)) bit(pos) else 0,
            .not_word_boundary => if (o.wordBoundary(pos)) 0 else bit(pos),
            .class => |set| if (pos < o.line.len and set.has(o.line[pos])) bit(pos + 1) else 0,
            .concat => |ab| blk: {
                var res: u64 = 0;
                var ends = o.matchAt(ab[0], pos);
                while (ends != 0) : (ends &= ends - 1) res |= o.matchAt(ab[1], @ctz(ends));
                break :blk res;
            },
            .alt => |ab| o.matchAt(ab[0], pos) | o.matchAt(ab[1], pos),
            .quest => |x| bit(pos) | o.matchAt(x, pos),
            .star => |x| o.closure(x, bit(pos)),
            .plus => |x| o.closure(x, o.matchAt(x, pos)),
            .capture => |g| o.matchAt(g.child, pos), // transparent to matching
        };
        o.memo.put(key, res) catch {};
        return res;
    }

    /// Kleene closure: from `seed` end-positions, keep applying `x` until the
    /// reachable set stops growing (≤ line.len+1 rounds; nullable `x` stabilizes
    /// because it re-adds positions already present).
    fn closure(o: Oracle, x: *const Node, seed: u64) u64 {
        var reach = seed;
        while (true) {
            var add: u64 = 0;
            var m = reach;
            while (m != 0) : (m &= m - 1) add |= o.matchAt(x, @ctz(m));
            const next = reach | add;
            if (next == reach) return reach;
            reach = next;
        }
    }

    fn substringMatch(o: Oracle, ast: *const Node) bool {
        var s: usize = 0;
        while (s <= o.line.len) : (s += 1) if (o.matchAt(ast, s) != 0) return true;
        return false;
    }
};

/// Independent doc oracle: rg `-l` line model — `\n` *terminates* a line (no
/// phantom empty final line after a trailing `\n`; content after the last `\n`
/// is still a line), OR of `substringMatch` per line. Mirrors gist's documented
/// `docMatch` line-splitting but matches each line with the independent oracle.
fn docMatchOracle(a: std.mem.Allocator, ast: *const Node, doc: []const u8) bool {
    var rest = doc;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        var memo = Memo.init(a);
        defer memo.deinit();
        if ((Oracle{ .line = rest[0..end], .memo = &memo }).substringMatch(ast)) return true;
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
    return false;
}

/// Compile, parse independently, and check `docMatch` (DFA fused scan, or the
/// Pike per-line fallback) against the doc oracle over a multi-line buffer.
fn docAgrees(col: *Collector, a: std.mem.Allocator, pattern: []const u8, doc: []const u8) void {
    var re = Regex.compile(a, pattern) catch return;
    defer re.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var p = syn.Parser{ .src = pattern, .arena = arena.allocator() };
    const ast = p.parseAlt() catch return;
    if (p.pos != pattern.len) return;

    const want = docMatchOracle(a, ast, doc);
    var sim = Regex.Sim.init(a, &re) catch return;
    defer sim.deinit();
    const got = re.docMatch(&sim, doc);
    if (got != want) {
        var b: [64]u8 = undefined;
        col.report("DOC-DIVERGENCE", pattern, doc, std.fmt.bufPrint(&b, "oracle={} doc={} dfa_built={}", .{ want, got, re.dfa != null }) catch "");
    }
}

/// Accumulates divergences across a whole run (rather than failing on the first)
/// so one expensive build surfaces every distinct bug. Dedups by pattern so many
/// failing lines of the same pattern print once; caps printed output.
const Collector = struct {
    arena: std.heap.ArenaAllocator, // owns deduped key copies (fuzz frees its pat buffers)
    seen: std.StringHashMap(void),
    fails: usize = 0,
    printed: usize = 0,
    const max_print = 60;

    fn init(a: std.mem.Allocator) Collector {
        return .{ .arena = std.heap.ArenaAllocator.init(a), .seen = std.StringHashMap(void).init(a) };
    }
    fn deinit(c: *Collector) void {
        c.seen.deinit();
        c.arena.deinit();
    }
    fn report(c: *Collector, comptime kind: []const u8, pattern: []const u8, line: []const u8, extra: []const u8) void {
        c.fails += 1;
        if (c.seen.contains(pattern)) return;
        const owned = c.arena.allocator().dupe(u8, pattern) catch return;
        c.seen.put(owned, {}) catch {};
        if (c.printed >= max_print) return;
        c.printed += 1;
        std.debug.print("{s} pat=/{s}/ line=\"{s}\" {s}\n", .{ kind, pattern, line, extra });
    }
};

/// Compile with gist, parse independently for the oracle, and check the DFA path,
/// the Pike+prefilter path, and the literal-prefilter analyses against the oracle
/// on `line`, recording (not throwing) any disagreement. BadPattern /
/// parse-incomplete ⇒ a grammar question outside the engine's remit, skipped.
fn engineAgrees(c: *Collector, a: std.mem.Allocator, pattern: []const u8, line: []const u8) void {
    if (line.len >= 64) return;
    var re = Regex.compile(a, pattern) catch return;
    defer re.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var p = syn.Parser{ .src = pattern, .arena = arena.allocator() };
    const ast = p.parseAlt() catch return;
    if (p.pos != pattern.len) return;

    var memo = Memo.init(a);
    defer memo.deinit();
    const want = (Oracle{ .line = line, .memo = &memo }).substringMatch(ast);

    var sim = Regex.Sim.init(a, &re) catch return;
    defer sim.deinit();
    const dfa_ans = re.lineMatch(&sim, line);
    const pike_ans = re.lineMatchPike(&sim, line);

    var b: [128]u8 = undefined;
    if (dfa_ans != want or pike_ans != want)
        c.report("MATCH-DIVERGENCE", pattern, line, std.fmt.bufPrint(&b, "oracle={} dfa={} pike={} dfa_built={}", .{ want, dfa_ans, pike_ans, re.dfa != null }) catch "");
    if (want and re.required.len > 0 and std.mem.indexOf(u8, line, re.required) == null)
        c.report("REQUIRED-UNSOUND", pattern, line, std.fmt.bufPrint(&b, "required=\"{s}\" claimed mandatory but absent", .{re.required}) catch "");
    if (want and re.alts.len > 0) {
        var any = false;
        for (re.alts) |lit| if (std.mem.indexOf(u8, line, lit) != null) {
            any = true;
            break;
        };
        if (!any) c.report("ALT-COVER-UNSOUND", pattern, line, "no cover member present in matching line");
    }
}

// ───────────────────── rg second oracle (parser-level differential) ─────────────────────
//
// The `Oracle` above reuses gist's own parser (`syntax.zig`), so a PARSER bug —
// a mis-decoded class range, escape, or `{n,m}` — is invisible to it (the oracle
// inherits the same misread AST). ripgrep is a fully independent implementation,
// including its parser, so a gist-vs-rg disagreement on a pattern BOTH accept is
// a real semantic/parse divergence. Patterns either side rejects (rg exit 2,
// gist `BadPattern`) are grammar-scope questions, not bugs — skipped.

/// rg runs against a temp file (`process.run` forces `stdin=.ignore`, so a file
/// arg is the input channel). `true`/`false` = matched/didn't; `null` = rg
/// errored (grammar exit 2) or couldn't run ⇒ the case isn't comparable.
const RgCtx = struct { io: std.Io, gpa: std.mem.Allocator, tmp: []const u8, rg: []const u8 };

fn rgMatch(ctx: RgCtx, pattern: []const u8, input: []const u8) ?bool {
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.tmp, .data = input }) catch return null;
    const res = std.process.run(ctx.gpa, ctx.io, .{
        .argv = &.{ ctx.rg, "-q", "-a", "--no-unicode", "--color", "never", "-e", pattern, ctx.tmp },
    }) catch return null;
    ctx.gpa.free(res.stdout);
    ctx.gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |code| switch (code) {
            0 => true, // match
            1 => false, // no match
            else => null, // 2 = grammar error ⇒ out of comparable scope
        },
        else => null,
    };
}

/// `Threaded.init(.{})` gives the child an empty environ (no PATH), so argv[0]
/// must be an absolute path. Probe the usual install sites; first one whose
/// `--version` exits 0 wins. null ⇒ rg absent ⇒ the test skips (CI-hermetic).
fn findRg(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const cands = [_][]const u8{ "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg", "/opt/local/bin/rg", "/bin/rg" };
    for (cands) |cand| {
        const res = std.process.run(gpa, io, .{ .argv = &.{ cand, "--version" } }) catch continue;
        gpa.free(res.stdout);
        gpa.free(res.stderr);
        if (res.term == .exited and res.term.exited == 0) return cand;
    }
    return null;
}

/// Compare gist `lineMatch` (single line; rg fed `line ++ "\n"` so an empty line
/// is one empty line, not zero lines) and `docMatch` (multi-line; rg fed the raw
/// doc) against rg. Records (doesn't throw) divergences where both engines accept
/// the pattern.
fn rgAgrees(c: *Collector, ctx: RgCtx, pattern: []const u8, line: bool, input: []const u8) void {
    var re = Regex.compile(ctx.gpa, pattern) catch return; // gist rejects ⇒ scope, skip
    defer re.deinit();
    var sim = Regex.Sim.init(ctx.gpa, &re) catch return;
    defer sim.deinit();

    if (line) {
        var buf: [80]u8 = undefined;
        if (input.len + 1 > buf.len) return;
        @memcpy(buf[0..input.len], input);
        buf[input.len] = '\n';
        const rg = rgMatch(ctx, pattern, buf[0 .. input.len + 1]) orelse return;
        const got = re.lineMatch(&sim, input);
        if (got != rg) {
            var b: [64]u8 = undefined;
            c.report("RG-LINE-DIVERGENCE", pattern, input, std.fmt.bufPrint(&b, "gist={} rg={}", .{ got, rg }) catch "");
        }
    } else {
        const rg = rgMatch(ctx, pattern, input) orelse return;
        const got = re.docMatch(&sim, input);
        if (got != rg) {
            var b: [64]u8 = undefined;
            c.report("RG-DOC-DIVERGENCE", pattern, input, std.fmt.bufPrint(&b, "gist={} rg={}", .{ got, rg }) catch "");
        }
    }
}

// ─────────────────────────── curated adversarial cases ───────────────────────────

const Case = struct { pat: []const u8, line: []const u8 };

test "adversarial: curated patterns vs independent oracle" {
    const a = std.testing.allocator;
    const cases = [_]Case{
        // Large / boundary counted repetition (fuzz only emits {2},{1,3},{0,2}).
        .{ .pat = "a{5,8}", .line = "aaaaaa" },
        .{ .pat = "a{5,8}", .line = "aaaa" },
        .{ .pat = "^a{0,3}$", .line = "aaaa" },
        .{ .pat = "x{0,0}y", .line = "y" },
        .{ .pat = "(ab){2,3}c", .line = "ababababc" },
        // Negated & sparse classes → many first-byte ranges (prefilter range/scalar).
        .{ .pat = "[^a-c]+", .line = "aaazzz" },
        .{ .pat = "[ace gik]{2,}", .line = "x a c e" },
        .{ .pat = "[^ -~]", .line = "ok\x80end" }, // a non-printable byte
        // High bytes through '.' and literals.
        .{ .pat = ".\xff.", .line = "a\xffb" },
        .{ .pat = "[\x80-\xff]+", .line = "ab\x80\x81cd" },
        // Nested nullable quantifiers (epsilon-loop hazard for compile/Pike).
        .{ .pat = "(a*)*b", .line = "aaab" },
        .{ .pat = "(a?)+", .line = "" },
        .{ .pat = "(|a)b", .line = "b" }, // empty alternation branch
        .{ .pat = "a**", .line = "aaa" },
        // Anchors interleaved with nullable prefixes (eol_empty hazard).
        .{ .pat = "\\d*$", .line = "abc123" },
        .{ .pat = "^[a-z]*$", .line = "hello" },
        .{ .pat = "^[a-z]*$", .line = "Hello" },
        .{ .pat = "x|$", .line = "zzz" },
        // Alternation cover soundness with a short branch.
        .{ .pat = "panic|0x", .line = "0xFF" },
        .{ .pat = "return|break", .line = "    break" },
        // Mid-pattern anchors: unsatisfiable seams `^`/`$` can't straddle a char.
        .{ .pat = "a$b", .line = "ab" }, // `$` mid ⇒ never matches
        .{ .pat = "a^b", .line = "ab" }, // `^` mid ⇒ never matches
        .{ .pat = "(a$|b)c", .line = "bc" }, // anchored alt branch dies, other lives
        .{ .pat = "(a$|b)c", .line = "ac" },
        .{ .pat = "^a|b$", .line = "xby" }, // neither anchor satisfied mid-line
        .{ .pat = "^a|b$", .line = "xb" }, // `b$` satisfied
        .{ .pat = "(^|x)y", .line = "zy" }, // `^` branch fails off-start, `xy` absent
        .{ .pat = "(^|x)y", .line = "xy" },
        .{ .pat = "$a", .line = "" }, // `$` then a char on empty line
        // Word boundaries `\b`/`\B`: leading/trailing/both-sided, BOL/EOL boundaries,
        // and non-boundary `\B` inside vs between words.
        .{ .pat = "\\bcat\\b", .line = "the cat sat" }, // whole word ⇒ match
        .{ .pat = "\\bcat\\b", .line = "concatenate" }, // substring only ⇒ no match
        .{ .pat = "\\bcat", .line = "cat" }, // boundary at BOL
        .{ .pat = "cat\\b", .line = "cat" }, // boundary at EOL
        .{ .pat = "\\bcat\\b", .line = "cat" }, // both boundaries on a bare word
        .{ .pat = "\\Bcat", .line = "concat" }, // `\B`: no boundary before `cat`
        .{ .pat = "\\Bcat", .line = "cat" }, // BOL is a boundary ⇒ `\B` fails
        .{ .pat = "a\\Bb", .line = "ab" }, // mid-word non-boundary
        .{ .pat = "a\\bb", .line = "ab" }, // no boundary between two word bytes ⇒ no
        .{ .pat = "\\b", .line = "" }, // empty line has no word byte ⇒ no boundary
        .{ .pat = "\\B", .line = "" }, // empty line is all non-boundary ⇒ match
        .{ .pat = "\\w+\\b", .line = "foo_bar baz" },
        .{ .pat = "\\b\\d{4}\\b", .line = "year 2026 ok" },
        .{ .pat = "\\b\\d{4}\\b", .line = "id12345x" }, // digits glued to words ⇒ no
    };
    var col = Collector.init(a);
    defer col.deinit();
    for (cases) |c| engineAgrees(&col, a, c.pat, c.line);
    if (col.fails != 0) {
        std.debug.print("curated: {} divergence(s)\n", .{col.fails});
        return error.CuratedDivergence;
    }
}

// ──────────────────────── randomized adversarial fuzz ────────────────────────

/// Richer than `dfa_test`'s generator: negated/sparse classes, all the `\X`
/// escapes, `{n,}`/large `{n,m}`, alternation, optional leading `^`/trailing `$`.
const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    const E = std.mem.Allocator.Error;

    fn atom(g: *Gen, depth: u8) E!void {
        const list = "abe01_";
        switch (g.r.uintLessThan(u8, if (depth > 0) 15 else 14)) {
            0 => try g.buf.append(g.a, list[g.r.uintLessThan(usize, list.len)]),
            1 => try g.buf.append(g.a, '.'),
            2 => try g.buf.appendSlice(g.a, "[a-c]"),
            3 => try g.buf.appendSlice(g.a, "[^a-c]"),
            4 => try g.buf.appendSlice(g.a, "[ace1]"),
            5 => try g.buf.appendSlice(g.a, "\\d"),
            6 => try g.buf.appendSlice(g.a, "\\D"),
            7 => try g.buf.appendSlice(g.a, "\\w"),
            8 => try g.buf.appendSlice(g.a, "\\s"),
            9 => try g.buf.appendSlice(g.a, "\\S"),
            10 => try g.buf.append(g.a, 0xFF), // raw high-byte literal atom
            11 => try g.buf.appendSlice(g.a, "[^ -~]"), // negated printable ⇒ many first-byte ranges
            12 => try g.buf.appendSlice(g.a, "\\b"), // word boundary (zero-width)
            13 => try g.buf.appendSlice(g.a, "\\B"), // non-boundary (zero-width)
            else => {
                try g.buf.append(g.a, '(');
                try g.alt(depth - 1);
                try g.buf.append(g.a, ')');
            },
        }
    }
    fn quant(g: *Gen, depth: u8) E!void {
        try g.atom(depth);
        switch (g.r.uintLessThan(u8, 11)) {
            0 => try g.buf.append(g.a, '*'),
            1 => try g.buf.append(g.a, '+'),
            2 => try g.buf.append(g.a, '?'),
            3 => try g.buf.appendSlice(g.a, "{2}"),
            4 => try g.buf.appendSlice(g.a, "{1,3}"),
            5 => try g.buf.appendSlice(g.a, "{0,2}"),
            6 => try g.buf.appendSlice(g.a, "{2,}"),
            7 => try g.buf.appendSlice(g.a, "{3,5}"),
            8 => try g.buf.appendSlice(g.a, "{0}"), // ⇒ empty
            9 => try g.buf.appendSlice(g.a, "{4,6}"),
            else => {},
        }
    }
    fn concat(g: *Gen, depth: u8) E!void {
        const n = 1 + g.r.uintLessThan(usize, 3);
        for (0..n) |_| try g.quant(depth);
    }
    fn alt(g: *Gen, depth: u8) E!void {
        try g.concat(depth);
        const n = g.r.uintLessThan(usize, 3);
        for (0..n) |_| {
            try g.buf.append(g.a, '|');
            try g.concat(depth);
        }
    }
    fn pattern(g: *Gen) E!void {
        if (g.r.boolean()) try g.buf.append(g.a, '^');
        try g.alt(1);
        if (g.r.boolean()) try g.buf.append(g.a, '$');
    }
};

test "adversarial: randomized differential vs independent oracle" {
    const a = std.testing.allocator;
    const alphabet = "abe01_ X\x80\xff"; // \w-fodder, separators, two high bytes
    var line_buf: [50]u8 = undefined;

    var col = Collector.init(a);
    defer col.deinit();

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 140) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        for (0..6) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            engineAgrees(&col, a, pat.items, line_buf[0..len]);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 700);
    if (col.fails != 0) {
        std.debug.print("fuzz: {} divergence(s) across {} checks\n", .{ col.fails, checked });
        return error.FuzzDivergence;
    }
}

test "adversarial: curated multi-line boundary docs vs independent oracle" {
    const a = std.testing.allocator;
    // The line-boundary corners: empty doc (zero lines ≠ one empty line), bare/
    // leading/trailing newlines, empty lines between content, `$`/`^$`/`.` at
    // those seams. All cross-checked against the rg `-l` terminator model.
    const cases = [_]Case{
        .{ .pat = "a*", .line = "" }, // empty doc: zero lines ⇒ NO match (Bug #1)
        .{ .pat = "x|$", .line = "" }, // nullable via `$`, empty doc ⇒ no match
        .{ .pat = "^$", .line = "" }, // empty doc has no empty line ⇒ no match
        .{ .pat = "^$", .line = "\n" }, // one empty line ⇒ match
        .{ .pat = "^$", .line = "\n\n" }, // two empty lines ⇒ match
        .{ .pat = "^$", .line = "x\n" }, // no empty line (no phantom trailing) ⇒ no
        .{ .pat = ".", .line = "\n" }, // empty line has no char for `.` ⇒ no match
        .{ .pat = ".", .line = "\n\n" },
        .{ .pat = "c$", .line = "abc\n" }, // last line ends with c ⇒ match
        .{ .pat = "^abc$", .line = "abc\n" },
        .{ .pat = "\\d+", .line = "a\n12\nb" }, // middle line matches
        .{ .pat = "a", .line = "\na\n" }, // content after a leading empty line
        .{ .pat = "z", .line = "a\nb\nc" }, // no line matches
        .{ .pat = "\\w*$", .line = "" }, // nullable over empty doc ⇒ no match
    };
    var col = Collector.init(a);
    defer col.deinit();
    for (cases) |c| docAgrees(&col, a, c.pat, c.line);
    if (col.fails != 0) {
        std.debug.print("curated-doc: {} divergence(s)\n", .{col.fails});
        return error.CuratedDocDivergence;
    }
}

test "adversarial: Pike docMatch fallback (DFA-null) vs independent oracle" {
    const a = std.testing.allocator;
    // `[ab]*a[ab]{13}` forces a powerset blow-up past `max_states` (a DFA must
    // remember which of the last 14 bytes was `a` ⇒ 2^14 states), so `dfa==null`
    // and `docMatch` takes the never-otherwise-fuzzed Pike per-line fallback.
    const ab13 = "[ab][ab][ab][ab][ab][ab][ab][ab][ab][ab][ab][ab][ab]";
    const blow = "[ab]*a" ++ ab13;
    {
        var re = try Regex.compile(a, blow);
        defer re.deinit();
        try std.testing.expect(re.dfa == null); // confirm the fallback is exercised
    }
    const nullable_blow = "([ab]*a" ++ ab13 ++ ")*"; // eol_empty + DFA-null
    const docs = [_][]const u8{
        "", "\n", "\n\n", // boundary docs through the fallback
        "abababababababa", // single matching line (a then 13 of [ab])
        "xx\nabababababababab\nyy", // match on the middle line
        "abababababababab\n", // trailing newline, no phantom line
        "short\nlines\nonly", // no line long enough to match
    };
    var col = Collector.init(a);
    defer col.deinit();
    for (docs) |d| {
        docAgrees(&col, a, blow, d);
        docAgrees(&col, a, nullable_blow, d);
    }
    if (col.fails != 0) {
        std.debug.print("pike-doc-fallback: {} divergence(s)\n", .{col.fails});
        return error.PikeDocFallbackDivergence;
    }
}

test "adversarial: Sim reuse across calls ≡ fresh Sim per call" {
    // Real callers (bench/certify/scan) reuse ONE `Sim` across many documents; a
    // stale `gen`/`seen` not reset between calls would silently corrupt every
    // call after the first. The harness elsewhere allocates a fresh `Sim` per
    // check, so this is the only place that path is adversarially exercised.
    const a = std.testing.allocator;
    const pats = [_][]const u8{ "\\d+", "ab*c", "[a-c]{2,}", "^x|y$", "(foo|bar)", "\\w+$", "a.*b" };
    const inputs = [_][]const u8{ "123", "abbbc", "aabbcc", "y", "xfoo", "", "no", "barbar\nfoo\n", "a\nb", "zzz" };
    for (pats) |pat| {
        var re = Regex.compile(a, pat) catch continue;
        defer re.deinit();
        var reused = try Regex.Sim.init(a, &re);
        defer reused.deinit();
        for (inputs) |inp| {
            const r_line = re.lineMatch(&reused, inp);
            const r_doc = re.docMatch(&reused, inp);
            var fresh_l = try Regex.Sim.init(a, &re);
            defer fresh_l.deinit();
            var fresh_d = try Regex.Sim.init(a, &re);
            defer fresh_d.deinit();
            try std.testing.expectEqual(re.lineMatch(&fresh_l, inp), r_line);
            try std.testing.expectEqual(re.docMatch(&fresh_d, inp), r_doc);
        }
    }
}

test "adversarial: docMatch multi-line differential vs independent oracle" {
    const a = std.testing.allocator;
    const alphabet = "abe1_ \n\nX\xff"; // '\n' ⇒ lines/empty lines/trailing nl; high byte
    var doc_buf: [48]u8 = undefined;

    var col = Collector.init(a);
    defer col.deinit();

    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 90) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0xD1B54A32D192ED03);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        for (0..6) |trial| {
            const len = if (trial == 0) 0 else r.uintLessThan(usize, doc_buf.len + 1);
            for (0..len) |i| doc_buf[i] = alphabet[r.uintLessThan(usize, alphabet.len)];
            docAgrees(&col, a, pat.items, doc_buf[0..len]);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 400);
    if (col.fails != 0) {
        std.debug.print("doc fuzz: {} divergence(s) across {} checks\n", .{ col.fails, checked });
        return error.DocFuzzDivergence;
    }
}

// ─────────────────── prefilter first-byte scanner brute-force ───────────────────

/// Ground-truth: first index ≥ `from` whose byte is in `set`.
fn bruteNextStart(set: ByteSet, line: []const u8, from: usize) ?usize {
    var i = from;
    while (i < line.len) : (i += 1) if (set.has(line[i])) return i;
    return null;
}

var prefilter_fails: usize = 0;

fn checkPrefilter(set: ByteSet, line: []const u8) void {
    const pf = prefilter.Prefilter.init(set);
    var from: usize = 0;
    while (from <= line.len) : (from += 1) {
        const got = pf.nextStart(line, from);
        const want = bruteNextStart(set, line, from);
        if (got != want) {
            prefilter_fails += 1;
            if (prefilter_fails <= 30)
                std.debug.print("PREFILTER-DIVERGENCE from={} got={?} want={?} count={} byte={?} nranges={}\n", .{ from, got, want, pf.count(), pf.byte, pf.nranges });
        }
    }
}

test "adversarial: prefilter.nextStart vs brute force over adversarial sets" {
    prefilter_fails = 0;
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const r = prng.random();

    // Lines straddling the SIMD width (vlen is 16 on aarch64/x86): 0,15,16,17,…
    const lens = [_]usize{ 0, 1, 8, 15, 16, 17, 31, 32, 33, 40 };
    var line_buf: [40]u8 = undefined;

    // 1) Every singleton set (memchr tier) + its negation (1-or-2-range tier).
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        var single = ByteSet{};
        single.set(@intCast(b));
        var neg = single;
        neg.negate();
        for (lens) |len| {
            for (0..len) |i| line_buf[i] = r.int(u8);
            checkPrefilter(single, line_buf[0..len]);
            checkPrefilter(neg, line_buf[0..len]);
        }
    }

    // 2) Random sparse sets of k bits — k large enough to blow past max_ranges
    //    (6) into the scalar-probe fallback, plus the full set.
    var full = ByteSet{};
    full.bits = @splat(~@as(u64, 0));
    for (0..3000) |t| {
        var set = if (t % 97 == 0) full else ByteSet{};
        if (t % 97 != 0) {
            const k = 1 + r.uintLessThan(usize, 30);
            for (0..k) |_| set.set(r.int(u8));
        }
        const len = lens[r.uintLessThan(usize, lens.len)];
        for (0..len) |i| line_buf[i] = r.int(u8);
        checkPrefilter(set, line_buf[0..len]);
    }
    if (prefilter_fails != 0) {
        std.debug.print("prefilter: {} divergence(s)\n", .{prefilter_fails});
        return error.PrefilterDivergence;
    }
}

// ───────────────────── rg second-oracle differential (parser) ─────────────────────

test "adversarial: rg second-oracle differential (parser-level)" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rg = findRg(a, io) orelse return error.SkipZigTest; // hermetic on CI without ripgrep

    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/gist_rgcheck_{x}.txt", .{@intFromPtr(&threaded)});
    const ctx = RgCtx{ .io = io, .gpa = a, .tmp = tmp, .rg = rg };
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var col = Collector.init(a);
    defer col.deinit();

    // Literal text including regex-meta bytes (to exercise escapes) and
    // class-relevant bytes. Fed to rg as `line ++ "\n"` ⇒ one line, never zero.
    const lines = [_][]const u8{
        "",    "a",     "abc", "aaa", "abcabc", "012",   "a1b2",
        "a-b", "a.b",   "a*b", "(a)", "[x]",    "a b c", "ABC",
        "...", "axbxc", "end", "ccc", "-",      "}",
    };
    // Parser corners: escapes, class range/edge handling, `{n,m}`, alternation,
    // anchors, nesting. rg or gist rejecting one ⇒ scope question, auto-skipped.
    const pats = [_][]const u8{
        "a\\.c",  "\\.",      "\\*",     "a\\*b", "\\(",    "\\)",   "\\[",      "\\]",
        "\\|",    "\\^",      "\\$",     "\\\\",  "\\+",    "\\?",   "a\\{2\\}", "a.c",
        "a..c",   ".*",       ".",       "[abc]", "[^abc]", "[a-c]", "[c-c]",    "[-a]",
        "[a-]",   "[a^b]",    "[.]",     "[*]",   "[\\^]",  "[\\-]", "[\\]]",    "[\\d]",
        "[\\w]",  "[a-cA-C]", "[0-9]",   "[^-a]", "a{2}",   "a{2,}", "a{0,2}",   "a{0}",
        "a{1,3}", "ab{2}",    "(ab){2}", "a{3}",  "a|b",    "(a|)b", "(|a)b",    "ab|cd",
        "^a",     "a$",       "^abc$",   "^$",    "a^b",    "a$b",   "^a|b$",    "(^|x)y",
        "((a))",  "(a*)*b",   "(a|b)+",  "(a?)+", "a**",
        // Word boundaries `\b`/`\B` (ASCII, rg `--no-unicode`): leading, trailing,
        // both-sided, around classes, and the non-boundary `\B` — the foot-gun this
        // change fixes (gist used to read `\b` as a literal byte 'b').
        "\\ba",   "a\\b",     "\\babc",  "abc\\b", "\\babc\\b", "\\b\\w+", "\\w+\\b",
        "\\bend\\b", "\\Bb",  "a\\Bb",   "\\Bbc",  "[a-c]\\b",  "\\b-",    "-\\b",
    };
    for (pats) |p| for (lines) |l| rgAgrees(&col, ctx, p, true, l);

    // Randomized breadth: the supported-subset generator vs rg over printable
    // lines — the parser corner a hand-picked list would miss. rg/gist rejecting
    // a generated pattern auto-skips (grammar scope).
    const lalpha = "abc012 _-.";
    var line_buf: [24]u8 = undefined;
    var seed: u64 = 0;
    while (seed < 70) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x2545F4914F6CDD1D);
        const r = prng.random();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        g.pattern() catch continue;
        for (0..4) |t| {
            const len = if (t == 0) 0 else r.uintLessThan(usize, line_buf.len + 1);
            for (0..len) |i| line_buf[i] = lalpha[r.uintLessThan(usize, lalpha.len)];
            rgAgrees(&col, ctx, pat.items, true, line_buf[0..len]);
        }
    }

    // docMatch (multi-line) vs rg over the line-boundary corners — independently
    // re-confirms the empty-doc fix against a real implementation.
    const docs = [_][]const u8{ "", "\n", "\n\n", "abc", "abc\n", "x\nabc\ny", "a\n\nb" };
    const doc_pats = [_][]const u8{ "a*", "\\d*$", "^$", "c$", "^abc$", "x|$", "abc", "z", "^a" };
    for (doc_pats) |p| for (docs) |d| rgAgrees(&col, ctx, p, false, d);

    if (col.fails != 0) {
        std.debug.print("rg differential: {} divergence(s)\n", .{col.fails});
        return error.RgDivergence;
    }
}
