//! gist — T2 regex execution: a linear-time Thompson NFA over bytes (RE2 /
//! ripgrep philosophy — no backtracking, no catastrophic blowup), compiled from
//! the AST in `regex_syntax.zig` and run with a Pike simulation. Plus the public
//! `Regex` handle carrying the required-literal that lets a regex reuse the T0
//! trigram prefilter.
//!
//! Grep semantics: a line matches if the pattern matches ANY substring of it
//! (unanchored). We never construct `.*pat.*`; the Pike simulation re-seeds the
//! start thread at every position — the standard linear search. Anchors
//! (`^ $ \b`) and Unicode classes are out of scope this tier; the equality
//! oracle runs `rg (?-u)…` so semantics coincide exactly.

const std = @import("std");
const syn = @import("regex_syntax.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

const State = union(enum) {
    consume: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
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

        var states: std.ArrayList(State) = .empty;
        errdefer states.deinit(allocator);
        const match_idx = try push(&states, allocator, .match);
        const start = try compileNode(&states, allocator, ast, match_idx);

        const req = try syn.literalInfo(arena, ast);
        return .{
            .states = try states.toOwnedSlice(allocator),
            .start = start,
            .required = try allocator.dupe(u8, req.best),
            .allocator = allocator,
        };
    }

    fn push(states: *std.ArrayList(State), gpa: std.mem.Allocator, s: State) ParseError!u32 {
        try states.append(gpa, s);
        return @intCast(states.items.len - 1);
    }

    /// Compile `node` so all its exits flow to state `next`; return its entry.
    fn compileNode(states: *std.ArrayList(State), gpa: std.mem.Allocator, node: *Node, next: u32) ParseError!u32 {
        switch (node.*) {
            .empty => return next,
            .class => |set| return push(states, gpa, .{ .consume = .{ .set = set, .out = next } }),
            .concat => |ab| {
                const s2 = try compileNode(states, gpa, ab[1], next);
                return compileNode(states, gpa, ab[0], s2);
            },
            .alt => |ab| {
                const sa = try compileNode(states, gpa, ab[0], next);
                const sb = try compileNode(states, gpa, ab[1], next);
                return push(states, gpa, .{ .split = .{ .a = sa, .b = sb } });
            },
            .quest => |x| {
                const sx = try compileNode(states, gpa, x, next);
                return push(states, gpa, .{ .split = .{ .a = sx, .b = next } });
            },
            .star => |x| {
                const sp = try push(states, gpa, .{ .split = .{ .a = 0, .b = next } });
                const sx = try compileNode(states, gpa, x, sp);
                states.items[sp].split.a = sx;
                return sp;
            },
            .plus => |x| {
                const sp = try push(states, gpa, .{ .split = .{ .a = 0, .b = next } });
                const sx = try compileNode(states, gpa, x, sp);
                states.items[sp].split.a = sx;
                return sx; // run x once, then loop via the split
            },
        }
    }

    /// Reusable Pike-simulation scratch (sized to the program once).
    pub const Sim = struct {
        cur: []u32,
        nxt: []u32,
        seen: []u32,
        gen: u32 = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, re: *const Regex) ParseError!Sim {
            const n = re.states.len;
            const seen = try allocator.alloc(u32, n);
            @memset(seen, 0);
            return .{
                .cur = try allocator.alloc(u32, n),
                .nxt = try allocator.alloc(u32, n),
                .seen = seen,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *Sim) void {
            self.allocator.free(self.cur);
            self.allocator.free(self.nxt);
            self.allocator.free(self.seen);
            self.* = undefined;
        }
    };

    fn addThread(re: *const Regex, list: []u32, len: *usize, seen: []u32, gen: u32, s: u32) void {
        if (seen[s] == gen) return;
        seen[s] = gen;
        switch (re.states[s]) {
            .split => |sp| {
                re.addThread(list, len, seen, gen, sp.a);
                re.addThread(list, len, seen, gen, sp.b);
            },
            else => {
                list[len.*] = s;
                len.* += 1;
            },
        }
    }

    /// Does the pattern match any substring of `line`? Linear in `line.len`.
    pub fn lineMatch(re: *const Regex, sim: *Sim, line: []const u8) bool {
        var cur_len: usize = 0;
        sim.gen += 1;
        re.addThread(sim.cur, &cur_len, sim.seen, sim.gen, re.start);
        for (sim.cur[0..cur_len]) |s| if (re.states[s] == .match) return true;

        for (line) |c| {
            var nxt_len: usize = 0;
            sim.gen += 1;
            for (sim.cur[0..cur_len]) |s| {
                switch (re.states[s]) {
                    .consume => |cn| if (cn.set.has(c)) re.addThread(sim.nxt, &nxt_len, sim.seen, sim.gen, cn.out),
                    else => {},
                }
            }
            re.addThread(sim.nxt, &nxt_len, sim.seen, sim.gen, re.start); // unanchored re-seed
            std.mem.swap([]u32, &sim.cur, &sim.nxt);
            cur_len = nxt_len;
            for (sim.cur[0..cur_len]) |s| if (re.states[s] == .match) return true;
        }
        return false;
    }

    /// Does any '\n'-delimited line of `doc` match? (rg `-l` semantics).
    pub fn docMatch(re: *const Regex, sim: *Sim, doc: []const u8) bool {
        var start: usize = 0;
        while (start <= doc.len) {
            const nl = std.mem.indexOfScalarPos(u8, doc, start, '\n');
            const end = nl orelse doc.len;
            if (re.lineMatch(sim, doc[start..end])) return true;
            if (nl == null) break;
            start = end + 1;
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
