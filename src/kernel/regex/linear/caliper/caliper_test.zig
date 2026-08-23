//! irregex — the caliper against its oracle.
//!
//! Every span the two jaws report must be the span the Pike VM reports, span
//! for span, over the whole iteration — not just the first match. The VM is the
//! definition of this package's leftmost-first semantics (`a|ab`→`a`, greedy
//! `a+` maximal), so any divergence here is the caliper being wrong.

const std = @import("std");
const t = std.testing;
const core = @import("../program/core.zig");
const pike = @import("../pike/span.zig");
const caliper = @import("caliper.zig");
const lower = @import("../program/lower.zig");
const span = @import("../pike/span.zig");
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
    return agreeOpts(gpa, pattern, line, .{});
}

/// `agree` under an explicit compile model. The buffer model (`multiline`) is
/// not a variant of the line model for this engine's purposes — it is the ONLY
/// model any language binding ever compiles under (`compile/captures.zig`'s
/// `lowerOptions` forces `.multiline = true` and carries `(?m)` separately as
/// `line_anchors`), so a suite that only ever exercised the default was
/// exercising the one configuration no caller outside the CLI can produce.
fn agreeOpts(gpa: std.mem.Allocator, pattern: []const u8, line: []const u8, opts: lower.Options) !usize {
    var re = try Regex.compileOpts(gpa, pattern, opts);
    defer re.deinit();
    if (!caliper.eligible(re.states, re.multiline, re.line_anchors)) return 0;

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

/// Is the caliper offered this pattern at all, under this model? The guard in
/// `eligible` is a correctness claim, not a tuning one, so it needs an assertion
/// that fires when the gate opens — `agree` returning 0 cannot say whether the
/// pattern was declined or merely had nothing to compare.
fn offered(gpa: std.mem.Allocator, pattern: []const u8, opts: lower.Options) !bool {
    var re = try Regex.compileOpts(gpa, pattern, opts);
    defer re.deinit();
    return caliper.eligible(re.states, re.multiline, re.line_anchors);
}

test "caliper: the buffer model, over haystacks that hold newlines" {
    const gpa = t.allocator;
    // What every language binding compiles: the haystack is a buffer, and `^`
    // is the buffer's edge because the caller did not ask for `(?m)`.
    const buf: lower.Options = .{ .multiline = true, .line_anchors = false };
    const hay = "  const AcmeStore = mk(user_id_key);\n  let HTTPServer = two_word_here;\n";

    // The multi-segment shapes this engine exists for, now that a binding can
    // actually reach it — each spanning a haystack with interior newlines.
    try t.expect(try agreeOpts(gpa, "[A-Z][a-z]+[A-Z][A-Za-z]*", hay, buf) > 0);
    try t.expect(try agreeOpts(gpa, "[a-z]+_[a-z]+_[a-z]+", hay, buf) > 0);
    try t.expect(try agreeOpts(gpa, "[a-z]+\\(", hay, buf) > 0);
    // A match may legally cross `\n` under this model — the case the old
    // blanket gate was justified by and never actually tested.
    _ = try agreeOpts(gpa, "mk\\(user_id_key\\);\\s+let", hay, buf);
    _ = try agreeOpts(gpa, "[a-z]+\\s+[A-Z]\\w+", hay, buf);
    _ = try agreeOpts(gpa, ".+", hay, buf);
    _ = try agreeOpts(gpa, "\\bmk\\b", hay, buf);
    // `^`/`$` mean the buffer's own edges here, which is exactly what the jaws
    // read off the slice, so these stay eligible and must still agree.
    try t.expect(try offered(gpa, "^  const", buf));
    _ = try agreeOpts(gpa, "^  const", hay, buf);
    _ = try agreeOpts(gpa, "here;\\n$", hay, buf);
}

test "caliper: line anchors under the buffer model are declined, not guessed" {
    const gpa = t.allocator;
    // `(?m)`: `^` now passes after every `\n`, but a jaw reads `at_start` off
    // the edge of the slice it was handed. The two disagree, so the caliper
    // must not be offered the pattern at all — silently answering only the
    // first line's match is the bug this guard exists to prevent.
    const m: lower.Options = .{ .multiline = true, .line_anchors = true };
    try t.expect(!try offered(gpa, "^  const", m));
    try t.expect(!try offered(gpa, "here;$", m));
    try t.expect(!try offered(gpa, "^.*$", m));
    // A pattern with no line anchor reads nothing the slice cannot answer, so
    // `(?m)` alone must not cost it the caliper.
    try t.expect(try offered(gpa, "[a-z]+_[a-z]+_[a-z]+", m));
    try t.expect(try offered(gpa, "\\bmk\\b", m));
    // Word boundaries are read off the real bytes either side of the gap, not
    // off the slice edges, so they are unaffected by the model.
    const hay = "  const AcmeStore = mk(user_id_key);\n  let HTTPServer = two_word_here;\n";
    _ = try agreeOpts(gpa, "\\b[a-z]+_[a-z]+_[a-z]+\\b", hay, m);
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
// A memo keyed on a bare base address proves "same haystack" by provenance,
// and provenance is what an allocator recycles: two haystacks that never
// coexist can share a pointer, so the second must not inherit the first's
// answer. Every case above walks ONE haystack per jaw, which is the one shape
// that cannot see this. Both sims below are driven over the same bytes and must
// agree — a reused jaw is an accelerator, so its answer is the fresh one's or
// it is a bug.
test "caliper: a recycled haystack does not inherit the last one's candidate" {
    const gpa = t.allocator;
    var re = try Regex.compile(gpa, "\\bcat\\b");
    defer re.deinit();
    // The preconditions for the path under test: a pattern the caliper claims,
    // and no pure-literal reduction above it to answer first.
    try t.expect(re.caliper != null);
    try t.expect(re.lits.len == 0);

    // One buffer, two tenants — a freed 5-byte haystack's block handed back for
    // a 9-byte one. The candidate remembered at 3 is PAST the real one at 2.
    var buf: [16]u8 = undefined;
    const stale = buf[0..5];
    @memcpy(stale, "ab\ncd");
    var reused = try Regex.SpanSim.init(gpa, &re);
    defer reused.deinit();
    try t.expectEqual(@as(?caliper.Span, null), pike.matchWindow(&re, &reused, caliper.Window.whole(stale, 0)));

    const live = buf[0..9];
    @memcpy(live, "a cat sat");
    var fresh = try Regex.SpanSim.init(gpa, &re);
    defer fresh.deinit();
    const want = pike.matchWindow(&re, &fresh, caliper.Window.whole(live, 0));
    try t.expectEqual(@as(?caliper.Span, .{ .start = 2, .end = 5 }), want);
    try t.expectEqual(want, pike.matchWindow(&re, &reused, caliper.Window.whole(live, 0)));
}

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

test "a word assertion must not price the caliper out of its own memo" {
    // The memo is charged in `Machine.stride` units — `rows × ncls` — so a floor
    // stated in BYTES buys a different number of states for every program, and
    // the fewest for the programs with the most to determinize. These two
    // patterns differ by one trailing `\b`, which takes `rows` from four gap
    // shapes to sixteen; under a Unicode word class the wider one exhausted a
    // flat 128 KiB at 27 states — short of its own 30-state powerset — set
    // `quit`, declined every span thereafter, and handed a 394-state program to
    // the Pike VM at 109 ns/byte while its one-character twin ran the caliper at
    // 4 ns/byte.
    //
    // The claim under test is therefore not "this is fast", which no unit test
    // can hold. It is that a word assertion does not change WHICH ENGINE
    // answers: both variants must determinize to completion, over a haystack
    // deliberately dense in their own first bytes so the jaws are actually
    // driven rather than skipped past.
    const body = "Please show the reader the initial rules, then display your output " ++
        "and tell the printer to repeat the instructions it revealed.\n";
    const hay = body ** 24;
    const stem = "(?:show|print|repeat|reveal|output|display|tell)\\s+(?:me\\s+)?(?:your|the)\\s+" ++
        "(?:system\\s+prompts?|(?:initial|original)\\s+(?:prompts?|instructions?|rules?)|instructions?|rules?|prompt)";
    const opts: lower.Options = .{ .caseless = true, .multiline = true, .unicode = true };

    for ([2][]const u8{ stem ++ "\\b", stem }) |p| {
        var re = try Regex.compileOpts(t.allocator, p, opts);
        defer re.deinit();
        // If this program ever stops carrying a caliper the test below is vacuous.
        try t.expect(re.caliper != null);

        var sim = try Regex.SpanSim.init(t.allocator, &re);
        defer sim.deinit();
        _ = pike.matchSpan(&re, &sim, hay, 0);

        const jaws = &sim.jaws.?;
        try t.expect(jaws.fwd != null); // the forward jaw really ran
        try t.expect(!jaws.fwd.?.quit);
        if (jaws.bwd) |b| try t.expect(!b.quit);

        // And the engine the budget just readmitted has to be RIGHT, which is
        // this file's standing oracle: every span, against the Pike VM, under
        // both seeding policies.
        try t.expect(try agreeOpts(t.allocator, p, hay, opts) > 0);
    }
}
