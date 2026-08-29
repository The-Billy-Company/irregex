//! irregex — the epsilon-closure: everything the Pike VM decides at ONE fixed
//! input position. Zero-width assertions (`^ $ \b \B \< \> \A \z`) are resolved
//! here against that position's flags, so the boolean walk (`search.zig`) and
//! the span walk (`span.zig`) can never disagree about what a boundary means.
//! Also owns the position predicates themselves: per-line, a haystack's own
//! edges are its anchors; under multiline (`-U`) `^`/`$` hold at every `\n`
//! adjacency.

const core = @import("../program/core.zig");
const word = @import("../../syntax/word.zig");
const syn = @import("../../syntax/syntax.zig");
const scratch = @import("scratch.zig");

const Regex = core.Regex;
const ThreadList = scratch.ThreadList;

// The shared `\b`/`\B`/`\<`/`\>` word test (`word.zig`) — one definition for
// this VM and the capture VM, so the two engines can never disagree.

/// One epsilon-closure pass at a fixed input position; bundles the invariants (target `list`, per-pass `seen`/`gen` dedup, position flags) so the recursion carries only the varying state index.
pub const Closure = struct {
    re: *const Regex,
    list: *ThreadList,
    seen: []u32,
    gen: u32,
    at_start: bool,
    at_end: bool,
    // Buffer-edge flags for `\A`/`\z` (multiline only — in the per-line
    // default the parser lowered them to `^`/`$`, so these states never
    // exist there and the flags are inert). Distinct from `at_start`/
    // `at_end`, which multiline resolves at every LINE boundary.
    at_buf_start: bool,
    at_buf_end: bool,
    // How the characters straddling this (fixed) position look, for `\b` and
    // its five siblings — word-ness plus whether each side is a whole character.
    sides: syn.Sides,
    // Optional start-offset side-channel for `-o` span extraction: when
    // `starts` is set, every state pushed to `list` records where the thread
    // reaching it BEGAN (`cur_start`). Null on the hot boolean path (no cost).
    starts: ?[]usize = null,
    cur_start: usize = 0,

    /// Epsilon-closure of `s` into `list`; returns whether it reached the match state (so `lineMatch` answers without a second list scan). Zero-width assertions resolve against the position's flags — `^`/`$` against `at_start`/`at_end`, every word assertion against `sides` (`syntax.mask.holds`) — and a failed assertion just kills that branch (the position is fixed across one closure).
    pub fn add(c: Closure, s: u32) bool {
        if (c.seen[s] == c.gen) return false;
        c.seen[s] = c.gen;
        return switch (c.re.states[s]) {
            .split => |sp| blk: {
                // Bind both arms first — `or` short-circuits, but both must close.
                const a = c.add(sp.a);
                break :blk a or c.add(sp.b);
            },
            .assert_start => |out| c.at_start and c.add(out),
            .assert_end => |out| c.at_end and c.add(out),
            .assert_buf_start => |out| c.at_buf_start and c.add(out),
            .assert_buf_end => |out| c.at_buf_end and c.add(out),
            .assert_word => |w| w.mask.holds(c.sides) and c.add(w.out),
            else => blk: {
                c.list.push(s);
                if (c.starts) |st| st[s] = c.cur_start; // first (highest-priority) write wins
                break :blk c.re.states[s] == .match;
            },
        };
    }
};

// `sim` is either Pike scratch grain (`Sim`/`SpanSim` — only `seen`/`gen` are read).
pub fn closure(re: *const Regex, sim: anytype, list: *ThreadList, at_start: bool, at_end: bool, sides: syn.Sides) Closure {
    // Per-line callers: the line IS the haystack, so the buffer edges
    // coincide with `at_start`/`at_end` (and `\A`/`\z` were lowered to
    // `^`/`$` anyway). `closureBuf` overrides both for multiline.
    return .{ .re = re, .list = list, .seen = sim.seen, .gen = sim.gen, .at_start = at_start, .at_end = at_end, .at_buf_start = at_start, .at_buf_end = at_end, .sides = sides };
}

/// A gap position `p` (0..=buf.len) is a line start iff it is the buffer start
/// or immediately follows a `\n`; a line end iff it is the buffer end or a `\n`
/// begins there. These are the multiline `^`/`$` predicates.
pub fn lineStart(buf: []const u8, p: usize, nl_terminates: bool) bool {
    // BOF always is. After a `\n`, it depends on what that `\n` IS, and at
    // `p == buf.len` the two wide haystack models part company.
    //
    // `nl_terminates` — the document model, which is `-U` and every per-line
    // caller — says the haystack's final `\n` TERMINATES its last line, so it
    // opens no phantom empty line at `buf.len` (rg: `^$` matches "abc\n\n" at the
    // real interior empty line but NOT "abc\n"). Cleared, the haystack is a
    // `--null-data` RECORD whose terminator was the NUL and was stripped before
    // this call, so a trailing `\n` is ordinary content and opens the empty line
    // after it exactly as an interior one does — which is what `rg --null-data
    // -c '^$'` and `grep -z -c '^$'` both report on a file ending `…mid\n`, and
    // where ripgrep contradicts its own `-U` answer on the same bytes.
    //
    // `$` needs no such distinction either way (`\n$` matches "abc\n" at EOF).
    return p == 0 or (buf[p - 1] == '\n' and (p < buf.len or !nl_terminates));
}
pub fn lineEnd(buf: []const u8, p: usize) bool {
    return p == buf.len or buf[p] == '\n';
}

/// `^`/`$` predicates at gap `p`: multiline resolves them against `\n`
/// adjacency (a line boundary), the per-line default against the buffer ends.
/// Shared by `matchSpan` so one span engine serves both modes.
pub fn atStart(re: *const Regex, buf: []const u8, p: usize) bool {
    return if (re.line_anchors) lineStart(buf, p, re.nl_terminates) else p == 0;
}
pub fn atEnd(re: *const Regex, buf: []const u8, p: usize) bool {
    return if (re.line_anchors) lineEnd(buf, p) else p == buf.len;
}

/// Epsilon-closure at a whole-buffer position `p`, resolving `^`/`$` against
/// `\n` adjacency (multiline) rather than a single external BOL/EOL flag.
/// `\A`/`\z` (assert_buf_*) resolve against the true buffer edges here — a
/// line boundary is NOT a buffer edge under multiline.
pub fn closureBuf(re: *const Regex, sim: *scratch.Sim, list: *ThreadList, buf: []const u8, p: usize) Closure {
    // `^`/`$` resolve against `\n` adjacency when the `m` flag is live, else
    // only the true buffer ends (`(?-m)` under `-U`).
    const at_start = if (re.line_anchors) lineStart(buf, p, re.nl_terminates) else p == 0;
    const at_end = if (re.line_anchors) lineEnd(buf, p) else p == buf.len;
    var c = closure(re, sim, list, at_start, at_end, word.sides(re.unicode, buf, p));
    c.at_buf_start = p == 0;
    c.at_buf_end = p == buf.len;
    return c;
}
