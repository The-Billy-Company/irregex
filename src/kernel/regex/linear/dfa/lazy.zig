//! gist — the ON-DEMAND driver of the subset construction: the same automaton
//! `powerset.zig` builds, except a state is determinized the first time a haystack
//! actually walks into it. RE2 / rust-`regex`'s hybrid DFA, in Billy's shape.
//!
//! It picks up eager builds declined on cost: a Unicode trie can make every eager
//! closure expensive while ASCII haystacks visit only a handful of states. Both
//! drivers share `subset.zig`; their division is policy, never semantics.
//!
//! **Quitting is a first-class answer.** Every entry point returns `?bool`; null
//! means "run Pike". Memory pressure first schedules a bounded cache generation
//! reset when observed reuse can amortize it. Only repeated expensive regeneration
//! (or allocation failure) sticks. Declining costs throughput, never correctness.
//!
//! `Lazy` is immutable/shared; mutable `Cache` remains caller-owned thread scratch.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const subset = @import("subset.zig");
const dwell = @import("../automata/dwell.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const word = @import("../../syntax/word.zig");
const State = syn.State;
const unknown = subset.unknown;

/// Program-proportional memory, bounded against tiny and Unicode NFAs.
const min_cache_bytes: usize = 256 * 1024;
const max_cache_bytes: usize = 4 * 1024 * 1024;
pub const Policy = struct {
    byte_budget: usize,
    reset_limit: u8 = 2,

    pub fn forProgram(nstates: usize) Policy {
        return .{ .byte_budget = std.math.clamp(nstates * 64, min_cache_bytes, max_cache_bytes) };
    }
};

pub const Decline = enum(u8) { none, unicode_word, memory_pressure, regeneration_costly, allocation_failure };

/// Copyable per-thread admission census.
pub const Stats = struct {
    allocated_bytes: usize,
    peak_bytes: usize,
    bytes_per_new_state: usize,
    states: u32,
    lookups: u64,
    hits: u64,
    new_states: u64,
    resets: u8,
    pressure_events: u8,
    decline: Decline,
    sticky: bool,
};

/// Immutable pattern half; transition tables live only in per-thread `Cache`.
pub const Lazy = struct {
    states: []const State, // borrowed from the owning `Regex`
    start_nfa: u32,
    cls: subset.Classes,
    anchored: bool,
    word_ctx: bool,
    unicode_word: bool,
    start_dwell: ?prefilter.Prefilter,
    allocator: std.mem.Allocator,

    /// Prepare on-demand determinization; buffer anchors decline.
    pub fn build(
        gpa: std.mem.Allocator,
        states: []const State,
        start: u32,
        anchored: bool,
        unicode: bool,
    ) std.mem.Allocator.Error!?*Lazy {
        if (subset.hasBufferAnchor(states)) return null;
        const word_ctx = subset.hasWordContext(states);
        const cls = subset.Classes.build(states, word_ctx);
        // Word-context has split starts/tables, outside the dwell's row shape.
        const start_dwell = if (word_ctx) null else try probeStartDwell(gpa, states, start, anchored, cls);
        const lz = try gpa.create(Lazy);
        lz.* = .{
            .states = states,
            .start_nfa = start,
            .cls = cls,
            .anchored = anchored,
            .word_ctx = word_ctx,
            .unicode_word = word_ctx and unicode,
            .start_dwell = start_dwell,
            .allocator = gpa,
        };
        return lz;
    }

    fn probeStartDwell(
        gpa: std.mem.Allocator,
        states: []const State,
        start: u32,
        anchored: bool,
        cls: subset.Classes,
    ) std.mem.Allocator.Error!?prefilter.Prefilter {
        var sub = try subset.Subset.init(gpa, states, start, anchored, false, cls);
        defer sub.deinit();
        const empty_match = sub.closeStart(true, true, false) != 0;
        const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;
        try sub.forceStartRow(start_id);
        return dwell.ofStart(anchored, empty_match, sub.trans_in.items, sub.trans_fin.items, sub.is_match.items, &cls.class, cls.ncls, start_id);
    }

    pub fn deinit(self: *Lazy) void {
        self.allocator.destroy(self);
    }
};

/// Per-thread growable memo. IDs stay unmultiplied because rows append on demand.
pub const Cache = struct {
    lazy: *const Lazy,
    sub: subset.Subset,
    start_id: u32,
    start_w_id: u32, // == start_id unless `word_ctx`
    empty_match: bool, // does the pattern match an empty line? (`^$`, `a*`)
    quit: bool = false,
    policy: Policy,
    lookups: u64 = 0,
    hits: u64 = 0,
    new_states: u64 = 0,
    generation_new: u64 = 0,
    generation_lookups: u64 = 0,
    generation_base_bytes: usize = 0,
    resets: u8 = 0,
    pressure_events: u8 = 0,
    peak_bytes: usize = 0,
    decline: Decline = .none,
    reset_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator, lz: *const Lazy) std.mem.Allocator.Error!Cache {
        return initWithPolicy(gpa, lz, Policy.forProgram(lz.states.len));
    }

    pub fn initWithPolicy(gpa: std.mem.Allocator, lz: *const Lazy, policy: Policy) std.mem.Allocator.Error!Cache {
        var sub = try subset.Subset.init(gpa, lz.states, lz.start_nfa, lz.anchored, lz.word_ctx, lz.cls);
        errdefer sub.deinit();
        const empty_match = sub.closeStart(true, true, false) != 0;
        const start_id = (try sub.intern(sub.closeStart(true, false, false))).id;
        const start_w_id = if (lz.word_ctx) (try sub.intern(sub.closeStart(true, false, true))).id else start_id;
        var c: Cache = .{
            .lazy = lz,
            .sub = sub,
            .start_id = start_id,
            .start_w_id = start_w_id,
            .empty_match = empty_match,
            .policy = policy,
        };
        c.policy.byte_budget = @max(c.policy.byte_budget, c.allocatedBytes());
        c.peak_bytes = c.allocatedBytes();
        c.generation_base_bytes = c.peak_bytes;
        return c;
    }

    pub fn deinit(c: *Cache) void {
        c.sub.deinit();
        c.* = undefined;
    }

    fn isMatch(c: *const Cache, id: u32) bool {
        return c.sub.is_match.items[id];
    }

    fn isDead(c: *const Cache, id: u32) bool {
        return c.sub.dead != unknown and id == c.sub.dead;
    }

    /// Allocator-visible scratch, keys, memo arrays, and hash capacity.
    fn allocatedBytes(c: *const Cache) usize {
        const s = &c.sub;
        const map_cap: usize = s.map.capacity();
        var map_bytes = map_cap; // one control byte per bucket
        map_bytes = std.mem.alignForward(usize, map_bytes, @alignOf([]const u64)) + map_cap * @sizeOf([]const u64);
        map_bytes = std.mem.alignForward(usize, map_bytes, @alignOf(u32)) + map_cap * @sizeOf(u32);
        var keys: usize = 0;
        for (s.sets.items) |key| keys += key.len * @sizeOf(u64);
        return map_bytes + keys +
            s.visited.len * @sizeOf(u64) + s.out.len * @sizeOf(u64) +
            s.stack.len * @sizeOf(u32) + s.key_scratch.len * @sizeOf(u64) +
            s.sets.capacity * @sizeOf([]u64) + s.is_match.capacity * @sizeOf(bool) +
            (s.trans_in.capacity + s.trans_in_w.capacity + s.trans_fin.capacity) * @sizeOf(u32);
    }

    /// Bytes this generation has spent per state it added — the growth rate the
    /// pressure check extrapolates one expansion forward, and the figure `stats`
    /// reports. Null when the generation has added nothing yet, which is the one
    /// case with no rate rather than a rate of zero; each caller has its own
    /// answer for that.
    ///
    /// Typed `usize` because that is what it measures, and saying so is the point:
    /// the state counter is `u64`, so the division widens on a 32-bit target and
    /// will not narrow back on its own. A quotient of `bytes` by a count of at
    /// least one cannot exceed `bytes`, so the narrowing is lossless by
    /// construction — not by clamp, and not by widening the reported `Stats` on
    /// every target to suit one.
    fn churnPerState(c: *const Cache, bytes: usize) ?usize {
        if (c.generation_new == 0) return null;
        return @intCast((bytes -| c.generation_base_bytes) / c.generation_new);
    }

    pub fn stats(c: *const Cache) Stats {
        const bytes = c.allocatedBytes();
        const churn = c.churnPerState(bytes) orelse 0;
        return .{ .allocated_bytes = bytes, .peak_bytes = @max(bytes, c.peak_bytes), .bytes_per_new_state = churn, .states = c.sub.nstates, .lookups = c.lookups, .hits = c.hits, .new_states = c.new_states, .resets = c.resets, .pressure_events = c.pressure_events, .decline = c.decline, .sticky = c.quit };
    }

    /// Four probes per new state predicts reuse cheaper than Pike.
    fn reuseLikely(c: *const Cache) bool {
        return c.generation_new != 0 and c.generation_lookups >= c.generation_new * 4;
    }

    fn reset(c: *Cache) bool {
        var fresh = Cache.initWithPolicy(c.sub.gpa, c.lazy, c.policy) catch {
            c.quit = true;
            c.decline = .allocation_failure;
            return false;
        };
        c.sub.deinit();
        c.sub = fresh.sub;
        c.start_id = fresh.start_id;
        c.start_w_id = fresh.start_w_id;
        c.empty_match = fresh.empty_match;
        fresh.sub = undefined;
        c.resets += 1;
        c.generation_new = 0;
        c.generation_lookups = 0;
        c.reset_pending = false;
        c.decline = .none;
        c.peak_bytes = @max(c.peak_bytes, c.allocatedBytes());
        c.generation_base_bytes = c.allocatedBytes();
        return true;
    }

    fn prepare(c: *Cache) bool {
        return !c.quit and (!c.reset_pending or c.reset());
    }

    fn pressure(c: *Cache) ?u32 {
        c.pressure_events +|= 1;
        c.decline = .memory_pressure;
        if (c.resets < c.policy.reset_limit and c.reuseLikely()) {
            c.reset_pending = true;
        } else if (c.resets != 0 or c.pressure_events > 1) {
            c.quit = true;
            c.decline = .regeneration_costly;
        }
        return null;
    }

    fn next(c: *Cache, id: u32, k: u16, table: subset.Subset.Table) ?u32 {
        c.lookups += 1;
        c.generation_lookups += 1;
        const off = @as(usize, id) * c.lazy.cls.ncls + k;
        const memo = c.sub.tableItems(table)[off];
        if (memo != unknown) {
            c.hits += 1;
            return memo;
        }
        const bytes = c.allocatedBytes();
        const ntables: usize = 2 + @as(usize, @intFromBool(c.lazy.word_ctx));
        const floor = (c.sub.words + 1) * @sizeOf(u64) +
            @as(usize, c.lazy.cls.ncls) * @sizeOf(u32) * ntables;
        const churn = @max(floor, c.churnPerState(bytes) orelse 0);
        if (bytes +| churn > c.policy.byte_budget) return c.pressure();
        const before = c.sub.nstates;
        const next_id = c.sub.expand(id, k, table) catch {
            c.quit = true;
            c.decline = .allocation_failure;
            return null;
        };
        const added = c.sub.nstates - before;
        c.new_states += added;
        c.generation_new += added;
        c.peak_bytes = @max(c.peak_bytes, c.allocatedBytes());
        return next_id;
    }

    pub fn match(c: *Cache, line: []const u8) ?bool {
        std.debug.assert(!c.lazy.word_ctx); // word-boundary programs go through `matchWord`
        if (!c.prepare()) return null;
        if (line.len == 0) return c.empty_match;
        if (c.lazy.start_dwell) |*exits| return c.matchDwell(line, exits);
        const cls = &c.lazy.cls.class;
        var s = c.start_id;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        for (line[0..last]) |ch| {
            s = c.next(s, cls[ch], .interior) orelse return null;
            if (c.isMatch(s)) return true;
            if (c.lazy.anchored and c.isDead(s)) return false; // no re-seed ⇒ dead
        }
        s = c.next(s, cls[line[last]], .final) orelse return null;
        return c.isMatch(s);
    }

    /// Start-state SIMD skip, preserving the final-byte `$` transition.
    fn matchDwell(c: *Cache, line: []const u8, pf: *const prefilter.Prefilter) ?bool {
        const cls = &c.lazy.cls.class;
        const start = c.start_id;
        var s = start;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        var i: usize = 0;
        while (i < line.len) {
            if (s == start) {
                const j = pf.nextStart(line, i) orelse line.len;
                if (j >= line.len) { // dead tail: only the last byte can match (`$`)
                    s = c.next(start, cls[line[last]], .final) orelse return null;
                    return c.isMatch(s);
                }
                i = j; // skipped non-exit bytes [i, j); landed on an exit byte
            }
            if (i == last) { // resolve the final byte with `$`
                s = c.next(s, cls[line[i]], .final) orelse return null;
                return c.isMatch(s);
            }
            s = c.next(s, cls[line[i]], .interior) orelse return null;
            i += 1;
            if (c.isMatch(s)) return true;
        }
        return false;
    }

    /// Look-ahead table selection for ASCII word context; Unicode gaps quit.
    pub fn matchWord(c: *Cache, line: []const u8) ?bool {
        std.debug.assert(c.lazy.word_ctx);
        if (!c.prepare()) return null;
        if (line.len == 0) return c.empty_match;
        const uni = c.lazy.unicode_word;
        if (uni and line[0] >= 0x80) {
            c.decline = .unicode_word;
            return null;
        }
        const cls = &c.lazy.cls.class;
        var s = if (word.isWordByte(line[0])) c.start_w_id else c.start_id;
        if (c.isMatch(s)) return true;
        const last = line.len - 1;
        var j: usize = 0;
        while (j < last) : (j += 1) {
            const nb = line[j + 1]; // the byte after the gap we're about to land on
            if (uni and nb >= 0x80) {
                c.decline = .unicode_word;
                return null;
            }
            const table: subset.Subset.Table = if (word.isWordByte(nb)) .interior_word else .interior;
            s = c.next(s, cls[line[j]], table) orelse return null;
            if (c.isMatch(s)) return true;
            if (c.lazy.anchored and c.isDead(s)) return false;
        }
        // Last content byte: EOL gap ⇒ `word_after=false`, resolved by the final table.
        s = c.next(s, cls[line[last]], .final) orelse return null;
        return c.isMatch(s);
    }

    /// Fused per-line scalar walk; unsettled tables preclude eager's multi-lane path.
    pub fn docMatch(c: *Cache, doc: []const u8) ?bool {
        std.debug.assert(!c.lazy.word_ctx); // word-boundary programs go per line
        if (!c.prepare()) return null;
        if (c.lazy.start_dwell) |*exits| return c.docMatchDwell(doc, exits);
        const cls = &c.lazy.cls.class;
        const n = doc.len;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (c.empty_match) return true;
                i += 1;
                continue;
            }
            var s = c.start_id;
            if (c.isMatch(s)) return true; // BOL / zero-width match
            var prev = s;
            var hit_dead = false;
            while (i < n and doc[i] != '\n') {
                prev = s;
                s = c.next(s, cls[doc[i]], .interior) orelse return null;
                i += 1;
                if (c.isMatch(s)) return true;
                if (c.lazy.anchored and c.isDead(s)) { // `^`-anchored thread set drained
                    // …but only abandon if content remains: the LAST content byte still gets the final table, whose `$`-resolving (at_end) closure can match where the interior (at_end=false) one died.
                    if (i < n and doc[i] != '\n') hit_dead = true;
                    break;
                }
            }
            if (!hit_dead) { // resolve the line's last content byte (`doc[i-1]`) with `$`
                s = c.next(prev, cls[doc[i - 1]], .final) orelse return null;
                if (c.isMatch(s)) return true;
                if (i < n) i += 1; // skip the '\n'
            } else { // dead `^`-thread: SIMD-`memchr` past the rest of this dead line
                i = std.mem.indexOfScalarPos(u8, doc, i, '\n') orelse n;
                if (i < n) i += 1;
            }
        }
        return false;
    }

    /// Fused walk with the same start-state skip as `Dfa.docMatchDwell`.
    fn docMatchDwell(c: *Cache, doc: []const u8, pf: *const prefilter.Prefilter) ?bool {
        const cls = &c.lazy.cls.class;
        const n = doc.len;
        const start = c.start_id;
        var i: usize = 0;
        while (i < n) {
            if (doc[i] == '\n') { // empty line
                if (c.empty_match) return true;
                i += 1;
                continue;
            }
            var s = start;
            if (c.isMatch(s)) return true; // BOL / zero-width match
            var prev = s;
            var line_done = false; // dead-tail already resolved its `$` inside the loop
            while (i < n and doc[i] != '\n') {
                if (s == start) { // skip the dead run to the next exit byte / `\n`
                    const j = pf.nextStart(doc, i) orelse n;
                    if (j >= n or doc[j] == '\n') {
                        // Non-exit tail to the line end: no interior byte can match
                        // (start self-loops), but the last content byte `doc[j-1]`
                        // can still match `$` — resolve it from the *start* state
                        // (the live state across the skip), not the stale `prev`.
                        s = c.next(start, cls[doc[j - 1]], .final) orelse return null;
                        if (c.isMatch(s)) return true;
                        i = j;
                        line_done = true;
                        break;
                    }
                    i = j;
                }
                prev = s;
                s = c.next(s, cls[doc[i]], .interior) orelse return null;
                i += 1;
                if (c.isMatch(s)) return true;
            }
            // Contiguous-processing exit (hit `\n`/EOF): resolve the line's last
            // content byte with `$` from `prev`, exactly as the dense walk does.
            // Skipped tails already handled themselves via `line_done`.
            if (!line_done and i > 0 and doc[i - 1] != '\n') {
                s = c.next(prev, cls[doc[i - 1]], .final) orelse return null;
                if (c.isMatch(s)) return true;
            }
            if (i < n and doc[i] == '\n') i += 1;
        }
        return false;
    }
};

fn testSet(bytes: []const u8) syn.ByteSet {
    var set: syn.ByteSet = .{};
    for (bytes) |b| set.set(b);
    return set;
}

fn testLazy(states: []const State, start: u32, anchored: bool) !*Lazy {
    return (try Lazy.build(std.testing.allocator, states, start, anchored, false)).?;
}

test "lazy cache stable reuse does not grow" {
    const states = [_]State{ .{ .consume = .{ .set = testSet("a"), .out = 1 } }, .match };
    const lz = try testLazy(&states, 0, true);
    defer lz.deinit();
    var cache = try Cache.init(std.testing.allocator, lz);
    defer cache.deinit();

    try std.testing.expect(cache.match("a").?);
    const first = cache.stats();
    try std.testing.expect(cache.match("a").?);
    const second = cache.stats();
    try std.testing.expectEqual(first.states, second.states);
    try std.testing.expect(second.hits > first.hits);
}

test "lazy cache churn schedules a bounded reset" {
    const states = [_]State{ .{ .consume = .{ .set = testSet("a"), .out = 1 } }, .match };
    const lz = try testLazy(&states, 0, true);
    defer lz.deinit();
    var cache = try Cache.initWithPolicy(std.testing.allocator, lz, .{ .byte_budget = 1, .reset_limit = 1 });
    defer cache.deinit();

    cache.generation_new = 1;
    cache.generation_lookups = 4;
    try std.testing.expect(cache.pressure() == null);
    try std.testing.expect(cache.reset_pending);
    try std.testing.expect(cache.prepare());
    try std.testing.expectEqual(@as(u8, 1), cache.stats().resets);
}

test "lazy cache reset cap makes repeated regeneration sticky" {
    const states = [_]State{ .{ .consume = .{ .set = testSet("a"), .out = 1 } }, .match };
    const lz = try testLazy(&states, 0, true);
    defer lz.deinit();
    var cache = try Cache.initWithPolicy(std.testing.allocator, lz, .{ .byte_budget = 1, .reset_limit = 1 });
    defer cache.deinit();

    cache.generation_new = 1;
    cache.generation_lookups = 4;
    _ = cache.pressure();
    try std.testing.expect(cache.prepare());
    cache.generation_new = 1;
    cache.generation_lookups = 4;
    _ = cache.pressure();
    try std.testing.expect(cache.quit);
    try std.testing.expectEqual(Decline.regeneration_costly, cache.stats().decline);
}

test "lazy cache allocation failure declines to Pike" {
    const states = [_]State{ .{ .consume = .{ .set = testSet("a"), .out = 1 } }, .match };
    const lz = try testLazy(&states, 0, true);
    defer lz.deinit();
    var cache = try Cache.init(std.testing.allocator, lz);
    defer cache.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    cache.sub.gpa = failing.allocator();
    try std.testing.expect(cache.match("a") == null);
    cache.sub.gpa = std.testing.allocator;
    try std.testing.expect(cache.quit);
    try std.testing.expectEqual(Decline.allocation_failure, cache.stats().decline);
}
