//! gist — the Pike VM's boolean walks: does the pattern match *anywhere* in this
//! haystack? A generation-stamped thread list steps one byte at a time, so the
//! cost is O(states)/byte with no backtracking and no catastrophic blowup — the
//! capped-powerset fallback behind the DFA, and the proven oracle the DFA's
//! differential fuzz compares against.
//!
//! Two haystack models share the machinery: `lineMatchPike` scans one line
//! (comptime-specialized by seeding policy — anchored · first-byte skip · plain)
//! and `bufMatch` scans a whole `-U` buffer, where `^`/`$` are resolved per
//! position against `\n` adjacency instead of an external BOL/EOL flag.

const std = @import("std");
const core = @import("../program/core.zig");
const word = @import("../../syntax/word.zig");
const scratch = @import("scratch.zig");
const eps = @import("closure.zig");

const Regex = core.Regex;
const Sim = scratch.Sim;
const ThreadList = scratch.ThreadList;
const wordAt = word.wordAt;
const wordBefore = word.wordBefore;

const Scan = enum { anchored, skip, plain };

/// The Pike-VM-only dispatch (anchored fast path · first-byte skip · plain
/// re-seed). The `lineMatch`/`docMatch` fallback when the powerset blew past
/// the cap and no DFA was built, and the correctness reference the DFA's
/// differential fuzz compares against (so the test can force the Pike path).
pub fn lineMatchPike(re: *const Regex, sim: *Sim, line: []const u8) bool {
    if (re.eol_empty) return true; // see `eol_empty`: matches every line (`\d*$`)
    if (re.anchored) return search(re, sim, line, .anchored);
    // A conditionally-nullable pattern (`x|\b$`, `\B{2}`) can match zero-width
    // at a bare boundary / EOL the `.skip` search never seeds — it only jumps
    // to first-bytes. `.plain` re-seeds every position (EOL included), so it's
    // the sound path even when a first-set exists from another branch.
    if (re.nullable) return search(re, sim, line, .plain);
    if (re.first.count() != 0) return search(re, sim, line, .skip);
    return search(re, sim, line, .plain);
}

/// Unified Pike search, specialized at comptime by seeding policy:
///   `.anchored` — never re-seed; the instant the thread list drains, done
///                 (a match can only begin at line position 0).
///   `.skip`     — re-seed a start only where a byte could begin a match, and
///                 when the list empties jump to the next such byte (skipping
///                 dead spans the way rg's literal prefilter does). Equivalent
///                 to seeding every position — a start whose first byte isn't
///                 in `first` dies at once — minus the wasted closure work.
///   `.plain`    — re-seed the start at every position (first set empty).
fn search(re: *const Regex, sim: *Sim, line: []const u8, comptime mode: Scan) bool {
    sim.gen += 1;
    sim.cur.len = 0;
    // Position 0: line start; also the end iff the line is empty. Answers any
    // empty/zero-width match (`a*`, `^$`) without scanning. `\b` here straddles
    // BOL (no byte before) and line[0].
    if (eps.closure(re, sim, &sim.cur, true, line.len == 0, wordBefore(re.unicode, line, 0), wordAt(re.unicode, line, 0)).add(re.start)) return true;
    if (mode == .skip) sim.cur.len = 0; // drive purely by first-byte jumps
    var i: usize = 0;
    while (i < line.len) {
        if (sim.cur.len == 0) switch (mode) {
            .anchored => return false, // no live thread, no new start allowed
            .skip => {
                i = re.first.nextStart(line, i) orelse return false;
                sim.gen += 1;
                sim.cur.len = 0;
                if (eps.closure(re, sim, &sim.cur, i == 0, i + 1 == line.len, wordBefore(re.unicode, line, i), wordAt(re.unicode, line, i)).add(re.start)) return true;
            },
            .plain => {},
        };
        const c = line[i];
        sim.nxt.len = 0;
        sim.gen += 1;
        // The next closure sits at the gap AFTER byte i (position i+1): the
        // word byte before it is line[i], the one after is line[i+1].
        const cl = eps.closure(re, sim, &sim.nxt, false, i + 1 == line.len, wordBefore(re.unicode, line, i + 1), wordAt(re.unicode, line, i + 1));
        var matched = false;
        for (sim.cur.slice()) |s| switch (re.states[s]) {
            // `and` keeps `add` from firing on a non-matching byte; `or matched`
            // accumulates without clobbering an earlier hit this position.
            .consume => |cn| matched = (cn.set.has(c) and cl.add(cn.out)) or matched,
            else => {},
        };
        switch (mode) { // re-seed the next start per policy
            .anchored => {},
            .plain => matched = cl.add(re.start) or matched,
            .skip => matched = (i + 1 < line.len and re.first.has(line[i + 1]) and cl.add(re.start)) or matched,
        }
        std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
        if (matched) return true;
        i += 1;
    }
    return false;
}

// ─────────────────────── multiline (`-U`) whole-buffer match ───────────────────────
//
// In multiline mode the pattern is matched against the ENTIRE buffer as one
// haystack — a match may cross `\n` — and `^`/`$` are line-boundary anchors
// (they hold at the buffer ends AND around every `\n`, rg's `-U` default).
// Those anchors are content-dependent (they look at the byte adjacent to the
// position, exactly like `\b`), so the eager BOL/EOL DFA can't serve them and
// `re.dfa` is null here; a whole-buffer Pike scan resolves them per-position.
// `.` and negated classes already had their `\n` membership decided at parse
// time from the multiline/dotall flags.

/// Does the pattern match any substring of the WHOLE buffer under multiline
/// semantics? Linear in `buf.len`: re-seed the start at every position (the
/// plain unanchored search — a `^`-anchored branch simply dies wherever the
/// per-position line-start assertion fails), threading `\n`-aware `^`/`$`.
/// This is the multiline counterpart to `docMatch`; called only when
/// `re.multiline` (the caller passes the whole file's bytes, never a split line).
pub fn bufMatch(re: *const Regex, sim: *Sim, buf: []const u8) bool {
    // An empty document has zero lines, so it never matches — rg's line model
    // (`rg -U` on a zero-byte file reports no match for ANY pattern, even a
    // nullable `a*`/`^$`). This is the whole-buffer twin of `docMatch`'s
    // `doc.len > 0` guard; without it a nullable pattern would spuriously hit.
    if (buf.len == 0) return false;
    // Class-run existence is position-independent, so it holds under `-U`
    // exactly as written: the buffer is the haystack, `\n` stayed in the
    // set if the pattern admits it. Sound even when the program carries
    // assertions (a nullable wrapper can hide `^`/`\b` without weakening
    // the reduction — see `analysis.classRunShape`), which also rescues
    // patterns the multiline DFA refused.
    if (re.classrun) |*cr| switch (cr.scan(buf)) {
        .hit => return true,
        .miss => return false,
        .unproven => {},
    };
    // Assertion-free multiline: the DFA is exact over the whole buffer as one
    // haystack (no `^`/`$`/`\b` to resolve; `trans_fin` ≡ `trans_in` when no
    // assert_end exists, so the last-byte table is inert) — one table lookup
    // per byte instead of a Pike closure per byte. Equivalence held by the
    // multiline differential fuzz in `../dfa/dfa_test.zig`.
    if (re.assert_free) if (re.dfa) |d| return d.match(buf);
    sim.gen += 1;
    sim.cur.len = 0;
    // Position 0 (buffer start ⇒ a line start; also a line end iff empty).
    if (eps.closureBuf(re, sim, &sim.cur, buf, 0).add(re.start)) return true;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        sim.nxt.len = 0;
        sim.gen += 1;
        const cl = eps.closureBuf(re, sim, &sim.nxt, buf, i + 1);
        var matched = false;
        for (sim.cur.slice()) |s| switch (re.states[s]) {
            .consume => |cn| matched = (cn.set.has(c) and cl.add(cn.out)) or matched,
            else => {},
        };
        // Plain re-seed a start at i+1 — EXCEPT at the phantom position after
        // a trailing final `\n`: that gap belongs to no line (rg's line model
        // opens no phantom empty last line), so no match may START there. A
        // bare `\z` therefore does NOT match "abc\n" while `\n\z` (a thread
        // started at the real last byte) does — both verified against rg -U.
        const phantom = i + 1 == buf.len and c == '\n';
        if (!phantom) matched = cl.add(re.start) or matched;
        std.mem.swap(ThreadList, &sim.cur, &sim.nxt);
        if (matched) return true;
    }
    return false;
}
