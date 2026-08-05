//! irregex — the MATCH half: a compiled pattern SET with attribution.
//!
//! One search intent compiles through `kernel/query/query.zig`; this module compiles
//! MANY — the Hyperscan-shaped workload (Wang et al., NSDI 2019) that agent
//! tools actually run: a renamer classifies dozens of literals per pass, a
//! lint suite scans forbidden-pattern lists, a freshness checker replays a query
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
//!   • A MUSTER (`muster.zig`) — one Teddy SIMD pass over the literals pooled
//!     from all N patterns, which both rejects a document AND names which
//!     patterns are even in play. The gate answers "anything?" in one pass but
//!     leaves attribution costing N confirms; the muster makes attribution
//!     itself cost one pass, so a set's price stops tracking its size. A pattern
//!     whose literals DECIDE it (`muster.zig::coverOf`) is answered by that pass
//!     and never confirmed at all. It only ever removes patterns that provably
//!     cannot match, so the answer is unchanged — `patterns_test.zig` proves
//!     equality with it both on and off.
//!
//! What a slate deliberately does NOT hold is the attributing union automaton
//! (`regex/linear/program/chorus.zig`). One union DFA walk sounds like it should
//! beat N engine confirms, and it does not: a confirm for a literal pattern
//! never reaches a DFA at all (it is a SIMD memmem), and a regex confirm still
//! carries a required-literal prefilter and the fused multi-lane walk. Measured
//! on six slates in `bench/rungs/patternid`, the union ran 0.06x-0.41x the speed
//! of the confirms it would replace, with identical answers — and its powerset
//! construction is paid at COMPILE time by every caller, which for a Unicode
//! class alternation is hundreds of milliseconds. Compile the `Chorus` directly
//! when you want its one irreplaceable answer (every end position, including the
//! ones a leftmost scan swallows); `Munch` does exactly that.
//!
//! Kernel profile: no I/O, explicit allocator, immutable after `compile`;
//! per-worker mutable state lives in a caller-owned `Scratch` (one per
//! thread), mirroring `CompiledQuery`'s own discipline.

const std = @import("std");
const query = @import("../query/query.zig");
const bits = @import("../math/bits.zig");
const muster_mod = @import("muster.zig");

const B64 = bits.Field(u64);

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
    /// Whether a gate hit DECIDES the set, or merely nominates it. The gate is
    /// fused from pattern TEXT, so a per-spec flag that narrows the match set
    /// after the fact — `-w`, or a PCRE body compiled here under the linear
    /// engine — is not carried into it. Such a gate is a sound OVER-approximation:
    /// still perfect for rejection, never sufficient for a verdict. Same
    /// nominates-versus-decides split the muster draws with `settled`.
    gate_exact: bool,
    /// The fused gate's alternation source — owned here because a compiled
    /// regex may alias its pattern bytes (the same reason `CompiledQuery`
    /// keeps `escaped` alive). Freed by `deinit`.
    gate_pattern: ?[]u8,
    /// The SIMD literal roll call (see `muster.zig`). Optional and purely an
    /// accelerator: `null` restores the gate-then-confirm-all execution.
    muster: ?muster_mod.Muster,

    /// Which question the caller will ask, and therefore which accelerators are
    /// worth their compile time. Both faces answer exactly, with or without an
    /// accelerator; this only decides what gets built.
    pub const Face = enum {
        /// `anyMatch` / `docMask` / `lineHits` — a document split into lines.
        line,
        /// `bufAnyMatch` / `bufMask` — the whole text as one unit.
        buffer,
    };

    /// Compile one query per spec, plus the accelerators the line face uses.
    /// Specs' `pattern` slices are aliased per `kernel/query/query.zig`'s
    /// contract — the caller keeps them alive.
    pub fn compile(gpa: std.mem.Allocator, specs: []const Spec) CompileError!PatternSet {
        return compileFor(gpa, specs, .line);
    }

    /// `compile`, for a caller who knows which face it will ask.
    ///
    /// The fused gate is a `.line` accelerator and only that: the buffer face
    /// cannot use it (an alternation over-approximates per line and is UNSOUND
    /// per buffer — see the buffer face's own note), so building one for a
    /// buffer caller is pure cost. And it is not a small cost. The gate is one
    /// `CompiledQuery` over `(?:p0)|(?:p1)|…`, so its price grows with the whole
    /// slate rather than with any one pattern: 64 patterns of the shape
    /// `a<i>x+\d?` cost ~5.5 s to fuse and ~40 ms to compile individually. A C
    /// host asking about two hundred patterns is the advertised scale of the
    /// ABI's slate plane, and it never walks a line.
    pub fn compileFor(gpa: std.mem.Allocator, specs: []const Spec, face: Face) CompileError!PatternSet {
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
        var set: PatternSet = .{ .queries = queries, .gate = null, .gate_exact = true, .gate_pattern = null, .muster = null };
        if (face == .line) buildGate(gpa, specs, &set);
        set.muster = muster_mod.build(gpa, queries, specs) catch null;
        return set;
    }

    pub fn deinit(self: *PatternSet, gpa: std.mem.Allocator) void {
        for (self.queries) |*q| q.deinit(gpa);
        gpa.free(self.queries);
        if (self.gate) |*g| g.deinit(gpa);
        if (self.gate_pattern) |p| gpa.free(p);
        if (self.muster) |*m| m.deinit(gpa);
    }

    pub fn len(self: *const PatternSet) usize {
        return self.queries.len;
    }

    /// Which prefilter mechanism this set compiled to — `dragnet`, `trawl`, or
    /// `none`. Never changes the answer; reportable so a benchmark row can name
    /// the tier that produced it (see `muster.tier`).
    pub fn tier(self: *const PatternSet) []const u8 {
        return if (self.muster) |*m| m.tier() else "none";
    }

    /// Per-worker mutable state: one match scratch per pattern, the gate's, and
    /// the muster's roll-call word array. One `Scratch` per thread, never
    /// shared. Holding `play` here is what keeps the roll allocation-free.
    pub const Scratch = struct {
        per: []query.Scratch,
        gate: query.Scratch,
        play: []u64,
        /// Span scratch for the BUFFER face only (`bufMask`/`bufAnyMatch`),
        /// materialized on that face's first call and empty until then.
        ///
        /// Lazy rather than built beside `per` because the two faces have
        /// different populations: every corpus walk in the ecosystem asks the
        /// line question and would otherwise allocate a span VM per pattern it
        /// never runs. `query` already draws this line for a single pattern —
        /// `Scratch` is the boolean kernels' state and `MatchScratch` the span
        /// walk's, "kept apart" for exactly this reason — so carrying both here
        /// is that separation surviving one level up rather than a new idea.
        spans: []query.MatchScratch = &.{},

        pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
            for (self.per) |*s| s.deinit();
            gpa.free(self.per);
            self.gate.deinit();
            gpa.free(self.play);
            for (self.spans) |*s| s.deinit();
            gpa.free(self.spans);
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
        const play = try gpa.alloc(u64, B64.words(self.queries.len));
        errdefer gpa.free(play);
        return .{ .per = per, .gate = if (self.gate) |*g| try g.scratch(gpa) else .none, .play = play };
    }

    /// Does ANY pattern match anywhere in `bytes`? The muster's roll rejects an
    /// all-miss document in one SIMD pass and can even ANSWER YES outright when
    /// a settled pattern is present; past that it falls to the fused gate, else
    /// first-hit-wins over the per-pattern queries. The cheap rejection a batch
    /// workload spends most of its time in.
    ///
    /// Every yes here is either settled or confirmed. The gate alone is not
    /// enough to say yes unless it is `gate_exact` — that distinction is the one
    /// this function got wrong until a `-w` slate answered true for a document
    /// no pattern matched.
    pub fn anyMatch(self: *const PatternSet, bytes: []const u8, sc: *Scratch) bool {
        if (self.muster) |*m| {
            if (!m.roll(bytes, sc.play)) return false;
            for (sc.play, m.settled) |w, done| if (w & done != 0) return true;
            return self.confirmAny(bytes, sc, sc.play);
        }
        if (self.gate) |*g| {
            if (!g.docMatches(bytes, &sc.gate)) return false;
            if (self.gate_exact) return true;
        }
        return self.confirmAny(bytes, sc, null);
    }

    /// First-hit-wins confirm, restricted to `play` when the muster named a
    /// candidate set (a pattern outside it provably cannot match).
    fn confirmAny(self: *const PatternSet, bytes: []const u8, sc: *Scratch, play: ?[]const u64) bool {
        for (self.queries, sc.per, 0..) |*q, *s, i| {
            if (play) |p| if (!B64.get(p, i)) continue;
            if (q.docMatches(bytes, s)) return true;
        }
        return false;
    }

    /// Attribution over a whole document: set bit `i` in `mask` for every
    /// pattern that matches `bytes`. `mask` is caller-owned, `maskWords(len)`
    /// long, and is cleared first. Returns whether any bit was set.
    ///
    /// This is the call whose cost used to grow with N — one engine confirm per
    /// pattern, every document. The muster collapses it: one SIMD roll names
    /// the candidates, settled patterns are already answered, and only the
    /// remainder reach an engine. Without a muster the old gate-then-confirm-all
    /// path runs unchanged.
    pub fn docMask(self: *const PatternSet, bytes: []const u8, sc: *Scratch, mask: []u64) bool {
        @memset(mask, 0);
        if (self.muster) |*m| {
            if (!m.roll(bytes, sc.play)) return false;
            var any = false;
            for (sc.play, m.settled, 0..) |w, done, wi| {
                mask[wi] = w & done; // settled ⇒ presence WAS the decision
                any = any or mask[wi] != 0;
                var it = bits.ones(w & ~done);
                while (it.next()) |b| {
                    const i = wi * 64 + b;
                    if (self.queries[i].docMatches(bytes, &sc.per[i])) {
                        B64.set(mask, i);
                        any = true;
                    }
                }
            }
            return any;
        }
        // The gate is used AS a gate here, so its over-approximation costs
        // nothing: every surviving pattern is confirmed below regardless.
        if (self.gate) |*g| if (!g.docMatches(bytes, &sc.gate)) return false;
        var any = false;
        for (self.queries, sc.per, 0..) |*q, *s, i| {
            if (q.docMatches(bytes, s)) {
                B64.set(mask, i);
                any = true;
            }
        }
        return any;
    }

    /// Attribution over one LINE (no trailing newline): append the index of
    /// every matching pattern to `hits`. The per-line confirm behind streamed
    /// `pattern_id` records — run it only on lines the gate already implicated.
    /// The roll runs per line too: on a line, N is usually reduced to zero or
    /// one candidate, so this is where a wide slate stops costing N engines.
    pub fn lineHits(self: *const PatternSet, line: []const u8, sc: *Scratch, gpa: std.mem.Allocator, hits: *std.ArrayList(u32)) error{OutOfMemory}!void {
        if (self.muster) |*m| {
            if (!m.roll(line, sc.play)) return;
            for (sc.play, 0..) |w, wi| {
                var it = bits.ones(w);
                while (it.next()) |b| {
                    const i = wi * 64 + b;
                    if (m.isSettled(i) or self.queries[i].docMatches(line, &sc.per[i]))
                        try hits.append(gpa, @intCast(i));
                }
            }
            return;
        }
        for (self.queries, sc.per, 0..) |*q, *s, i| {
            if (q.docMatches(line, s)) try hits.append(gpa, @intCast(i));
        }
    }

    // ── the buffer face ──────────────────────────────────────────────────────
    //
    // Everything above asks the LINE question: `docMask` splits a document into
    // lines and reports which patterns match one of them, so `^` and `$` are a
    // line's ends and no match crosses a newline. That is a searcher's unit, and
    // it is the right unit for the corpus walks this kernel was built for.
    //
    // A library caller holds ONE unit. It hands over a whole string, `^` and `$`
    // are that string's ends, and `a\sb` matches `"a\nb"` because the `\n` is
    // just a byte in the middle. Both questions are legitimate; the bug would be
    // answering the second with the first, which is what a set built out of
    // `docMask` tells a host that also has `Pattern.isMatch` — and the two
    // disagree on every anchored pattern and every empty haystack.
    //
    // So the confirm changes and nothing else does. `holds(bytes, true, …)` is
    // already the single-unit question (its own doc names the C ABI as the
    // caller that has to ask it), which makes this face agree with
    // `regex/glean/pattern.zig::isMatch` by construction rather than by a second
    // implementation that could drift. The invariant `contract/kinship.toml`
    // states for a slate — an answer bit-identical to N independent
    // single-pattern runs — is therefore the same invariant here, just read
    // against the library's `isMatch` instead of the searcher's `docMatches`.
    //
    // What survives from the line face and what does not:
    //
    //   * The MUSTER survives whole. Its roll is SIMD literal presence over the
    //     bytes, with no notion of a line at all, and its two claims are
    //     unit-free: a required literal is required by any match, and an
    //     `equivalence` literal's presence IS a match. A `settled` pattern is
    //     therefore still answered without a confirm.
    //   * The fused GATE does not, and it is left out rather than reused. It is
    //     asked through `docMatches`, so it is a per-LINE over-approximation of
    //     a per-line question — sound there, unsound here in the direction that
    //     matters: the gate `(?:a\sb)` matches no line of `"a\nb"`, so using it
    //     would reject a buffer the pattern matches. A gate that can say no
    //     wrongly is not a gate.

    /// Attribution over the whole buffer as ONE unit: set bit `i` in `mask` for
    /// every pattern matching `bytes`, and return whether any bit was set.
    /// `mask` is caller-owned, `maskWords(len)` long, and cleared first.
    ///
    /// The library counterpart to `docMask` — see the section comment above for
    /// which question each answers and why the confirm is the only difference.
    /// `gpa` is used at most once per `Scratch`, to materialize `Scratch.spans`.
    pub fn bufMask(self: *const PatternSet, bytes: []const u8, sc: *Scratch, gpa: std.mem.Allocator, mask: []u64) CompileError!bool {
        @memset(mask, 0);
        const spans = try self.spanScratch(sc, gpa);
        var any = false;
        if (self.muster) |*m| {
            if (!m.roll(bytes, sc.play)) return false;
            for (sc.play, m.settled, 0..) |w, done, wi| {
                mask[wi] = w & done; // settled ⇒ presence WAS the decision
                any = any or mask[wi] != 0;
                var it = bits.ones(w & ~done);
                while (it.next()) |b| {
                    const i = wi * 64 + b;
                    if (self.queries[i].holds(bytes, true, &spans[i])) {
                        B64.set(mask, i);
                        any = true;
                    }
                }
            }
            return any;
        }
        for (self.queries, spans, 0..) |*q, *ms, i| {
            if (q.holds(bytes, true, ms)) {
                B64.set(mask, i);
                any = true;
            }
        }
        return any;
    }

    /// Does ANY pattern match `bytes` taken as one unit? `bufMask`'s question
    /// without the attribution, stopped at the first yes.
    pub fn bufAnyMatch(self: *const PatternSet, bytes: []const u8, sc: *Scratch, gpa: std.mem.Allocator) CompileError!bool {
        const spans = try self.spanScratch(sc, gpa);
        if (self.muster) |*m| {
            if (!m.roll(bytes, sc.play)) return false;
            for (sc.play, m.settled) |w, done| if (w & done != 0) return true;
            for (self.queries, spans, 0..) |*q, *ms, i| {
                if (!B64.get(sc.play, i)) continue;
                if (q.holds(bytes, true, ms)) return true;
            }
            return false;
        }
        for (self.queries, spans) |*q, *ms| if (q.holds(bytes, true, ms)) return true;
        return false;
    }

    /// `Scratch.spans`, built on first use. Idempotent, and all-or-nothing: a
    /// partial array is torn down rather than cached, so a retry after
    /// exhaustion starts from the same state the first call saw.
    fn spanScratch(self: *const PatternSet, sc: *Scratch, gpa: std.mem.Allocator) CompileError![]query.MatchScratch {
        if (sc.spans.len == self.queries.len) return sc.spans;
        const made = try gpa.alloc(query.MatchScratch, self.queries.len);
        var built: usize = 0;
        errdefer {
            for (made[0..built]) |*m| m.deinit();
            gpa.free(made);
        }
        for (self.queries, 0..) |*q, i| {
            made[i] = try q.matchScratch(gpa);
            built += 1;
        }
        sc.spans = made;
        return made;
    }

    /// The sound trigram prefilter literals for pattern `i` — delegate to the
    /// underlying query so index-backed callers prune candidates per pattern
    /// exactly as the single-pattern engine would.
    pub fn prefilter(self: *const PatternSet, i: usize, one: *[1][]const u8) []const []const u8 {
        return self.queries[i].prefilter(one);
    }
};

/// A word-bounded set over literal `names`: each becomes `\bNAME\b`, so a scan
/// never matches `run` inside `runner`. Names are regex-escaped, so a token
/// carrying regex punctuation stays literal. The specs and their patterns are
/// allocated from `gpa` and must outlive the set — callers building one set per
/// query pass an arena.
pub fn wordSet(gpa: std.mem.Allocator, names: []const []const u8) !PatternSet {
    const specs = try gpa.alloc(Spec, names.len);
    for (names, specs) |name, *s| {
        const escaped = try query.escapeLiteral(gpa, name);
        s.* = .{ .pattern = try std.fmt.allocPrint(gpa, "\\b{s}\\b", .{escaped}), .fixed = false };
    }
    return PatternSet.compile(gpa, specs);
}

/// Words needed for a `docMask` bitmask over `n` patterns.
pub const maskWords = B64.words;

/// Is bit `i` set in a `docMask` bitmask?
pub const maskHas = B64.get;

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
    // `-w` narrows a spec's match set after the fact and `pcre` may mean
    // something the linear engine spells differently, and neither survives the
    // fusion into pattern text. The gate stays — it rejects perfectly well — but
    // it no longer gets to decide. See `gate_exact`.
    for (specs) |s| {
        if (s.word or s.pcre) set.gate_exact = false;
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
