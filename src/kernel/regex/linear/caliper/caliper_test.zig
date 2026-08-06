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
const prefilter = @import("../../analysis/prefilter.zig");

const Regex = core.Regex;

/// The same compiled program with every span reduction and the caliper itself
/// switched off, so `pike.matchWindow` on it really is the VM. A value copy: the
/// original still owns every allocation, and nothing here frees any of it. This
/// has to be explicit — a `SpanSim` carries jaws whenever the program has a
/// caliper, so an oracle that forgot to clear the field would be comparing this
/// engine against itself.
fn oracleOf(re: Regex) Regex {
    var o = re;
    o.lits = &.{};
    o.caliper = null;
    if (o.classrun) |*cr| cr.span = false;
    return o;
}

/// Walk `line` with both engines and assert they agree at every step, under both
/// seeding policies — gap by gap, and with the first-byte prefilter driving the
/// skip, which must be an accelerator and nothing else. Returns the number of
/// spans compared, so a case can prove it exercised something.
fn agree(gpa: std.mem.Allocator, pattern: []const u8, line: []const u8) !usize {
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();
    if (!caliper.eligible(re.states, re.multiline)) return 0;

    const cal = (try caliper.build(gpa, re.states, re.start, re.unicode)) orelse return 0;
    defer cal.deinit();

    var oracle = oracleOf(re);
    var sim = try Regex.SpanSim.init(gpa, &re);
    defer sim.deinit();

    var n: usize = 0;
    for ([2]?*const prefilter.Prefilter{ null, &re.first }) |skip| {
        var jaws = caliper.Jaws.init(gpa, cal);
        defer jaws.deinit();
        n = 0;
        var from: usize = 0;
        while (from <= line.len) {
            const win = caliper.Window.whole(line, from);
            const want = pike.matchWindow(&oracle, &sim, win);
            switch (caliper.measure(&jaws, win, skip)) {
                .decline => break, // budget, not disagreement
                .none => {
                    if (want) |w| {
                        std.debug.print("\npattern `{s}` line `{s}` from {d} skip={any}: caliper found nothing, Pike found [{d},{d})\n", .{ pattern, line, from, skip != null, w.start, w.end });
                        return error.CaliperMissedMatch;
                    }
                    break;
                },
                .found => |got| {
                    const w = want orelse {
                        std.debug.print("\npattern `{s}` line `{s}` from {d} skip={any}: caliper found [{d},{d}), Pike found nothing\n", .{ pattern, line, from, skip != null, got.start, got.end });
                        return error.CaliperInventedMatch;
                    };
                    if (got.start != w.start or got.end != w.end) {
                        std.debug.print("\npattern `{s}` line `{s}` from {d} skip={any}: caliper [{d},{d}) vs Pike [{d},{d})\n", .{ pattern, line, from, skip != null, got.start, got.end, w.start, w.end });
                        return error.CaliperSpanDiverged;
                    }
                    // The bound, at the ceilings that can change the answer: the
                    // match's own end (tightest that still admits it), one byte
                    // inside it (must yield something shorter or nothing), its
                    // start, and the origin. The VM answers the bounded question
                    // too, so the comparison stays span-for-span.
                    const ceilings = [_]usize{ from, w.start, w.end -| 1, w.end, (w.end + line.len) / 2 };
                    for (ceilings) |to| {
                        const bw: caliper.Window = .{ .hay = line, .from = from, .to = to };
                        const bwant = pike.matchWindow(&oracle, &sim, bw);
                        switch (caliper.measure(&jaws, bw, skip)) {
                            .decline => {},
                            .none => if (bwant) |b| {
                                std.debug.print("\npattern `{s}` line `{s}` [{d},{d}]: bounded caliper found nothing, Pike found [{d},{d})\n", .{ pattern, line, from, to, b.start, b.end });
                                return error.BoundedCaliperMissedMatch;
                            },
                            .found => |bgot| {
                                const b = bwant orelse {
                                    std.debug.print("\npattern `{s}` line `{s}` [{d},{d}]: bounded caliper found [{d},{d}), Pike found nothing\n", .{ pattern, line, from, to, bgot.start, bgot.end });
                                    return error.BoundedCaliperInventedMatch;
                                };
                                if (bgot.end > to) return error.BoundedSpanEscapedCeiling;
                                if (bgot.start != b.start or bgot.end != b.end) {
                                    std.debug.print("\npattern `{s}` line `{s}` [{d},{d}]: bounded caliper [{d},{d}) vs Pike [{d},{d})\n", .{ pattern, line, from, to, bgot.start, bgot.end, b.start, b.end });
                                    return error.BoundedCaliperSpanDiverged;
                                }
                            },
                        }
                    }
                    n += 1;
                    from = if (w.end == w.start) w.start + 1 else w.end;
                },
            }
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
    const line = "  const AcmeStore = makeThing(user_id_key, HTTPServer);";
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
