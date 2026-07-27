//! gist — the caliper against its oracle.
//!
//! Every span the two jaws report must be the span the Pike VM reports, span
//! for span, over the whole iteration — not just the first match. The VM is the
//! definition of gist's leftmost-first semantics (`a|ab`→`a`, greedy `a+`
//! maximal), so any divergence here is the caliper being wrong.

const std = @import("std");
const t = std.testing;
const core = @import("../program/core.zig");
const pike = @import("../pike/span.zig");
const caliper = @import("caliper.zig");

const Regex = core.Regex;

/// Walk `line` with both engines and assert they agree at every step. Returns
/// the number of spans compared, so a case can prove it exercised something.
fn agree(gpa: std.mem.Allocator, pattern: []const u8, line: []const u8) !usize {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    if (!caliper.eligible(re.states, re.multiline)) return 0;

    const cal = (try caliper.build(gpa, re.states, re.start, re.unicode)) orelse return 0;
    defer cal.deinit();
    var jaws = caliper.Jaws.init(gpa, cal);
    defer jaws.deinit();

    var sim = try Regex.SpanSim.init(gpa, &re);
    defer sim.deinit();

    var from: usize = 0;
    var n: usize = 0;
    while (from <= line.len) {
        const want = pike.matchSpan(&re, &sim, line, from);
        switch (caliper.measure(&jaws, line, from)) {
            .decline => return n, // budget, not disagreement
            .none => {
                if (want) |w| {
                    std.debug.print("\npattern `{s}` line `{s}` from {d}: caliper found nothing, Pike found [{d},{d})\n", .{ pattern, line, from, w.start, w.end });
                    return error.CaliperMissedMatch;
                }
                return n;
            },
            .found => |got| {
                const w = want orelse {
                    std.debug.print("\npattern `{s}` line `{s}` from {d}: caliper found [{d},{d}), Pike found nothing\n", .{ pattern, line, from, got.start, got.end });
                    return error.CaliperInventedMatch;
                };
                if (got.start != w.start or got.end != w.end) {
                    std.debug.print("\npattern `{s}` line `{s}` from {d}: caliper [{d},{d}) vs Pike [{d},{d})\n", .{ pattern, line, from, got.start, got.end, w.start, w.end });
                    return error.CaliperSpanDiverged;
                }
                n += 1;
                from = if (w.end == w.start) w.start + 1 else w.end;
            },
        }
    }
    return n;
}

test "caliper: leftmost-first preference is the Pike VM's" {
    const gpa = t.allocator;
    // The cases that separate leftmost-first from every other semantics.
    _ = try agree(gpa, "a|ab", "ab");
    _ = try agree(gpa, "ab|a", "ab");
    _ = try agree(gpa, "a+", "aaaa");
    _ = try agree(gpa, "a+?", "aaaa");
    _ = try agree(gpa, "axxx|x", "axxx");
    _ = try agree(gpa, "x|axxx", "axxx");
    _ = try agree(gpa, "a*", "bbb");
    _ = try agree(gpa, "(ab)+", "ababab");
    _ = try agree(gpa, "a{2,4}", "aaaaaa");
    _ = try agree(gpa, "foo|foobar", "xx foobar yy");
}

test "caliper: the multi-segment shapes the VM used to own alone" {
    const gpa = t.allocator;
    const line = "  const WalletService = makeThing(user_id_key, HTTPServer);";
    try t.expect(try agree(gpa, "[A-Z][a-z]+[A-Z][A-Za-z]*", line) > 0);
    try t.expect(try agree(gpa, "[a-z]+_[a-z]+_[a-z]+", line) > 0);
    try t.expect(try agree(gpa, "[a-z]+\\(", line) > 0);
    _ = try agree(gpa, "\\w+@\\w+\\.[a-z]+", "mail bob@host.com and eve@x.io done");
}

test "caliper: assertions survive reversal" {
    const gpa = t.allocator;
    _ = try agree(gpa, "^ab", "abab");
    _ = try agree(gpa, "ab$", "abab");
    _ = try agree(gpa, "^a.*b$", "axxxb");
    _ = try agree(gpa, "\\bfoo\\b", "foo food foo");
    _ = try agree(gpa, "\\Boo\\B", "foo food book");
    _ = try agree(gpa, "\\<[a-z]+\\>", "one two three");
    _ = try agree(gpa, "[a-z]+\\b", "one two three");
    _ = try agree(gpa, "^$", "");
    _ = try agree(gpa, "\\ba", "a ba ab");
}

test "caliper: edges — empty, zero-width, no match, whole line" {
    const gpa = t.allocator;
    _ = try agree(gpa, "a", "");
    _ = try agree(gpa, "", "abc");
    _ = try agree(gpa, "x*", "aaa");
    _ = try agree(gpa, "zzz", "aaa");
    _ = try agree(gpa, ".*", "abc");
    _ = try agree(gpa, ".+", "abc");
    _ = try agree(gpa, "[^a]*", "aaabbb");
}

// A deterministic sweep over generated pattern/haystack pairs. Cheap enough to
// run on every build, wide enough that a reversal or priority bug shows up as a
// concrete divergence rather than a benchmark that quietly lies.
test "caliper: differential sweep against the Pike VM" {
    const gpa = t.allocator;
    const pieces = [_][]const u8{
        "a",     "b",      "[ab]",   "[a-c]",  "[^a]",     ".",
        "a+",    "a*",     "a?",     "[ab]+",  "[a-c]*",   "a|b",
        "ab|ba", "(a|b)+", "a{2}",   "a{1,3}", "\\w",      "\\d",
        "\\w+",  "[a-z]+", "x",      "(ab)?",  "a+?",      "[abc]{2,3}",
        "\\b",   "\\B",    "^",      "$",      "a|ab",     "ab|a",
        "\\w*?", "[^b]+?", "(a|bc)", "c?",     "[a-c]|xy", "\\s",
    };
    const lines = [_][]const u8{
        "",       "a",      "ab",        "ba",
        "aab",    "abab",   "aaabbbccc", "xyz",
        "a1b2c3", "  ab  ", "cabbage",   "abcabcabc",
        "aaaa",   "bbbb",   "a b c",     "zzzabczzz",
        " a ",    "a\tb c", "_a_b_",     "AbCaBc",
    };
    var rng = std.Random.DefaultPrng.init(0x5caff01d);
    const r = rng.random();
    var checked: usize = 0;
    for (0..20000) |_| {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        // Concatenate one to three pieces — enough structure to make the
        // forward jaw choose between competing ends.
        for (0..1 + r.uintLessThan(usize, 3)) |_| {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            if (len + p.len > buf.len) break;
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        const line = lines[r.uintLessThan(usize, lines.len)];
        checked += agree(gpa, buf[0..len], line) catch |e| switch (e) {
            error.BadPattern => continue, // a concatenation the grammar rejects
            else => return e,
        };
    }
    try t.expect(checked > 1000);
}
