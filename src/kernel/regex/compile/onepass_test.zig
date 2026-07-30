//! The one-pass capture engine's proof obligations.
//!
//! `onepass.zig` is only ever allowed to be a SPEED decision: for every pattern
//! it accepts, its slot vector must equal the Pike VM's byte for byte, on every
//! input. So the Pike VM is the oracle here — not a second implementation of the
//! same idea, but the general engine the fast one is a specialization of. Three
//! obligations:
//!
//!   1. ACCEPTANCE IS SOUND — a randomized differential over generated patterns
//!      and inputs. Every accepted pattern is compared slot-for-slot.
//!   2. REFUSAL IS SAFE — the shapes that are definitionally not one-pass are
//!      refused, and the caller's Pike VM still answers them correctly.
//!   3. THE FAST PATH IS REACHED — a curated corpus of real `-r`/`--json`
//!      patterns, asserting the ones that must be accepted actually are, so a
//!      regression that quietly refuses everything shows up as a test failure
//!      rather than as a silent loss of the speedup.

const std = @import("std");
/// The test runner (brigade) is this binary's root module — the same door
/// `std.testing.fuzz` reaches through. `note` is its stdout channel: a passing
/// test's census belongs there, not on the stderr that Zig renders as a failure.
const brigade = @import("root");
const captures = @import("captures.zig");
const fault = @import("../../../fault.zig");
const Captures = captures.Captures;
const OnePass = captures.OnePass;

const ta = std.testing.allocator;

/// Run both engines over `line` and require identical verdicts and slots.
fn agree(op: *OnePass, pike: *Captures, line: []const u8, from: usize) !void {
    var a: [64]isize = undefined;
    var b: [64]isize = undefined;
    const av = a[0..op.nslots];
    const bv = b[0..pike.nslots];
    const ha = op.find(line, from, av);
    const hb = pike.find(line, from, bv);
    try std.testing.expectEqual(hb, ha);
    if (hb) try std.testing.expectEqualSlices(isize, bv, av);
}

const Arms = struct { op: OnePass, pike: Captures };

/// Compile both arms for `pat` — two independent `Captures`, so the oracle can
/// never be perturbed by the engine under test. Returns null when the pattern is
/// refused, which is a legitimate outcome and not a failure.
fn arms(pat: []const u8, unicode: bool) !?Arms {
    var pike = try Captures.compile(ta, pat, false, unicode);
    errdefer pike.deinit();
    var second = try Captures.compile(ta, pat, false, unicode);
    errdefer second.deinit();
    switch (try OnePass.attach(ta, second)) {
        .got => |op| return .{ .op = op, .pike = pike },
        .declined => {
            second.deinit();
            pike.deinit();
            return null;
        },
    }
}

// ── 1. Acceptance is sound: randomized differential ──────────────────────────

const alphabet = "aabbcx,= \t\"09_";

/// A structural pattern generator: builds a tree and prints it, so every
/// pattern is syntactically valid by construction and the generator can bias
/// itself toward the shapes one-pass actually cares about (disjoint followers,
/// nested groups, greedy vs lazy repeats).
const Gen = struct {
    rnd: std.Random,
    out: *std.ArrayList(u8),
    ngroups: u32 = 0,

    const atoms = [_][]const u8{ "a", "b", "c", "x", ",", "=", " ", "\"", "\\w", "\\d", "\\s", "[a-c]", "[^,]", "[0-9]", ".", "_" };
    const reps = [_][]const u8{ "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}" };

    fn emit(self: *Gen, s: []const u8) std.mem.Allocator.Error!void {
        try self.out.appendSlice(ta, s);
    }

    fn atom(self: *Gen, depth: u32) std.mem.Allocator.Error!void {
        // A group or a nested sub-expression, else a leaf.
        const roll = self.rnd.uintLessThan(u8, 10);
        if (depth < 3 and roll < 3 and self.ngroups < 5) {
            self.ngroups += 1;
            try self.emit("(");
            try self.alt(depth + 1);
            try self.emit(")");
        } else if (depth < 3 and roll < 5) {
            try self.emit("(?:");
            try self.alt(depth + 1);
            try self.emit(")");
        } else {
            try self.emit(atoms[self.rnd.uintLessThan(usize, atoms.len)]);
        }
        if (self.rnd.uintLessThan(u8, 10) < 4) try self.emit(reps[self.rnd.uintLessThan(usize, reps.len)]);
    }

    fn cat(self: *Gen, depth: u32) std.mem.Allocator.Error!void {
        const n = 1 + self.rnd.uintLessThan(u32, if (depth == 0) 4 else 2);
        for (0..n) |_| try self.atom(depth);
    }

    fn alt(self: *Gen, depth: u32) std.mem.Allocator.Error!void {
        try self.cat(depth);
        var k: u32 = 0;
        while (k < 2 and self.rnd.uintLessThan(u8, 10) < 3) : (k += 1) {
            try self.emit("|");
            try self.cat(depth);
        }
    }
};

test "onepass: randomized slot-exact differential against the Pike VM" {
    var prng = std.Random.DefaultPrng.init(0xA11CE5);
    const rnd = prng.random();

    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(ta);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ta);

    var accepted: usize = 0;
    var refused: usize = 0;
    var pairs: usize = 0;

    for (0..900) |i| {
        pat.clearRetainingCapacity();
        var g = Gen{ .rnd = rnd, .out = &pat };
        // Half the corpus is Unicode-mode (gist's default), half `(?-u)`, so the
        // byte-trie lowering is exercised on both sides of the alphabet.
        const unicode = i % 2 == 0;
        if (rnd.uintLessThan(u8, 10) < 2) try g.emit("^");
        try g.alt(0);
        if (rnd.uintLessThan(u8, 10) < 2) try g.emit("$");

        var both = (arms(pat.items, unicode) catch continue) orelse {
            refused += 1;
            continue;
        };
        defer both.op.deinit();
        defer both.pike.deinit();
        accepted += 1;

        for (0..30) |_| {
            line.clearRetainingCapacity();
            const n = rnd.uintLessThan(usize, 24);
            for (0..n) |_| try line.append(ta, alphabet[rnd.uintLessThan(usize, alphabet.len)]);
            const from = if (line.items.len == 0) 0 else rnd.uintLessThan(usize, line.items.len + 1);
            agree(&both.op, &both.pike, line.items, 0) catch |e| {
                std.debug.print("MISMATCH pattern='{s}' unicode={} line='{s}' from=0\n", .{ pat.items, unicode, line.items });
                return e;
            };
            agree(&both.op, &both.pike, line.items, from) catch |e| {
                std.debug.print("MISMATCH pattern='{s}' unicode={} line='{s}' from={d}\n", .{ pat.items, unicode, line.items, from });
                return e;
            };
            pairs += 2;
        }
    }
    // Report the run size the acceptance bar asks for, and hold the generator to
    // a floor: a change that made the checker refuse everything would still pass
    // every comparison, so "zero mismatches" alone is not evidence.
    brigade.note("\n[onepass] differential: {d} patterns accepted / {d} refused, {d} (pattern,input) comparisons, 0 mismatches\n", .{ accepted, refused, pairs });
    try std.testing.expect(accepted >= 150);
    try std.testing.expect(pairs >= 8000);
}

test "onepass: differential over UTF-8 input, not just ASCII" {
    const pats = [_][]const u8{ "(\\w+)\\(", "([^\"]*)\"", "(\\p{L}+)=", "(.+?)," };
    const lines = [_][]const u8{
        "héllo(wörld)",
        "naïve café(x)",
        "\"ünïcode\"",
        "αβγ=δε",
        "日本語,テスト",
        "",
        "(",
        "\xff\xfe bad utf8 (",
    };
    for (pats) |p| {
        var both = (try arms(p, true)) orelse continue;
        defer both.op.deinit();
        defer both.pike.deinit();
        for (lines) |l| {
            try agree(&both.op, &both.pike, l, 0);
            if (l.len > 1) try agree(&both.op, &both.pike, l, 1);
        }
    }
}

// ── 2. Refusal is safe ───────────────────────────────────────────────────────

test "onepass: definitionally ambiguous patterns are refused, and the Pike VM still answers" {
    // Each of these has two live alternatives on some byte, so a one-pass table
    // cannot represent it. The refusal must be a declinature (routine — never a
    // fault), and the Pike VM the caller keeps must produce the right groups.
    const cases = [_]struct { pat: []const u8, line: []const u8, want: []const isize }{
        // Shared literal prefix across alternation branches.
        .{ .pat = "(ab|ac)", .line = "zac", .want = &.{ 1, 3, 1, 3 } },
        // The repeat's body and its follower overlap on 'b'.
        .{ .pat = "(a|b)*b", .line = "abab", .want = &.{ 0, 4, 2, 3 } },
        // `\w` swallows digits, so the follower is not disjoint.
        .{ .pat = "\\w+(\\d)", .line = "ab12", .want = &.{ 0, 4, 3, 4 } },
        // Two adjacent unbounded repeats over the same class.
        .{ .pat = "(a*)(a*)", .line = "aaa", .want = &.{ 0, 3, 0, 3, 3, 3 } },
        // `.` covers the separator it is supposed to stop before.
        .{ .pat = "(.*)=(.*)", .line = "k=v=w", .want = &.{ 0, 5, 0, 3, 4, 5 } },
    };
    for (cases) |c| {
        var pike = try Captures.compile(ta, c.pat, false, false);
        defer pike.deinit();
        try std.testing.expectEqual(fault.Decline.not_worthwhile, (try OnePass.attach(ta, pike)).declined);
        // `attach` declining must leave `pike` untouched and usable — that is the
        // contract `compileCaps` relies on to avoid a second parse.
        var out: [64]isize = undefined;
        const slots = out[0..pike.nslots];
        try std.testing.expect(pike.find(c.line, 0, slots));
        try std.testing.expectEqualSlices(isize, c.want, slots);
    }
}

test "onepass: a refused pattern routed through Caps still captures correctly" {
    // The seam the product actually uses: `Caps` with the Pike arm, for a
    // pattern the one-pass builder declined.
    const pike = try Captures.compile(ta, "(ab|ac)+", false, false);
    try std.testing.expectEqual(fault.Decline.not_worthwhile, (try OnePass.attach(ta, pike)).declined);
    var caps = captures.Caps{ .linear = pike };
    defer caps.deinit();
    var out: [64]isize = undefined;
    const slots = out[0..caps.nslots()];
    try std.testing.expect(caps.find("xabac!", 0, slots));
    try std.testing.expectEqualSlices(isize, &.{ 1, 5, 3, 5 }, slots);
}

// ── 3. The fast path is reached ──────────────────────────────────────────────

test "onepass: the real -r / --json patterns that must take the fast arm" {
    // Every one of these is one-pass by inspection: the repeat's class and its
    // follower are disjoint at the BYTE level even under the UTF-8 lowering.
    // If a change makes one of them fall back, the speedup is gone and this
    // fails rather than quietly regressing.
    const must = [_][]const u8{
        "fn (\\w+)\\(",
        "(\\w+)=(\\w+)",
        "([^\"]*)\"",
        "([^,]+),",
        "(\\d+)\\.(\\d+)",
        "^(\\s*)#",
        "\\b(\\w+)\\(",
        "pub const (\\w+)",
        "(\\w+)://",
    };
    for (must) |p| {
        var pike = try Captures.compile(ta, p, false, true);
        switch (try OnePass.attach(ta, pike)) {
            .got => |built| {
                var owned = built;
                owned.deinit();
            },
            .declined => {
                pike.deinit();
                std.debug.print("expected one-pass, was declined: {s}\n", .{p});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "onepass: eligibility census over a realistic -r/--json pattern corpus" {
    // Measures — and prints — how much of a real capture workload reaches the
    // fast arm, in gist's DEFAULT Unicode mode and under `--no-unicode`. The gap
    // between the two columns is the UTF-8 lead-byte cost: two classes that are
    // disjoint as CODEPOINT sets (`\w` vs `\s`) share lead bytes once lowered to
    // a byte trie, so the byte automaton really does have two live alternatives
    // there even though the codepoint automaton does not. Resolving that needs a
    // predicate/minterm alphabet at the lowering, not a looser checker here.
    const corpus = [_][]const u8{
        "(\\w+)\\s*=\\s*(\\w+)",      "fn (\\w+)\\(",           "(\\w+)=(\\w+)",
        "([^\"]*)\"",                 "([^,]+),",               "(\\d+)\\.(\\d+)",
        "^(\\s*)#",                   "\\b(\\w+)\\(",           "pub const (\\w+)",
        "(\\w+)://",                  "import (\\w+)",          "(\\w+)\\.(\\w+)\\.(\\w+)",
        "TODO\\((\\w+)\\):",          "def (\\w+)",             "class (\\w+)",
        "(\\d{4})-(\\d{2})-(\\d{2})", "<(\\w+)>",               "\\$\\{(\\w+)\\}",
        "(\\w+)@(\\w+)",              "^(#+) (.*)$",            "(.*)=(.*)",
        "(a|b)*b",                    "(\\w+)\\s+(\\w+)",       "\\[(\\w+)\\]\\((\\S+)\\)",
        "(?P<k>\\w+): (?P<v>.*)",     "impl (\\w+) for (\\w+)", "-- (\\w+) --",
    };
    var uni: usize = 0;
    var ascii: usize = 0;
    for (corpus) |p| {
        var ok: [2]bool = .{ false, false };
        for ([_]bool{ true, false }, 0..) |u, k| {
            var pike = Captures.compile(ta, p, false, u) catch continue;
            switch (try OnePass.attach(ta, pike)) {
                .got => |built| {
                    var owned = built;
                    owned.deinit();
                    ok[k] = true;
                    if (u) uni += 1 else ascii += 1;
                },
                .declined => pike.deinit(),
            }
        }
        // Name the patterns the UTF-8 lowering alone costs us — those are the
        // ones a predicate/minterm alphabet would hand back.
        if (!ok[0] and ok[1]) brigade.note("[onepass] unicode-only refusal: {s}\n", .{p});
    }
    brigade.note("[onepass] eligibility census over {d} real patterns: unicode {d}/{d}, no-unicode {d}/{d}\n", .{ corpus.len, uni, corpus.len, ascii, corpus.len });
    // A floor, not a target: this is what stops a regression from silently
    // turning the fast arm off for the whole product.
    try std.testing.expect(uni * 2 >= corpus.len);
}

test "onepass: greedy accept with live successors defers its own slot writes" {
    // The trap this engine has to avoid: at the accept the pattern may still
    // grow, and the surviving path may bypass a group the accepting ε-path
    // entered. Writing the accept's slots eagerly would leak that group.
    const cases = [_]struct { pat: []const u8, line: []const u8 }{
        .{ .pat = "(a*)(?:x|((b)?))", .line = "aax" },
        .{ .pat = "(a*)(?:x|((b)?))", .line = "aa" },
        .{ .pat = "(a*)(bc)?", .line = "aab" },
        .{ .pat = "(a*)(bc)?", .line = "aabc" },
        .{ .pat = "(a+)(b*)(c?)", .line = "aabbb" },
        .{ .pat = "(a*?)(b*)", .line = "aabb" },
    };
    for (cases) |c| {
        var both = (try arms(c.pat, false)) orelse {
            std.debug.print("expected one-pass: {s}\n", .{c.pat});
            return error.TestUnexpectedResult;
        };
        defer both.op.deinit();
        defer both.pike.deinit();
        try agree(&both.op, &both.pike, c.line, 0);
        for (0..c.line.len) |k| try agree(&both.op, &both.pike, c.line, k);
    }
}

test "onepass: assertions on an accept, and a post-match branch under one" {
    // A `match` reached with a pending assertion may FAIL at run time and hand
    // control to a lower-priority branch — a choice the table cannot express.
    // The builder must refuse rather than silently drop that branch.
    var pike = try Captures.compile(ta, "(a*)(?:$|b)", false, false);
    defer pike.deinit();
    try std.testing.expectEqual(fault.Decline.not_worthwhile, (try OnePass.attach(ta, pike)).declined);

    // But an assertion that only guards a transition, or an accept with no
    // successors at all, stays representable.
    const ok = [_]struct { pat: []const u8, line: []const u8 }{
        .{ .pat = "^(\\w+)", .line = "abc def" },
        .{ .pat = "(\\w+)$", .line = "abc def" },
        .{ .pat = "\\b(x+)\\b", .line = "y xx y" },
        .{ .pat = "(?:^|,)(\\d+)", .line = "12,34" },
    };
    for (ok) |c| {
        var both = (try arms(c.pat, false)) orelse continue;
        defer both.op.deinit();
        defer both.pike.deinit();
        for (0..c.line.len + 1) |k| try agree(&both.op, &both.pike, c.line, k);
    }
}

test "onepass: the step budget degrades to the Pike VM without changing the answer" {
    // `(a+)b` restarts at every position of a long `a` run — quadratic if the
    // one-pass loop kept going, linear once it hands back to the Pike VM. The
    // answer must be identical either way, and the degradation is sticky.
    var both = (try arms("(a+)b", false)) orelse return error.TestUnexpectedResult;
    defer both.op.deinit();
    defer both.pike.deinit();

    const line = "a" ** 4000;
    try agree(&both.op, &both.pike, line, 0);
    try std.testing.expect(both.op.trips > 0);
    // Conceding is evidence-driven, not one-strike: a single pathological line
    // must not cost a good pattern its fast arm for a whole run.
    try std.testing.expect(!both.op.degraded);
    for (0..20) |_| try agree(&both.op, &both.pike, line, 0);
    try std.testing.expect(both.op.degraded);
    // Still correct after degrading, including on inputs that DO match.
    try agree(&both.op, &both.pike, "a" ** 40 ++ "b", 0);
    try agree(&both.op, &both.pike, "", 0);
}

test "onepass: empty and zero-length-match edges" {
    const cases = [_]struct { pat: []const u8, line: []const u8 }{
        .{ .pat = "(a*)", .line = "" },
        .{ .pat = "(a*)", .line = "bbb" },
        .{ .pat = "()", .line = "xy" },
        .{ .pat = "(x?)", .line = "" },
        .{ .pat = "^$", .line = "" },
        .{ .pat = "(\\s*)$", .line = "ab  " },
    };
    for (cases) |c| {
        var both = (try arms(c.pat, false)) orelse continue;
        defer both.op.deinit();
        defer both.pike.deinit();
        for (0..c.line.len + 1) |k| try agree(&both.op, &both.pike, c.line, k);
    }
}

test "onepass: named groups survive the arm swap" {
    const pike = try Captures.compile(ta, "(?P<key>\\w+)=(?P<val>[^,]*)", false, false);
    var op = (try OnePass.attach(ta, pike)).got;
    defer op.deinit();
    try std.testing.expectEqual(@as(?u32, 1), op.groupByName("key"));
    try std.testing.expectEqual(@as(?u32, 2), op.groupByName("val"));
    try std.testing.expectEqual(@as(?u32, null), op.groupByName("nope"));
}
