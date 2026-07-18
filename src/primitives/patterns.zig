//! irregex — the MATCH half: a compiled pattern SET with attribution.
//!
//! One search intent compiles through `engine/query.zig`; this module compiles
//! MANY — the Hyperscan-shaped workload (Wang et al., NSDI 2019) that agent
//! tools actually run: relocator classifies dozens of literals per pass, the
//! trust lints scan forbidden-pattern lists, doc-radar replays a whole query
//! corpus. Today each caller either re-runs the engine once per pattern (N
//! walks, N reads) or fuses an alternation and then RE-DERIVES "which pattern
//! hit" downstream in Python. `PatternSet` owns both halves: one shared pass
//! answers "does anything match?" and attribution answers "WHICH patterns,
//! where?" — exact, per pattern, in the kernel.
//!
//! Mechanism (prefilter → confirm, kept exact):
//!
//!   • Every pattern is its own `CompiledQuery` — the same fail-closed,
//!     thread-safe compile the CLI and resident session execute through, so a
//!     pattern-set answer can never disagree with N single-pattern runs.
//!   • A fused GATE — the `(?:p0)|(?:p1)|…` alternation, exactly the shape
//!     `combinePatterns` builds for the CLI — cheaply rejects a document that
//!     matches nothing. It is built only when every spec shares one case/
//!     Unicode setting and every body compiles linear; otherwise the set runs
//!     confirm-only, still exact. The gate can only skip work, never change an
//!     answer: attribution always comes from the per-pattern queries.
//!
//! Kernel profile: no I/O, explicit allocator, immutable after `compile`;
//! per-worker mutable state lives in a caller-owned `Scratch` (one per
//! thread), mirroring `CompiledQuery`'s own discipline.

const std = @import("std");
const query = @import("../gist/kernel/engine/query.zig");

pub const Spec = query.Spec;
pub const CompiledQuery = query.CompiledQuery;

pub const CompileError = query.CompileError;

/// A compiled, immutable set of search intents. Share freely across walk
/// workers; all mutable match state lives in `Scratch`.
pub const PatternSet = struct {
    queries: []CompiledQuery,
    /// The fused any-of gate, when expressible (see module doc). Optional —
    /// purely an accelerator; `null` means confirm-only execution.
    gate: ?CompiledQuery,
    /// The fused gate's alternation source — owned here because a compiled
    /// regex may alias its pattern bytes (the same reason `CompiledQuery`
    /// keeps `escaped` alive). Freed by `deinit`.
    gate_pattern: ?[]u8,

    /// Compile one query per spec, plus the fused gate when the set is
    /// homogeneous enough to express one. Specs' `pattern` slices are aliased
    /// per `engine/query.zig`'s contract — the caller keeps them alive.
    pub fn compile(gpa: std.mem.Allocator, specs: []const Spec) CompileError!PatternSet {
        const queries = try gpa.alloc(CompiledQuery, specs.len);
        var built: usize = 0;
        errdefer {
            for (queries[0..built]) |*q| q.deinit(gpa);
            gpa.free(queries);
        }
        for (specs, 0..) |spec, i| {
            queries[i] = try CompiledQuery.compile(gpa, spec);
            built += 1;
        }
        var set: PatternSet = .{ .queries = queries, .gate = null, .gate_pattern = null };
        buildGate(gpa, specs, &set);
        return set;
    }

    pub fn deinit(self: *PatternSet, gpa: std.mem.Allocator) void {
        for (self.queries) |*q| q.deinit(gpa);
        gpa.free(self.queries);
        if (self.gate) |*g| g.deinit(gpa);
        if (self.gate_pattern) |p| gpa.free(p);
    }

    pub fn len(self: *const PatternSet) usize {
        return self.queries.len;
    }

    /// Per-worker mutable state: one match scratch per pattern, plus the
    /// gate's. One `Scratch` per thread, never shared.
    pub const Scratch = struct {
        per: []query.Scratch,
        gate: query.Scratch,

        pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
            for (self.per) |*s| s.deinit();
            gpa.free(self.per);
            self.gate.deinit();
        }
    };

    pub fn scratch(self: *const PatternSet, gpa: std.mem.Allocator) CompileError!Scratch {
        const per = try gpa.alloc(query.Scratch, self.queries.len);
        var built: usize = 0;
        errdefer {
            for (per[0..built]) |*s| s.deinit();
            gpa.free(per);
        }
        for (self.queries, 0..) |*q, i| {
            per[i] = try q.scratch(gpa);
            built += 1;
        }
        return .{ .per = per, .gate = if (self.gate) |*g| try g.scratch(gpa) else .none };
    }

    /// Does ANY pattern match anywhere in `bytes`? One gate pass when the
    /// fused gate exists; otherwise first-hit-wins over the per-pattern
    /// queries. The cheap rejection a batch workload spends most of its time in.
    pub fn anyMatch(self: *const PatternSet, bytes: []const u8, sc: *Scratch) bool {
        if (self.gate) |*g| return g.docMatches(bytes, &sc.gate);
        for (self.queries, sc.per) |*q, *s| {
            if (q.docMatches(bytes, s)) return true;
        }
        return false;
    }

    /// Attribution over a whole document: set bit `i` in `mask` for every
    /// pattern that matches `bytes`. `mask` is caller-owned, `maskWords(len)`
    /// long, and is cleared first. Returns whether any bit was set. The gate
    /// (when present) short-circuits the all-miss case.
    pub fn docMask(self: *const PatternSet, bytes: []const u8, sc: *Scratch, mask: []u64) bool {
        @memset(mask, 0);
        if (self.gate != null and !self.anyMatch(bytes, sc)) return false;
        var any = false;
        for (self.queries, sc.per, 0..) |*q, *s, i| {
            if (q.docMatches(bytes, s)) {
                mask[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
                any = true;
            }
        }
        return any;
    }

    /// Attribution over one LINE (no trailing newline): append the index of
    /// every matching pattern to `hits`. The per-line confirm behind streamed
    /// `pattern_id` records — run it only on lines the gate already implicated.
    pub fn lineHits(self: *const PatternSet, line: []const u8, sc: *Scratch, gpa: std.mem.Allocator, hits: *std.ArrayList(u32)) error{OutOfMemory}!void {
        for (self.queries, sc.per, 0..) |*q, *s, i| {
            if (q.docMatches(line, s)) try hits.append(gpa, @intCast(i));
        }
    }

    /// The sound trigram prefilter literals for pattern `i` — delegate to the
    /// underlying query so index-backed callers prune candidates per pattern
    /// exactly as the single-pattern engine would.
    pub fn prefilter(self: *const PatternSet, i: usize, one: *[1][]const u8) []const []const u8 {
        return self.queries[i].prefilter(one);
    }
};

/// Words needed for a `docMask` bitmask over `n` patterns.
pub fn maskWords(n: usize) usize {
    return (n + 63) / 64;
}

/// Is bit `i` set in a `docMask` bitmask?
pub fn maskHas(mask: []const u64, i: usize) bool {
    return (mask[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}

/// Build the fused `(?:p0)|(?:p1)|…` gate when the set can honestly share one
/// engine: every spec on the same `ignore_case`/`unicode` setting (irregex
/// compiles ONE engine — the same constraint `combinePatterns` enforces for
/// the CLI), fixed patterns escaped exactly as the CLI escapes them. Any
/// failure (a body outside the linear syntax, allocation) leaves the gate
/// null — the set silently runs confirm-only, never wrong, never fatal.
fn buildGate(gpa: std.mem.Allocator, specs: []const Spec, set: *PatternSet) void {
    if (specs.len < 2) return;
    for (specs[1..]) |s| {
        if (s.ignore_case != specs[0].ignore_case or s.unicode != specs[0].unicode) return;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (specs, 0..) |s, i| {
        if (i != 0) buf.append(gpa, '|') catch return;
        const escaped: ?[]u8 = if (s.fixed) query.escapeLiteral(gpa, s.pattern) catch return else null;
        defer if (escaped) |e| gpa.free(e);
        buf.print(gpa, "(?:{s})", .{escaped orelse s.pattern}) catch return;
    }
    const pattern = buf.toOwnedSlice(gpa) catch return;
    set.gate = CompiledQuery.compile(gpa, .{
        .pattern = pattern,
        .mode = .files,
        .fixed = false,
        .ignore_case = specs[0].ignore_case,
        .unicode = specs[0].unicode,
    }) catch {
        gpa.free(pattern);
        return;
    };
    set.gate_pattern = pattern;
}
