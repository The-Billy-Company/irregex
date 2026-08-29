//! irregex — the engine ladder: every boolean "does this match?" entry point, and
//! the dispatch that picks the cheapest sound machine to answer it. Rungs, in
//! order of cost: a zero-width end-of-line certainty (no scan at all), the SIMD
//! class-run kernel (load bandwidth), the accelerator tier (`rungs.zig` — the
//! optional machines that beat the DFA on the patterns they accept), the
//! byte-class DFA (one table lookup per byte, whole document in one fused pass),
//! and the Pike VM (`pike/search.zig`) as the capped fallback and proven oracle.
//!
//! The tier is consulted through ONE call per entry point, not one per rung:
//! `rungs.zig` owns the order, the admission policy, and the protocol that makes
//! a decider and a sieve answerable by the same switch. Adding a rung never
//! touches this file.
//!
//! Dispatch only — never semantics. Every rung answers identically to the Pike
//! VM; the equality is held by the rg oracle and the differential fuzz, so a
//! rung that cannot decide a haystack (`.unproven`, a Unicode word-boundary
//! quit) falls through instead of guessing. The `*Fused` predicates let callers
//! with their own per-line loops ask *which* machine would answer before paying
//! a line split.

const std = @import("std");
const core = @import("../program/core.zig");
const scratch = @import("../pike/scratch.zig");
const search = @import("../pike/search.zig");
const classrun = @import("../../../scan/classrun.zig");
const prefilter = @import("../../analysis/prefilter.zig");
const dwell = @import("../automata/dwell.zig");

const Regex = core.Regex;
const Sim = scratch.Sim;

/// Does the pattern match any substring of `line`? Linear in `line.len`.
/// Dispatches to the cheapest sound strategy: `^…` seeds only at line start
/// (`.anchored`); a known first-byte set drives a `memchr`-skip search
/// (`.skip`); otherwise the plain re-seed-every-position search (`.plain`,
/// e.g. a bare `$` whose first set is empty).
pub fn lineMatch(re: *const Regex, sim: *Sim, line: []const u8) bool {
    // A `--null-data` record whose pattern cannot cross a newline IS a sequence
    // of lines (`lower.lineLocal`) — so this haystack is not a line at all, it
    // is a small DOCUMENT, and the whole-document walk below already answers
    // "does some line of this match" the cheap way. Splitting here instead
    // would answer the same question while forfeiting every whole-buffer
    // machine the walk has: one SIMD literal pass over the record settles it
    // for the 99% of records that hold no candidate at all, where a split pays
    // per-line dispatch on all eight of them first.
    if (re.split_lines) return walk(re, sim, line, .record);
    return lineMatchOne(re, sim, line);
}

fn lineMatchOne(re: *const Regex, sim: *Sim, line: []const u8) bool {
    // The byte-class DFA is the floor: one table lookup per byte, anchors and
    // all, regardless of match density — what the Pike skip path lost to rg on.
    // Present for every non-pathological pattern; only a powerset blow-up past
    // the cap leaves it null, and then the Pike VM (the proven oracle) serves.
    // Equivalence held by the rg oracle + the DFA-vs-Pike differential fuzz —
    // this is purely dispatch.
    if (re.eol_empty) return true; // matches every line's zero-width end (`\d*$`)
    // The literal engine, cheapest of all: an `.exact` set (the pattern IS an
    // alternation of these literals) decides with one SIMD/Teddy/Aho scan and no
    // automaton; a `.candidate` (cover union or required literal) is a necessary
    // condition, so a miss rejects the line and a hit falls through unchanged.
    if (re.literal_scan) |*set| switch (set.presence(line)) {
        .exact => |matched| return matched,
        .candidate => |nominated| if (!nominated) return false,
    };
    // Class-run patterns skip the automaton entirely: SIMD membership +
    // word-trick run detection at load bandwidth. `.unproven` (codepoint
    // projection met a high byte) falls through to the engines below.
    if (re.classrun) |*cr| switch (cr.scan(line)) {
        .hit => return true,
        .miss => return false,
        .unproven => {},
    };
    // The accelerator tier (`rungs.zig`): the SP-quotient sieve prunes, then
    // whichever decider admitted this pattern answers it outright. All of them
    // decline at compile time by being absent, and `.unproven` falls through to
    // the DFA family below exactly as the class-run kernel's does.
    switch (re.rungs.line(line)) {
        .hit => return true,
        .miss => return false,
        .unproven => {},
    }
    if (re.dfa) |d| {
        // Word-boundary DFA (`\b`/`\B`/`\<`/`\>`): resolves word context at the
        // DFA floor, but under Unicode QUITS (null) on a non-ASCII gap — the
        // Pike VM (the oracle) then resolves that line. `(?-u)` never quits.
        if (d.word_ctx) return d.matchWord(line) orelse search.lineMatchPike(re, sim, line);
        return d.match(line);
    }
    // The eager build declined this pattern's budget, so the same automaton is
    // determinized on demand against this thread's memo. It quits (null) on an
    // undecidable Unicode word gap — retried per line, like the eager walk — or
    // once the memo outgrows its cap, which sticks so later lines don't re-pay a
    // lost cause. Either way the Pike VM answers.
    if (sim.lazy) |*c| if (!c.quit) {
        const v = if (c.lazy.word_ctx) c.matchWord(line) else c.match(line);
        if (v) |hit| return hit;
    };
    return search.lineMatchPike(re, sim, line);
}

/// What a trailing `\n` IS, which is the only thing separating the two
/// newline-delimited haystacks this walk serves.
const Model = enum {
    /// A file, or any `-U` buffer: the final `\n` TERMINATES the last line and
    /// opens no empty line after it (rg's line model).
    document,
    /// A `--null-data` record: its terminator was the NUL and was stripped
    /// before the engine saw it, so a trailing `\n` is ordinary content and
    /// opens the empty line after it — and an empty record is one empty line,
    /// where an empty document is no lines at all.
    record,
};

/// Does any line of `doc` match? rg `-l` line model: `\n` *terminates* a line, so a trailing newline yields no phantom empty final line (only a real blank line matches `^$`) — content after the last `\n` (no terminator) is still a line. (`splitScalar` would emit the phantom and over-match `^$`/`$` on every newline-terminated file vs ripgrep.)
pub fn docMatch(re: *const Regex, sim: *Sim, doc: []const u8) bool {
    return walk(re, sim, doc, .document);
}

fn walk(re: *const Regex, sim: *Sim, doc: []const u8, model: Model) bool {
    // The record model's one extra line, and the only place the two models
    // differ: the empty line a record's trailing `\n` opens, plus the single
    // empty line an empty record IS. Asked once per record rather than folded
    // into the machines below, because it is a constant-cost question about a
    // fixed haystack ("") and every whole-buffer machine below is then free to
    // keep answering the document model it was proven against.
    if (model == .record and (doc.len == 0 or doc[doc.len - 1] == '\n')) {
        if (lineMatchOne(re, sim, "")) return true;
        if (doc.len == 0) return false;
    }
    // `eol_empty` ⇒ every line matches at its zero-width end — but `docMatch`
    // asks whether SOME line matches, which for an empty doc (zero lines, not
    // one empty line) is false. rg agrees: an empty input never matches, even
    // `a*`. Conflating "every" with "some" here over-matched empty files.
    if (re.eol_empty) return doc.len > 0;
    // Literals never span `\n` (per-line only), so "some line holds one" ≡ "the
    // buffer holds one": one whole-buffer scan settles an `.exact` set, and a
    // `.candidate` miss rejects every line at once.
    //
    // A `.candidate` hit also says WHERE, and that is worth as much as the miss.
    // Every match contains the literal and no match crosses `\n`, so a line lying
    // entirely before the literal's first occurrence cannot match — and the machines
    // below may start at the line that holds it instead of at byte zero. Without
    // this, a buffer is crossed twice: once by the substring kernel at SIMD
    // bandwidth, then again from the beginning by the slowest machine in the ladder,
    // to rediscover a position the first pass already had. `find` costs exactly what
    // `presence` cost — it is the same scan with its result kept.
    var body = doc;
    // `findOn` and not `find`: this is a WHOLE-document scan, so it is the one
    // grain where re-pricing the anchor pair on the bytes in hand pays for itself
    // (it declines below its own size gate, so an ordinary file is unaffected).
    if (re.literal_scan) |*set| switch (set.findOn(doc, 0)) {
        .exact => |at| return at != null,
        .candidate => |at| {
            const p = at orelse return false;
            // `-U` is the one model where the offset proves nothing about a start: a
            // match may cross `\n`, so it can begin arbitrarily far left of `p`.
            // Multiline searches enter through `bufMatch`, not here; the guard keeps
            // that fact local to the function whose soundness rests on it.
            if (!re.multiline) body = doc[lineStart(doc, p)..];
        },
    };
    // One SIMD pass over the raw buffer: per-line compiles removed `\n`
    // from the set (`nl_free`), so a run can never cross a line boundary —
    // "some line holds a run" ≡ "the buffer holds a run", newlines and the
    // no-phantom-final-line rule included (min ≥ 1 needs real bytes).
    if (re.classrun) |*cr| if (cr.nl_free) switch (cr.scan(body)) {
        .hit => return true,
        .miss => return false,
        .unproven => {},
    };
    // Same tier, whole-buffer grain. Every rung that answers here has proven no
    // match of its pattern can cross a `\n` — the class-run kernel's `nl_free`
    // argument, discharged per rung at admission — so "some line matches" and
    // "the buffer matches" are the same question and need no line split.
    switch (re.rungs.doc(body)) {
        .hit => return true,
        .miss => return false,
        .unproven => {},
    }
    // The DFA scans the whole buffer in one fused pass (one byte-touch); only a
    // powerset blow-up past the cap leaves it null, and then the Pike VM (proven
    // oracle) serves per line. Equivalence held by the doc-level differential fuzz.
    // A word-boundary DFA has no fused doc scan this rung (`word_ctx`); it runs
    // per line through `lineMatch` (the DFA floor, Pike on a Unicode quit).
    if (re.dfa) |d| if (!d.word_ctx) return d.docMatch(body);
    // Same fused whole-buffer shape from the on-demand driver. A quit falls
    // through to the per-line loop below, which is correct but re-walks what the
    // doc scan already covered — bounded, because the cap that caused the quit is
    // sticky, so subsequent lines go straight to the Pike VM.
    if (sim.lazy) |*c| if (!c.lazy.word_ctx and !c.quit) {
        if (c.docMatch(body)) |hit| return hit;
    };
    // `lineMatchOne` and not `lineMatch`: this loop IS the line split, so
    // re-entering the dispatcher would send a record straight back here.
    var i: usize = 0;
    while (i < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
        if (lineMatchOne(re, sim, body[i..end])) return true;
        i = end + 1;
    }
    return false;
}

/// Start of the line holding `p` — the one seam a whole-buffer per-line scan may
/// begin at without changing what any line is. Bounded by the distance back to the
/// previous `\n`, so it is a line's worth of work however large the buffer.
fn lineStart(doc: []const u8, p: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, doc[0..p], '\n')) |nl| nl + 1 else 0;
}

/// Is `docMatch` a single fused whole-buffer pass (class-run kernel or
/// DFA) rather than the per-line Pike fallback? Callers with their own
/// gated per-line loops (the `-l` emit path) use this to prefer one
/// whole-buffer boolean only when it is actually the faster machine.
pub fn docMatchFused(re: *const Regex) bool {
    if (re.eol_empty) return true;
    // An `.exact` literal engine decides the whole buffer in one scan — a fused
    // whole-buffer machine. A `.candidate` only prunes, so like the sieve it does
    // not count: the machine that decides is still the DFA below.
    if (re.literal_scan) |*set| if (set.authority == .exact) return true;
    if (re.classrun) |*cr| if (cr.decides()) return true;
    // An armed DECIDER is a whole-buffer machine. The sieve deliberately does
    // not count: it narrows the question without answering it, so the machine
    // that actually decides is still the DFA below and the caller's preference
    // should be decided by that.
    if (re.rungs.fused()) return true;
    // A word-boundary DFA runs per line (no fused doc scan this rung), so it
    // is not a whole-buffer machine — callers keep their per-line loop.
    if (re.dfa) |d| return !d.word_ctx;
    // The on-demand driver has the same fused doc scan, so it is a whole-buffer
    // machine too. It may quit mid-document, but this predicate only expresses a
    // preference — `docMatch` handles the quit — and preferring it is right: the
    // alternative for these patterns is the Pike VM, per line.
    if (re.lazy) |l| return !l.word_ctx;
    return false;
}

/// Can `countRunLines` settle this pattern's `-c` tally? True exactly for
/// a `\n`-free class run the kernel decides FINALLY — byte-exact, or a
/// codepoint class whose full ranges it holds. A bare projection defers
/// on high bytes and a `\n`-bearing set's runs cross lines, so both
/// decline. The emit layers consult this BEFORE paying the line split.
pub fn countRunFused(re: *const Regex) bool {
    if (re.eol_empty) return false;
    if (re.classrun) |*cr| return (cr.exact or cr.cp != null) and cr.nl_free;
    return false;
}

/// Count matching lines of `doc` (rg `-c` line model) in ONE whole-buffer pass,
/// or null when the reduction cannot settle counts (`!countRunFused`). Exactly
/// the per-line `lineMatch` tally — held by the differential fuzz — minus the
/// line split and per-line dispatch.
///
/// Two passes answer it, and which one is a claim about the class, not the
/// document. `countLines` STREAMS: every block is classified, which runs at load
/// bandwidth and is unbeatable when members are common. `countLeadLines` JUMPS
/// between the bytes a member can begin with, which is unbeatable when they are
/// rare. `leadJump` decides.
pub fn countRunLines(re: *const Regex, doc: []const u8) ?u64 {
    if (!countRunFused(re)) return null;
    const cr = &re.classrun.?;
    return if (leadJump(re, cr)) countLeadLines(cr, &re.first, doc) else cr.countLines(doc);
}

/// Should the `-c` tally jump between lead bytes instead of streaming blocks?
///
/// Only for a **codepoint** class, and that restriction is the whole argument.
/// For a byte-exact set, streaming classifies each block with a couple of vector
/// compares and never leaves the fast path, so a jump would trade bandwidth for
/// two `memchr`s and a re-scan per candidate line. For a codepoint class,
/// `countLines` must drop the WHOLE 64-byte block to a scalar decode walk the
/// moment any byte in it is ≥ 0x80 — and a member of the class is itself such a
/// byte, so the pass degrades exactly where the answers are. Jumping pays the
/// scalar walk on the candidate's line alone.
///
/// Priced by the same corpus economics and the same bar (`min_profitable_stride`)
/// the START-state dwell uses — the nearest calibrated question, a skip that may
/// run across newlines. Conservative here, since this skip stands down a scalar
/// UTF-8 decode per byte rather than one boolean DFA step, and over-strictness is
/// the cheap direction: dense-Unicode text prices its own lead bytes common and
/// keeps the streaming pass.
fn leadJump(re: *const Regex, cr: *const classrun.ClassRun) bool {
    if (cr.cp == null or re.nullable) return false;
    return re.first.count() != 0 and re.first.economics.beatsDense(dwell.min_profitable_stride);
}

/// `countRunLines`'s jumping pass: hop to the next byte a match can BEGIN with,
/// settle that byte's whole line with the kernel's own per-line verdict, resume
/// after it. Byte-identical to `countLines` by construction rather than by
/// re-derivation — the count is a sum of `ClassRun.scan` verdicts, the same
/// verdict the per-line model asks for.
///
/// Two facts make it sound, and `countRunFused` has already established both.
/// The lead set is a NECESSARY condition (a non-nullable match consumes its
/// first byte from it), so a line holding none of those bytes cannot match and
/// skipping it is free. And `nl_free` means a run cannot cross `\n`, so a line's
/// verdict depends on that line's bytes alone — which is what lets one scan
/// settle the line and the loop resume past it, whether the scan said hit or
/// miss. A line with fifty candidates is therefore scanned once, not fifty times.
///
/// A third fact makes the confirm scan start at the candidate rather than at the
/// line's start, which is what keeps this loop to ONE forward pass over the
/// document. `pos` is always a line start and `p` is the FIRST lead byte at or
/// after it, so `[pos, p)` — and therefore the whole of `p`'s line before `p` —
/// holds no lead byte. Every run begins at a lead byte, so no run in this line
/// can begin left of `p`, and `doc[p..le]` holds exactly the same verdict as the
/// full line. Without it each candidate line was crossed three times: a scalar
/// walk backwards to find its start (`lastIndexOfScalar` has no vector form),
/// then the kernel forwards over bytes the jump had already proven barren.
fn countLeadLines(cr: *const classrun.ClassRun, lead: *const prefilter.Prefilter, doc: []const u8) u64 {
    var count: u64 = 0;
    var pos: usize = 0;
    while (lead.nextStart(doc, pos)) |p| {
        const le = std.mem.indexOfScalarPos(u8, doc, p, '\n') orelse doc.len;
        count += @intFromBool(cr.scan(doc[p..le]) == .hit);
        if (le >= doc.len) break;
        pos = le + 1;
    }
    return count;
}
