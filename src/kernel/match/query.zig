//! gist search core — the compiled, transport-neutral query (ADR-352).
//!
//! One deep module owns "a search intent, compiled". A `(pattern, fixed,
//! ignore_case, mode)` spec — the whole shape the unified search contract admits
//! — lowers into an immutable matcher: a bare literal for the `-F` no-fold fast
//! path (SIMD substring), else gist's linear-time regex engine (a `-F -i` literal
//! is escaped so the engine does the ASCII case fold). From that one compiled
//! form every face draws the two things it needs — the sound TRIGRAM PREFILTER
//! that prunes index candidates, and the per-doc MATCH / line-COUNT decision.
//!
//! Two invariants make this the shared core the CLI, the resident daemon, and
//! (later) the C FFI can all execute through instead of forking the logic:
//!
//!   • Fail-closed, never fatal. Every entry point RETURNS a typed error — a
//!     pattern outside the linear-time syntax is `error.Unsupported`, an
//!     allocation failure is `error.OutOfMemory` — so a bad query can never
//!     `die()`/exit an embedding host (the exact hazard ADR-352 defers the FFI
//!     on). The CLI's cold path keeps its own `die()` shell; this core does not.
//!   • Thread-safe for the parallel walk. A `CompiledQuery` is immutable after
//!     `compile`; the only per-query mutable state — the regex Pike-VM
//!     simulation — is a caller-owned `Scratch`, one per worker, threaded into
//!     the match primitives. N workers share one compiled query with N scratches.
//!
//! Before this module, the warm engine (`session/resident.zig`) and the cold
//! engine (`runtime/cold/`) each re-derived the required-literal-vs-alts
//! prefilter and re-implemented literal/regex verification; the two "cannot
//! drift" only because they now compile and match through the same code here.

const std = @import("std");
const simd = @import("scan/simd.zig");
const Regex = @import("regex/linear/core.zig").Regex;
const word_mod = @import("regex/syntax/word.zig");

/// The three mode shapes the shared core answers: `files` (any line matches),
/// `count` (how many lines match), and `lines` (the default `path:text` match
/// lines — rendered by the warm session through the cold `Emitter` itself, so
/// the presentation cannot drift). Richer cold-only presentations (context,
/// JSON, replace, --only-matching) stay in `runtime/cold/` — they consume
/// the same match decision but shape their own output.
pub const Mode = enum(u8) { files = 0, count = 1, lines = 2 };

/// A search intent before compilation. Mirrors the resident classifier's
/// `Request` fields (`session/request.zig`) — the transport-neutral subset of
/// the contract's request options.
pub const Spec = struct {
    /// The search pattern. For a `literal` body it is aliased, not copied — the
    /// caller keeps it alive for the query's lifetime.
    pattern: []const u8,
    mode: Mode = .files,
    /// `-F`: treat the pattern as a fixed string, not a regex.
    fixed: bool = false,
    /// `-i`: case-insensitive (Unicode fold when `unicode`, else ASCII).
    ignore_case: bool = false,
    /// Unicode mode (rg default ON): full case-fold orbits and codepoint
    /// `\w`/`\d`/`\s`/`.`/`\p{…}`/`\b`. The daemon stays at this default; the
    /// in-process FFI may explicitly select ASCII through the same compile seam.
    unicode: bool = true,
    /// `-w`/`--word-regexp`: only word-bounded match spans count. This is rg's
    /// POST-MATCH rule, NOT `\b(pat)\b` — a span `[s,e)` counts iff a non-word
    /// codepoint (or the line edge) bounds it on BOTH sides (`wordOk` below,
    /// mirroring `runtime/cold/emit/output.zig::wordOk` over the same shared
    /// `\b` oracle), so a punctuation-only match is still a valid word match.
    word: bool = false,
    /// `-m N`/`--max-count`: cap matching lines PER FILE at N (`0` = unlimited).
    /// rg's explicit `-m0` (match nothing) is resolved at the session boundary
    /// before compilation (`session/request.zig::matchNothing`), so a compiled
    /// query never carries a zero cap that means "nothing".
    max_count: u64 = 0,
};

pub const CompileError = error{
    /// The pattern is outside gist's linear-time regex syntax (e.g. a construct
    /// only PCRE would accept). The caller answers cold rather than approximating.
    Unsupported,
    OutOfMemory,
};

/// Per-query mutable match scratch — the regex simulation state, or nothing for
/// a literal query. One per thread; never shared. Made by `CompiledQuery.scratch`.
pub const Scratch = union(enum) {
    none,
    sim: Regex.Sim,
    /// `-w` over a regex body. The boolean DFA cannot decide `-w` (it has no
    /// span), so a word query carries BOTH VMs: the boolean sim stays the
    /// cheap doc/line pre-gate (word only narrows the match set — a doc/line
    /// the plain engine rejects can never hold a word-valid span), and the
    /// span VM decides word validity per span. Only word queries pay for the
    /// extra scratch; the non-word variants and their hot loops are untouched.
    word: WordScratch,

    pub fn deinit(self: *Scratch) void {
        switch (self.*) {
            .sim => |*s| s.deinit(),
            .word => |*w| {
                w.sim.deinit();
                w.span.deinit();
            },
            .none => {},
        }
    }
};

/// The `-w` regex scratch pair (see `Scratch.word`).
pub const WordScratch = struct { sim: Regex.Sim, span: Regex.SpanSim };

/// A matched byte span `[start, end)` within one line. Aliases the regex
/// engine's own span so the FFI reports the exact offsets the cold `--json`
/// submatch stream does.
pub const Span = Regex.Span;

/// Per-query span scratch for match-record emission (`collectSpans`) — the
/// slot-free span VM (`Regex.SpanSim`) for a regex body, or nothing for a
/// literal (whose spans are plain `indexOf` occurrences). Kept apart from
/// `Scratch`: the boolean `docMatches`/`countLines` hot path never allocates
/// the span maps, and match emission never needs the cheaper boolean scratch.
/// One per thread; never shared. Made by `CompiledQuery.matchScratch`.
pub const MatchScratch = union(enum) {
    none,
    sim: Regex.SpanSim,

    pub fn deinit(self: *MatchScratch) void {
        switch (self.*) {
            .sim => |*s| s.deinit(),
            .none => {},
        }
    }
};

/// A compiled, immutable search intent. Cheap to share across walk workers;
/// `deinit` releases the compiled regex and any escaped-literal buffer.
pub const CompiledQuery = struct {
    mode: Mode,
    /// `-i` was requested — recorded because it makes the trigram required-literal
    /// prefilter an UNsafe proxy for "can match" (the fold changes which bytes
    /// appear), so `prefilter` must decline for a caseless regex.
    caseless: bool,
    /// `-w` was requested: every match face routes through the word-valid span
    /// decision (`docMatchesWord`/`countLinesWord`/`collectSpansWord`). The
    /// trigram prefilter stays FULLY sound under `-w` (word only narrows the
    /// match set; the required literal is still required — cold's
    /// `trigramFilter` likewise keeps the index on), so `prefilter` ignores it.
    word: bool = false,
    /// Unicode mode for the word oracle (`Spec.unicode`; rg-parity default ON).
    unicode: bool = true,
    /// `-m N`: per-file matching-line cap (`0` = unlimited). Only the `count`
    /// face reads it (the `lines`/emit face caps through the cold `Emitter`'s
    /// `max_per_file`; `files` existence is cap-invariant for N≥1). `-m0` never
    /// reaches here — the session short-circuits it (`Request.matchNothing`).
    max_count: u64 = 0,
    body: union(enum) {
        /// `-F` no-fold: verified by `simd.contains`. Aliases `Spec.pattern`.
        literal: []const u8,
        /// The compiled linear-time engine (plain regex, or an escaped `-F -i`).
        regex: Regex,
    },
    /// Owns the escaped-literal buffer for the `-F -i` path (regex over a fixed
    /// string); null otherwise. Freed by `deinit`.
    escaped: ?[]u8 = null,

    /// Lower a spec into a compiled query. `-F` without `-i` becomes a literal
    /// (the SIMD fast path); everything else compiles to the regex engine, with
    /// a fixed `-F -i` string escaped first so the engine, not a raw substring
    /// scan, applies the case fold.
    pub fn compile(gpa: std.mem.Allocator, spec: Spec) CompileError!CompiledQuery {
        if (spec.fixed and !spec.ignore_case)
            return .{ .mode = spec.mode, .caseless = false, .word = spec.word, .unicode = spec.unicode, .max_count = spec.max_count, .body = .{ .literal = spec.pattern } };

        const escaped: ?[]u8 = if (spec.fixed) try escapeLiteral(gpa, spec.pattern) else null;
        errdefer if (escaped) |e| gpa.free(e);

        const re = Regex.compileOpts(gpa, escaped orelse spec.pattern, .{ .caseless = spec.ignore_case, .unicode = spec.unicode }) catch
            return CompileError.Unsupported;
        return .{ .mode = spec.mode, .caseless = spec.ignore_case, .word = spec.word, .unicode = spec.unicode, .max_count = spec.max_count, .body = .{ .regex = re }, .escaped = escaped };
    }

    pub fn deinit(self: *CompiledQuery, gpa: std.mem.Allocator) void {
        switch (self.body) {
            .regex => |*re| re.deinit(),
            .literal => {},
        }
        if (self.escaped) |e| gpa.free(e);
    }

    /// A fresh per-thread match scratch: the regex simulation for a regex body
    /// (plus the span VM under `-w` — see `Scratch.word`), or `.none` for a
    /// literal (SIMD substring / `indexOf` occurrence scans need no state).
    pub fn scratch(self: *const CompiledQuery, gpa: std.mem.Allocator) CompileError!Scratch {
        switch (self.body) {
            .literal => return .none,
            .regex => |*re| {
                var sim = Regex.Sim.init(gpa, re) catch return CompileError.OutOfMemory;
                if (!self.word) return .{ .sim = sim };
                const span = Regex.SpanSim.init(gpa, re) catch {
                    sim.deinit();
                    return CompileError.OutOfMemory;
                };
                return .{ .word = .{ .sim = sim, .span = span } };
            },
        }
    }

    /// The sound trigram prefilter literals for pruning index candidates, or
    /// empty when none apply. A caseless query declines (the fold makes a raw
    /// literal an unsafe proxy). A literal body yields the needle itself (≥3
    /// bytes — a trigram needs three); a regex yields its guaranteed required
    /// literal (≥3), else its per-branch alternation cover (`foo|bar` ⇒
    /// {foo,bar}), both of which the index treats as sound supersets. `one`
    /// backs the single-literal return so the callee allocates nothing.
    pub fn prefilter(self: *const CompiledQuery, one: *[1][]const u8) []const []const u8 {
        if (self.caseless) return &.{};
        switch (self.body) {
            .literal => |needle| {
                if (needle.len < 3) return &.{};
                one[0] = needle;
                return one[0..1];
            },
            .regex => |*re| return regexPrefilter(re, one),
        }
    }

    /// Does any line of `bytes` match? (rg `-l` semantics.) Literal → substring
    /// presence; regex → whole-doc match over the caller's `scratch`. Under
    /// `-w` the decision routes through the word-valid span scan — one branch
    /// HERE, so the non-word bodies below stay byte-for-byte the hot path they
    /// were (the perf guard for the existing warm slate).
    pub fn docMatches(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) bool {
        if (self.word) return self.docMatchesWord(bytes, sc);
        return switch (self.body) {
            .literal => |needle| simd.contains(bytes, needle),
            .regex => |*re| re.docMatch(&sc.sim, bytes),
        };
    }

    /// The `-w` doc gate: does any WORD-VALID span exist anywhere in `bytes`?
    /// A literal body scans whole-doc occurrences directly — the pattern never
    /// carries a newline (session-classifier guarantee) and `\n` is a non-word
    /// byte, so a word neighbor checked against doc bytes is exactly the
    /// per-line rule (`\n` and the line edge are both "not a word char"), and
    /// occurrences in different lines can never overlap. A regex body pre-gates
    /// with the cheap boolean `docMatch` (sound: word only NARROWS the match
    /// set) and then span-scans line by line until one word-valid span appears.
    fn docMatchesWord(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) bool {
        switch (self.body) {
            .literal => |needle| return firstWordHit(self.unicode, bytes, needle) != null,
            .regex => |*re| {
                if (!re.docMatch(&sc.word.sim, bytes)) return false;
                var rest = bytes;
                while (rest.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    const end = nl orelse rest.len;
                    if (lineHasWordMatch(self.unicode, re, rest[0..end], &sc.word)) return true;
                    if (nl == null) break;
                    rest = rest[end + 1 ..];
                }
                return false;
            },
        }
    }

    /// Count matching LINES in `bytes` (rg `-c` semantics), over rg's line model
    /// (`\n` terminates; no phantom final line). Two orthogonal knobs are lifted
    /// to `comptime` here and dispatched ONCE at the top — `-w` (the word-valid
    /// span twin) and `-m N` (the per-file cap: stop scanning this file after
    /// N hits, so `-c` reports min(actual, N)). Every branch is compiled out of
    /// the plain, uncapped loop, keeping it byte-identical to the warm slate.
    pub fn countLines(self: *const CompiledQuery, bytes: []const u8, sc: *Scratch) u64 {
        const capped = self.max_count != 0;
        if (self.word) return if (capped) self.countGeneric(true, true, bytes, sc) else self.countGeneric(true, false, bytes, sc);
        return if (capped) self.countGeneric(false, true, bytes, sc) else self.countGeneric(false, false, bytes, sc);
    }

    /// The one count loop, specialized at `comptime` on `word`/`capped`. The
    /// word variant counts a line iff it holds ≥1 word-valid NON-EMPTY span
    /// (cold's `lineHitWord`); the capped variant halts the file at `max_count`.
    inline fn countGeneric(self: *const CompiledQuery, comptime word: bool, comptime capped: bool, bytes: []const u8, sc: *Scratch) u64 {
        var n: u64 = 0;
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            const line = rest[0..end];
            const hit = if (word) switch (self.body) {
                .literal => |needle| firstWordHit(self.unicode, line, needle) != null,
                .regex => |*re| lineHasWordMatch(self.unicode, re, line, &sc.word),
            } else switch (self.body) {
                .literal => |needle| simd.contains(line, needle),
                .regex => |*re| re.lineMatch(&sc.sim, line),
            };
            if (hit) {
                n += 1;
                if (capped and n >= self.max_count) break;
            }
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return n;
    }

    /// A fresh per-thread SPAN scratch for `collectSpans`: the slot-free span VM
    /// for a regex body, or `.none` for a literal (whose spans are `indexOf`
    /// occurrences, needing no state).
    pub fn matchScratch(self: *const CompiledQuery, gpa: std.mem.Allocator) CompileError!MatchScratch {
        return switch (self.body) {
            .literal => .none,
            .regex => |*re| .{ .sim = Regex.SpanSim.init(gpa, re) catch return CompileError.OutOfMemory },
        };
    }

    /// Append every non-empty match span in `line` (leftmost, non-overlapping)
    /// to `out`. A literal body walks successive `indexOf` occurrences; a regex
    /// body drives the leftmost-first span VM, skipping a zero-width match by one
    /// byte exactly as the cold `--json` submatch iterator does
    /// (`runtime/cold/emit/json.zig::emitSubmatches`), so a match record emitted
    /// here carries byte-identical submatch offsets to the subprocess `--json`
    /// stream. Under `-w` the word-invalid spans are filtered with cold
    /// `nextSpan`'s exact progress rule (branch once at the top — the plain
    /// bodies below are untouched); `-r` replacement stays cold-only.
    pub fn collectSpans(self: *const CompiledQuery, a: std.mem.Allocator, line: []const u8, sc: *MatchScratch, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
        if (self.word) return self.collectSpansWord(a, line, sc, out);
        switch (self.body) {
            .literal => |needle| {
                if (needle.len == 0) return;
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, line, from, needle)) |i| {
                    try out.append(a, .{ .start = i, .end = i + needle.len });
                    from = i + needle.len; // non-overlapping, like rg's leftmost scan
                }
            },
            .regex => |*re| {
                var from: usize = 0;
                while (from <= line.len) {
                    const sp = re.matchSpan(&sc.sim, line, from) orelse break;
                    if (sp.end == sp.start) {
                        from = sp.start + 1; // step past a zero-width match (json.zig parity)
                        continue;
                    }
                    try out.append(a, sp);
                    from = sp.end;
                }
            },
        }
    }

    /// The `-w` twin of `collectSpans` — cold `output.zig::nextSpan`'s exact
    /// span-iteration progress rule: a zero-width span skips one byte, a
    /// word-REJECTED span advances to its end and keeps scanning the same line
    /// (a later occurrence may be word-valid). Only word-valid spans append,
    /// so the FFI record stream stays byte-identical to cold `-w --json`.
    fn collectSpansWord(self: *const CompiledQuery, a: std.mem.Allocator, line: []const u8, sc: *MatchScratch, out: *std.ArrayList(Span)) error{OutOfMemory}!void {
        switch (self.body) {
            .literal => |needle| {
                if (needle.len == 0) return;
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, line, from, needle)) |i| {
                    from = i + needle.len; // non-overlapping, rejected or not (nextSpan's rule)
                    if (!wordOk(self.unicode, line, i, i + needle.len)) continue;
                    try out.append(a, .{ .start = i, .end = i + needle.len });
                }
            },
            .regex => |*re| {
                var from: usize = 0;
                while (from <= line.len) {
                    const sp = re.matchSpan(&sc.sim, line, from) orelse break;
                    if (sp.end == sp.start) {
                        from = sp.start + 1;
                        continue;
                    }
                    from = sp.end;
                    if (!wordOk(self.unicode, line, sp.start, sp.end)) continue;
                    try out.append(a, sp);
                }
            },
        }
    }
};

/// ripgrep `-w`: a match span `[s,e)` is a word match iff bounded by a non-word
/// CODEPOINT (or the line edge) on BOTH sides. The same 2-term composition of
/// the engines' shared `\b` oracle (`regex/syntax/word.zig`) that cold's
/// `runtime/cold/emit/output.zig::wordOk` applies — restated here because the
/// search core cannot import the cold runtime (dependency direction), and both
/// reduce to the one oracle, so they cannot drift.
pub fn wordOk(unicode: bool, hay: []const u8, s: usize, e: usize) bool {
    return !word_mod.wordBefore(unicode, hay, s) and !word_mod.wordAt(unicode, hay, e);
}

/// Leftmost word-valid occurrence of `needle` in `hay`, over rg's
/// non-overlapping leftmost scan — the literal twin of `nextSpan`'s progress
/// rule (a word-rejected occurrence advances past its own end and the scan
/// continues; adjacent repeats like "aa" in "aaa" never overlap). Null when no
/// occurrence is word-valid. An empty needle is never word-valid (a zero-width
/// span never counts under `-w`).
fn firstWordHit(unicode: bool, hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |i| {
        if (wordOk(unicode, hay, i, i + needle.len)) return i;
        from = i + needle.len;
    }
    return null;
}

/// One line's `-w` verdict for a regex body: the cheap boolean pre-gate first
/// (a line the plain engine rejects can never hold a word-valid span), then
/// cold `nextSpan`'s exact loop until the first word-valid non-empty span.
fn lineHasWordMatch(unicode: bool, re: *const Regex, line: []const u8, w: *WordScratch) bool {
    if (!re.lineMatch(&w.sim, line)) return false;
    var from: usize = 0;
    while (from <= line.len) {
        const sp = re.matchSpan(&w.span, line, from) orelse return false;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        from = sp.end;
        if (wordOk(unicode, line, sp.start, sp.end)) return true;
    }
    return false;
}

/// The sound trigram prefilter for a compiled regex, independent of the
/// caseless/mode guards a specific face layers on top: the engine's guaranteed
/// required literal (present in EVERY match) when it is ≥3 bytes, else its
/// per-branch alternation cover (`re.alts`). Shared verbatim by the compiled
/// query above and the cold CLI's `trigramFilter`, so warm and cold cannot drift
/// on which literals are safe to prune by.
pub fn regexPrefilter(re: *const Regex, one: *[1][]const u8) []const []const u8 {
    if (re.required.len >= 3) {
        one[0] = re.required;
        return one[0..1];
    }
    return re.alts;
}

/// Escape a literal into a regex (for the caseless `-F -i` path, where the
/// trigram prefilter is unsafe and the regex engine does the case fold).
/// `pub` because the warm lines renderer (`session/render.zig`) builds its
/// emission `Matcher` from the SAME escaped form the cold `-F` path compiles.
pub fn escapeLiteral(a: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pat) |c| {
        if (std.mem.indexOfScalar(u8, ".^$*+?()[]{}|\\", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
