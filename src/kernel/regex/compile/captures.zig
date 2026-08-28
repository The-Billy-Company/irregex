//! irregex — regex *capture* extraction: a Pike VM that reports group
//! boundaries.
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
const syn = @import("../syntax/syntax.zig");
const compile_mod = @import("compile.zig");
const lower = @import("../linear/program/lower.zig");
const word = @import("../syntax/word.zig");
const closure_mod = @import("../linear/pike/closure.zig");
const ByteSet = syn.ByteSet;
const Node = syn.Node;

pub const ParseError = syn.ParseError;

/// PCRE2's capture twin — the `-P -r` arm of the `Caps` union below.
pub const PcreCaptures = @import("../pcre2/captures.zig").PcreCaptures;

/// The determinized twin of THIS VM — the arm that runs when the pattern is
/// provably one-pass, built from (and falling back to) a `Captures` instance.
pub const OnePass = @import("onepass.zig").OnePass;

/// The engine-neutral capture seam for `-r`/`--replace` and `--json` submatches,
/// mirroring `matcher.zig`'s `Matcher`: the one-pass table (`OnePass`), the
/// general linear Pike VM (`Captures`), or the PCRE2 capture engine
/// (`PcreCaptures`), behind the three primitives the replacement expander needs
/// — `nslots` (slot-vector width), `find` (fill a match's group offsets),
/// `groupByName` (`${name}` → number) — plus that last one inverted,
/// `nameOfGroup`, which no expansion needs but every FFI host walking a match
/// into a keyed record does. The output layer names `Caps` without knowing which
/// engine produced the groups; the `-r` template expansion (`expandInto`) is
/// byte-identical to ripgrep either way.
///
/// The first two arms answer IDENTICALLY by construction — `OnePass` is only
/// chosen for patterns whose ε-closures determinize, and it keeps the `Captures`
/// it was built from as its own fallback — so which one runs is a pure speed
/// decision (`onepass_test.zig` holds it to slot-exact parity).
pub const Caps = union(enum) {
    onepass: OnePass,
    linear: Captures,
    pcre: PcreCaptures,

    pub fn nslots(self: *const Caps) usize {
        return switch (self.*) {
            inline else => |*c| c.nslots,
        };
    }
    pub fn find(self: *Caps, line: []const u8, from: usize, out: []isize) bool {
        return switch (self.*) {
            inline else => |*c| c.find(line, from, out),
        };
    }
    /// `find`, anchored: the match must begin exactly at `from`. Every arm owes
    /// it for the same reason they owe `find` — a caller asking what a byte
    /// position IS (a lexer probe deciding a token) must not be answered about a
    /// position further along that it never reached.
    pub fn matchAt(self: *Caps, line: []const u8, from: usize, out: []isize) bool {
        return switch (self.*) {
            inline else => |*c| c.matchAt(line, from, out),
        };
    }
    pub fn groupByName(self: *const Caps, name: []const u8) ?u32 {
        return switch (self.*) {
            inline else => |*c| c.groupByName(name),
        };
    }
    pub fn nameOfGroup(self: *const Caps, index: u32) ?[]const u8 {
        return switch (self.*) {
            inline else => |*c| c.nameOfGroup(index),
        };
    }
    pub fn deinit(self: *Caps) void {
        switch (self.*) {
            inline else => |*c| c.deinit(),
        }
    }

    /// Which grammar a pattern is written in, and under what semantics. Both
    /// arms read `multiline`/`dotall` — the linear VM resolves `^`/`$` against
    /// `\n` adjacency when `multiline` asks it to (the same `lineStart`/`lineEnd`
    /// predicates the boolean Pike VM consults, so the two engines cannot
    /// disagree about where a line begins), and `dotall` reaches its parser so
    /// `.` spans `\n` exactly where the span arm said the match was. `word`/
    /// `crlf` are the two rewrites that change what the pattern MEANS, so both
    /// arms owe them — a capture program that skipped any of these would report
    /// a different span than the search that asked for it (`-w -r`, `--crlf -r`).
    pub const Selection = struct {
        caseless: bool = false,
        unicode: bool = true,
        pcre: bool = false,
        multiline: bool = false,
        dotall: bool = false,
        word: bool = false,
        crlf: bool = false,

        /// This selection as the linear lowerer's options — the ONE owner of the
        /// mapping, because every derived analysis has to parse under exactly the
        /// options the matcher was built under.
        ///
        /// That is not a tidiness argument. A cover or a literal set derived under
        /// a different `caseless` or `line_anchors` than the engine can require a
        /// trigram no real match contains, or promise a prefix no real match has —
        /// and both fail as a MISSING result rather than a wrong one, which is the
        /// failure mode nothing downstream can notice. It had already forked three
        /// ways (`glean.Options.linear`, the literals plane, the sieve plane), each
        /// copy correct on the day it was written and none of them coupled.
        ///
        /// `multiline` is forced rather than read. Down in `lower.zig` it does not
        /// mean `^`; it is the statement *the haystack is a buffer rather than one
        /// line*, and every `Selection` in existence is minted by
        /// `glean.Options.selection` for a `Pattern`, which is handed whole buffers
        /// by definition. `(?m)` is the separate question, so it rides
        /// `line_anchors` and cannot be inherited by accident — a `Pattern`
        /// compiled per-line finds NO matches for `\s+` over `"a\nb\n"`, not fewer.
        pub fn lowerOptions(self: Selection) lower.Options {
            return .{
                .caseless = self.caseless,
                .unicode = self.unicode,
                .multiline = true,
                .line_anchors = self.multiline,
                .dotall = self.dotall,
                .word = self.word,
                .crlf = self.crlf,
            };
        }
    };

    /// Compile `pattern` into whichever arm it belongs to — the ecosystem's ONE
    /// capture-arm policy: `-P` routes to PCRE2 outright, everything else
    /// compiles the linear VM and then determinizes it when the ε-closures
    /// permit (a pure speed choice; `onepass_test.zig` holds the two to
    /// slot-exact parity).
    ///
    /// It lives on the union rather than in the CLI because both transports
    /// choose here now: `exec/cold/writ/arm.zig` wraps it with `die`, and the C
    /// ABI's `surface/ffi/pattern.zig` reports the same two errors as statuses.
    /// A second copy of this decision is how an in-process capture would start
    /// disagreeing with the same pattern's `--json` submatches.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, sel: Selection) error{ BadPattern, OutOfMemory }!Caps {
        if (sel.pcre) return .{
            .pcre = PcreCaptures.compile(gpa, pattern, .{
                .caseless = sel.caseless,
                .multiline = sel.multiline,
                .dotall = sel.dotall,
                .unicode = sel.unicode,
                .word = sel.word,
            }) catch |e| switch (e) {
                error.OutOfMemory => |oom| return oom,
                // `Unsupported` joins `BadPattern`: to a caller holding one
                // pattern, "PCRE2 refused this" is one answer, and the reason is
                // `pcre2.lastError()`'s to give.
                else => return error.BadPattern,
            },
        };
        const linear = try Captures.compile(gpa, pattern, sel);
        return switch (try OnePass.attach(gpa, linear)) {
            .got => |op| .{ .onepass = op },
            .declined => .{ .linear = linear },
        };
    }
};

/// A capture-VM instruction. `save{slot}` records the current input position into
/// a thread's slot (group `g` uses slots `2g`/`2g+1`; group 0 = whole match).
///
/// Public only for `onepass.zig`, which determinizes this exact program rather
/// than lowering a second one — a fork of the lowering is how the two arms would
/// start disagreeing about what a pattern means.
pub const Inst = union(enum) {
    char: struct { set: ByteSet, out: u32 },
    split: struct { a: u32, b: u32 },
    save: struct { slot: u32, out: u32 },
    astart: u32,
    aend: u32,
    abufstart: u32, // `\A` under multiline — the true buffer start, never a line's
    abufend: u32, // `\z` under multiline — the true buffer end

    aword: struct { mask: syn.Word, out: u32 }, // `\b \B \< \>`, `\b{…}` — see `syntax.Word`
    match,
};

// The shared `\b`/`\B`/`\<`/`\>` word test (`word.zig`) — one definition for
// this VM and the boolean Pike VM, so the two engines can never disagree.
const wordAt = word.wordAt;
const wordBefore = word.wordBefore;

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
    // `(?m)`: `^`/`$` resolve at `\n` adjacency rather than only the buffer
    // ends — the same `closure.lineStart`/`lineEnd` the boolean engine reads.
    line_anchors: bool,
    allocator: std.mem.Allocator,

    // Reused across finds: the two thread lists, the per-generation dedup, and the
    // slot snapshot for each program counter (valid for its list generation).
    cur: []u32,
    nxt: []u32,
    seen: []u32,
    cslots: [][]isize,
    nslots_buf: [][]isize,
    gen: u32 = 0,

    /// The same `sel` the union's `compile` resolved, so this arm applies the
    /// meaning-changing rewrites (`-i`, `--crlf`, `-w`) that the search matcher
    /// applies in `linear/program/lower.zig::parse` — one list, spelled once each
    /// in `syntax/scalars.zig`, so a replacement can never be measured against a
    /// span the search engine would not have chosen.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, sel: Caps.Selection) ParseError!Captures {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const unicode = sel.unicode;
        var names: std.ArrayList(syn.NamedCap) = .empty;
        // `.multiline = true` for the same reason `Selection.lowerOptions` forces
        // it: every haystack this arm sees is a whole buffer (the FFI hands
        // buffers by definition; a CLI line is a buffer of one line). `(?m)` is
        // the separate question and rides `line_anchors` below.
        var parser = syn.Parser{ .src = pattern, .arena = arena, .names = &names, .unicode = unicode, .caseless = sel.caseless, .multiline = true, .dotall = sel.dotall };
        const parsed = try parser.parseAlt();
        if (parser.pos != pattern.len) return ParseError.BadPattern;
        if (sel.caseless) try syn.foldCaseAst(arena, parsed, unicode);
        if (sel.crlf) try syn.stripCpAst(arena, parsed, '\r');
        const ast = if (sel.word) try syn.wordBoundedAst(arena, parsed) else parsed;

        var c = Comp{ .gpa = gpa };
        defer c.loom.deinit(gpa);
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
        // MUST be zeroed: the generation dedup compares `seen[pc] == gen`
        // and `gen` counts up from 0 — heap garbage that happens to equal
        // a live generation silently drops a VM thread (a nondeterministic
        // missed capture in ReleaseFast; caught by the torture-corpus `-r`
        // differential flaking against rg).
        const seen = try gpa.alloc(u32, n);
        @memset(seen, 0);
        return .{
            .prog = prog,
            .start = start,
            .ngroups = ngroups,
            .nslots = nslots,
            .names = owned_names,
            .unicode = unicode,
            .line_anchors = sel.multiline,
            .allocator = gpa,
            .cur = try gpa.alloc(u32, n),
            .nxt = try gpa.alloc(u32, n),
            .seen = seen,
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

    /// The name group `index` was declared with, or null when it is a plain
    /// `(…)`. The inverse of `groupByName`, and it exists because a host walking
    /// a match into a keyed record needs the arrow that way round; without it
    /// the only route is to re-parse the pattern for `(?P<…>)` spellings, which
    /// is the parser's job and already done here.
    pub fn nameOfGroup(self: *const Captures, index: u32) ?[]const u8 {
        for (self.names) |nc| if (nc.idx == index) return nc.name;
        return null;
    }

    /// A priority-ordered thread list plus each pc's slot snapshot.
    const St = struct { list: []u32, len: usize = 0, slots: [][]isize };

    /// Leftmost-first match of the whole pattern within `line[from..]`. On success
    /// fills `out` (length `nslots`) with byte offsets (−1 = unset) and returns
    /// true; `out[0]`/`out[1]` bracket the whole match. Priority mirrors the main
    /// engine: leftmost start, earliest alternation branch, greedy quantifiers.
    pub fn find(self: *Captures, line: []const u8, from: usize, out: []isize) bool {
        return self.run(line, from, out, false);
    }

    /// The anchored twin of `find`: the match must BEGIN at `from`. Same program,
    /// same priority rules — the only difference is that no new thread is seeded
    /// at later positions, which is precisely what "anchored" means for a Pike
    /// VM. A caller asking what a byte position IS (a lexer probe) needs this;
    /// `find`'s forward search would answer about a position it never reached.
    pub fn matchAt(self: *Captures, line: []const u8, from: usize, out: []isize) bool {
        return self.run(line, from, out, true);
    }

    fn run(self: *Captures, line: []const u8, from: usize, out: []isize, anchored: bool) bool {
        var clist = St{ .list = self.cur, .slots = self.cslots };
        var nlist = St{ .list = self.nxt, .slots = self.nslots_buf };

        const init_slots = out; // reuse the caller's buffer as the seed vector

        self.gen += 1;
        clist.len = 0;
        @memset(init_slots, -1);
        self.addThread(&clist.list, &clist.len, clist.slots, self.start, init_slots, from, line);

        var have = false;
        var cut = self.takeMatch(&clist, out, &have);

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
            if (!have and !anchored) {
                @memset(init_slots, -1);
                self.addThread(&nlist.list, &nlist.len, nlist.slots, self.start, init_slots, i + 1, line);
            }
            // Anchored, no surviving thread, and nothing reseeds: the rest of the
            // line cannot matter, so stop rather than walk it.
            if (anchored and nlist.len == 0) break;
            std.mem.swap(St, &clist, &nlist);
            cut = self.takeMatch(&clist, out, &have);
            if (have and cut == 0) break;
        }
        return have;
    }

    /// Copy the first (highest-priority) `.match` thread's slots into `out`, if
    /// any, and return its index — the priority CUT below which threads can no
    /// longer win (or the full list length when no match landed yet).
    fn takeMatch(self: *const Captures, st: *const St, out: []isize, have: *bool) usize {
        for (st.list[0..st.len], 0..) |pc, k| if (self.prog[pc] == .match) {
            @memcpy(out, st.slots[pc]);
            have.* = true;
            return k;
        };
        return st.len;
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
            .astart => |o| if (if (self.line_anchors) closure_mod.lineStart(line, pos) else pos == 0)
                self.addThread(list, len, slots, o, in_slots, pos, line),
            .aend => |o| if (if (self.line_anchors) closure_mod.lineEnd(line, pos) else pos == line.len)
                self.addThread(list, len, slots, o, in_slots, pos, line),
            .abufstart => |o| if (pos == 0) self.addThread(list, len, slots, o, in_slots, pos, line),
            .abufend => |o| if (pos == line.len) self.addThread(list, len, slots, o, in_slots, pos, line),
            .aword => |w| if (w.mask.holds(word.sides(self.unicode, line, pos)))
                self.addThread(list, len, slots, w.out, in_slots, pos, line),
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
    /// Woven `uclass` tries, reused across occurrences — see `compile.Loom`.
    loom: compile_mod.Loom = .empty,
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
            .anchor_buf_start => return self.push(.{ .abufstart = next }),
            .anchor_buf_end => return self.push(.{ .abufend = next }),
            .word => |mask| return self.push(.{ .aword = .{ .mask = mask, .out = next } }),
            .class => |set| return self.push(.{ .char = .{ .set = set, .out = next } }),
            .uclass => |ranges| return compile_mod.lowerUtf8(self.gpa, &self.loom, ranges, next, self),
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
