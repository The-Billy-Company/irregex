//! gist `rg` — the line-free literal fast path.
//!
//! Split from `output.zig`: ripgrep's searcher-loop architecture (candidate
//! jump → line bounds → confirm → skip the line) for a pure-literal pattern.
//! Where `grid.zig` walks an already-split line array, this skims the raw body
//! hit to hit and never materializes one — a literal carries no newline, so a
//! SIMD jump lands strictly inside a line whose bounds two memchrs recover.
//!
//! It emits through the same `Emitter` vocabulary and `display.zig` frame as
//! `grid`, so its bytes are identical by construction, not by re-derivation.

const std = @import("std");
const simd = @import("../../../../../kernel/match/scan/simd.zig");
const palette = @import("../color.zig");
const Matcher = @import("../../../../../kernel/match/regex/regex.zig").Matcher;
const output = @import("../output.zig");
const Emitter = output.Emitter;
const display = @import("display.zig");

/// Is the literal set prefix-free — no literal a prefix of another? Then at
/// most one literal matches at any offset (two matching one start ⟺ one is a
/// prefix of the other), which is exactly the condition under which the
/// NFA-free `litNextSpan` reproduces `matchSpan`'s leftmost-first spans. O(k²)
/// over a ≤8-literal set, computed once per file.
fn prefixFree(lits: []const []const u8) bool {
    for (lits, 0..) |a, i| for (lits, 0..) |b, j| {
        if (i != j and a.len <= b.len and std.mem.eql(u8, b[0..a.len], a)) return false;
    };
    return true;
}

/// Prefix-free pure-literal span at/after `from` — the NFA-free twin of
/// `nextSpan` for `-o`/`--count-matches`/`--column` on the fast path. When
/// no literal is a prefix of another (`prefixFree`), at most one literal
/// matches at any offset, so leftmost-first collapses to "nearest literal,
/// span `[p, p+len)`": one `indexOfAnyPos` jump, then identify the (unique)
/// literal at `p`. Byte-identical to `matchSpan` for such a set, with no
/// Pike-VM run per line. Literals are non-empty, so there is no zero-width
/// case; `-w`/`-i` are already excluded by `litFastEligible`.
fn litNextSpan(lits: []const []const u8, mv: []const u8, from: usize) ?Matcher.Span {
    const p = simd.indexOfAnyPos(mv, from, lits) orelse return null;
    for (lits) |lit| if (p + lit.len <= mv.len and std.mem.eql(u8, mv[p..][0..lit.len], lit))
        return .{ .start = p, .end = p + lit.len };
    return null; // unreachable for a prefix-free set (the jump found a hit)
}

/// `-o` emit for a prefix-free literal set — `emitMatches` without the
/// Pike VM. Same helpers (`prefix`/`paint`/`add`), so output is byte-exact.
fn emitMatchesLit(self: *Emitter, lits: []const []const u8, path: []const u8, lineno: usize, line: []const u8, mv: []const u8) usize {
    var from: usize = 0;
    var n: usize = 0;
    while (litNextSpan(lits, mv, from)) |span| {
        from = span.end;
        self.prefix(path, lineno, span.start + 1, self.offOf(line) + span.start, true);
        self.paint(palette.match_on, line[span.start..span.end]);
        self.add(self.o.outTerm());
        n += 1;
    }
    return n;
}

/// Eligible for the line-free literal fast path (`fileLit`)? Needs the
/// pure-literal match EQUIVALENCE (`re.lits`, empty under `-i`/`-w`/`-U`) so
/// every candidate line provably matches, and a mode whose output does not
/// depend on the physical line grid: no context window (`-A/-B/-C`), invert,
/// passthru, vimgrep, `--stats`, `--stop-on-nonmatch`, or `-r` replacement.
/// The eligible modes — plain, `-n`, `--column`, `-o`, `-c`,
/// `--count-matches`, `-l` — reuse the SAME `row`/`emitMatches`/`bufTally`
/// helpers as `file`, so output is byte-identical.
pub fn litFastEligible(self: *const Emitter) bool {
    const o = self.o;
    if (self.re.lits().len == 0) return false;
    if (o.invert or o.word or o.passthru or o.vimgrep or o.stats or o.stop_on_nonmatch) return false;
    if (o.before != 0 or o.after != 0) return false;
    if (o.replace != null) return false;
    return true;
}

/// The line-free literal fast path — ripgrep's searcher-loop architecture
/// (candidate jump → line bounds → confirm → skip the line), the piece gist
/// was missing. For a pure-literal pattern it NEVER builds the line array:
/// one `indexOfAnyPos` sweep jumps hit→hit over `body`; each hit's line
/// bounds come from a reverse/forward memchr (`lastIndexOfScalar`/`memchr`);
/// the line is emitted through the same helpers as `file`; and the scan
/// resumes past the line terminator, so each matching line is visited exactly
/// once — a literal carries no `\n`, so a hit `p` lands strictly inside
/// `[ls,le)`, hence the line matches (the `re.lits` equivalence). `-c` need
/// not even run the engine (candidate line ⟺ matching line). Line numbers are
/// counted incrementally over the inter-match gap (SIMD `countByte`), paid
/// only under `-n`. `base`/`body_end` are set by the caller, so `offOf` and
/// unterminated-tail handling — and therefore every output byte — match
/// `file`. Returns the mode's tally (matching lines, or spans under `-o`/
/// `--count-matches`).
///
/// The scan is restricted to hits in `[lo, hi)` and line numbers start at
/// `base_lineno` — `0`/`0`/`body.len` for a whole file, and a line-aligned
/// sub-range for a single-file SHARD (the parallelism ripgrep can't use: it
/// is hard-wired single-threaded on one file). `hi` is always a line start,
/// so no matching line straddles two shards. `tally=false` makes a count mode
/// RETURN its partial count instead of emitting the `path:N` line, so the
/// shard driver can sum partials and print one total.
pub fn fileLit(self: *Emitter, path: []const u8, body: []const u8, lo: usize, hi: usize, base_lineno: usize, tally: bool) usize {
    const o = self.o;
    const lits = self.re.lits();
    const term = o.term();
    // `-c -o` resolved to `.count_matches` back in argv (`answer.Mode.settle`),
    // so counting spans is exactly the one mode — no second reading of `-o`.
    const count_spans = o.mode == .count_matches;
    const counting = o.mode.counting();
    const emit_spans = o.only_matching and !counting;
    // Prefix-free literals resolve spans without the Pike VM (`litNextSpan`),
    // so a span-emitting mode over such a set never allocates a `SpanSim`.
    const lit_span = prefixFree(lits);
    const wants_span = emit_spans or count_spans or (o.column and !counting);
    var ssim: ?Matcher.SpanSim = if (wants_span and !lit_span)
        (Matcher.SpanSim.init(self.a, self.re) catch return 0)
    else
        null;
    defer if (ssim) |*s| s.deinit();

    var lineno: usize = base_lineno; // newlines in body[0..counted] (only advanced under -n)
    var counted: usize = lo;
    var pos: usize = lo;
    var lines_hit: usize = 0;
    var spans: usize = 0;
    const max = o.max_per_file;
    // Pure `-c` counts matching LINES and never emits, so it needs only the
    // line END (to skip past a counted line) — its reverse-memchr line START
    // is dead work. Every other mode builds the line slice, so needs both.
    const need_start = !(counting and !count_spans);
    while (simd.indexOfAnyPos(body, pos, lits)) |p| {
        if (p >= hi) break; // this shard owns only lines whose hit falls in [lo,hi)
        if (o.mode == .files_with_matches) return self.emitPathOnly(path);
        const le = simd.memchr(body, p, term) orelse body.len;
        lines_hit += 1;
        if (need_start) {
            const ls = if (simd.lastIndexOfScalar(body, p, term)) |nl| nl + 1 else 0;
            const line = body[ls..le];
            if (count_spans) {
                const mv = self.mview(line);
                // No `-m` break inside either loop: `-m` limits matched
                // LINES, so the last admitted line contributes every span it
                // holds (`rg --count-matches -m1` over a two-match line is 2).
                // The outer loop stops on the line count instead.
                if (lit_span) {
                    var from: usize = 0;
                    while (litNextSpan(lits, mv, from)) |sp| {
                        from = sp.end;
                        spans += 1;
                    }
                } else {
                    var from: usize = 0;
                    while (output.nextSpan(self.re, &ssim.?, o, mv, &from)) |_| spans += 1;
                }
            } else {
                if (o.line_num) {
                    lineno += simd.countByte(body[counted..ls], term);
                    counted = ls;
                }
                const mv = self.mview(line);
                if (emit_spans) {
                    spans += if (lit_span) emitMatchesLit(self, lits, path, lineno + 1, line, mv) else display.emitMatches(self, &ssim.?, path, lineno + 1, line, mv);
                } else {
                    const col: usize = if (!o.column) 0 else if (lit_span) blk: {
                        const sp = litNextSpan(lits, mv, 0) orelse break :blk 0;
                        break :blk sp.start + 1;
                    } else self.firstCol(&ssim.?, mv);
                    self.row(path, lineno + 1, col, ls, line, true);
                }
            }
        }
        if (le >= body.len) break;
        pos = le + 1;
        // `-m` counts matched LINES in every mode — the span modes included, so
        // a line's spans are never split across the limit (`grid.zig` caps its
        // line index the same way). Capping on spans here made `-o -m2` stop
        // two matches in rather than two lines in.
        const done = lines_hit;
        if (max != 0 and done >= max) break;
    }
    const n = if (count_spans) spans else lines_hit;
    if (counting) return if (tally) self.bufTally(path, n) else n;
    return if (emit_spans) spans else lines_hit;
}
