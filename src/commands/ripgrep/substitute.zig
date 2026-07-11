//! gist `rg` — word-boundary semantics + the `-r/--replace` template engine.
//!
//! Split from `output.zig`: these are the pure text-transformation primitives
//! behind the presentation layer, with no dependence on the `Emitter`'s output
//! buffer — `-w` word-boundary tests (`wordOk`) and the rust-regex `Replacer`
//! template expansion (`$1`/`${name}`/`$$`). They're shared verbatim across the
//! text `Emitter` (`output.zig`), the `--json` record stream (`json.zig`), and
//! the `--stats` tally (`grepfile.zig`), so a single definition keeps the three
//! from drifting. `output.zig` re-exports the public names.

const std = @import("std");
const Captures = @import("../../regex/captures.zig").Captures;
const die = @import("args.zig").die;

pub fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// ripgrep `-w`: a match span `[s,e)` is a word match iff bounded by a non-word
/// byte (or the line edge) on BOTH sides. Unlike `\b(pat)\b` this does not
/// require the match to contain word bytes, so a punctuation match (e.g. `.`
/// matching `.`) is still a valid word match — rg's actual semantics.
pub fn wordOk(line: []const u8, s: usize, e: usize) bool {
    const before = s == 0 or !isWordByte(line[s - 1]);
    const after = e == line.len or !isWordByte(line[e]);
    return before and after;
}

/// Resolve a `-r` group reference: an all-digit name is the numeric index; else
/// a named group looked up in the capture program. Null ⇒ unknown (→ empty).
pub fn groupIndexOf(caps: *const Captures, name: []const u8) ?u32 {
    var all_digits = true;
    for (name) |c| if (c < '0' or c > '9') {
        all_digits = false;
        break;
    };
    if (all_digits) return std.fmt.parseInt(u32, name, 10) catch null;
    return caps.groupByName(name);
}

/// Expand a `-r` replacement template into `buf`: `$1`/`${1}` numeric groups,
/// `$name`/`${name}` named groups (`$0` = whole match), `$$` → literal `$`, an
/// unknown/out-of-range group → empty (ripgrep / rust-regex `Replacer` rules).
/// Shared by the text `Emitter` and the `--json` record stream (`json.zig`).
pub fn expandInto(a: std.mem.Allocator, caps: *const Captures, buf: *std.ArrayList(u8), tmpl: []const u8, line: []const u8, slots: []const isize) void {
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] != '$') {
            buf.append(a, tmpl[i]) catch die("oom\n", .{});
            i += 1;
            continue;
        }
        if (i + 1 < tmpl.len and tmpl[i + 1] == '$') {
            buf.append(a, '$') catch die("oom\n", .{});
            i += 2;
            continue;
        }
        i += 1;
        var name: []const u8 = "";
        if (i < tmpl.len and tmpl[i] == '{') {
            const st = i + 1;
            var j = st;
            while (j < tmpl.len and tmpl[j] != '}') j += 1;
            name = tmpl[st..j];
            i = if (j < tmpl.len) j + 1 else j;
        } else {
            const st = i;
            while (i < tmpl.len and isWordByte(tmpl[i])) i += 1;
            name = tmpl[st..i];
        }
        if (name.len == 0) {
            buf.append(a, '$') catch die("oom\n", .{});
            continue;
        }
        const gi = groupIndexOf(caps, name) orelse continue;
        if (2 * gi + 1 >= slots.len) continue; // out-of-range group → empty
        const so = slots[2 * gi];
        const eo = slots[2 * gi + 1];
        if (so >= 0 and eo >= 0) buf.appendSlice(a, line[@intCast(so)..@intCast(eo)]) catch die("oom\n", .{});
    }
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
pub fn buildReplaced(a: std.mem.Allocator, caps_opt: ?*Captures, word: bool, tmpl: []const u8, line: []const u8) Replaced {
    const caps = caps_opt orelse return .{ .text = line, .starts = &.{} };
    const slots = a.alloc(isize, caps.nslots) catch die("oom\n", .{});
    var buf: std.ArrayList(u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var from: usize = 0;
    var last_end: ?usize = null;
    while (from <= line.len and caps.find(line, from, slots)) {
        const s: usize = @intCast(slots[0]);
        const e: usize = @intCast(slots[1]);
        buf.appendSlice(a, line[from..s]) catch die("oom\n", .{});
        const empty_adjacent = e == s and last_end != null and s == last_end.?;
        if (empty_adjacent or (word and !wordOk(line, s, e))) {
            if (s < line.len) buf.append(a, line[s]) catch die("oom\n", .{});
            from = s + 1;
            continue;
        }
        starts.append(a, buf.items.len) catch die("oom\n", .{});
        expandInto(a, caps, &buf, tmpl, line, slots);
        last_end = e;
        if (e == s) {
            if (s < line.len) buf.append(a, line[s]) catch die("oom\n", .{});
            from = s + 1;
        } else from = e;
    }
    if (from < line.len) buf.appendSlice(a, line[from..]) catch die("oom\n", .{});
    return .{ .text = buf.toOwnedSlice(a) catch die("oom\n", .{}), .starts = starts.toOwnedSlice(a) catch die("oom\n", .{}) };
}
