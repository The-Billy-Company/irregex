//! gist — T2 regex execution: a linear-time Thompson NFA over bytes (RE2 /
//! ripgrep philosophy — no backtracking, no catastrophic blowup), compiled from
//! the AST in `regex_syntax.zig` and run with a Pike simulation. Plus the public
//! `Regex` handle carrying the required-literal that lets a regex reuse the T0
//! trigram prefilter.
//!
//! Grep semantics: a line matches if the pattern matches ANY substring of it
//! (unanchored). We never construct `.*pat.*`; the Pike simulation re-seeds the
//! start thread at every position — the standard linear search. Line anchors
//! `^` / `$` are zero-width assertions resolved during the epsilon-closure from
//! the (start, end)-of-line flags at each position; `\b` and Unicode classes are
//! out of scope this tier. The equality oracle runs `rg (?-u)…` so semantics
//! coincide exactly.

const std = @import("std");
const syn = @import("regex_syntax.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;

/// A contiguous byte range `[lo, hi]`. The first-byte set decomposes into a
/// handful of these (`[0-9]`, `[a-f0-9]`, `\w`, the `{p,0}` of `panic|0x`), which
/// the scanner's skip loop tests with one SIMD compare per range instead of a
/// scalar byteset probe per byte.
const Range = struct { lo: u8, hi: u8 };
const max_ranges = 6; // beyond this (e.g. a negated class) the scalar probe wins

const State = union(enum) {
    consume: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    assert_start: u32, // zero-width `^`: pass to `out` only at line start
    assert_end: u32, // zero-width `$`: pass to `out` only at line end
    match,
};

pub const Regex = struct {
    states: []State,
    start: u32,
    required: []u8, // longest literal that must appear in every match ("" if none)
    // Alternation cover set: literals whose UNION every match intersects (each
    // ≥3 B). Non-empty only when `required` is too short for a single-literal
    // prefilter but a `foo|bar`-style union is provable. Empty ⇒ unused.
    alts: []const []const u8,
    // Scan accelerators (verify-time, no effect on match semantics):
    //   anchored   — every match begins at line start (`^…`); seed only at pos 0.
    //   first      — bytes that can BEGIN a match mid-line; lets the scanner
    //                `memchr`-skip dead spans instead of re-seeding every byte.
    //   first_byte — `first`'s sole member, when singleton (SIMD `indexOfScalar`).
    anchored: bool,
    first: ByteSet,
    first_byte: ?u8,
    first_ranges: [max_ranges]Range,
    first_nranges: u8, // 0 ⇒ singleton (memchr) or too-many-ranges (scalar probe)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.states);
        self.allocator.free(self.required);
        for (self.alts) |s| self.allocator.free(s);
        if (self.alts.len > 0) self.allocator.free(self.alts);
        self.* = undefined;
    }

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Regex {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var parser = syn.Parser{ .src = pattern, .arena = arena };
        const ast = try parser.parseAlt();
        if (parser.pos != pattern.len) return ParseError.BadPattern;

        var c = Compiler{ .gpa = allocator };
        errdefer c.states.deinit(allocator);
        const match_idx = try c.push(.match);
        const start = try c.compileNode(ast, match_idx);

        const req = try syn.literalInfo(arena, ast);
        const required = try allocator.dupe(u8, req.best);
        errdefer allocator.free(required);
        const alts = try dupeCover(allocator, arena, ast, req.best);
        errdefer {
            for (alts) |s| allocator.free(s);
            if (alts.len > 0) allocator.free(alts);
        }

        const states = try c.states.toOwnedSlice(allocator);
        errdefer allocator.free(states);
        const anchored = syn.startsAnchored(ast);
        var first: ByteSet = .{};
        if (!anchored) try analyzeFirst(allocator, states, start, &first);
        const single = first.only();
        var ranges: [max_ranges]Range = undefined;
        // SIMD range scan only earns its keep when there's no singleton memchr;
        // null (>max_ranges) falls back to the scalar byteset probe.
        const nranges: u8 = if (single != null) 0 else firstRanges(first, &ranges) orelse 0;

        return .{
            .states = states,
            .start = start,
            .required = required,
            .alts = alts,
            .anchored = anchored,
            .first = first,
            .first_byte = single,
            .first_ranges = ranges,
            .first_nranges = nranges,
            .allocator = allocator,
        };
    }

    /// Decompose a byte set into contiguous `[lo,hi]` ranges; null if it needs
    /// more than `max_ranges` (the scalar probe is then cheaper than that many
    /// SIMD compares per chunk).
    fn firstRanges(set: ByteSet, out: *[max_ranges]Range) ?u8 {
        var n: u8 = 0;
        var c: usize = 0;
        while (c < 256) {
            if (!set.has(@intCast(c))) {
                c += 1;
                continue;
            }
            const lo: u8 = @intCast(c);
            while (c < 256 and set.has(@intCast(c))) c += 1;
            if (n == max_ranges) return null;
            out[n] = .{ .lo = lo, .hi = @intCast(c - 1) };
            n += 1;
        }
        return n;
    }

    /// Collect every byte that can be the FIRST consumed byte of a match at SOME
    /// position — a sound superset that lets the scanner skip spans containing
    /// none of them. `^` (assert_start) is *traversed*, not blocked: it holds at
    /// line starts, where the scanner does seed (with the right `at_start` flag),
    /// so a `^p…` branch's `p` must be reachable — at a mid-line `p` the seeded
    /// thread simply dies on the failed assertion, never a false positive. `$`
    /// (assert_end) is blocked: a byte can't be consumed after the line ends.
    /// Iterative (worklist) to bound stack depth under `{n}`-expanded programs.
    fn analyzeFirst(gpa: std.mem.Allocator, states: []const State, start: u32, out: *ByteSet) ParseError!void {
        const visited = try gpa.alloc(bool, states.len);
        defer gpa.free(visited);
        @memset(visited, false);
        const stack = try gpa.alloc(u32, states.len);
        defer gpa.free(stack);
        var sp: usize = 1;
        stack[0] = start;
        visited[start] = true;
        const push = struct {
            fn f(t: u32, vis: []bool, st: []u32, n: *usize) void {
                if (!vis[t]) {
                    vis[t] = true;
                    st[n.*] = t;
                    n.* += 1;
                }
            }
        }.f;
        while (sp > 0) {
            sp -= 1;
            switch (states[stack[sp]]) {
                .consume => |cn| out.unionWith(cn.set),
                .split => |spl| {
                    push(spl.a, visited, stack, &sp);
                    push(spl.b, visited, stack, &sp);
                },
                .assert_start => |o| push(o, visited, stack, &sp), // holds at line start
                .assert_end, .match => {}, // `$`: no byte follows; match: zero-width
            }
        }
    }

    /// Own a copy of the alternation cover set (empty when a single-literal
    /// prefilter already applies, i.e. `best` ≥ 3, or none is provable).
    fn dupeCover(gpa: std.mem.Allocator, arena: std.mem.Allocator, ast: *Node, best: []const u8) ParseError![]const []const u8 {
        if (best.len >= 3) return &[_][]const u8{}; // single-literal prefilter wins
        const cover = (try syn.requiredAny(arena, ast)) orelse return &[_][]const u8{};
        if (cover.len == 0) return &[_][]const u8{};
        const dst = try gpa.alloc([]const u8, cover.len);
        var n: usize = 0;
        errdefer {
            for (dst[0..n]) |s| gpa.free(s);
            gpa.free(dst);
        }
        for (cover) |s| {
            dst[n] = try gpa.dupe(u8, s);
            n += 1;
        }
        return dst;
    }

    /// Lowers the AST into a flat NFA-state program (Thompson construction).
    const Compiler = struct {
        states: std.ArrayList(State) = .empty,
        gpa: std.mem.Allocator,

        fn push(self: *Compiler, s: State) ParseError!u32 {
            try self.states.append(self.gpa, s);
            return @intCast(self.states.items.len - 1);
        }

        /// Compile `node` so all its exits flow to state `next`; return its entry.
        fn compileNode(self: *Compiler, node: *Node, next: u32) ParseError!u32 {
            switch (node.*) {
                .empty => return next,
                .anchor_start => return self.push(.{ .assert_start = next }),
                .anchor_end => return self.push(.{ .assert_end = next }),
                .class => |set| return self.push(.{ .consume = .{ .set = set, .out = next } }),
                .concat => |ab| {
                    const s2 = try self.compileNode(ab[1], next);
                    return self.compileNode(ab[0], s2);
                },
                .alt => |ab| {
                    const sa = try self.compileNode(ab[0], next);
                    const sb = try self.compileNode(ab[1], next);
                    return self.push(.{ .split = .{ .a = sa, .b = sb } });
                },
                .quest => |x| {
                    const sx = try self.compileNode(x, next);
                    return self.push(.{ .split = .{ .a = sx, .b = next } });
                },
                .star, .plus => |x, tag| {
                    const sp = try self.push(.{ .split = .{ .a = 0, .b = next } });
                    const sx = try self.compileNode(x, sp);
                    self.states.items[sp].split.a = sx;
                    // star enters at the split (zero iters OK); plus enters at x (run once, then loop back via the split).
                    return if (tag == .star) sp else sx;
                },
            }
        }
    };

    /// A run-list of active states: a program-sized fixed buffer plus a fill cursor (capacity bounded by `states.len` — `Sim.seen` dedup adds each state at most once per generation).
    const ThreadList = struct {
        buf: []u32,
        len: usize = 0,

        fn push(self: *ThreadList, s: u32) void {
            self.buf[self.len] = s;
            self.len += 1;
        }
        fn slice(self: ThreadList) []const u32 {
            return self.buf[0..self.len];
        }
    };

    /// Reusable Pike-simulation scratch (sized to the program once).
    pub const Sim = struct {
        cur: ThreadList,
        nxt: ThreadList,
        seen: []u32,
        gen: u32 = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!Sim {
            const n = re.states.len;
            const seen = try allocator.alloc(u32, n);
            @memset(seen, 0);
            return .{
                .cur = .{ .buf = try allocator.alloc(u32, n) },
                .nxt = .{ .buf = try allocator.alloc(u32, n) },
                .seen = seen,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *Sim) void {
            self.allocator.free(self.cur.buf);
            self.allocator.free(self.nxt.buf);
            self.allocator.free(self.seen);
            self.* = undefined;
        }
    };

    /// One epsilon-closure pass at a fixed input position; bundles the invariants (target `list`, per-pass `seen`/`gen` dedup, position flags) so the recursion carries only the varying state index.
    const Closure = struct {
        re: *const Regex,
        list: *ThreadList,
        seen: []u32,
        gen: u32,
        at_start: bool,
        at_end: bool,

        /// Epsilon-closure of `s` into `list`; returns whether it reached the match state (so `lineMatch` answers without a second list scan). Zero-width anchors resolve against `at_start`/`at_end` — a failed assertion just kills that branch (the position is fixed across one closure).
        fn add(c: Closure, s: u32) bool {
            if (c.seen[s] == c.gen) return false;
            c.seen[s] = c.gen;
            return switch (c.re.states[s]) {
                .split => |sp| blk: {
                    // Bind both arms first — `or` short-circuits, but both must close.
                    const a = c.add(sp.a);
                    break :blk a or c.add(sp.b);
                },
                .assert_start => |out| c.at_start and c.add(out),
                .assert_end => |out| c.at_end and c.add(out),
                else => blk: {
                    c.list.push(s);
                    break :blk c.re.states[s] == .match;
                },
            };
        }
    };

    fn closure(re: *const Regex, sim: *Sim, list: *ThreadList, at_start: bool, at_end: bool) Closure {
        return .{ .re = re, .list = list, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end };
    }

    const Scan = enum { anchored, skip, plain };

    /// Does the pattern match any substring of `line`? Linear in `line.len`.
    /// Dispatches to the cheapest sound strategy: `^…` seeds only at line start
    /// (`.anchored`); a known first-byte set drives a `memchr`-skip search
    /// (`.skip`); otherwise the plain re-seed-every-position search (`.plain`,
    /// e.g. a bare `$` whose first set is empty).
    pub fn lineMatch(re: *const Regex, sim: *Sim, line: []const u8) bool {
        if (re.anchored) return re.search(sim, line, .anchored);
        if (re.first.count() != 0) return re.search(sim, line, .skip);
        return re.search(sim, line, .plain);
    }

    /// Next index ≥ `from` whose byte can begin a match. Three tiers: SIMD
    /// `indexOfScalar` for a singleton set (`;$`), a SIMD range scan for a few
    /// contiguous ranges (`[0-9]{4}`, `[a-f0-9]{2,}`), and a scalar byteset probe
    /// for anything wider (a negated class).
    fn nextStart(re: *const Regex, line: []const u8, from: usize) ?usize {
        if (re.first_byte) |b| return std.mem.indexOfScalarPos(u8, line, from, b);
        if (re.first_nranges > 0) return re.nextStartRange(line, from);
        var j = from;
        while (j < line.len) : (j += 1) if (re.first.has(line[j])) return j;
        return null;
    }

    /// Vectorized hunt for the first byte falling in any of `first_ranges`: one
    /// `lo ≤ b ≤ hi` compare per range across a `vlen`-wide window, OR the lane
    /// masks, take the lowest set lane. The scalar tail handles the remainder.
    fn nextStartRange(re: *const Regex, line: []const u8, from: usize) ?usize {
        const Vec = @Vector(vlen, u8);
        const Mask = std.meta.Int(.unsigned, vlen);
        const ranges = re.first_ranges[0..re.first_nranges];
        var i = from;
        while (i + vlen <= line.len) : (i += vlen) {
            const blk: Vec = line[i..][0..vlen].*;
            var hit: @Vector(vlen, bool) = @splat(false);
            for (ranges) |rg| {
                const lo: Vec = @splat(rg.lo);
                const hi: Vec = @splat(rg.hi);
                hit |= (blk >= lo) & (blk <= hi);
            }
            const bits: Mask = @bitCast(hit);
            if (bits != 0) return i + @ctz(bits);
        }
        while (i < line.len) : (i += 1) if (re.first.has(line[i])) return i;
        return null;
    }

    /// Unified Pike search, specialized at comptime by seeding policy:
    ///   `.anchored` — never re-seed; the instant the thread list drains, done
    ///                 (a match can only begin at line position 0).
    ///   `.skip`     — re-seed a start only where a byte could begin a match, and
    ///                 when the list empties jump to the next such byte (skipping
    ///                 dead spans the way rg's literal prefilter does). Equivalent
    ///                 to seeding every position — a start whose first byte isn't
    ///                 in `first` dies at once — minus the wasted closure work.
    ///   `.plain`    — re-seed the start at every position (first set empty).
    fn search(re: *const Regex, sim: *Sim, line: []const u8, comptime mode: Scan) bool {
        sim.gen += 1;
        sim.cur.len = 0;
        // Position 0: line start; also the end iff the line is empty. Answers any
        // empty/zero-width match (`a*`, `^$`) without scanning.
        if (re.closure(sim, &sim.cur, true, line.len == 0).add(re.start)) return true;
        if (mode == .skip) sim.cur.len = 0; // drive purely by first-byte jumps
        var i: usize = 0;
        while (i < line.len) {
            if (sim.cur.len == 0) switch (mode) {
                .anchored => return false, // no live thread, no new start allowed
                .skip => {
                    i = re.nextStart(line, i) orelse return false;
                    sim.gen += 1;
                    sim.cur.len = 0;
                    if (re.closure(sim, &sim.cur, i == 0, i + 1 == line.len).add(re.start)) return true;
                },
                .plain => {},
            };
            const c = line[i];
            sim.nxt.len = 0;
            sim.gen += 1;
            const cl = re.closure(sim, &sim.nxt, false, i + 1 == line.len);
            var matched = false;
            for (sim.cur.slice()) |s| switch (re.states[s]) {
                .consume => |cn| if (cn.set.has(c) and cl.add(cn.out)) {
                    matched = true;
                },
                else => {},
            };
            switch (mode) { // re-seed the next start per policy
                .anchored => {},
                .plain => if (cl.add(re.start)) {
                    matched = true;
                },
                .skip => if (i + 1 < line.len and re.first.has(line[i + 1]) and cl.add(re.start)) {
                    matched = true;
                },
            }
            std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
            if (matched) return true;
            i += 1;
        }
        return false;
    }

    /// Does any line of `doc` match? rg `-l` line model: `\n` *terminates* a line, so a trailing newline yields no phantom empty final line (only a real blank line matches `^$`) — content after the last `\n` (no terminator) is still a line. (`splitScalar` would emit the phantom and over-match `^$`/`$` on every newline-terminated file vs ripgrep.)
    pub fn docMatch(re: *const Regex, sim: *Sim, doc: []const u8) bool {
        var rest = doc;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            if (re.lineMatch(sim, rest[0..end])) return true;
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return false;
    }
};
