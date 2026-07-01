//! gist — regex *capture* extraction: a Pike VM that reports group boundaries.
//!
//! The primary engine (`core.zig` DFA + Pike) answers *whether* / *where* a line
//! matches — it is deliberately capture-free (a byte-class DFA can't track group
//! spans, and 99% of grep never needs them). `-r`/`--replace` and `--json`, though,
//! need each capturing group's byte span, so this module compiles the SAME
//! `syntax.zig` AST into a small program WITH `save` instructions and runs a
//! classic priority-ordered Pike simulation (Russ Cox / RE2 style) that threads a
//! slot vector through the ε-closure. It is intentionally separate: the AST's
//! `capture` node is transparent to the main engine (identical boolean semantics),
//! and this slower slot-carrying VM only runs when a replacement/JSON emit asks
//! for groups — never on the hot search path.

const std = @import("std");
const syn = @import("syntax.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

/// A capture-VM instruction. `save{slot}` records the current input position into
/// a thread's slot (group `g` uses slots `2g`/`2g+1`; group 0 = whole match).
const Inst = union(enum) {
    char: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    save: struct { slot: u32, out: u32 },
    astart: u32,
    aend: u32,
    awb: u32,
    anwb: u32,
    match,
};

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}
fn wordAt(line: []const u8, p: usize) bool {
    return p < line.len and isWord(line[p]);
}
fn wordBefore(line: []const u8, p: usize) bool {
    return p > 0 and isWord(line[p - 1]);
}

/// A compiled capture matcher: the program plus per-find scratch. `nslots` =
/// `2*(ngroups+1)`; `slots[2g]`/`slots[2g+1]` bracket group `g` (0 = whole match).
pub const Captures = struct {
    prog: []Inst,
    start: u32,
    ngroups: u32,
    nslots: usize,
    names: []syn.NamedCap,
    allocator: std.mem.Allocator,

    // Reused across finds: the two thread lists, the per-generation dedup, and the
    // slot snapshot for each program counter (valid for its list generation).
    cur: []u32,
    nxt: []u32,
    seen: []u32,
    cslots: [][]isize,
    nslots_buf: [][]isize,
    gen: u32 = 0,

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, caseless: bool) ParseError!Captures {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var names: std.ArrayList(syn.NamedCap) = .empty;
        var parser = syn.Parser{ .src = pattern, .arena = arena, .names = &names };
        const ast = try parser.parseAlt();
        if (parser.pos != pattern.len) return ParseError.BadPattern;
        if (caseless) syn.foldCaseAst(ast);

        var c = Comp{ .gpa = gpa };
        errdefer c.prog.deinit(gpa);
        const m = try c.push(.match);
        const close0 = try c.push(.{ .save = .{ .slot = 1, .out = m } });
        const body = try c.compileNode(ast, close0);
        const start = try c.push(.{ .save = .{ .slot = 0, .out = body } });

        const ngroups = parser.ncaps;
        const nslots = 2 * (ngroups + 1);
        // The ε-closure copies the slot vector onto a fixed 64-wide stack buffer per
        // `save`; cap groups so it never overflows (31 groups is far beyond any
        // replacement/JSON case in practice).
        if (nslots > 64) return ParseError.BadPattern;
        const prog = try c.prog.toOwnedSlice(gpa);
        errdefer gpa.free(prog);
        const n = prog.len;

        const owned_names = try gpa.dupe(syn.NamedCap, names.items);
        // The name slices point into `pattern` (caller-owned, outlives us) — dupe
        // them so a transient pattern buffer can't dangle.
        errdefer gpa.free(owned_names);
        for (owned_names) |*nc| nc.name = try gpa.dupe(u8, nc.name);

        const cslots = try gpa.alloc([]isize, n);
        const nslots_buf = try gpa.alloc([]isize, n);
        for (cslots, nslots_buf) |*a, *b| {
            a.* = try gpa.alloc(isize, nslots);
            b.* = try gpa.alloc(isize, nslots);
        }
        return .{
            .prog = prog,
            .start = start,
            .ngroups = ngroups,
            .nslots = nslots,
            .names = owned_names,
            .allocator = gpa,
            .cur = try gpa.alloc(u32, n),
            .nxt = try gpa.alloc(u32, n),
            .seen = try gpa.alloc(u32, n),
            .cslots = cslots,
            .nslots_buf = nslots_buf,
        };
    }

    pub fn deinit(self: *Captures) void {
        const g = self.allocator;
        for (self.cslots, self.nslots_buf) |a, b| {
            g.free(a);
            g.free(b);
        }
        g.free(self.cslots);
        g.free(self.nslots_buf);
        g.free(self.cur);
        g.free(self.nxt);
        g.free(self.seen);
        for (self.names) |nc| g.free(nc.name);
        g.free(self.names);
        g.free(self.prog);
        self.* = undefined;
    }

    pub fn groupByName(self: *const Captures, name: []const u8) ?u32 {
        for (self.names) |nc| if (std.mem.eql(u8, nc.name, name)) return nc.idx;
        return null;
    }

    /// Leftmost-first match of the whole pattern within `line[from..]`. On success
    /// fills `out` (length `nslots`) with byte offsets (−1 = unset) and returns
    /// true; `out[0]`/`out[1]` bracket the whole match. Priority mirrors the main
    /// engine: leftmost start, earliest alternation branch, greedy quantifiers.
    pub fn find(self: *Captures, line: []const u8, from: usize, out: []isize) bool {
        const St = struct {
            list: []u32,
            len: usize = 0,
            slots: [][]isize,
        };
        var clist = St{ .list = self.cur, .slots = self.cslots };
        var nlist = St{ .list = self.nxt, .slots = self.nslots_buf };

        const init_slots = out; // reuse the caller's buffer as the seed vector

        self.gen += 1;
        clist.len = 0;
        @memset(init_slots, -1);
        self.addThread(&clist.list, &clist.len, clist.slots, self.start, init_slots, from, line);

        var have = false;
        var cut = clist.len;
        if (self.firstMatch(clist.list[0..clist.len])) |mi| {
            @memcpy(out, clist.slots[clist.list[mi]]);
            have = true;
            cut = mi;
        }

        var i: usize = from;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            self.gen += 1;
            nlist.len = 0;
            for (clist.list[0..cut]) |pc| switch (self.prog[pc]) {
                .char => |cn| if (cn.set.has(ch))
                    self.addThread(&nlist.list, &nlist.len, nlist.slots, cn.out, clist.slots[pc], i + 1, line),
                else => {},
            };
            if (!have) {
                @memset(init_slots, -1);
                self.addThread(&nlist.list, &nlist.len, nlist.slots, self.start, init_slots, i + 1, line);
            }
            std.mem.swap(St, &clist, &nlist);
            cut = clist.len;
            if (self.firstMatch(clist.list[0..clist.len])) |mi| {
                @memcpy(out, clist.slots[clist.list[mi]]);
                have = true;
                cut = mi;
            }
            if (have and cut == 0) break;
        }
        return have;
    }

    /// First `.match` pc in priority order, or null.
    fn firstMatch(self: *const Captures, list: []const u32) ?usize {
        for (list, 0..) |pc, k| if (self.prog[pc] == .match) return k;
        return null;
    }

    /// ε-closure of `pc` into `list`, applying `save`/assertions at input position
    /// `pos`. Threads carry `slots` (copied on each `save` so branches don't alias);
    /// a `char`/`match` pc is appended and its slot snapshot recorded.
    fn addThread(self: *Captures, list: *[]u32, len: *usize, slots: [][]isize, pc: u32, in_slots: []const isize, pos: usize, line: []const u8) void {
        if (self.seen[pc] == self.gen) return;
        self.seen[pc] = self.gen;
        switch (self.prog[pc]) {
            .split => |sp| {
                self.addThread(list, len, slots, sp.a, in_slots, pos, line);
                self.addThread(list, len, slots, sp.b, in_slots, pos, line);
            },
            .save => |sv| {
                var tmp: [64]isize = undefined;
                const buf = tmp[0..self.nslots];
                @memcpy(buf, in_slots);
                buf[sv.slot] = @intCast(pos);
                self.addThread(list, len, slots, sv.out, buf, pos, line);
            },
            .astart => |o| if (pos == 0) self.addThread(list, len, slots, o, in_slots, pos, line),
            .aend => |o| if (pos == line.len) self.addThread(list, len, slots, o, in_slots, pos, line),
            .awb => |o| if (wordBefore(line, pos) != wordAt(line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
            .anwb => |o| if (wordBefore(line, pos) == wordAt(line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
            .char, .match => {
                list.*[len.*] = pc;
                @memcpy(slots[pc], in_slots);
                len.* += 1;
            },
        }
    }
};

/// AST → capture-program lowering (the `save`-emitting sibling of `compile.zig`).
const Comp = struct {
    prog: std.ArrayList(Inst) = .empty,
    gpa: std.mem.Allocator,

    fn push(self: *Comp, s: Inst) ParseError!u32 {
        try self.prog.append(self.gpa, s);
        return @intCast(self.prog.items.len - 1);
    }

    fn compileNode(self: *Comp, node: *Node, next: u32) ParseError!u32 {
        switch (node.*) {
            .empty => return next,
            .anchor_start => return self.push(.{ .astart = next }),
            .anchor_end => return self.push(.{ .aend = next }),
            .word_boundary => return self.push(.{ .awb = next }),
            .not_word_boundary => return self.push(.{ .anwb = next }),
            .class => |set| return self.push(.{ .char = .{ .set = set, .out = next } }),
            .capture => |g| {
                const close = try self.push(.{ .save = .{ .slot = 2 * g.idx + 1, .out = next } });
                const body = try self.compileNode(g.child, close);
                return self.push(.{ .save = .{ .slot = 2 * g.idx, .out = body } });
            },
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
                self.prog.items[sp].split.a = sx;
                return if (tag == .star) sp else sx;
            },
        }
    }
};
