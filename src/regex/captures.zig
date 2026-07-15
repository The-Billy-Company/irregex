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
const compile_mod = @import("compile.zig");
const udec = @import("unicode/decode.zig");
const utables = @import("unicode/tables.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

/// PCRE2's capture twin — the `-P -r` arm of the `Caps` union below.
pub const PcreCaptures = @import("pcre2/captures.zig").PcreCaptures;

/// The engine-neutral capture seam for `-r`/`--replace` and `--json` submatches,
/// mirroring `matcher.zig`'s `Matcher`: the linear Pike VM (`Captures`) or the
/// PCRE2 capture engine (`PcreCaptures`), behind the three primitives the
/// replacement expander needs — `nslots` (slot-vector width), `find` (fill a
/// match's group offsets), `groupByName` (`${name}` → number). The output layer
/// names `Caps` without knowing which engine produced the groups; the `-r`
/// template expansion (`expandInto`) is byte-identical to ripgrep either way.
pub const Caps = union(enum) {
    linear: Captures,
    pcre: PcreCaptures,

    pub fn nslots(self: *const Caps) usize {
        return switch (self.*) {
            .linear => |*c| c.nslots,
            .pcre => |*c| c.nslots,
        };
    }
    pub fn find(self: *Caps, line: []const u8, from: usize, out: []isize) bool {
        return switch (self.*) {
            .linear => |*c| c.find(line, from, out),
            .pcre => |*c| c.find(line, from, out),
        };
    }
    pub fn groupByName(self: *const Caps, name: []const u8) ?u32 {
        return switch (self.*) {
            .linear => |*c| c.groupByName(name),
            .pcre => |*c| c.groupByName(name),
        };
    }
    pub fn deinit(self: *Caps) void {
        switch (self.*) {
            .linear => |*c| c.deinit(),
            .pcre => |*c| c.deinit(),
        }
    }
};

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
    awstart: u32, // `\<` — word start (¬word|word)
    awend: u32, // `\>` — word end (word|¬word)
    match,
};

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}
/// Word-ness of the codepoint STARTING at gap `p` (Unicode mode decodes forward;
/// ASCII/`(?-u)` mode is the single-byte test) — see `core.zig` for the contract.
fn wordAt(unicode: bool, line: []const u8, p: usize) bool {
    if (p >= line.len) return false;
    if (!unicode or line[p] < 0x80) return isWordByte(line[p]);
    const d = udec.decode(line[p..]) orelse return false;
    return utables.isWord(d.cp);
}
/// Word-ness of the codepoint ending just BEFORE gap `p` (Unicode mode decodes
/// backward via `decodeLast`; ASCII mode is the single-byte test).
fn wordBefore(unicode: bool, line: []const u8, p: usize) bool {
    if (p == 0) return false;
    if (!unicode or line[p - 1] < 0x80) return isWordByte(line[p - 1]);
    const d = udec.decodeLast(line[0..p]) orelse return false;
    return utables.isWord(d.cp);
}

/// A compiled capture matcher: the program plus per-find scratch. `nslots` =
/// `2*(ngroups+1)`; `slots[2g]`/`slots[2g+1]` bracket group `g` (0 = whole match).
pub const Captures = struct {
    prog: []Inst,
    start: u32,
    ngroups: u32,
    nslots: usize,
    names: []syn.NamedCap,
    // Unicode mode (rg default): drives the `\b`/`\B`/`\<`/`\>` word test to
    // decode the straddling codepoint, matching the main engine. Class/literal
    // Unicode is baked into `prog` at parse time.
    unicode: bool,
    allocator: std.mem.Allocator,

    // Reused across finds: the two thread lists, the per-generation dedup, and the
    // slot snapshot for each program counter (valid for its list generation).
    cur: []u32,
    nxt: []u32,
    seen: []u32,
    cslots: [][]isize,
    nslots_buf: [][]isize,
    gen: u32 = 0,

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, caseless: bool, unicode: bool) ParseError!Captures {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var names: std.ArrayList(syn.NamedCap) = .empty;
        var parser = syn.Parser{ .src = pattern, .arena = arena, .names = &names, .unicode = unicode };
        const ast = try parser.parseAlt();
        if (parser.pos != pattern.len) return ParseError.BadPattern;
        if (caseless) try syn.foldCaseAst(arena, ast, unicode);

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
            .unicode = unicode,
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
            .awb => |o| if (wordBefore(self.unicode, line, pos) != wordAt(self.unicode, line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
            .anwb => |o| if (wordBefore(self.unicode, line, pos) == wordAt(self.unicode, line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
            .awstart => |o| if (!wordBefore(self.unicode, line, pos) and wordAt(self.unicode, line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
            .awend => |o| if (wordBefore(self.unicode, line, pos) and !wordAt(self.unicode, line, pos)) self.addThread(list, len, slots, o, in_slots, pos, line),
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

    // The two hooks `compile_mod.lowerUtf8` drives to weave a `uclass` into a
    // UTF-8 byte trie over this VM's own instruction set (byte-range `char` +
    // `split`), so the boolean compiler and the capture VM share one lowering.
    pub fn emitConsume(self: *Comp, lo: u8, hi: u8, out: u32) ParseError!u32 {
        var set = ByteSet{};
        set.setRange(lo, hi);
        return self.push(.{ .char = .{ .set = set, .out = out } });
    }
    pub fn emitSplit(self: *Comp, a: u32, b: u32) ParseError!u32 {
        return self.push(.{ .split = .{ .a = a, .b = b } });
    }

    fn compileNode(self: *Comp, node: *Node, next: u32) ParseError!u32 {
        switch (node.*) {
            .empty => return next,
            .anchor_start => return self.push(.{ .astart = next }),
            .anchor_end => return self.push(.{ .aend = next }),
            // The captures parser never sets `multiline` (the CLI serves `-r`/
            // `--json` per line only), so `\A`/`\z` already lowered to the line
            // anchors above; the whole-buffer variants cannot occur here.
            .anchor_buf_start, .anchor_buf_end => unreachable,
            .word_boundary => return self.push(.{ .awb = next }),
            .not_word_boundary => return self.push(.{ .anwb = next }),
            .word_start => return self.push(.{ .awstart = next }),
            .word_end => return self.push(.{ .awend = next }),
            .class => |set| return self.push(.{ .char = .{ .set = set, .out = next } }),
            .uclass => |ranges| return compile_mod.lowerUtf8(self.gpa, ranges, next, self),
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
            .quest => |r| {
                const sx = try self.compileNode(r.node, next);
                // Greedy prefers the body (`.a` = higher priority in the Pike VM),
                // lazy prefers the exit — this is what makes captured spans minimal.
                return self.push(if (r.lazy) .{ .split = .{ .a = next, .b = sx } } else .{ .split = .{ .a = sx, .b = next } });
            },
            .star, .plus => |r, tag| {
                const sp = try self.push(.{ .split = .{ .a = 0, .b = 0 } });
                const sx = try self.compileNode(r.node, sp);
                self.prog.items[sp].split = if (r.lazy) .{ .a = next, .b = sx } else .{ .a = sx, .b = next };
                return if (tag == .star) sp else sx;
            },
        }
    }
};
