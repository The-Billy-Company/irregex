//! gist `rg` — the `-r/--replace` half of the emitter.
//!
//! Split from `output.zig`: expanding a replacement template against a match's
//! capture slots, and building the rewritten line (or `-o` fragment) that gets
//! printed in place of the original. `expandInto` is deliberately
//! `Emitter`-free — the `--json` record stream (`json.zig`) expands the same
//! template through the same function, so a `$1` can never mean two things.

const std = @import("std");
const oom = @import("../../../../surface/cli/outcome.zig").oom;
const Caps = @import("../../../../kernel/regex/regex.zig").Caps;
const display = @import("display.zig");
const output = @import("../output.zig");
const Emitter = output.Emitter;

/// Resolve a `-r` group reference: an all-digit name is the numeric index; else
/// a named group looked up in the capture program. Null ⇒ unknown (→ empty).
pub fn groupIndexOf(caps: *const Caps, name: []const u8) ?u32 {
    for (name) |c| if (!std.ascii.isDigit(c)) return caps.groupByName(name);
    return std.fmt.parseInt(u32, name, 10) catch null;
}

/// Expand a `-r` replacement template into `buf`: `$1`/`${1}` numeric groups,
/// `$name`/`${name}` named groups (`$0` = whole match), `$$` → literal `$`, an
/// unknown/out-of-range group → empty (ripgrep / rust-regex `Replacer` rules).
/// Shared by the text `Emitter` and the `--json` record stream (`json.zig`).
pub fn expandInto(a: std.mem.Allocator, caps: *const Caps, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] != '$') {
            // Copy the whole literal run up to the next `$` in one appendSlice (a
            // template is mostly literal between group refs) — vectorized scan,
            // byte-identical to a per-char walk.
            const st = i;
            i = std.mem.indexOfScalarPos(u8, tmpl, i, '$') orelse tmpl.len;
            buf.appendSlice(a, tmpl[st..i]) catch oom();
            continue;
        }
        if (i + 1 < tmpl.len and tmpl[i + 1] == '$') {
            buf.append(a, '$') catch oom();
            i += 2;
            continue;
        }
        i += 1;
        const name = if (i < tmpl.len and tmpl[i] == '{') blk: {
            const st = i + 1;
            const j = std.mem.indexOfScalarPos(u8, tmpl, st, '}') orelse tmpl.len;
            i = @min(j + 1, tmpl.len);
            break :blk tmpl[st..j];
        } else blk: {
            const st = i;
            while (i < tmpl.len and output.isWordByte(tmpl[i])) i += 1;
            break :blk tmpl[st..i];
        };
        if (name.len == 0) {
            buf.append(a, '$') catch oom();
            continue;
        }
        const gi = groupIndexOf(caps, name) orelse continue;
        if (2 * gi + 1 >= slots.len) continue; // out-of-range group → empty
        const so = slots[2 * gi];
        const eo = slots[2 * gi + 1];
        if (so >= 0 and eo >= 0) buf.appendSlice(a, line[@intCast(so)..@intCast(eo)]) catch oom();
    }
}

/// The `Emitter`-bound spelling of `expandInto` — expands against this run's
/// capture program into `buf`. `pub`: `multibuf` expands `-U` templates too.
pub fn expand(self: *Emitter, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
    expandInto(self.a, self.caps.?, buf, tmpl, line, slots);
}

/// The result of applying a `-r` template to a line: the rewritten text plus
/// the byte offset (within `text`) where each replacement begins — the match
/// granularity ripgrep uses for the `--max-columns` "N matches" placeholders.
pub const Replaced = struct { text: []const u8, starts: []const usize };

/// Build `line` with every (leftmost-first, non-overlapping) match span replaced
/// by the expanded `-r` template. Non-matching text is copied verbatim; under
/// `-w`, a span that isn't a word match is left in place. An empty match whose
/// start coincides with the previous match's end is skipped (rust-regex
/// `find_iter` progress rule), else empties advance one byte. Arena-owned.
pub fn buildReplaced(self: *Emitter, tmpl: []const u8, line: []const u8) Replaced {
    const caps = self.caps orelse return .{ .text = line, .starts = &.{} };
    const slots = self.a.alloc(isize, caps.nslots()) catch oom();
    var buf: std.ArrayList(u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var from: usize = 0;
    var last_end: ?usize = null;
    // rg searches each line WITH its terminator, so the zero-width match at the
    // end of the content is real for a terminated line and absent on a file's
    // unterminated tail — the same rule `output.Rows` applies (measured:
    // `-r X -e 'x*'` over a file whose only byte is `f` prints `Xf`, not `XfX`).
    const terminated = self.lineTerminated(line);
    while (from <= line.len and caps.find(line, from, slots)) {
        const s: usize = @intCast(slots[0]);
        const e: usize = @intCast(slots[1]);
        buf.appendSlice(self.a, line[from..s]) catch oom();
        const empty_adjacent = e == s and last_end != null and s == last_end.?;
        const rejected = empty_adjacent or (e == s and !terminated and s == line.len) or
            (self.o.word and !output.wordOk(self.o.unicode, line, s, e));
        if (!rejected) {
            starts.append(self.a, buf.items.len) catch oom();
            expand(self, &buf, tmpl, line, slots);
            last_end = e;
        }
        // A rejected or empty span keeps/advances past one source byte;
        // an accepted non-empty span resumes after its end.
        if (rejected or e == s) {
            if (s < line.len) buf.append(self.a, line[s]) catch oom();
            from = s + 1;
        } else from = e;
    }
    if (from < line.len) buf.appendSlice(self.a, line[from..]) catch oom();
    return .{ .text = buf.toOwnedSlice(self.a) catch oom(), .starts = starts.toOwnedSlice(self.a) catch oom() };
}

/// Write one `-o -r` row's expanded template, honoring `--trim`. rg trims the
/// RENDERED row, not the template, so a `$0` starting mid-line keeps its blanks
/// (`-r '[$0]'` prints `[   bar]`) while a template of its own leading blanks
/// loses them. Trimming therefore needs the whole expansion in hand; without
/// `--trim` it still streams straight to the output buffer. Arena-owned.
fn emitExpanded(self: *Emitter, tmpl: []const u8, line: []const u8, slots: []const isize) void {
    if (!self.o.trim) return expand(self, self.out, tmpl, line, slots);
    var buf: std.ArrayList(u8) = .empty;
    expand(self, &buf, tmpl, line, slots);
    self.add(display.trimRow(self, buf.items));
}

/// Emit each match on one line as its expanded `-r` template (the `-o` frame),
/// `so_far` matches already counted toward `--max-count`. `is_match` frames the
/// rows — under `-v` the spans live on the context line (see `emitMatches`).
/// Returns the count on this line.
pub fn emitLineRepl(self: *Emitter, path: []const u8, lineno: usize, line: []const u8, is_match: bool) usize {
    const caps = self.caps.?;
    const tmpl = self.o.replace.?;
    const slots = self.a.alloc(isize, caps.nslots()) catch oom();
    var n: usize = 0;
    var from: usize = 0;
    var last_end: ?usize = null;
    const terminated = self.lineTerminated(line);
    while (from <= line.len and caps.find(line, from, slots)) {
        const s: usize = @intCast(slots[0]);
        const e: usize = @intCast(slots[1]);
        const empty = e == s;
        // `-o -r` prints ONE row per `output.Rows` span, empties included — rg's
        // `-o -r X -e 'x*'` over "ab\n" prints three `X` rows, and over the
        // unterminated "f" exactly one. Dropping every empty span printed nothing
        // at all for a nullable pattern (found by the differential fuzzer), so
        // this walk applies Rows' rules rather than a rule of its own.
        const word_bad = self.o.word and !output.wordOk(self.o.unicode, line, s, e);
        const skip = word_bad or (empty and self.re.nullable() == false) or
            (empty and last_end != null and s == last_end.?) or
            (empty and !terminated and s == line.len);
        if (skip) {
            from = if (empty or word_bad) s + 1 else e;
            continue;
        }
        last_end = e;
        self.prefix(path, lineno, s + 1, self.offOf(line) + s, is_match);
        emitExpanded(self, tmpl, line, slots);
        self.add(self.o.outTerm()); // expanded text carries no terminator — rg appends the full one
        n += 1;
        // No span cap: `-m` counts matched LINES, so this line emits all of
        // its replacements and the caller stops between lines. An accepted empty
        // still advances one byte — the Rows progress rule.
        from = if (empty) s + 1 else e;
    }
    return n;
}
