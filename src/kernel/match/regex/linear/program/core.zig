//! gist — T2 regex execution: a linear-time Thompson NFA over bytes (RE2 /
//! ripgrep philosophy — no backtracking, no catastrophic blowup), compiled from
//! the AST in `syntax.zig` and run with a Pike simulation. Plus the public
//! `Regex` handle carrying the required-literal that lets a regex reuse the T0
//! trigram prefilter.
//!
//! Grep semantics: a line matches if the pattern matches ANY substring of it
//! (unanchored). We never construct `.*pat.*`; the Pike simulation re-seeds the
//! start thread at every position — the standard linear search. Line anchors
//! `^` / `$` and word boundaries `\b` / `\B` / `\<` / `\>` are zero-width
//! assertions resolved during the epsilon-closure: `^`/`$` from the (start,
//! end)-of-line flags at each position, and the word boundaries from the word-ness
//! of the bytes straddling it (ASCII `[0-9A-Za-z_]`, exactly rg `--no-unicode`).
//! Word-boundary patterns are ALSO determinized: `powerset.build` refines byte
//! classes by ASCII word-ness and doubles the interior table so the DFA selects
//! the transition by the *next* byte's word-ness (`trans_in`/`trans_in_w`,
//! `start`/`start_w`) — resolving `\b`/`\B`/`\<`/`\>` at the DFA floor
//! (`dfa.matchWord`). Under Unicode a gap abutting a non-ASCII scalar is
//! undecidable by an ASCII-classed DFA, so `matchWord` QUITS and the Pike VM (the
//! oracle) resolves that line; a bounded literal still rides the trigram prefilter
//! (`\bfunc\b` ⇒ "func"). Broader Unicode word classes remain out of scope this
//! tier. The equality oracle runs `rg (?-u)…` so semantics coincide exactly.
//!
//! This file is the HANDLE: the immutable compiled state, its lifetime, and the
//! program-walk predicates that read nothing but `states`. The behavior hangs off
//! it from four neighbors — `lower.zig` beside it compiles, `ladder/verdict.zig`
//! picks the engine per boolean question, `pike/` is the linear-time VM, `dfa/`
//! the determinized primary — adopted below as decls, so `Regex.compile`,
//! `re.lineMatch`, `re.matchSpan` … stay one namespace to every caller.

const std = @import("std");
const syn = @import("../../syntax/syntax.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dfa_mod = @import("../dfa/dfa.zig");
const lazy_mod = @import("../dfa/lazy.zig");
const classrun_mod = @import("../../../scan/classrun.zig");
const lower = @import("lower.zig");
const verdict = @import("../ladder/verdict.zig");
const scratch = @import("../pike/scratch.zig");
const search = @import("../pike/search.zig");
const span = @import("../pike/span.zig");

pub const ParseError = syn.ParseError;

// The compiled Thompson-NFA instruction lives in `syntax.zig` (beside the AST it
// lowers from) so `dfa/` can determinize over it without an import cycle.
// Aliased here to keep the engine's references unchanged.
const State = syn.State;

/// A compiled pattern: the Thompson-NFA program plus every verify-time
/// accelerator the scanner consults (required literal, cover/equivalence sets,
/// first-byte prefilter, optional byte-class DFA). Immutable after compile;
/// per-thread scratch lives in `Sim`/`SpanSim`.
pub const Regex = struct {
    states: []State,
    start: u32,
    required: []u8, // longest literal that must appear in every match ("" if none)
    // Alternation cover set: literals (each ≥3 B) whose UNION every match
    // intersects. Non-empty only when `required` is too short for a single-literal
    // prefilter but a `foo|bar`-style union is provable. Empty ⇒ unused.
    alts: []const []const u8,
    // Pure-literal EQUIVALENCE set: non-empty iff the whole pattern is exactly an
    // alternation of these literals (`panic|0x` ⇒ {panic, 0x}) — a line matches
    // ⟺ it contains one of them. Strictly stronger than `alts` (which is mere
    // containment): the boolean scan path may answer from SIMD `contains` alone,
    // with no regex engine run. Empty ⇒ unused. See `analysis.pureLiterals`.
    lits: []const []const u8,
    // Scan accelerators (verify-time, no effect on match semantics): `anchored` —
    // every match begins at line start (`^…`), seed only at pos 0; `first` — the
    // bytes that can BEGIN a match mid-line plus the precomputed skip strategy
    // (`prefilter.zig`), letting the scanner jump over dead spans instead of
    // re-seeding a closure every byte.
    anchored: bool,
    // True iff the start epsilon-reaches `match` at end-of-line (at_start=false,
    // at_end=true) — a nullable prefix then `$` (e.g. `\d*$`, `a*`, `x|$`). Such a
    // pattern matches the zero-width end of EVERY line, so `lineMatch`
    // short-circuits to true; also closes a latent Pike `.skip` soundness hole
    // (skip only seeds first-byte positions and would miss this EOL match).
    eol_empty: bool,
    // True iff the start epsilon-reaches `match` through a zero-width path that may
    // cross a word boundary (`\b{2,}$`, `\B{2}`, `x|\b$`) — a CONDITIONAL empty
    // match `eol_empty` can't see (it won't traverse `\b`/`\B`). The first-byte
    // `.skip` search would miss such a match (it only seeds before a first-byte,
    // never at a bare boundary / EOL), so these patterns take the `.plain` search.
    nullable: bool,
    first: prefilter.Prefilter,
    // T2 byte-class DFA (`dfa/dfa.zig`): the primary match engine — O(1)/byte, anchors
    // included, immutable + scratch-free, scanning a whole document in one fused
    // pass. Non-null unless the powerset blew past the cap, when the Pike VM serves
    // (the `first` prefilter accelerates that fallback's skip search).
    dfa: ?*dfa_mod.Dfa,
    // On-demand determinization (`dfa/lazy.zig`), non-null exactly when a DFA was
    // wanted but the eager build declined the budget (too many states, or too many
    // subset closures to keep finding out — a large Unicode class costs ~15 ms
    // eagerly to discover a small automaton). Same automaton, same `subset.zig`
    // core, materialized one visited state at a time; it carries no tables itself,
    // so the per-thread memo lives in the caller's `Sim`. Both engines are never
    // set at once, and either may quit to the Pike VM, which stays the oracle.
    lazy: ?*lazy_mod.Lazy,
    // SIMD class-run kernel (`scan/classrun.zig`): non-null iff the pattern
    // provably reduces to "≥ min consecutive members of one byte set"
    // (`analysis.classRunShape` — the dense-class family: `\w+`, `[a-z]{3,}`,
    // `[0-9a-f]{8}`). Boolean dispatch consults it FIRST — it answers at load
    // bandwidth where the DFA's chained table walk pays load latency — and a
    // `.unproven` verdict (codepoint-class projection meeting a high byte)
    // falls through to the DFA/Pike engines unchanged. Boolean paths only;
    // `matchSpan` never consults it. Per-line compiles drop `\n` from the set
    // (a line never contains one), which licenses the whole-buffer `docMatch`
    // scan: runs then provably break at every line boundary.
    classrun: ?classrun_mod.ClassRun,
    // Multiline (`-U`): the pattern matches the WHOLE buffer as one haystack — a
    // match may span `\n`, and `^`/`$` anchor at every line boundary (rg's `-U`
    // default), resolved per-position against `\n` adjacency (content-dependent,
    // exactly like `\b`), so the eager `at_start`/`at_end` DFA can't serve an
    // assertion-BEARING multiline regex — it runs the Pike whole-buffer scan
    // (`bufMatch`). An assertion-FREE one (`assert_free`) has nothing positional
    // to resolve, so the DFA serves the whole buffer as one haystack at
    // O(1)/byte. False ⇒ the per-line model, unchanged.
    multiline: bool,
    // No zero-width assertion states in the compiled program (`^ $ \b \B \< \>
    // \A \z`): match validity then depends ONLY on the consumed bytes, which is
    // what licenses the multiline DFA above and makes any prefix-found match a
    // match of the full buffer (substring closure — see `bufMatch` callers).
    assert_free: bool,
    // The regex `m` flag, decoupled from `multiline` (the `-U` whole-buffer
    // search): true ⇒ `^`/`$` anchor at every `\n` (a line boundary), false ⇒
    // only at the buffer ends. Under `-U` it defaults true (rg's `m`-on default)
    // and `(?-m)` clears it — the buffer stays one haystack, but `^` holds only
    // at position 0. In the per-line model it tracks `multiline` (false), where a
    // line's own edges already are its anchors, so the distinction is inert.
    line_anchors: bool,
    // Unicode mode (rg default; `(?-u)`/`--no-unicode` clears it). Drives the
    // word test behind `\b`/`\B`/`\<`/`\>` and `-w`: set, the codepoint straddling
    // a gap is decoded and tested against the full `\w` set; cleared, it's the
    // ASCII single-byte test (byte-for-byte today's behavior). Class/literal
    // Unicode is already baked into the compiled program at parse time; this flag
    // only reaches the content-dependent word-context assertions the Pike VM
    // resolves per position.
    unicode: bool,
    allocator: std.mem.Allocator,

    // ── adopted decls: the handle's namespace, the siblings' implementations ──
    //
    // Zig has no `usingnamespace`, so each sibling's public entry point is bound
    // here by name. Behavior lives next to the state it reasons about; callers
    // still see ONE type (`Regex.compile`, `re.docMatch`, `Regex.Span` …), and
    // moving a function between siblings never touches a call site.

    /// Compile-time knobs (`lower.zig`): `-i` folding, `-U` multiline, dotall,
    /// Unicode, the decoupled `m` flag, and the determinizer's test hook.
    pub const Options = lower.Options;
    pub const compile = lower.compile;
    pub const compileOpts = lower.compileOpts;

    /// The Crest sieve's forced swell — ĝ per top-level alternative — for a
    /// pattern under these same options, derived from the AST `compileOpts`
    /// lowers, by the same parse, so the sieve cannot disagree with this engine
    /// about what a construct means.
    pub const forcedSwell = lower.forcedSwell;

    /// Reusable Pike-simulation scratch (`pike/scratch.zig`), sized to the
    /// program once; `SpanSim` adds the per-state start-offset maps `-o` needs.
    pub const Sim = scratch.Sim;
    pub const SpanSim = scratch.SpanSim;

    /// Boolean questions and their engine ladder (`ladder/verdict.zig`): classrun →
    /// DFA → Pike, plus the `*Fused` predicates naming which machine answers.
    pub const lineMatch = verdict.lineMatch;
    pub const docMatch = verdict.docMatch;
    pub const docMatchFused = verdict.docMatchFused;
    pub const countRunFused = verdict.countRunFused;
    pub const countRunLines = verdict.countRunLines;

    /// The linear-time VM itself (`pike/`): the capped fallback and the oracle
    /// the DFA's differential fuzz compares against, plus `-U` whole-buffer.
    pub const lineMatchPike = search.lineMatchPike;
    pub const bufMatch = search.bufMatch;

    /// `-o` leftmost-first spans (`pike/span.zig`).
    pub const Span = span.Span;
    pub const matchSpan = span.matchSpan;

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.states);
        self.allocator.free(self.required);
        lower.freeAlts(self.allocator, self.alts);
        lower.freeAlts(self.allocator, self.lits);
        if (self.dfa) |d| d.deinit();
        if (self.lazy) |l| l.deinit();
        if (self.classrun) |cr| if (cr.cp) |r| self.allocator.free(r);
        self.* = undefined;
    }

    /// Can any match consume a `\n`? Mirrors rg's `multi_line_with_matcher`
    /// gate: under `-U` a pattern that can never match the line terminator is
    /// searched line-by-line (roll buffer, line-mode binary semantics), not as
    /// one slice — every consuming instruction is a `.consume` byte set, so a
    /// program-walk is a complete answer.
    pub fn canMatchNewline(self: *const Regex) bool {
        return self.canMatchByte('\n');
    }

    /// Can any match consume byte `b`? Walks the consuming instructions — a
    /// program-complete answer, since every byte a match eats is some `.consume`
    /// set.
    pub fn canMatchByte(self: *const Regex, b: u8) bool {
        for (self.states) |st| switch (st) {
            .consume => |c| if (c.set.has(b)) return true,
            else => {},
        };
        return false;
    }

    /// Does the pattern *require* byte `b` somewhere — i.e. is `b` a literal or a
    /// single-byte class? Backs rg's NUL policy (`crates/regex/src/ban.rs`): a
    /// byte is banned only when a sub-expression *must* match it, never when a
    /// broad class (`.`, `[^\x00]`, `[\x00a]`) incidentally includes it. A
    /// literal byte and a `[b]`-style singleton class each lower to a `.consume`
    /// whose set is exactly `{b}` (`only() == b`); wider classes are non-singleton
    /// and never ban. Walking every `.consume` covers all alternation branches,
    /// so `\x00|ab` bans while `[^\x00]` does not — matching rg's HIR walk.
    pub fn bansByte(self: *const Regex, b: u8) bool {
        for (self.states) |st| switch (st) {
            .consume => |c| if (c.set.only() == b) return true,
            else => {},
        };
        return false;
    }
};
