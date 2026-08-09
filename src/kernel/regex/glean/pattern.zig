//! irregex — the handle a consumer holds.
//!
//! `Regex` is what the engine compiled: a program, its prefilters, the facts the
//! walk planner interrogates (`bufPrefixClosed`, `countRunFused`,
//! `claimsNewline`). Every one of those earns its place — they are how the cold
//! pipeline decides what work to skip — and none of them is a question a person
//! with a pattern and a string is asking. Between that type and that person sat
//! a `Sim`, an offset to advance by hand, and no iterator at all.
//!
//! `Pattern` is the other face over the same engine: compile, ask, walk, rewrite.
//! It owns the scratch (`pool.zig`) so no signature mentions one, it compiles the
//! capture arm only if someone asks for a group, and it reaches the PCRE2 backend
//! through the same door as the linear one. Nothing here is a new engine — every
//! method below lowers to a call the walk already makes.
//!
//! **Two types rather than one, because a `Regex` gets copied.** `Matcher` holds
//! one by value, the differential tests hold two side by side. A pool inside
//! `Regex` would make every one of those copies a double free, so the handle
//! that owns scratch is the handle you must not copy, and it is a separate type
//! so that rule attaches to it alone. Move a `Pattern`; never copy one.

const std = @import("std");
const matcher = @import("../matcher.zig");
const captures = @import("../compile/captures.zig");
const lower = @import("../linear/program/lower.zig");
const pcre2 = @import("../pcre2/backend.zig");
const mark = @import("../../../mark.zig");
const pool_mod = @import("pool.zig");
const cursor_mod = @import("cursor.zig");
const groups_mod = @import("groups.zig");
const rewrite = @import("rewrite.zig");

const Matcher = matcher.Matcher;
const Regex = matcher.Regex;
const Pcre = matcher.Pcre;
const Caps = captures.Caps;
const Pool = pool_mod.Pool;

pub const Span = mark.Span;
pub const Window = mark.Window;
pub const Cursor = cursor_mod.Cursor;
pub const Groups = groups_mod.Groups;
pub const Reach = rewrite.Reach;

/// A bound this engine cannot express. Only the PCRE2 backend raises it, and
/// only for a live `Window` bound: its subject model has one length, so the only
/// way to stop a match at `to` is to shorten the subject, which also moves `$`,
/// `\z`, `\b` and every lookahead. Refusing beats quietly answering a different
/// question (see `Matcher.windows`).
pub const BoundError = error{BoundUnsupported};

/// A question this pattern's engine has no machine for. Raised by the earliest
/// verbs alone, and only for a pattern whose compile has no halting walk behind
/// it (`Pattern.halts`): the PCRE arm, or a program carrying a positional
/// assertion. It is a fault rather than a declinature for the reason
/// `BoundUnsupported` is — there is no slower tier that answers it, since a
/// leftmost search does not compute an earliest match at any price — and refusing
/// beats handing back the leftmost span under an earliest label.
pub const EarliestError = error{Unsupported};

/// What a pattern means. The six knobs a caller actually sets, mapped onto each
/// backend's own option record.
///
/// `unicode` defaults **on**, which is this package's documented posture and
/// ripgrep's: `-i` folds, `\b` and `\w` speak codepoints. The engine's internal
/// `Regex.Options` defaults it off because every internal caller sets it
/// explicitly from a parsed flag; a default is a statement about who is asking,
/// and the two askers differ. The engine's remaining knobs (`line_anchors`,
/// `force_dfa`, `symbolic`) are cost and semantics dials for the walk planner
/// and stay behind the `regex` door with it.
pub const Options = struct {
    caseless: bool = false,
    unicode: bool = true,
    dotall: bool = false,
    word: bool = false,
    crlf: bool = false,
    /// Compile with PCRE2 instead of the linear engine — lookaround and
    /// backreferences, at backtracking's worst case.
    pcre: bool = false,

    /// `^` and `$` match at every line break as well as the text's ends —
    /// Python's `re.M`, Rust's and PCRE2's `(?m)`. Off by default, as it is in
    /// all three: `^` means the start of the text you passed. `\A` and `\z` are
    /// the text's ends either way, and are unaffected by this.
    ///
    /// **This is a different question from the one the engine's own `multiline`
    /// asks**, and conflating them is the bug this field exists to keep apart.
    /// Down in `lower.zig`, `multiline` is not about `^` at all; it is the
    /// statement *the haystack is a buffer rather than a single line*, and the
    /// entire per-line model hangs off it. Under that model the compiler is
    /// licensed to assume no haystack ever contains a `\n` — it drops `\n` from
    /// a class run on exactly that promise, and resolves `^`/`$` against the
    /// haystack's own edges because the haystack IS the line.
    ///
    /// `gist` keeps that promise: it feeds one line at a time. A `Pattern` is
    /// handed whole buffers by definition, so it cannot. A `Pattern` compiled
    /// per-line finds nothing at all for `\s`, `\n`, `[\n\t]` or `\s+` over
    /// `"a\nb\n"` — not fewer matches, *none*, because a promise the caller
    /// never made was compiled in as fact. So the buffer model is not a default
    /// here, it is an invariant, and `line_anchors` carries the `(?m)` question
    /// separately rather than riding along with it.
    multiline: bool = false,

    /// The haystack is a buffer, always — see `multiline` above for why this is
    /// not a knob, and `Caps.Selection.lowerOptions`, which forces it for every
    /// reader rather than only for this one.
    fn linear(self: Options) lower.Options {
        return self.selection().lowerOptions();
    }

    /// `word` belongs here as much as in `linear()`. Neither backend takes it as
    /// a match-time flag — each LOWERS it, the linear arm by rewriting the AST
    /// (`syntax/scalars.zig::wordBoundedAst`) and PCRE2 by wrapping the source
    /// in `(?<!\w)(?:…)(?!\w)` — so the engine settles on a word-bounded span by
    /// construction instead of being handed one and asked to judge it.
    ///
    /// That distinction is why omitting it here was not a small leak. A caller
    /// could only have repaired it by filtering the spans afterwards, and a
    /// filter can just reject what it was given where a lowered rule lets the
    /// automaton CHOOSE: under `-w`, `a|ab` over `ab` must report `ab`, which a
    /// post-hoc vet never sees because leftmost-first already committed to `a`.
    fn pcreOpts(self: Options) pcre2.Options {
        return .{
            .caseless = self.caseless,
            .unicode = self.unicode,
            // PCRE2 has no per-line model to opt out of - its haystack is
            // always the buffer - so its `multiline` is only ever the `(?m)`
            // question, and takes the caller's answer to it directly.
            .multiline = self.multiline,
            .dotall = self.dotall,
            .word = self.word,
        };
    }

    fn selection(self: Options) Caps.Selection {
        return .{
            .caseless = self.caseless,
            .unicode = self.unicode,
            .pcre = self.pcre,
            .multiline = self.multiline,
            .dotall = self.dotall,
            .word = self.word,
            .crlf = self.crlf,
        };
    }
};

/// A compiled pattern, its scratch, and everything you can ask of it.
pub const Pattern = struct {
    gpa: std.mem.Allocator,
    engine: Matcher,
    scratch: Pool,
    /// The pattern text, kept so the capture arm can be compiled on demand
    /// rather than for everyone. A capture VM is a second program; charging
    /// every `isMatch` for one nobody asked for is the cost this defers.
    src: []u8,
    sel: Caps.Selection,
    caps: ?Caps = null,
    slots: []isize = &.{},

    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8) !Pattern {
        return compileOpts(gpa, pattern, .{});
    }

    pub fn compileOpts(gpa: std.mem.Allocator, pattern: []const u8, opts: Options) !Pattern {
        const src = try gpa.dupe(u8, pattern);
        errdefer gpa.free(src);
        var engine: Matcher = if (opts.pcre)
            .{ .pcre = try Pcre.compileOpts(gpa, pattern, opts.pcreOpts()) }
        else
            .{ .linear = try Regex.compileOpts(gpa, pattern, opts.linear()) };
        errdefer engine.deinit();
        return .{
            .gpa = gpa,
            .engine = engine,
            .scratch = Pool.init(gpa),
            .src = src,
            .sel = opts.selection(),
        };
    }

    pub fn deinit(self: *Pattern) void {
        if (self.caps) |*c| c.deinit();
        if (self.slots.len > 0) self.gpa.free(self.slots);
        self.scratch.deinit();
        self.engine.deinit();
        self.gpa.free(self.src);
        self.* = undefined;
    }

    // ── asking ───────────────────────────────────────────────────────────────

    /// Does the pattern match anywhere in `hay`?
    ///
    /// The boolean grain, which is not merely `find() != null`: it runs the
    /// engine's boolean path, which may answer from a lazy DFA or a fused
    /// class-run scan and never builds the per-state offset maps a span needs.
    ///
    /// The fast path is taken only where the engine PROVES it exact, and all
    /// three conditions were found the same way — by generating patterns and
    /// comparing the two verbs, which is the only way this class of bug shows up.
    ///
    ///   * a non-empty haystack. The boolean kernels come from a line model in
    ///     which an empty buffer has no lines and therefore no match, but `b*`
    ///     matches zero-width at 0 and `re.search` agrees. Walking an empty
    ///     haystack costs nothing anyway.
    ///   * `bufBoolExact` — rules out a nullable pattern whose zero-width match
    ///     the boolean model is entitled to drop.
    ///   * `!claimsNewline` — rules out a pattern that can match the line
    ///     terminator, because a boolean kernel may treat a newline as an edge:
    ///     `\n]*()` over `"a\nb"` is a match that `bufMatch` alone calls none.
    ///
    /// Otherwise it walks. A cheap verb that disagrees with the expensive one is
    /// worse than no cheap verb, since the whole reason to call it is to decide
    /// whether to pay for spans — and `query`'s `holds`, which this plane's C ABI
    /// used before, was always the walk anyway. So the guard costs nothing that
    /// was previously being saved, and buys the DFA path where it is sound.
    pub fn isMatch(self: *Pattern, hay: []const u8) !bool {
        if (hay.len != 0 and self.engine.bufBoolExact() and !self.engine.claimsNewline()) {
            const loan = try self.scratch.boolean(&self.engine);
            defer loan.release();
            return self.engine.bufMatch(loan.sim, hay);
        }
        return (try self.find(hay)) != null;
    }

    /// Whether `win` holds a match — bounded search, full-haystack assertions
    /// (see `mark.Window`). `BoundUnsupported` when the backend cannot express a
    /// live bound.
    ///
    /// No boolean fast path, and not because one was forgotten: every kernel
    /// `isMatch` reaches for answers a question about a whole buffer, so the only
    /// way to ask it about a region is to hand it a shorter buffer — which moves
    /// the haystack edges and is the precise thing a window exists not to do. The
    /// walk is already the honest answer here, so this is `findIn` with the span
    /// dropped rather than a second search strategy that could disagree with it.
    pub fn isMatchIn(self: *Pattern, win: Window) !bool {
        return (try self.findIn(win)) != null;
    }

    /// The leftmost match in `hay`, or null.
    pub fn find(self: *Pattern, hay: []const u8) !?Span {
        return self.findIn(Window.whole(hay, 0));
    }

    /// The leftmost match inside `win` — bounded search, full-haystack
    /// assertions (see `mark.Window`). `BoundUnsupported` when the backend
    /// cannot express a live bound.
    pub fn findIn(self: *Pattern, win: Window) !?Span {
        const loan = try self.scratch.spans(&self.engine);
        defer loan.release();
        return switch (self.engine.matchWindow(loan.sim, win)) {
            .found => |sp| sp,
            .none => null,
            .decline => BoundError.BoundUnsupported,
        };
    }

    /// Every non-overlapping match in `hay`, pulled one at a time. The cursor
    /// borrows the pattern and the haystack and holds a scratch loan — `deinit`
    /// it before the pattern goes away.
    pub fn matches(self: *Pattern, hay: []const u8) !Cursor {
        return self.matchesIn(Window.whole(hay, 0));
    }

    /// Every non-overlapping match inside `win`. `BoundUnsupported` when the
    /// backend cannot express a live bound — checked once, here, so `Cursor.next`
    /// never has to answer for it.
    pub fn matchesIn(self: *Pattern, win: Window) !Cursor {
        return self.walk(win, .{});
    }

    /// The match that begins exactly at `win.from`, or null — the anchored
    /// single find (`Cursor.Mode.anchored` for what "anchored" means here, and why
    /// it is not `\A`).
    ///
    /// It is the first step of `matchesAt` rather than its own search, which is
    /// the only way the two can be guaranteed to agree about where a run begins —
    /// and it is where the halting walk earns its keep: the answer to "does
    /// anything begin here" no longer costs a leftmost hunt across the positions
    /// this verb was never allowed to report from.
    pub fn findAt(self: *Pattern, win: Window) !?Span {
        var cur = try self.matchesAt(win);
        defer cur.deinit();
        return cur.next();
    }

    /// Whether a match begins exactly at `win.from` — `findAt` with the span
    /// dropped, except that it usually never extracts one.
    ///
    /// The halting walk answers this outright: an acceptance means a match begins
    /// here, and a dead automaton means none does, so nothing has to be located to
    /// decide it. Falls back to `findAt` for a pattern with no halting machine,
    /// which is the same answer at the old price.
    pub fn isMatchAt(self: *Pattern, win: Window) !bool {
        if (!win.unbounded() and !self.engine.windows()) return BoundError.BoundUnsupported;
        const loan = try self.scratch.probes(&self.engine);
        defer loan.release();
        return switch (loan.sim.onset(win, true)) {
            .at => true,
            .none => false,
            .decline => (try self.findAt(win)) != null,
        };
    }

    /// Every match inside `win`, each beginning where the previous one ended —
    /// the contiguous walk a tokenizer wants, stopping at the first position
    /// nothing starts at. See `Cursor.Mode.anchored`.
    pub fn matchesAt(self: *Pattern, win: Window) !Cursor {
        return self.walk(win, .{ .anchored = true });
    }

    /// The EARLIEST match in `hay` — the one that ends first, which is not the
    /// leftmost one and cannot be filtered out of it. See `Cursor.Mode.earliest`.
    pub fn earliest(self: *Pattern, hay: []const u8) !?Span {
        return self.earliestIn(Window.whole(hay, 0));
    }

    /// The earliest match inside `win`. `Unsupported` when this pattern has no
    /// halting machine (`halts`), because there is no leftmost answer to fall back
    /// on that would still be an earliest one.
    pub fn earliestIn(self: *Pattern, win: Window) !?Span {
        var cur = try self.walk(win, .{ .earliest = true });
        defer cur.deinit();
        return cur.next();
    }

    /// Can this pattern be asked an earliest question at all? A static property of
    /// the compile — a `Pattern` on the PCRE arm, or one carrying a positional
    /// assertion, has no machine that can halt at an acceptance (see
    /// `Matcher.halts`). Ask once after compiling rather than per search, exactly
    /// as with `Matcher.windows`.
    pub fn halts(self: *const Pattern) bool {
        return self.engine.halts();
    }

    /// Every match inside `win` under `mode` — the one walk all three named
    /// spellings above are, and the entry a caller holding request bits wants
    /// rather than a switch over pairs of verbs.
    ///
    /// `BoundUnsupported` when the backend cannot express a live bound;
    /// `Unsupported` when `mode.earliest` asks a pattern with no halting machine.
    /// Both are checked once, here, so `Cursor.next` never has to answer for
    /// either.
    pub fn walk(self: *Pattern, win: Window, mode: Cursor.Mode) !Cursor {
        if (!win.unbounded() and !self.engine.windows()) return BoundError.BoundUnsupported;
        // Refused here rather than mid-walk, for the same reason a bound is: a
        // cursor that cannot answer the question it was opened for should never
        // exist, and `Cursor.next` has no channel to say so through.
        if (mode.earliest and !self.halts()) return EarliestError.Unsupported;
        // Borrowed only by a mode that asks it something. An ordinary walk never
        // opens one, so the leftmost sequence keeps exactly the cost it had.
        const probe: ?Pool.Probes = if (mode.anchored or mode.earliest) try self.scratch.probes(&self.engine) else null;
        errdefer if (probe) |p| p.release();
        return Cursor.init(&self.engine, try self.scratch.spans(&self.engine), win, mode, probe);
    }

    /// How many non-overlapping matches `hay` holds.
    pub fn count(self: *Pattern, hay: []const u8) !usize {
        var cur = try self.matches(hay);
        defer cur.deinit();
        return cur.tally();
    }

    // ── capture groups ───────────────────────────────────────────────────────

    /// The capture groups of the leftmost match in `hay`, or null if it does not
    /// match. Compiles the capture arm on first use.
    ///
    /// The result borrows this pattern's slot buffer, so it is valid until the
    /// next capture query on the same pattern — copy out what you keep.
    pub fn groups(self: *Pattern, hay: []const u8) !?Groups {
        return self.groupsFrom(hay, 0);
    }

    /// The capture groups of the leftmost match at or after `from`.
    pub fn groupsFrom(self: *Pattern, hay: []const u8, from: usize) !?Groups {
        const caps = try self.capsArm();
        if (!caps.find(hay, from, self.slots)) return null;
        return Groups{ .caps = caps, .hay = hay, .slots = self.slots };
    }

    /// Which ordinal `(?<name>…)` refers to, or null when the pattern has no
    /// such group. Answerable without a haystack, which is what a caller
    /// validating a pattern against a config wants.
    pub fn group(self: *Pattern, name: []const u8) !?usize {
        return (try self.capsArm()).groupByName(name) orelse null;
    }

    /// How many groups the pattern declares, group 0 (the whole match) included
    /// — the same counting as `Groups.len`, answerable without a haystack.
    pub fn groupCount(self: *Pattern) !usize {
        return (try self.capsArm()).nslots() / 2;
    }

    /// The name group `i` was declared with, or null for a plain `(…)`. The
    /// inverse of `group`, and the direction a caller cannot get any other way:
    /// recovering it from the pattern text means re-parsing for `(?<…>)`
    /// spellings, where an escaped `\(` and a non-capturing `(?:` both fool the
    /// obvious scan. The bytes borrow the compiled arm.
    pub fn groupName(self: *Pattern, i: usize) !?[]const u8 {
        return (try self.capsArm()).nameOfGroup(@intCast(i));
    }

    fn capsArm(self: *Pattern) !*Caps {
        if (self.caps == null) {
            var arm = try Caps.compile(self.gpa, self.src, self.sel);
            errdefer arm.deinit();
            self.slots = try self.gpa.alloc(isize, arm.nslots());
            self.caps = arm;
        }
        return &self.caps.?;
    }

    // ── rewriting ────────────────────────────────────────────────────────────

    /// `hay` with every match replaced by `with`. Caller owns the result.
    pub fn replaceAll(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8, with: []const u8) ![]u8 {
        return self.replaceReach(gpa, hay, with, .all);
    }

    /// `hay` with the first match replaced by `with`. Caller owns the result.
    pub fn replaceFirst(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8, with: []const u8) ![]u8 {
        return self.replaceReach(gpa, hay, with, .{ .first = 1 });
    }

    /// `hay` with `reach`-many matches replaced by `with`.
    pub fn replaceReach(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8, with: []const u8, reach: Reach) ![]u8 {
        var cur = try self.matches(hay);
        defer cur.deinit();
        return rewrite.replace(gpa, &cur, with, reach);
    }

    /// `hay` with each match replaced by whatever `writer` emits for it — the
    /// form that can reach capture groups, without a `$1` template grammar to
    /// parse. See `rewrite.replaceWith` for the shape `writer` must have.
    pub fn replaceWith(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8, writer: anytype, reach: Reach) ![]u8 {
        var cur = try self.matches(hay);
        defer cur.deinit();
        return rewrite.replaceWith(gpa, &cur, writer, reach);
    }

    /// The runs of `hay` between matches. Pieces borrow `hay`; the slice of them
    /// is the caller's to free.
    pub fn split(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8) ![][]const u8 {
        return self.splitReach(gpa, hay, .all);
    }

    /// The runs of `hay` between at most `reach` matches — the trailing piece
    /// holds everything the limit left unsplit.
    pub fn splitReach(self: *Pattern, gpa: std.mem.Allocator, hay: []const u8, reach: Reach) ![][]const u8 {
        var cur = try self.matches(hay);
        defer cur.deinit();
        return rewrite.split(gpa, &cur, reach);
    }

    // ── what the engine decided ──────────────────────────────────────────────

    /// The compiled program behind this handle, for a caller that needs the
    /// planner's face — the prefilter literals, the fused-count questions, the
    /// bounded-window capability. Borrowed; the pattern still owns it.
    pub fn engineOf(self: *Pattern) *const Matcher {
        return &self.engine;
    }

    /// The literal that must appear in every match (`""` when there is none) —
    /// a sound prefilter, never over-claimed, and the one fact an *index* needs
    /// from a pattern in order to elide reads without ever overruling bytes.
    pub fn required(self: *const Pattern) []const u8 {
        return self.engine.required();
    }

    /// Can the pattern match zero-width? What a caller writing its own walk
    /// needs in order to get the advance rule right (`Cursor` already has).
    pub fn nullable(self: *const Pattern) bool {
        return self.engine.nullable();
    }
};
