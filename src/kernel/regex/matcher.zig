//! irregex — the engine-neutral match seam.
//!
//! This package ships two match engines: the linear-time RE2/Pike default
//! (`program/core.zig`, `Regex`) and the opt-in PCRE2 backend (`pcre2/`, `Pcre`)
//! for `-P`. The
//! entire `exec/cold` output layer — the `Emitter`, the `--json` stream,
//! the per-file binary/stats machinery — needs exactly four match primitives
//! (`lineMatch`, `matchSpan`, `docMatch`, `bufMatch`) plus a required-literal for
//! the trigram prefilter and a `nullable`/`multiline` flag, and it needs them
//! WITHOUT knowing which engine produced a span. This module is that seam: a
//! tagged union that dispatches ONCE per line / per span-search (never per byte,
//! so the linear default's hot inner loops keep their direct, monomorphic form)
//! to whichever engine backs the query.
//!
//! The linear arm forwards verbatim to `Regex`, so the default path is
//! byte-for-byte unchanged; the `pcre` arm forwards to `Pcre`. Callers build a
//! `Matcher` from one compiled engine and thread its `Sim`/`SpanSim`/`Probe`
//! scratch (whose tag always matches the matcher's) into the primitives.
//!
//! **One entry here is not a span at all.** Every primitive above is
//! leftmost-first, because that is what a match IS to every consumer of a span.
//! `Probe.onset` is the halting question underneath them — *where does the first
//! acceptance lie* — which the leftmost answer cannot be filtered into (see
//! `linear/dfa/onset.zig`). It is the seam's only entry that reports a position
//! rather than a match, and the only one whose declinature is about the compiled
//! program rather than about the bound.

const std = @import("std");
const core = @import("linear/program/core.zig");
const pcre2 = @import("pcre2/backend.zig");
const onset_mod = @import("linear/dfa/onset.zig");

pub const Regex = core.Regex;
pub const Pcre = pcre2.Pcre;

/// Which engine backs a compiled query. The default `.linear` is this package's
/// linear-time RE2/Pike matcher; `.pcre` is the opt-in PCRE2 backend for `-P`.
pub const Backend = enum { linear, pcre };

/// A compiled query behind one engine, dispatched to at the line/span grain.
pub const Matcher = union(Backend) {
    linear: Regex,
    pcre: Pcre,

    /// One byte-span type across engines, so the output layer names `Matcher.Span`
    /// without reaching into a concrete engine (both engines' `Span` are this).
    pub const Span = Regex.Span;

    /// What to search and what to read while searching — `matchWindow`'s
    /// argument. `Window.whole` is what `matchSpan` passes.
    pub const Window = Regex.Window;

    /// A bounded search's answer, with room for the one thing an optional can't
    /// say: that this engine cannot express the bound (see `matchWindow`).
    pub const Verdict = union(enum) { none, found: Span, decline };

    /// A halting walk's answer: the first position something accepted at, or
    /// nothing, or no machine here (see `Probe.onset`).
    pub const Onset = onset_mod.Onset;

    pub fn deinit(self: *Matcher) void {
        switch (self.*) {
            inline else => |*e| e.deinit(),
        }
    }

    /// The sound trigram prefilter literal present in EVERY match ("" if none) —
    /// `Regex.required` / `Pcre.required`. Never over-claims, so the index can
    /// only ever elide a provable non-candidate read.
    pub fn required(self: *const Matcher) []const u8 {
        return switch (self.*) {
            inline else => |*e| e.required,
        };
    }

    /// The per-branch alternation cover set (`foo|bar` ⇒ {foo,bar}), or empty.
    pub fn alts(self: *const Matcher) []const []const u8 {
        return switch (self.*) {
            inline else => |*e| e.alts,
        };
    }

    /// The pure-literal EQUIVALENCE set (a line matches ⟺ it contains one of
    /// these), or empty. PCRE syntax is analyzed by the library, not this
    /// package's AST, so the pcre arm never claims one (empty ⇒ callers take the
    /// engine path).
    pub fn lits(self: *const Matcher) []const []const u8 {
        return if (self.* == .linear) self.linear.lits else &.{};
    }

    /// Can the pattern match zero-width (`a*`, a bare lookaround)? Governs the
    /// `-o` empty-match progress rule in the shared emitter.
    pub fn nullable(self: *const Matcher) bool {
        return switch (self.*) {
            inline else => |*e| e.nullable,
        };
    }

    /// Whole-buffer (`-U`) semantics: a match may cross `\n` and `^`/`$` anchor
    /// at line boundaries — so callers scan the whole buffer, not split lines.
    pub fn multiline(self: *const Matcher) bool {
        return switch (self.*) {
            inline else => |*e| e.multiline,
        };
    }

    /// Under `-U`, is the whole-buffer boolean (`bufMatch`) exactly the emit
    /// model's "some kept span exists" (rg's `-l`)? A non-nullable pattern
    /// always is: its spans consume bytes, and the emit model only ever drops
    /// zero-width spans (the `\z`-at-EOF style match `bufMatch` still reports).
    /// A nullable pattern keeps the equivalence only when assertion-free — it
    /// then matches zero-width at position 0, which the emit model keeps. The
    /// pcre arm's program isn't inspectable, so nullable pcre declines.
    pub fn bufBoolExact(self: *const Matcher) bool {
        if (!self.nullable()) return true;
        return self.* == .linear and self.linear.assert_free;
    }

    /// Positive prefix-proof soundness under `-U`: may a match found inside a
    /// PREFIX of a body be claimed as a match of the whole body? Requires an
    /// assertion-free pattern — `$`/`\z`/`\b` at the cut would assert against
    /// bytes the prefix doesn't hold. Only the linear arm can prove it (the
    /// compiled program is inspectable); PCRE2 conservatively declines.
    pub fn bufPrefixClosed(self: *const Matcher) bool {
        return self.* == .linear and self.linear.assert_free;
    }

    /// Does the line terminator belong to this pattern — consumed by a class,
    /// asserted against by a line anchor, or claimed by a `\A`/`\z` haystack
    /// anchor? This is rg's "is the line terminator outside
    /// `non_matching_bytes`", the gate `Searcher::multi_line_with_matcher` gives
    /// `-U`: false keeps the LINE-oriented model (roll buffer, line-mode binary
    /// semantics, per-line columns) even under `-U`. The linear arm walks the
    /// compiled program (see `Regex.claimsNewline` for what counts as a claim);
    /// rg's PCRE2 matcher never claims a non-matching line terminator, so
    /// `-P -U` is always the slice model (return true).
    pub fn claimsNewline(self: *const Matcher) bool {
        return self.* == .pcre or self.linear.claimsNewline();
    }

    /// Does the pattern *require* byte `b` (literal or single-byte class)? Backs
    /// rg's NUL policy: rg applies the ban only to its default engine
    /// (`crates/regex/src/config.rs` gates `ban::check`), so the pcre arm — which
    /// handles NUL natively — never bans and returns false.
    pub fn bansByte(self: *const Matcher, b: u8) bool {
        return self.* == .linear and self.linear.bansByte(b);
    }

    /// The sticky match-time error latched during this run (0 = none). Only the
    /// PCRE2 arm can fault (a resource limit on catastrophic input); the linear
    /// engine is failure-free by construction, so it always reports 0. The CLI
    /// mirrors ripgrep's exit-2 when this is non-zero after the search.
    pub fn matchError(self: *const Matcher) c_int {
        return if (self.* == .pcre) pcre2.matchError() else 0;
    }

    /// Per-query boolean-match scratch (one per worker thread; never shared). Its
    /// active tag always matches the matcher it was made from, so the dispatch
    /// below can index the correct arm without a runtime tag check of its own.
    pub const Sim = Scratch(Regex.Sim, Pcre.Sim);

    /// Per-query span-extraction scratch (the `-o`/`--json`/`-w`/`--column` path).
    pub const SpanSim = Scratch(Regex.SpanSim, Pcre.SpanSim);

    /// Per-query scratch for the HALTING walks — the third grain, and the only
    /// one that is not a union over the two engines, because only one of them has
    /// a program to determinize.
    ///
    /// It is scratch for the same reason the other two are: it owns a mutable
    /// determinization memo that no two threads may share. It allocates nothing
    /// until a mode actually asks something of it, so a `Pattern` that is never
    /// asked an anchored or earliest question pays only this struct.
    pub const Probe = struct {
        inner: onset_mod.Probe,

        pub fn init(allocator: std.mem.Allocator, m: *const Matcher) !Probe {
            return .{ .inner = onset_mod.Probe.init(allocator, haltable(m)) };
        }

        pub fn deinit(self: *Probe) void {
            self.inner.deinit();
        }

        /// The first position inside `w` at which a match ENDS — or, `anchored`,
        /// the first at which a match that BEGAN at `w.from` ends, with `.none`
        /// meaning none ever does.
        ///
        /// This is the entry the two request modes reach, and what each of them
        /// does with the answer is the caller's (see `glean/cursor.zig`): an
        /// anchored ask needs only which of the three arms it is, an earliest span
        /// needs one bounded leftmost pass under the position, and an ask that is
        /// both is answered outright.
        ///
        /// `w.to` is clamped to the haystack here rather than asserted, because a
        /// `Window`'s bound is documented as inert past the end and every span
        /// entry already treats it that way.
        pub fn onset(self: *Probe, w: Window, anchored: bool) Onset {
            return self.inner.onset(w.hay, w.from, @min(w.to, w.hay.len), anchored);
        }
    };

    /// Does a halting walk exist for this pattern? A static property of the
    /// compile, so a caller asks once — and the one capability an earliest span
    /// has no fallback for.
    pub fn halts(self: *const Matcher) bool {
        return haltable(self) != null;
    }

    /// The program a halting walk may determinize, or null.
    ///
    /// Two refusals, both structural. **PCRE2** has no inspectable program at all
    /// — its own match is a backtracking search whose earliest form is not
    /// exposed. **A positional assertion** (`^ $ \A \z \b \B`) makes a
    /// determinized state's meaning depend on the gap it was entered at, and a
    /// halting walk that starts partway into a buffer cannot fix those gaps: its
    /// start closure would have to know the word-ness of the byte before `from`
    /// and whether `from` is a line head, neither of which the automaton's own
    /// start state carries. `assert_free` is exactly the class where a walk's
    /// answer depends on the bytes it consumed and nothing else — which is also
    /// the class the buffer-model DFA tier already serves, so nothing is being
    /// narrowed here that the engine served before.
    fn haltable(m: *const Matcher) ?onset_mod.Probe.Program {
        if (m.* != .linear) return null;
        const re = &m.linear;
        if (!re.assert_free) return null;
        return .{ .states = re.states, .start = re.start };
    }

    /// Both boolean/span scratch grains are the same union shape over per-engine
    /// scratch types; one comptime factory owns the init/deinit dispatch for each.
    fn Scratch(comptime L: type, comptime P: type) type {
        return union(Backend) {
            linear: L,
            pcre: P,

            pub fn init(allocator: std.mem.Allocator, m: *const Matcher) !@This() {
                return switch (m.*) {
                    .linear => |*r| .{ .linear = try L.init(allocator, r) },
                    .pcre => |*p| .{ .pcre = try P.init(allocator, p) },
                };
            }
            pub fn deinit(self: *@This()) void {
                switch (self.*) {
                    inline else => |*s| s.deinit(),
                }
            }
        };
    }

    /// Does the pattern match any substring of `line`? (Per-line boolean path.)
    pub fn lineMatch(self: *const Matcher, sim: *Sim, line: []const u8) bool {
        return switch (self.*) {
            inline else => |*e, t| e.lineMatch(&@field(sim, @tagName(t)), line),
        };
    }

    /// Does any line of `doc` match? (rg `-l` line model.)
    pub fn docMatch(self: *const Matcher, sim: *Sim, doc: []const u8) bool {
        return switch (self.*) {
            inline else => |*e, t| e.docMatch(&@field(sim, @tagName(t)), doc),
        };
    }

    /// Is `docMatch` a fused whole-buffer pass (class-run kernel / DFA)?
    /// PCRE2 has no fused doc machine — its docMatch is the per-line loop.
    pub fn docMatchFused(self: *const Matcher) bool {
        return self.* == .linear and self.linear.docMatchFused();
    }

    /// Whole-buffer `-c` line tally via the class-run kernel, or null when
    /// the pattern isn't a byte-exact newline-free class run (PCRE2 included).
    pub fn countRunLines(self: *const Matcher, doc: []const u8) ?u64 {
        return if (self.* == .linear) self.linear.countRunLines(doc) else null;
    }

    /// Will `countRunLines` answer (never null)? The emit layers consult this
    /// BEFORE paying the per-file line split the fused count doesn't need.
    pub fn countRunFused(self: *const Matcher) bool {
        return self.* == .linear and self.linear.countRunFused();
    }

    /// Does the pattern match any substring of the WHOLE buffer under multiline
    /// semantics? (The `-U` whole-buffer twin of `docMatch`.)
    pub fn bufMatch(self: *const Matcher, sim: *Sim, buf: []const u8) bool {
        return switch (self.*) {
            inline else => |*e, t| e.bufMatch(&@field(sim, @tagName(t)), buf),
        };
    }

    /// Leftmost match of the pattern within `hay[from..]`, as a byte span, or
    /// null (`hay` is a line in the per-line default, the buffer under multiline).
    pub fn matchSpan(self: *const Matcher, sim: *SpanSim, hay: []const u8, from: usize) ?Span {
        return switch (self.*) {
            inline else => |*e, t| e.matchSpan(&@field(sim, @tagName(t)), hay, from),
        };
    }

    /// Can this engine honor a **bounded** window — search `[from, to]` while
    /// still reading `hay` end to end for assertion context? The linear engine
    /// can: the bound is a ceiling on its walk, and its closures never stopped
    /// reading the real haystack. PCRE2 cannot, and the reason is structural
    /// rather than an omission — its subject model has one length, so the only
    /// way to stop a match at `to` is to tell the library the subject ends
    /// there, which also moves `$`, `\z`, `\b`, and every lookahead. A shorter
    /// subject is a different question, not a bounded form of this one.
    pub fn windows(self: *const Matcher) bool {
        return self.* == .linear;
    }

    /// Leftmost match of the pattern inside the window `w` (see `Regex.Window`):
    /// it starts at or after `w.from`, ends at or before `w.to`, and every
    /// assertion reads the whole `w.hay`. `.decline` means this engine cannot
    /// express the bound (`windows()` is false and the bound is live) — never a
    /// statement about the haystack, so a caller either asks `windows()` first or
    /// falls back to `matchSpan` and its own filtering.
    pub fn matchWindow(self: *const Matcher, sim: *SpanSim, w: Window) Verdict {
        switch (self.*) {
            .linear => |*re| return if (re.matchWindow(&sim.linear, w)) |sp| .{ .found = sp } else .none,
            // An inert bound asks nothing of the engine, so the pcre arm answers
            // it with the search it already has.
            .pcre => |*p| return if (!w.unbounded()) .decline else if (p.matchSpan(&sim.pcre, w.hay, w.from)) |sp| .{ .found = sp } else .none,
        }
    }
};

test "linear arm forwards match primitives verbatim" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "a.c") };
    defer m.deinit();

    var sim = try Matcher.Sim.init(t.allocator, &m);
    defer sim.deinit();
    try t.expect(m.lineMatch(&sim, "xabcx"));
    try t.expect(!m.lineMatch(&sim, "xyz"));
    try t.expect(m.docMatch(&sim, "line1\naXc\n"));

    var ssim = try Matcher.SpanSim.init(t.allocator, &m);
    defer ssim.deinit();
    const sp = m.matchSpan(&ssim, "xabcx", 0).?;
    try t.expectEqual(@as(usize, 1), sp.start);
    try t.expectEqual(@as(usize, 4), sp.end);
    try t.expect(!m.multiline());
    try t.expect(!m.nullable());
}
