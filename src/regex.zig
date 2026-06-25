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
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.states);
        self.allocator.free(self.required);
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
        return .{
            .states = try c.states.toOwnedSlice(allocator),
            .start = start,
            .required = try allocator.dupe(u8, req.best),
            .allocator = allocator,
        };
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

    /// Does the pattern match any substring of `line`? Linear in `line.len`.
    pub fn lineMatch(re: *const Regex, sim: *Sim, line: []const u8) bool {
        sim.cur.len = 0;
        sim.gen += 1;
        // Position 0: start of line; also the end iff the line is empty.
        if (re.closure(sim, &sim.cur, true, line.len == 0).add(re.start)) return true;

        for (line, 0..) |c, i| {
            sim.nxt.len = 0;
            sim.gen += 1;
            // Threads seeded below sit at position i+1 — never line start, line end exactly when the byte just consumed was the last.
            const cl = re.closure(sim, &sim.nxt, false, i + 1 == line.len);
            var matched = false;
            for (sim.cur.slice()) |s| switch (re.states[s]) {
                .consume => |cn| if (cn.set.has(c) and cl.add(cn.out)) {
                    matched = true;
                },
                else => {},
            };
            if (cl.add(re.start)) matched = true; // unanchored re-seed
            std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
            if (matched) return true;
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

// ── tests ─────────────────────────────────────────────────────────────────

fn matches(pattern: []const u8, line: []const u8) !bool {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    var sim = try Regex.Sim.init(std.testing.allocator, &re);
    defer sim.deinit();
    return re.lineMatch(&sim, line);
}

test "regex: literal substring (unanchored)" {
    try std.testing.expect(try matches("cat", "the cat sat"));
    try std.testing.expect(try matches("cat", "concatenate"));
    try std.testing.expect(!try matches("cat", "the dog ran"));
}

test "regex: dot, star, plus, quest" {
    try std.testing.expect(try matches("a.c", "xxabcyy"));
    try std.testing.expect(!try matches("a.c", "ac"));
    try std.testing.expect(try matches("ab*c", "ac"));
    try std.testing.expect(try matches("ab*c", "abbbbc"));
    try std.testing.expect(try matches("ab+c", "abc"));
    try std.testing.expect(!try matches("ab+c", "ac"));
    try std.testing.expect(try matches("colou?r", "color"));
    try std.testing.expect(try matches("colou?r", "colour")); // spellchecker:disable-line
}

test "regex: alternation and groups" {
    try std.testing.expect(try matches("cat|dog", "the dog ran"));
    try std.testing.expect(try matches("(foo|bar)baz", "xxbarbazyy"));
    try std.testing.expect(!try matches("(foo|bar)baz", "bazonly"));
}

test "regex: classes and escapes" {
    try std.testing.expect(try matches("[0-9]+", "abc123"));
    try std.testing.expect(!try matches("[0-9]+", "abcdef"));
    try std.testing.expect(try matches("\\d\\w*", "x9_yz"));
    try std.testing.expect(try matches("func\\s+\\w+\\(", "func  Foo("));
    try std.testing.expect(try matches("[^a-z]", "ABC"));
    try std.testing.expect(try matches("a\\.b", "xa.b"));
    try std.testing.expect(!try matches("a\\.b", "axb")); // escaped dot is literal
}

test "regex: '.' does not cross newline within a line search" {
    try std.testing.expect(!try matches("a.b", "a\nb"));
}

test "regex: ^ anchors to line start" {
    try std.testing.expect(try matches("^func", "func main"));
    try std.testing.expect(!try matches("^func", "  func main")); // not at start
    try std.testing.expect(try matches("^a.c", "abc")); // anchored + dot
    try std.testing.expect(try matches("\\^x", "a^xb")); // escaped caret is literal
    try std.testing.expect(!try matches("\\^x", "ax")); // … so a bare 'x' won't do
}

test "regex: $ anchors to line end" {
    try std.testing.expect(try matches("nil$", "return nil"));
    try std.testing.expect(!try matches("nil$", "nil pointer")); // not at end
    try std.testing.expect(try matches(";$", "x := 1;"));
    try std.testing.expect(try matches("x\\$", "ax$")); // escaped dollar is literal
}

test "regex: ^…$ whole-line anchoring incl. empty line" {
    try std.testing.expect(try matches("^$", "")); // empty line matches ^$
    try std.testing.expect(!try matches("^$", "x")); // non-empty does not
    try std.testing.expect(try matches("^abc$", "abc")); // exact whole line
    try std.testing.expect(!try matches("^abc$", "abcd")); // trailing byte breaks $
    try std.testing.expect(!try matches("^abc$", "xabc")); // leading byte breaks ^
    try std.testing.expect(try matches("^$", "")); // re-affirm via docMatch below
}

test "regex: anchored required-literal still drives the prefilter" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "^func");
    defer re.deinit();
    try std.testing.expectEqualStrings("func", re.required); // anchor is zero-width
}

test "regex: $ via docMatch picks the right line" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "nil$");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "x := 1\nreturn nil\n}"));
    try std.testing.expect(!re.docMatch(&sim, "nil pointer\nok"));
}

test "regex: pathological (a+)+ stays linear, no catastrophic backtracking" {
    // A backtracking engine hangs on this; Thompson is linear and just answers.
    try std.testing.expect(!try matches("(a+)+z", "aaaaaaaaaaaaaaaaaaaaaaaa!"));
}

test "regex: required-literal extraction for the trigram prefilter" {
    const a = std.testing.allocator;
    {
        var re = try Regex.compile(a, "func\\s+\\w+\\(");
        defer re.deinit();
        try std.testing.expectEqualStrings("func", re.required); // "func" must appear
    }
    {
        var re = try Regex.compile(a, "ab.cd");
        defer re.deinit();
        // best mandatory run is len 2 — no usable ≥3 prefilter, caller scans all.
        try std.testing.expect(re.required.len == 2);
    }
    {
        var re = try Regex.compile(a, "cat|dog");
        defer re.deinit();
        try std.testing.expectEqualStrings("", re.required); // alternation ⇒ none
    }
}

test "regex: docMatch over multi-line doc" {
    const a = std.testing.allocator;
    var re = try Regex.compile(a, "return\\s+nil");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    try std.testing.expect(re.docMatch(&sim, "x := 1\nreturn  nil\n}"));
    try std.testing.expect(!re.docMatch(&sim, "return\nnil")); // split across lines
}
