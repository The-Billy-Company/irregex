//! irregex powerset (subset-construction) tests — split from `powerset.zig` to
//! keep the determinizer under the shape cap.
//!
//! These are deliberately **NOT** differential-oracle tests: `dfa_test.zig`
//! already diffs the built `Dfa`'s match verdict against the proven Pike VM. This
//! file proves correctness two complementary ways — neither leans on the Pike
//! engine under test:
//!
//! A. **Intrinsic structural invariants** — properties of a well-formed DFA,
//!    checkable against the NFA + emitted tables, that a verdict oracle can't see
//!    (bloat states, an unfilled slot the matcher happens never to follow, an
//!    unsound/over-refined byte-class partition that coincidentally agrees):
//!      1. **Shape/bounds** — table lengths, `start`/`dead` in range, `anchored`
//!         plumbed through, classes dense and in `[0,ncls)`.
//!      2. **Byte-class soundness** — no class straddles any consuming NFA set.
//!      3. **Byte-class minimality** — bytes indistinguishable by every set share
//!         a class (no gratuitous column blow-up).
//!      4. **Transition totality** — every `trans_in`/`trans_fin` slot of a
//!         reachable state is a filled, valid id (no `unknown` deref).
//!      5. **No orphans** — every state is `trans_in`-reachable from `start`, or a
//!         `trans_fin` target of one (terminal states, intentionally not expanded).
//!      6. **Dead-state absorption** — for `^`-anchored programs the sink loops to
//!         itself and never matches at EOL (what `Dfa.match`'s anchored bail relies on).
//!      7. **Build determinism** — two compiles are byte-identical.
//!
//! B. **EXHAUSTIVE language equivalence** — the strongest correctness statement:
//!    a from-scratch ε-closure NFA acceptor (`Spec`) *defines* this engine's grep
//!    semantics, and for each pattern EVERY string up to a bound (length 7
//!    curated / 4 fuzz, over {a,z,1,'\n'}) is asserted to match identically under
//!    the DFA and the spec. Exhaustive ⇒ a proof over that bounded space, not a
//!    sample — catching a wrong transition function (`step`/`close`/`buildClasses`
//!    following the wrong edges), the one bug class the invariants can't. The spec
//!    is independently validated ≡ the Pike VM (0 disagreements / ~500k strings).
//!
//! Plus exact hand-computed alphabet-class counts (a direct `buildClasses` test),
//! the `max_states` cap-bail to null, and a randomized fuzz running BOTH layers.

const std = @import("std");
const core = @import("../program/core.zig");
const syn = @import("../../syntax/syntax.zig");
const powerset = @import("powerset.zig");
const word = @import("../../syntax/word.zig");
const Regex = core.Regex;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const unfilled: u32 = std.math.maxInt(u32); // powerset's `unknown` slot sentinel

/// Compile and require an actual DFA (not a powerset-cap fallback) — so every
/// invariant case genuinely exercises the determinizer. Caller owns `deinit`.
/// `force_dfa`: many invariant patterns are byte-exact class runs, whose
/// production compile skips the (dead-weight) determinization — this harness
/// exists to test subset construction itself.
fn compileDfa(pattern: []const u8) !Regex {
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .force_dfa = true });
    if (re.dfa == null) {
        re.deinit();
        return error.PowersetCapHit;
    }
    return re;
}

/// `compileDfa`'s Unicode-mode twin — compiles with `.unicode = true` so the
/// pattern lowers non-ASCII content to a UTF-8 byte sub-automaton.
fn compileDfaU(pattern: []const u8) !Regex {
    var re = try Regex.compileOpts(std.testing.allocator, pattern, .{ .unicode = true, .force_dfa = true });
    if (re.dfa == null) {
        re.deinit();
        return error.PowersetCapHit;
    }
    return re;
}

fn countConsume(states: []const syn.State) usize {
    var n: usize = 0;
    for (states) |st| if (st == .consume) {
        n += 1;
    };
    return n;
}

/// Assert every intrinsic structural invariant on a built DFA. No reference
/// matcher — purely the NFA program (`re.states`) vs the emitted tables.
fn assertInvariants(re: *const Regex) !void {
    const a = std.testing.allocator;
    const d = re.dfa.?;
    const ncls: usize = d.ncls;
    const ns: usize = d.nstates;

    // (1) shape / bounds. The DFA is **premultiplied**: a state is its row offset
    // `id*ncls`, so table entries / `start` / `dead` are offsets.
    try expect(ncls >= 1 and ncls <= 256);
    try expect(ns >= 1);
    try expectEqual(ns * ncls, d.trans_in.len);
    try expectEqual(ns * ncls, d.trans_fin.len);
    // It is also **match-partitioned**: `freeze.zig` renumbers match states to the
    // front, so `match_hi` is a ROW boundary inside the table and the matching
    // offsets are exactly `[0, match_hi)`. An off-by-a-column bound here would
    // make `isMatch` answer about a slot no state occupies.
    try expect(d.match_hi % ncls == 0);
    try expect(d.match_hi <= ns * ncls);
    // The non-matching sink is never a match state — invariant (6) below proves
    // that for anchored programs, where `dead` is load-bearing; assert it here for
    // every program, since a renumbering that mis-mapped the id would be silent in
    // the unanchored case (nothing consults `dead` there).
    if (d.dead != unfilled) try expect(!d.isMatch(d.dead));
    try expect(d.start < ns * ncls and d.start % ncls == 0);
    try expect(d.start_w < ns * ncls and d.start_w % ncls == 0); // == start when !word_ctx
    try expect(d.dead == unfilled or (d.dead < ns * ncls and d.dead % ncls == 0));
    try expectEqual(re.anchored, d.anchored);
    // The word-context interior table exists iff the DFA carries word context.
    if (d.word_ctx) try expectEqual(ns * ncls, d.trans_in_w.len) else try expect(d.trans_in_w.len == 0);

    // classes are dense [0,ncls) and every byte maps inside that range.
    var class_present = [_]bool{false} ** 256;
    for (d.class) |c| {
        try expect(c < ncls);
        class_present[c] = true;
    }
    for (0..ncls) |c| try expect(class_present[c]); // no gaps

    // (2)+(3) hold of the frozen partition because it IS the partition the
    // determinizer ran on: `powerset` freezes `Classes.build`'s output unchanged. It
    // does not merge the columns a finished table turns out not to separate — that
    // pass exists (`../automata/reduce.zig`) and the byte road declines it by
    // measurement, so `d.class` stays exactly as refined as the NFA's sets make it.
    // If that ever changes, these two become statements about the pre-merge partition
    // and the frozen map owes a third: that it only ever JOINS these classes.

    // (2) byte-class soundness: no class straddles any consuming set — every
    // member of a class shares that set's membership bit.
    for (re.states) |st| switch (st) {
        .consume => |cn| {
            var class_member = [_]i8{-1} ** 256; // -1=unseen, 0/1=membership
            for (0..256) |bi| {
                const b: u8 = @intCast(bi);
                const m: i8 = @intFromBool(cn.set.has(b));
                const c = d.class[b];
                if (class_member[c] < 0) class_member[c] = m else try expect(class_member[c] == m);
            }
        },
        else => {},
    };

    // (3) byte-class minimality: bytes with an identical membership signature
    // across ALL consuming sets must land in the same class (≤64 sets ⇒ pack the
    // signature into a u64; every test/fuzz program is far under that). Under
    // `word_ctx` the partition is ALSO refined by ASCII word-ness, so word-ness
    // joins the signature (bit 63) and the consume-set budget drops to 63.
    const nconsume = countConsume(re.states);
    const sig_cap: usize = if (d.word_ctx) 63 else 64;
    if (nconsume <= sig_cap) {
        var sig = [_]u64{0} ** 256;
        var j: usize = 0;
        for (re.states) |st| switch (st) {
            .consume => |cn| {
                for (0..256) |bi| if (cn.set.has(@intCast(bi))) {
                    sig[bi] |= @as(u64, 1) << @intCast(j);
                };
                j += 1;
            },
            else => {},
        };
        if (d.word_ctx) for (0..256) |bi| if (word.isWordByte(@intCast(bi))) {
            sig[bi] |= @as(u64, 1) << 63;
        };
        var by_sig = std.AutoHashMap(u64, u8).init(a);
        defer by_sig.deinit();
        for (0..256) |bi| {
            const gop = try by_sig.getOrPut(sig[bi]);
            if (gop.found_existing) try expectEqual(gop.value_ptr.*, d.class[bi]) else gop.value_ptr.* = d.class[bi];
        }
    }

    // (4)+(5) reachability, transition totality, no orphans. BFS the machine the
    // matcher actually walks: `trans_in` edges from `start`. Every slot of a
    // reached state (interior AND final) must be a filled, valid offset. Values are
    // premultiplied offsets; `reached`/`fin_target` index the id space (`off/ncls`).
    const reached = try a.alloc(bool, ns);
    defer a.free(reached);
    @memset(reached, false);
    const stack = try a.alloc(u32, ns); // holds offsets; ≤ ns distinct states
    defer a.free(stack);
    var sp: usize = 0;
    // Seed BOTH starts: `start` (first byte non-word) and `start_w` (first byte a
    // word byte). They coincide when !word_ctx, so the extra push is a harmless dup.
    for ([_]u32{ d.start, d.start_w }) |s0| if (!reached[s0 / ncls]) {
        reached[s0 / ncls] = true;
        stack[sp] = s0;
        sp += 1;
    };
    while (sp > 0) {
        sp -= 1;
        const s = stack[sp]; // row offset
        for (0..ncls) |k| {
            const ti = d.trans_in[s + k];
            const tf = d.trans_fin[s + k];
            try expect(ti != unfilled and ti < ns * ncls and ti % ncls == 0); // interior slot total + valid
            try expect(tf != unfilled and tf < ns * ncls and tf % ncls == 0); // final slot total + valid
            // Interior edges from `trans_in`, plus `trans_in_w` under word context —
            // states reachable only through the word-byte table are real, so the BFS
            // must follow both or falsely flag them as orphans.
            const edges = [_]u32{ ti, if (d.word_ctx) d.trans_in_w[s + k] else ti };
            if (d.word_ctx) try expect(edges[1] != unfilled and edges[1] < ns * ncls and edges[1] % ncls == 0);
            for (edges[0..if (d.word_ctx) 2 else 1]) |e| {
                const tid = e / ncls;
                if (!reached[tid]) {
                    reached[tid] = true;
                    stack[sp] = e;
                    sp += 1;
                }
            }
        }
    }
    // No orphan: every state is reached, or is a `trans_fin` target of a reached
    // state (terminal states are interned for `is_match` but never enqueued).
    const fin_target = try a.alloc(bool, ns);
    defer a.free(fin_target);
    @memset(fin_target, false);
    for (0..ns) |sid| if (reached[sid]) {
        const s = sid * ncls;
        for (0..ncls) |k| fin_target[d.trans_fin[s + k] / ncls] = true;
    };
    for (0..ns) |sid| try expect(reached[sid] or fin_target[sid]);

    // (6) dead-state absorption (anchored only — unanchored re-seeds the start
    // into every step, so its empty set is not an absorbing sink and `match`
    // never consults `dead`). The empty/non-match sink must: never match; loop
    // to itself on every interior byte; never match even at EOL (`trans_fin`).
    if (re.anchored and d.dead != unfilled) {
        try expect(!d.isMatch(d.dead)); // `dead` is an offset; the match partition is by offset
        if (reached[d.dead / ncls]) for (0..ncls) |k| {
            try expectEqual(d.dead, d.trans_in[d.dead + k]); // self-loop (offset → same offset)
            if (d.word_ctx) try expectEqual(d.dead, d.trans_in_w[d.dead + k]); // and in the word-byte table
            try expect(!d.isMatch(d.trans_fin[d.dead + k]));
        };
    }
}

fn checkPattern(pattern: []const u8) !void {
    var re = try compileDfa(pattern);
    defer re.deinit();
    try assertInvariants(&re);
}

test "powerset: structural invariants hold across hand-picked adversarial shapes" {
    const pats = [_][]const u8{
        // literals, classes, dot, escapes
        "a",          "abc",        "[a-c]",    "[^a-c]",          ".",
        "\\d",        "\\w",        "\\s",      "a.b",             "a..b",
        // repetition (the linear `{n}` expansion the cap is sized around)
        "a*",         "a+",         "a?",       "ab*c",            "ab+c",
        "colou?r",    "a{3}",       "a{2,4}",   "a{0,3}",          "(ab){2,3}",
        // alternation (incl. overlapping/identical branches → subset merging)
        "foo|bar",    "a|a",        "(a|b)c",   "ab|cd|ef",        "(foo|bar)baz",
        // line anchors in every position
        "^a",         "a$",         "^abc$",    "^$",              "^",
        "$",          "^.*$",       "^\\}$",    "import|^package",
        // start-overlap hazards + class boundaries
        "ab",
        "abc",        "xyz",        "a[bc]d",   "[0-9]{4}",        "[a-f0-9]{2,}",
        "panic|0x",   "\\w{3,8}",   ".*",       "a.*b.*c",
        // nested groups / quantified groups
                "(a+)+",
        "(ab|cd)*ef", "((a|b)c)+d", "x(y|z)?w",
    };
    for (pats) |p| checkPattern(p) catch |e| {
        std.debug.print("INVARIANT FAILURE on pattern /{s}/: {}\n", .{ p, e });
        return e;
    };
}

test "powerset: byte-class partition has the exact computed cardinality" {
    // `buildClasses` collapses the 256-byte alphabet to one column per distinct
    // membership signature across all consuming sets. Hand-verify the count.
    const Case = struct { pat: []const u8, ncls: u16 };
    const cases = [_]Case{
        .{ .pat = "a", .ncls = 2 }, // {a} | rest
        .{ .pat = "abc", .ncls = 4 }, // {a}{b}{c} | rest
        .{ .pat = "[a-c]", .ncls = 2 }, // {a,b,c} | rest
        .{ .pat = ".", .ncls = 2 }, // {\n} | rest (dot excludes newline)
        .{ .pat = "\\d", .ncls = 2 }, // {0-9} | rest
        .{ .pat = "[^a]", .ncls = 2 }, // {a,\n} | rest (negated still drops \n)
        .{ .pat = "ab|cd", .ncls = 5 }, // {a}{b}{c}{d} | rest
        .{ .pat = "a.b", .ncls = 4 }, // {a}{b}{\n} | rest
        .{ .pat = "^$", .ncls = 1 }, // no consuming set ⇒ single class
        .{ .pat = "^", .ncls = 1 },
        .{ .pat = "$", .ncls = 1 },
    };
    for (cases) |c| {
        var re = try compileDfa(c.pat);
        defer re.deinit();
        expectEqual(c.ncls, re.dfa.?.ncls) catch |e| {
            std.debug.print("class-count mismatch /{s}/: want {} got {}\n", .{ c.pat, c.ncls, re.dfa.?.ncls });
            return e;
        };
    }
}

// ── the determinizer's contract: an independent NFA acceptor (NOT the Pike VM) ──
// A from-scratch ε-closure set-simulation over `syn.State` that *defines* this
// engine's grep line semantics (re-seed `start` at every position; `^`/`$`
// resolve against the BOL/EOL flags). It is the specification the DFA tables
// must reproduce exactly — and, run EXHAUSTIVELY over every short string below,
// gives certainty (not a sampled probability) that
// `step`/`close`/`buildClasses` compute the right language, the one class of
// bug the structural invariants cannot see.
const Spec = struct {
    states: []const syn.State,
    start: u32,
    a: std.mem.Allocator,
    seen: []u32, // ε-closure dedup, gen-stamped (no per-pass memset)
    gen: u32 = 0,
    stack: []u32, // closure worklist
    cur: []u32, // present consume-state ids "between bytes"
    nxt: []u32,
    seeds: []u32, // step injection buffer (consume outs + re-seeded start)

    fn init(a: std.mem.Allocator, re: *const Regex) !Spec {
        const n = re.states.len;
        const seen = try a.alloc(u32, n);
        @memset(seen, 0);
        return .{ .states = re.states, .start = re.start, .a = a, .seen = seen, .stack = try a.alloc(u32, n), .cur = try a.alloc(u32, n), .nxt = try a.alloc(u32, n), .seeds = try a.alloc(u32, n + 1) };
    }
    fn deinit(s: *Spec) void {
        for ([_][]u32{ s.seen, s.stack, s.cur, s.nxt, s.seeds }) |buf| s.a.free(buf);
    }
    /// ε-close `inject` at the given boundary flags; write the reached consume
    /// states into `out`, return (len, matched). `word_before`/`word_after` are the
    /// ASCII word-ness of the bytes straddling this gap — resolving `\b`/`\B`/`\<`/
    /// `\>` with the SAME predicates as `powerset.close` (and the Pike VM), so this
    /// independent acceptor also defines the word-context language the DFA must
    /// reproduce. (Under `(?-u)` a byte ≥0x80 is non-word, byte-for-byte, which is
    /// exactly what `matchWord` commits to when the DFA doesn't quit.)
    fn close(s: *Spec, inject: []const u32, at_start: bool, at_end: bool, word_before: bool, word_after: bool, out: []u32) struct { n: usize, m: bool } {
        s.gen +%= 1;
        var sp: usize = 0;
        for (inject) |t| if (s.seen[t] != s.gen) {
            s.seen[t] = s.gen;
            s.stack[sp] = t;
            sp += 1;
        };
        var n: usize = 0;
        var matched = false;
        const push = struct {
            fn f(sp_p: *usize, sk: []u32, sn: []u32, g: u32, o: u32) void {
                if (sn[o] != g) {
                    sn[o] = g;
                    sk[sp_p.*] = o;
                    sp_p.* += 1;
                }
            }
        }.f;
        while (sp > 0) {
            sp -= 1;
            const st = s.stack[sp];
            switch (s.states[st]) {
                .consume => {
                    out[n] = st;
                    n += 1;
                },
                .split => |x| for ([_]u32{ x.a, x.b }) |o| push(&sp, s.stack, s.seen, s.gen, o),
                .assert_start => |o| if (at_start) push(&sp, s.stack, s.seen, s.gen, o),
                .assert_end => |o| if (at_end) push(&sp, s.stack, s.seen, s.gen, o),
                .assert_word => |w| if (w.mask.admits(word_before, word_after)) push(&sp, s.stack, s.seen, s.gen, w.out),
                // Buffer anchors (`\A`/`\z`) only exist under multiline, where no
                // DFA is built — such patterns are never fed to this Spec.
                .assert_buf_start, .assert_buf_end => {},
                .match => matched = true,
            }
        }
        return .{ .n = n, .m = matched };
    }
    /// Does the pattern match any substring of `line`? (no '\n' in `line`). Word
    /// context is ASCII (`(?-u)` / Unicode-restricted-to-ASCII): `word_before` is
    /// false at BOL (nothing precedes), the just-consumed byte's word-ness in the
    /// interior; `word_after` is the next byte's word-ness, false at EOL.
    fn lineMatch(s: *Spec, line: []const u8) bool {
        const wa0 = line.len > 0 and word.isWordByte(line[0]);
        var seed1 = [_]u32{s.start};
        var r = s.close(&seed1, true, line.len == 0, false, wa0, s.cur); // BOL
        if (r.m) return true;
        var cur_len = r.n;
        for (line, 0..) |c, i| {
            var ns: usize = 0;
            for (s.cur[0..cur_len]) |st| switch (s.states[st]) {
                .consume => |cn| if (cn.set.has(c)) {
                    s.seeds[ns] = cn.out;
                    ns += 1;
                },
                else => {},
            };
            s.seeds[ns] = s.start; // re-seed (grep); `^` dies at at_start=false
            ns += 1;
            const at_eol = i + 1 == line.len;
            const wb = word.isWordByte(c); // byte just consumed
            const wa = !at_eol and word.isWordByte(line[i + 1]); // next byte (false at EOL)
            r = s.close(s.seeds[0..ns], false, at_eol, wb, wa, s.nxt);
            if (r.m) return true;
            std.mem.swap([]u32, &s.cur, &s.nxt);
            cur_len = r.n;
        }
        return false;
    }
    /// rg `-l` line model: '\n' terminates a line, no phantom trailing line.
    fn docMatch(s: *Spec, doc: []const u8) bool {
        var rest = doc;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const end = nl orelse rest.len;
            if (s.lineMatch(rest[0..end])) return true;
            if (nl == null) break;
            rest = rest[end + 1 ..];
        }
        return false;
    }
};

/// Enumerate EVERY string of length 0..=maxlen over `alphabet` and assert the
/// DFA's `match`/`docMatch` agree with the NFA spec on each. Exhaustive ⇒ a
/// proof of language equivalence over that bounded space, no sampling.
fn exhaustiveEquiv(pat: []const u8, re: *const Regex, alphabet: []const u8, maxlen: usize) !void {
    var spec = try Spec.init(std.testing.allocator, re);
    defer spec.deinit();
    const d = re.dfa.?;
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    while (len <= maxlen) : (len += 1) {
        var idx = [_]usize{0} ** 8;
        while (true) {
            for (0..len) |i| buf[i] = alphabet[idx[i]];
            const sline = buf[0..len];
            if (spec.docMatch(sline) != d.docMatch(sline)) {
                std.debug.print("DOC MISMATCH pat=/{s}/ s=\"{s}\" spec={} dfa={}\n", .{ pat, sline, spec.docMatch(sline), d.docMatch(sline) });
                return error.DocLangMismatch;
            }
            if (std.mem.indexOfScalar(u8, sline, '\n') == null and spec.lineMatch(sline) != d.match(sline)) {
                std.debug.print("LINE MISMATCH pat=/{s}/ s=\"{s}\" spec={} dfa={}\n", .{ pat, sline, spec.lineMatch(sline), d.match(sline) });
                return error.LineLangMismatch;
            }
            var c: usize = 0; // odometer over alphabet^len
            while (c < len) : (c += 1) {
                idx[c] += 1;
                if (idx[c] < alphabet.len) break;
                idx[c] = 0;
            }
            if (c == len) break;
        }
    }
}

test "powerset: EXHAUSTIVE language equivalence vs the NFA spec (every string ≤ 7)" {
    // The proof case: for each pattern, every string up to length 7 over
    // {a (∈[a-c]/\\w), z (∉[a-c]), 1 (∈\\d), '\\n'} is checked both ways — a bound
    // that exceeds every curated DFA's state count, so it pins the FULL language
    // (Myhill-Nerode). Covers anchors in every position, empty lines, class
    // boundaries, nullable/EOL. The NFA spec is itself validated ≡ the Pike VM.
    const pats = [_][]const u8{
        "a",     "ab",    "a*",     "a+",     "a?",     "a|b",
        "ab|ba", "^a",    "a$",     "^a$",    "^$",     "^",
        "$",     "a.b",   ".",      ".*",     "[ab]+",  "[^a]",
        "\\d",   "\\d+",  "\\w",    "a{2}",   "a{1,3}", "(ab)+",
        "a*b*",  "^a.*$", "\\d{2}", "a|^b",   "b$|a",   "(a|b)*a",
        "^.b",   "a.?b",  "[a-c]z", "^\\d+$",
    };
    for (pats) |p| {
        var re = try compileDfa(p);
        defer re.deinit();
        exhaustiveEquiv(p, &re, "az1\n", 7) catch |e| {
            std.debug.print("EXHAUSTIVE FAILURE on /{s}/: {}\n", .{ p, e });
            return e;
        };
    }
}

test "powerset: EXHAUSTIVE language equivalence for Unicode classes (DFA ≡ NFA over UTF-8)" {
    // A `uclass` lowers to a multi-byte UTF-8 sub-automaton; the `Spec` walks those
    // byte states, so this proves the determinizer follows the right edges through
    // 2–4-byte consume chains (the one bug class the intrinsic invariants can't
    // see). The alphabet mixes ASCII with the UTF-8 bytes of é (C3 A9) and 中
    // (E4 B8 AD) plus a lone continuation byte (80), so every string ≤ 4 bytes —
    // well-formed AND ill-formed — is checked both ways.
    const pats = [_][]const u8{
        "é",
        "é+",
        "\\w",
        "\\w+",
        "\\d",
        ".",
        ".*",
        "[à-ÿ]",
        "[^a]",
        "\\p{L}",
        "\\p{Nd}",
        "a\\wb",
        "中",
        "中+",
        "café",
        "\\w{2}",
        "é|中",
        "[a-cé中]",
        "\\S",
    };
    const alpha = [_]u8{ 'a', 0xC3, 0xA9, 0xE4, 0xB8, 0xAD, 0x80 };
    for (pats) |p| {
        var re = compileDfaU(p) catch |e| {
            if (e == error.PowersetCapHit) continue; // Pike serves this one; no DFA to diff
            return e;
        };
        defer re.deinit();
        exhaustiveEquiv(p, &re, &alpha, 4) catch |e| {
            std.debug.print("UNICODE EXHAUSTIVE FAILURE on /{s}/: {}\n", .{ p, e });
            return e;
        };
    }
}

/// Line-level exhaustive equivalence for a word-CONTEXT DFA: every string ≤
/// `maxlen` over `alphabet` (ASCII-only, so `matchWord` never quits) is asserted
/// to match identically under `Dfa.matchWord` and the word-resolving NFA `Spec`.
/// This pins the doubled interior table (`trans_in`/`trans_in_w`) and the
/// `start`/`start_w` selection against an independent acceptor — the transition-
/// function bug class the structural invariants can't see.
fn exhaustiveWordEquiv(pat: []const u8, re: *const Regex, alphabet: []const u8, maxlen: usize) !void {
    var spec = try Spec.init(std.testing.allocator, re);
    defer spec.deinit();
    const d = re.dfa.?;
    std.debug.assert(d.word_ctx);
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    while (len <= maxlen) : (len += 1) {
        var idx = [_]usize{0} ** 8;
        while (true) {
            for (0..len) |i| buf[i] = alphabet[idx[i]];
            const sline = buf[0..len];
            // ASCII alphabet ⇒ never quits. Asserted as a test failure rather than
            // `unreachable`: if that ever stops holding, this reports it instead of
            // becoming undefined behavior in a ReleaseFast test run.
            const got = d.matchWord(sline) orelse return error.MatcherQuitOnAscii;
            if (spec.lineMatch(sline) != got) {
                std.debug.print("WORD MISMATCH pat=/{s}/ s=\"{s}\" spec={} dfa={}\n", .{ pat, sline, spec.lineMatch(sline), got });
                return error.WordLangMismatch;
            }
            var c: usize = 0; // odometer over alphabet^len
            while (c < len) : (c += 1) {
                idx[c] += 1;
                if (idx[c] < alphabet.len) break;
                idx[c] = 0;
            }
            if (c == len) break;
        }
    }
}

test "powerset: EXHAUSTIVE word-boundary equivalence vs the NFA spec (every string ≤ 6)" {
    // The word-context proof case: for each `\b`/`\B`/`\<`/`\>` pattern, every
    // string up to length 6 over {a (∈[a-c]/\\w), z (∈\\w, ∉[a-c]), 1 (∈\\d),
    // '_' (∈\\w), ' ' (non-word)} is checked both ways — enough to exceed each
    // DFA's state count and pin the FULL word-context language (Myhill-Nerode).
    // The NFA spec resolves the same word predicates as `powerset.close`, so this
    // is a SECOND independent oracle beyond the Pike differential in `dfa_test`.
    const pats = [_][]const u8{
        "\\bcat\\b", "\\bcat",      "cat\\b",     "\\b\\w+\\b",    "\\b\\d+\\b",
        "\\b",       "\\B",         "a\\Bb",      "\\Ba",          "\\ba\\b",
        "\\<cat",    "cat\\>",      "\\<\\w+\\>", "\\b[a-c]+\\b",  "\\b.\\b",
        "z\\Bz",     "\\b_\\b",     "\\B\\w+",    "\\w+\\B",       "^\\bfoo",
        "bar\\b$",   "\\b(a|z)\\b", "\\w\\b\\w",  "\\b\\w\\w?\\b",
    };
    for (pats) |p| {
        var re = compileDfa(p) catch |e| {
            if (e == error.PowersetCapHit) continue; // Pike serves this one; no DFA to diff
            return e;
        };
        defer re.deinit();
        try expect(re.dfa.?.word_ctx); // it really is the word-context path under test
        exhaustiveWordEquiv(p, &re, "az1_ ", 6) catch |e| {
            std.debug.print("WORD EXHAUSTIVE FAILURE on /{s}/: {}\n", .{ p, e });
            return e;
        };
    }
}

test "powerset: build is deterministic (byte-identical tables across two compiles)" {
    const pats = [_][]const u8{ "a.c", "foo|bar", "^abc$", "(a|b)*c", "[a-f0-9]{2,}", "\\w{3,8}" };
    for (pats) |p| {
        var x = try compileDfa(p);
        defer x.deinit();
        var y = try compileDfa(p);
        defer y.deinit();
        const dx = x.dfa.?;
        const dy = y.dfa.?;
        try expectEqual(dx.ncls, dy.ncls);
        try expectEqual(dx.nstates, dy.nstates);
        try expectEqual(dx.start, dy.start);
        try expectEqual(dx.dead, dy.dead);
        try expectEqual(dx.empty_match, dy.empty_match);
        try expectEqual(dx.anchored, dy.anchored);
        try expect(std.mem.eql(u8, &dx.class, &dy.class));
        try expect(std.mem.eql(u32, dx.trans_in, dy.trans_in));
        try expect(std.mem.eql(u32, dx.trans_fin, dy.trans_fin));
        try expectEqual(dx.match_hi, dy.match_hi);
    }
}

test "powerset: pathological alternation blows past max_states ⇒ eager declines (the ladder below still answers)" {
    // The classic `(a|b)*a(a|b)^n` "n-th byte from the end" DFA needs ~2^n
    // states; with n large the powerset exceeds `max_states` and the eager build
    // declines. Verify the bail fires AND the rungs beneath it — the on-demand
    // driver, and the Pike VM behind it — still answer correctly.
    const a = std.testing.allocator;
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(a);
    try pat.appendSlice(a, "(a|b)*a");
    for (0..14) |_| try pat.appendSlice(a, "(a|b)"); // 2^14 ≫ 4096

    var re = try Regex.compile(a, pat.items);
    defer re.deinit();
    try expect(re.dfa == null); // cap tripped — exactly the decline contract

    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();
    // 15th-from-last byte is 'a' ⇒ matches; all 'b' there ⇒ no match.
    try expect(re.lineMatch(&sim, "abbbbbbbbbbbbbb")); // 'a' then 14 bytes
    try expect(!re.lineMatch(&sim, "bbbbbbbbbbbbbbb")); // never an 'a' in position
}

// ─────────── compile-cost regression guard: allocations scale w/ states ───────

test "powerset: cap-busting compile allocates O(states), not O(transitions)" {
    // Determinizing it explodes past the eager bounds (~4k DFA states over 12
    // byte-classes) so `build` declines. The determinizer probes the subset map
    // ~states×ncls×2 (≈86k) times;
    // `intern` must reuse a scratch key for the probe and heap-allocate only on a
    // genuinely NEW state — one alloc per interned state, not one per probe. If a
    // future edit reintroduces alloc-per-probe, allocations jump ~20× (≈86k) and
    // compile time with it. This pins the O(states) bound with no flaky timer.
    // Counting rides std.testing.FailingAllocator (never failing via maxInt
    // fail_index): its `allocations` field tallies each successful `alloc`
    // exactly like the bespoke counter it replaced — and any alloc failure
    // under std.testing.allocator would fail the compile below anyway, so the
    // success-only count is the same number.
    const pat = "^[a-c]{3,5}[^a-c]+.{0,2}|\\S{0}\\S{2,}(\\D[a-c]{2}.{4,6}|0{4,6}\\w[ace1]*){1,3}|[^ -~]{0,2}[^a-c]+$";
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    const a = counter.allocator();

    var re = try Regex.compile(a, pat);
    defer re.deinit();
    try expect(re.dfa == null); // confirms the pathological cap-bail path is taken

    // Permanent allocations are bounded by the interned-state count (≤ max_states
    // + a handful of amortized ArrayList/HashMap growth reallocations); measured
    // at ~1.4k. 2×max_states leaves headroom while staying far under the
    // pre-fix ~86k, so the bound still fails loudly if alloc-per-probe returns.
    try expect(counter.allocations < 2 * powerset.max_states);
}

// ───────────────────────── randomized invariant fuzz ─────────────────────────

/// Random pattern generator over the supported subset, with optional `^`/`$`
/// (anchors are not quantifiable — `^*` is a parse error). Mirrors the
/// dfa_test generator so the adversarial space overlaps; here every compiled
/// DFA is run through the full intrinsic-invariant battery, NOT a matcher diff.
const Gen = struct {
    r: std.Random,
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    // When set, sprinkle word-boundary assertions (`\b \B \< \>`) between atoms
    // and at the edges — the word-context determinizer's fuzz coverage. Default
    // false ⇒ the anchor-only generator is byte-identical to before.
    words: bool = false,
    const E = std.mem.Allocator.Error;

    fn lit(g: *Gen) E!void {
        try g.buf.append(g.a, "abc"[g.r.uintLessThan(usize, 3)]);
    }
    fn wb(g: *Gen) E!void {
        try g.buf.appendSlice(g.a, ([_][]const u8{ "\\b", "\\B", "\\<", "\\>" })[g.r.uintLessThan(usize, 4)]);
    }
    fn atom(g: *Gen, depth: u8) E!void {
        switch (g.r.uintLessThan(u8, if (depth > 0) 7 else 6)) {
            0 => try g.lit(),
            1 => try g.buf.append(g.a, '.'),
            2 => try g.buf.appendSlice(g.a, "[a-c]"),
            3 => try g.buf.appendSlice(g.a, "[^a-c]"),
            4 => try g.buf.appendSlice(g.a, "\\d"),
            5 => try g.buf.appendSlice(g.a, "\\w"),
            else => {
                try g.buf.append(g.a, '(');
                try g.alt(depth - 1);
                try g.buf.append(g.a, ')');
            },
        }
    }
    fn quant(g: *Gen, depth: u8) E!void {
        try g.atom(depth);
        switch (g.r.uintLessThan(u8, 7)) {
            0 => try g.buf.append(g.a, '*'),
            1 => try g.buf.append(g.a, '+'),
            2 => try g.buf.append(g.a, '?'),
            3 => try g.buf.appendSlice(g.a, "{2}"),
            4 => try g.buf.appendSlice(g.a, "{1,3}"),
            5 => try g.buf.appendSlice(g.a, "{0,2}"),
            else => {},
        }
    }
    fn concat(g: *Gen, depth: u8) E!void {
        const n = 1 + g.r.uintLessThan(usize, 3);
        for (0..n) |_| {
            if (g.words and g.r.uintLessThan(u8, 3) == 0) try g.wb();
            try g.quant(depth);
        }
        if (g.words and g.r.boolean()) try g.wb();
    }
    fn alt(g: *Gen, depth: u8) E!void {
        try g.concat(depth);
        const n = g.r.uintLessThan(usize, 3);
        for (0..n) |_| {
            try g.buf.append(g.a, '|');
            try g.concat(depth);
        }
    }
    fn pattern(g: *Gen) E!void {
        if (g.r.boolean()) try g.buf.append(g.a, '^');
        try g.alt(2);
        if (g.r.boolean()) try g.buf.append(g.a, '$');
    }
};

test "powerset: structural invariants + bounded-exhaustive language equivalence on random programs" {
    const a = std.testing.allocator;
    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 2000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9E3779B97F4A7C15);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a };
        try g.pattern();

        // `force_dfa`: keep class-run-shaped random patterns in determinizer
        // coverage (production compile skips their dead-weight DFA).
        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue; // skip rare BadPattern
        defer re.deinit();
        if (re.dfa == null) continue; // powerset cap ⇒ Pike serves; nothing to check
        assertInvariants(&re) catch |e| {
            std.debug.print("FUZZ INVARIANT FAILURE pat=/{s}/ seed={}: {}\n", .{ pat.items, seed, e });
            return e;
        };
        // Every string ≤4 over {a,z,1,\n}: proves this random DFA's language on a
        // bounded space against the NFA spec (catches a wrong transition function).
        // Skip the rare giant NFA — the spec is O(states)/byte; invariants still ran.
        if (re.states.len <= 128) exhaustiveEquiv(pat.items, &re, "az1\n", 4) catch |e| {
            std.debug.print("FUZZ LANG FAILURE pat=/{s}/ seed={}: {}\n", .{ pat.items, seed, e });
            return e;
        };
        checked += 1;
    }
    try expect(checked > 1500); // the fuzz actually exercised the determinizer
}

test "powerset: word-context invariants + exhaustive equivalence vs the NFA spec on random programs" {
    // The word-context twin of the fuzz above — random `\b`/`\B`/`\<`/`\>`
    // programs, each run through the full structural-invariant battery AND (when
    // small enough) exhaustively diffed against the word-resolving `Spec` over
    // every string ≤ 4. A second independent oracle beyond `dfa_test`'s Pike
    // differential. `(?-u)`: ASCII word-ness, so `matchWord` never quits.
    const a = std.testing.allocator;
    var seed: u64 = 0;
    var checked: usize = 0;
    while (seed < 1500) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x2545F4914F6CDD1D);
        const r = prng.random();

        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(a);
        var g = Gen{ .r = r, .buf = &pat, .a = a, .words = true };
        try g.pattern();

        var re = Regex.compileOpts(a, pat.items, .{ .force_dfa = true }) catch continue; // ASCII word test
        defer re.deinit();
        if (re.dfa == null) continue; // powerset cap ⇒ Pike serves
        if (!re.dfa.?.word_ctx) continue; // only the word-context axis here
        assertInvariants(&re) catch |e| {
            std.debug.print("WORD FUZZ INVARIANT FAILURE pat=/{s}/ seed={}: {}\n", .{ pat.items, seed, e });
            return e;
        };
        if (re.states.len <= 128) exhaustiveWordEquiv(pat.items, &re, "az1_ ", 4) catch |e| {
            std.debug.print("WORD FUZZ LANG FAILURE pat=/{s}/ seed={}: {}\n", .{ pat.items, seed, e });
            return e;
        };
        checked += 1;
    }
    try expect(checked > 800); // the word-context determinizer was actually exercised
}
