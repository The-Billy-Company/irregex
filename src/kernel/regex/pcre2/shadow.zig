// MONOLITHIC: PCRE2 shadow — the sound linear-time over-approximation matcher; literal/class extraction and the confirm-only automaton share one no-false-negative construction
//! irregex — the PCRE2 shadow: a sound linear-time over-approximation of a PCRE
//! pattern, so the backtracking engine only ever CONFIRMS candidates.
//!
//! PCRE2's power (backreferences, lookaround, atomic groups) costs worst-case
//! exponential backtracking — `(\w{4,})\s+\1` spends ~11 s on one 3.6 MB file
//! of 120 KB base64 lines, because every start position re-walks a giant `\w`
//! run. rg pays exactly the same. The mathematical exit is a *shadow*: rewrite
//! the pattern into this package's linear syntax such that the shadow's
//! language is a SUPERSET of the PCRE language. Then a line/buffer the shadow
//! rejects provably cannot match the PCRE pattern, and the O(1)/byte byte-class
//! DFA answers it — PCRE2 never touches those bytes. The same containment makes
//! the shadow's NFA-derived required-literal/cover sound for the PCRE pattern,
//! which hands `-P` queries the trigram index prefilter they never had.
//!
//! The rewrite rules, each one provably language-growing (or -preserving):
//!   • every zero-width assertion is ERASED (`^ $ \b \B \A \z \Z \G`, all four
//!     lookarounds, comments) — dropping a constraint only grows the language;
//!     a quantifier bound to an erased zero-width atom is erased with it
//!   • a backreference is SPLICED with a rewritten copy of its group's source —
//!     the backref echoes one string the group matched; the copy accepts all of
//!     them (a group that can capture "" rewrites to a nullable copy, since
//!     capturing "" requires a nullable body once ITS assertions are erased)
//!   • atomic groups `(?>…)` → `(?:…)`; possessive quantifiers → greedy —
//!     removing commitment only adds matches
//! Anything whose containment is not trivially provable (recursion, subroutine
//! calls, conditionals, inline flags, `\v`-class escapes whose semantics differ
//! between the engines) BAILS: no shadow, PCRE2 runs raw exactly as before.
//! Under-approximating the *rewriter* costs only speed; over-approximating the
//! *language* is the one invariant — the differential fuzz in `backend_test.zig`
//! holds gated ≡ ungated across both engines' surfaces.

const std = @import("std");
const fault = @import("../../../fault.zig");
const literal_mod = @import("literal.zig");

/// Rewriter failure modes, PRIVATE to the recursive descent below: `Bail` =
/// construct outside the provable subset; OOM propagates. `Bail` never leaves
/// this module — `overapprox` converts it into the declinature at the seam,
/// which is what keeps `try` from ever mistaking a bail for a failure.
const Err = error{ Bail, OutOfMemory };

/// The rewriter's only declinature (fault-channel law 1): no containment proof, so
/// PCRE2 answers the pattern unrewritten. Both bail paths return this one value.
const no_shadow: fault.Answer([]u8) = .{ .declined = .unsupported_syntax };

/// Hard ceilings — beyond any of them the shadow bails rather than growing
/// pathological itself (a spliced backref chain can expand geometrically).
const max_groups = 32;
const max_splice_depth = 4;
const max_out_bytes = 8 * 1024;

/// One capture group's source span (body between its parens) + open position
/// (for relative `\g{-n}` resolution).
const Group = struct { open: usize, start: usize, end: usize };
const Named = struct { name: []const u8, idx: u32 };

/// The longest provable linear over-approximation of `pattern`, or a
/// declinature when any construct denies the containment proof. Caller owns the
/// returned slice. The result is assertion-free by construction, so it always
/// admits the byte-class DFA — including under `-U` multiline.
///
/// This is the shadow-rewriter→none seam. Only OOM is a fault: a bail is a
/// routing fact, and it sits in the success position so the caller has to say
/// what it does with it rather than reaching for `try`.
pub fn overapprox(a: std.mem.Allocator, pattern: []const u8) std.mem.Allocator.Error!fault.Answer([]u8) {
    var groups_buf: [max_groups]Group = undefined;
    var names_buf: [max_groups]Named = undefined;
    const tbl = collectGroups(pattern, &groups_buf, &names_buf) orelse return no_shadow;

    var ctx = Ctx{ .a = a, .src = pattern, .groups = tbl.groups, .names = tbl.names };
    defer ctx.out.deinit(a);
    rewrite(&ctx, pattern, 0) catch |e| switch (e) {
        error.Bail => return no_shadow,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .got = try ctx.out.toOwnedSlice(a) };
}

const Table = struct { groups: []const Group, names: []const Named };

/// Pass 1 — structural scan: record every capture group's body span (and name),
/// in opening-paren order. Null on anything that denies a clean paren tree
/// (which pass 2 would bail on anyway).
fn collectGroups(p: []const u8, groups: *[max_groups]Group, names: *[max_groups]Named) ?Table {
    var ngroups: usize = 0;
    var nnames: usize = 0;
    // Stack of open groups: index into `groups` for capturing, null slot marker
    // (max_groups) for non-capturing.
    var stack: [max_groups]usize = undefined;
    var depth: usize = 0;

    var i: usize = 0;
    while (i < p.len) {
        switch (p[i]) {
            '\\' => i = @min(i + 2, p.len),
            '[' => i = skipClass(p, i),
            '(' => {
                if (depth >= max_groups) return null;
                var capturing = true;
                var name: ?[]const u8 = null;
                var body = i + 1;
                if (i + 1 < p.len and p[i + 1] == '?') {
                    if (i + 2 >= p.len) return null;
                    switch (p[i + 2]) {
                        ':', '>', '=', '!' => {
                            capturing = false;
                            body = i + 3;
                        },
                        '#' => { // comment: ends at the first ')' (backslash inert)
                            i = (std.mem.indexOfScalarPos(u8, p, i + 3, ')') orelse return null) + 1;
                            continue;
                        },
                        '<' => {
                            if (i + 3 < p.len and (p[i + 3] == '=' or p[i + 3] == '!')) {
                                capturing = false;
                                body = i + 4;
                            } else { // (?<name>…)
                                const gt = std.mem.indexOfScalarPos(u8, p, i + 3, '>') orelse return null;
                                name = p[i + 3 .. gt];
                                body = gt + 1;
                            }
                        },
                        'P' => {
                            if (i + 3 < p.len and p[i + 3] == '<') { // (?P<name>…)
                                const gt = std.mem.indexOfScalarPos(u8, p, i + 4, '>') orelse return null;
                                name = p[i + 4 .. gt];
                                body = gt + 1;
                            } else if (i + 3 < p.len and p[i + 3] == '=') { // (?P=name) — a backref token, not a group
                                i = (std.mem.indexOfScalarPos(u8, p, i + 4, ')') orelse return null) + 1;
                                continue;
                            } else return null; // (?P>name) subroutine — bail
                        },
                        '\'' => { // (?'name'…)
                            const q = std.mem.indexOfScalarPos(u8, p, i + 3, '\'') orelse return null;
                            name = p[i + 3 .. q];
                            body = q + 1;
                        },
                        else => return null, // flags / conditionals / recursion — pass 2 bails too
                    }
                }
                if (capturing) {
                    if (ngroups >= max_groups) return null;
                    groups[ngroups] = .{ .open = i, .start = body, .end = body };
                    if (name) |nm| {
                        names[nnames] = .{ .name = nm, .idx = @intCast(ngroups + 1) };
                        nnames += 1;
                    }
                    stack[depth] = ngroups;
                    ngroups += 1;
                } else stack[depth] = max_groups;
                depth += 1;
                i = body;
            },
            ')' => {
                if (depth == 0) return null;
                depth -= 1;
                if (stack[depth] != max_groups) groups[stack[depth]].end = i;
                i += 1;
            },
            else => i += 1,
        }
    }
    if (depth != 0) return null;
    return .{ .groups = groups[0..ngroups], .names = names[0..nnames] };
}

// The `[...]` / `(...)` skippers are the required-literal extractor's — one
// definition of the PCRE syntax walk, shared (`literal.zig`).
const skipClass = literal_mod.skipClass;
const skipGroup = literal_mod.skipGroup;

/// Index just past any quantifier at `p[i..]` (`* + ?` or a valid `{n,m}`
/// count, each with an optional lazy `?` / possessive `+` suffix); `i` itself
/// when none. Used to erase a quantifier bound to an erased zero-width atom.
fn pastQuant(p: []const u8, i: usize) usize {
    if (i >= p.len) return i;
    switch (p[i]) {
        '*', '+', '?' => return pastSuffix(p, i + 1),
        '{' => {
            var j = i + 1;
            while (j < p.len and std.ascii.isDigit(p[j])) j += 1;
            const had_lo = j > i + 1;
            if (j < p.len and p[j] == ',') {
                j += 1;
                while (j < p.len and std.ascii.isDigit(p[j])) j += 1;
            } else if (!had_lo) return i;
            if (j < p.len and p[j] == '}' and (had_lo or p[i + 1] == ',')) return pastSuffix(p, j + 1);
            return i;
        },
        else => return i,
    }
}

fn pastSuffix(p: []const u8, i: usize) usize {
    return if (i < p.len and (p[i] == '?' or p[i] == '+')) i + 1 else i;
}

/// Rewriter state: the output builder plus the splice stack that detects
/// self-/mutually-referential backrefs (whose expansion would not terminate).
const Ctx = struct {
    a: std.mem.Allocator,
    src: []const u8,
    groups: []const Group,
    names: []const Named,
    out: std.ArrayListUnmanaged(u8) = .empty,
    active: [max_splice_depth]u32 = undefined,
    nactive: usize = 0,

    fn push(self: *Ctx, bytes: []const u8) Err!void {
        if (self.out.items.len + bytes.len > max_out_bytes) return error.Bail;
        try self.out.appendSlice(self.a, bytes);
    }
};

/// Escaped-atom dispatch classes for `\<e>` in atom position.
fn escClass(e: u8) enum { copy, erase, literal_lt_gt, bail } {
    return switch (e) {
        // Fixed-byte / class escapes with identical semantics in both engines.
        't', 'n', 'r', 'f', 'a', 'd', 'D', 'w', 'W', 's', 'S' => .copy,
        // Zero-width assertions: erasure grows the language.
        'b', 'B', 'A', 'z', 'Z', 'G' => .erase,
        // Literal `<`/`>` in PCRE2 — but word-boundary ASSERTIONS in this
        // package's linear syntax, so they must be emitted unescaped.
        '<', '>' => .literal_lt_gt,
        else => if (std.ascii.isAlphanumeric(e)) .bail else .copy, // punctuation → literal byte
    };
}

/// Pass 2 — emit the over-approximation of segment `seg` (at offset `base` in
/// the full pattern, for relative-backref resolution) into `ctx.out`.
fn rewrite(ctx: *Ctx, seg: []const u8, base: usize) Err!void {
    var i: usize = 0;
    while (i < seg.len) {
        const c = seg[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= seg.len) return error.Bail;
                const e = seg[i + 1];
                if (std.ascii.isDigit(e)) {
                    if (e == '0') return error.Bail; // octal — not modeled
                    var j = i + 1;
                    while (j < seg.len and std.ascii.isDigit(seg[j])) j += 1;
                    const n = std.fmt.parseInt(u32, seg[i + 1 .. j], 10) catch return error.Bail;
                    try spliceBackref(ctx, n);
                    i = j;
                    continue;
                }
                switch (e) {
                    'g' => { // \g1 \g{1} \g{-1} \g{name} — backrefs; \g<n>/\g'n' subroutines bail
                        i = try spliceGRef(ctx, seg, base, i + 2);
                        continue;
                    },
                    'k' => { // \k<name> \k'name' \k{name}
                        i = try spliceKRef(ctx, seg, i + 2);
                        continue;
                    },
                    'x' => { // \xHH / \x{…} — identical in both engines; bare \x bails
                        const end = pastHex(seg, i + 2) orelse return error.Bail;
                        try ctx.push(seg[i..end]);
                        i = end;
                        continue;
                    },
                    'p', 'P' => { // \p{…} / \pL — same Unicode property surface
                        const end = pastProp(seg, i + 2) orelse return error.Bail;
                        try ctx.push(seg[i..end]);
                        i = end;
                        continue;
                    },
                    else => {},
                }
                switch (escClass(e)) {
                    .copy => try ctx.push(seg[i .. i + 2]),
                    .erase => {
                        i = pastQuant(seg, i + 2);
                        continue;
                    },
                    .literal_lt_gt => try ctx.push(seg[i + 1 .. i + 2]),
                    .bail => return error.Bail, // \v \h \R \Q \c … — semantics differ or unmodeled
                }
                i += 2;
            },
            '[' => {
                const end = skipClass(seg, i);
                try copyClass(ctx, seg[i..end]);
                i = end;
            },
            '(' => {
                const end = skipGroup(seg, i);
                if (end > seg.len or seg[end - 1] != ')') return error.Bail;
                i = try rewriteGroup(ctx, seg, base, i, end);
            },
            '^', '$' => i = pastQuant(seg, i + 1), // erased assertion (+ bound quantifier)
            '*', '+', '?' => {
                try ctx.push(seg[i .. i + 1]);
                i += 1;
                // Lazy `?` copies (inert for a boolean gate); possessive `+` is
                // stripped — greedy is a superset of possessive.
                if (i < seg.len and seg[i] == '?') {
                    try ctx.push("?");
                    i += 1;
                } else if (i < seg.len and seg[i] == '+') i += 1;
            },
            '}' => {
                try ctx.push("}");
                i += 1;
                if (i < seg.len and seg[i] == '?') {
                    try ctx.push("?");
                    i += 1;
                } else if (i < seg.len and seg[i] == '+') i += 1;
            },
            else => {
                try ctx.push(seg[i .. i + 1]);
                i += 1;
            },
        }
    }
}

/// Rewrite one group `seg[open..end]` (parens included). Returns the index to
/// resume at (past the group — or past its quantifier too when erased).
fn rewriteGroup(ctx: *Ctx, seg: []const u8, base: usize, open: usize, end: usize) Err!usize {
    const inner_default = open + 1;
    if (inner_default < end - 1 and seg[open + 1] == '?') {
        if (open + 2 >= end) return error.Bail;
        switch (seg[open + 2]) {
            ':', '>' => { // non-capturing / atomic (atomicity removed = superset)
                try ctx.push("(?:");
                try rewrite(ctx, seg[open + 3 .. end - 1], base + open + 3);
                try ctx.push(")");
                return end;
            },
            '=', '!' => return pastQuant(seg, end), // lookahead — erased with its quantifier
            '#' => { // comment: zero-width but a following quantifier binds the PREVIOUS atom — keep it
                const close = std.mem.indexOfScalarPos(u8, seg, open + 3, ')') orelse return error.Bail;
                return close + 1;
            },
            '<' => {
                if (open + 3 < end and (seg[open + 3] == '=' or seg[open + 3] == '!'))
                    return pastQuant(seg, end); // lookbehind — erased
                const gt = std.mem.indexOfScalarPos(u8, seg, open + 3, '>') orelse return error.Bail;
                try ctx.push("(");
                try rewrite(ctx, seg[gt + 1 .. end - 1], base + gt + 1);
                try ctx.push(")");
                return end;
            },
            'P' => {
                if (open + 3 < end and seg[open + 3] == '<') { // (?P<name>…) — named def
                    const gt = std.mem.indexOfScalarPos(u8, seg, open + 4, '>') orelse return error.Bail;
                    try ctx.push("(");
                    try rewrite(ctx, seg[gt + 1 .. end - 1], base + gt + 1);
                    try ctx.push(")");
                    return end;
                }
                if (open + 3 < end and seg[open + 3] == '=') { // (?P=name) backref
                    try spliceByName(ctx, seg[open + 4 .. end - 1]);
                    return end;
                }
                return error.Bail; // (?P>name) subroutine
            },
            '\'' => { // (?'name'…) — named def
                const q = std.mem.indexOfScalarPos(u8, seg, open + 3, '\'') orelse return error.Bail;
                try ctx.push("(");
                try rewrite(ctx, seg[q + 1 .. end - 1], base + q + 1);
                try ctx.push(")");
                return end;
            },
            else => return error.Bail, // flags / conditionals / recursion / callouts
        }
    }
    // Plain capturing group.
    try ctx.push("(");
    try rewrite(ctx, seg[inner_default .. end - 1], base + inner_default);
    try ctx.push(")");
    return end;
}

/// Splice `(?:<rewritten group-n source>)` for a backreference to group `n`.
/// The copy's language contains every string the group can capture (its own
/// assertions erase to nullability wherever a zero-width capture is possible),
/// so replacing the echo with the copy is language-growing. Self-/enclosing
/// references (whose expansion recurses forever) bail.
fn spliceBackref(ctx: *Ctx, n: u32) Err!void {
    if (n == 0 or n > ctx.groups.len) return error.Bail;
    if (ctx.nactive >= max_splice_depth) return error.Bail;
    for (ctx.active[0..ctx.nactive]) |g| if (g == n) return error.Bail;
    const g = ctx.groups[n - 1];
    ctx.active[ctx.nactive] = n;
    ctx.nactive += 1;
    defer ctx.nactive -= 1;
    try ctx.push("(?:");
    try rewrite(ctx, ctx.src[g.start..g.end], g.start);
    try ctx.push(")");
}

/// `\g…` backref forms. Returns the resume index (past the reference).
fn spliceGRef(ctx: *Ctx, seg: []const u8, base: usize, at: usize) Err!usize {
    if (at >= seg.len) return error.Bail;
    if (seg[at] == '{') {
        const close = std.mem.indexOfScalarPos(u8, seg, at + 1, '}') orelse return error.Bail;
        const body = seg[at + 1 .. close];
        if (body.len == 0) return error.Bail;
        if (body[0] == '-') { // relative: -n ⇒ the n-th most recently opened group before here
            const back = std.fmt.parseInt(u32, body[1..], 10) catch return error.Bail;
            const idx = relativeIndex(ctx, base + at, back) orelse return error.Bail;
            try spliceBackref(ctx, idx);
        } else if (std.ascii.isDigit(body[0])) {
            try spliceBackref(ctx, std.fmt.parseInt(u32, body, 10) catch return error.Bail);
        } else try spliceByName(ctx, body);
        return close + 1;
    }
    if (std.ascii.isDigit(seg[at])) {
        var j = at;
        while (j < seg.len and std.ascii.isDigit(seg[j])) j += 1;
        try spliceBackref(ctx, std.fmt.parseInt(u32, seg[at..j], 10) catch return error.Bail);
        return j;
    }
    return error.Bail; // \g<n> / \g'n' are subroutine calls, not backrefs
}

/// `\k<name>` / `\k'name'` / `\k{name}` named backrefs.
fn spliceKRef(ctx: *Ctx, seg: []const u8, at: usize) Err!usize {
    if (at >= seg.len) return error.Bail;
    const term: u8 = switch (seg[at]) {
        '<' => '>',
        '\'' => '\'',
        '{' => '}',
        else => return error.Bail,
    };
    const close = std.mem.indexOfScalarPos(u8, seg, at + 1, term) orelse return error.Bail;
    try spliceByName(ctx, seg[at + 1 .. close]);
    return close + 1;
}

fn spliceByName(ctx: *Ctx, name: []const u8) Err!void {
    for (ctx.names) |nm| if (std.mem.eql(u8, nm.name, name)) return spliceBackref(ctx, nm.idx);
    return error.Bail;
}

/// Resolve `\g{-back}` at absolute pattern offset `abs`: the `back`-th most
/// recently OPENED capture group before that point.
fn relativeIndex(ctx: *const Ctx, abs: usize, back: u32) ?u32 {
    if (back == 0) return null;
    var opened: u32 = 0;
    for (ctx.groups) |g| {
        if (g.open < abs) opened += 1 else break;
    }
    if (back > opened) return null;
    return opened - back + 1;
}

/// Index past `\xHH` / `\x{H…}` hex bodies (at = index after the `x`).
fn pastHex(p: []const u8, at: usize) ?usize {
    if (at < p.len and p[at] == '{') {
        const close = std.mem.indexOfScalarPos(u8, p, at + 1, '}') orelse return null;
        if (close == at + 1) return null;
        for (p[at + 1 .. close]) |b| if (!std.ascii.isHex(b)) return null;
        return close + 1;
    }
    if (at + 1 < p.len and std.ascii.isHex(p[at]) and std.ascii.isHex(p[at + 1])) return at + 2;
    return null;
}

/// Index past `\p{…}` / `\pL` property bodies (at = index after the `p`/`P`).
fn pastProp(p: []const u8, at: usize) ?usize {
    if (at < p.len and p[at] == '{') {
        const close = std.mem.indexOfScalarPos(u8, p, at + 1, '}') orelse return null;
        return if (close > at + 1) close + 1 else null;
    }
    return if (at < p.len and std.ascii.isAlphabetic(p[at])) at + 1 else null;
}

/// Copy a `[...]` class verbatim — after proving every escape inside has
/// identical semantics in both engines (`\b` = backspace, `\v`/`\h` = space
/// CLASSES in PCRE2 but rejected/other in the linear syntax → bail).
fn copyClass(ctx: *Ctx, class: []const u8) Err!void {
    if (class.len < 2 or class[class.len - 1] != ']') return error.Bail;
    var i: usize = 1;
    while (i + 1 < class.len) : (i += 1) {
        if (class[i] != '\\') continue;
        i += 1;
        const e = class[i];
        switch (e) {
            't', 'n', 'r', 'f', 'a', 'd', 'D', 'w', 'W', 's', 'S' => {},
            'x' => _ = pastHex(class, i + 1) orelse return error.Bail,
            'p', 'P' => _ = pastProp(class, i + 1) orelse return error.Bail,
            else => if (std.ascii.isAlphanumeric(e)) return error.Bail,
        }
    }
    try ctx.push(class);
}

// ─────────────────────────── tests ───────────────────────────

const t = std.testing;

/// `want == null` asserts the rewriter DECLINED — the prong `try` cannot reach.
fn expectShadow(pattern: []const u8, want: ?[]const u8) !void {
    switch (try overapprox(t.allocator, pattern)) {
        .got => |g| {
            defer t.allocator.free(g);
            try t.expectEqualStrings(want orelse return error.TestUnexpectedResult, g);
        },
        .declined => |d| {
            try t.expect(want == null);
            try t.expectEqual(fault.Decline.unsupported_syntax, d);
        },
    }
}

test "backref splices a copy of its group source" {
    try expectShadow("(\\w{4,})\\s+\\1", "(\\w{4,})\\s+(?:\\w{4,})");
    try expectShadow("(foo)bar\\1", "(foo)bar(?:foo)");
    try expectShadow("(a|bb)x\\1y", "(a|bb)x(?:a|bb)y");
}

test "named backrefs resolve through every PCRE2 spelling" {
    try expectShadow("(?P<w>\\d+)-(?P=w)", "(\\d+)-(?:\\d+)");
    try expectShadow("(?<w>ab)\\k<w>", "(ab)(?:ab)");
    try expectShadow("(?'w'ab)\\k'w'", "(ab)(?:ab)");
    try expectShadow("(ab)\\g{1}", "(ab)(?:ab)");
    try expectShadow("(ab)(cd)\\g{-1}", "(ab)(cd)(?:cd)");
}

test "assertions and lookarounds erase; bound quantifiers erase with them" {
    try expectShadow("^foo$", "foo");
    try expectShadow("\\bword\\b", "word");
    try expectShadow("(?=export)\\w+", "\\w+");
    try expectShadow("(?<!\\.)\\d{3}", "\\d{3}");
    try expectShadow("a\\b+b", "ab"); // quantified assertion is still zero-width
    try expectShadow("\\Afoo\\z", "foo");
}

test "atomic groups and possessive quantifiers relax to greedy" {
    try expectShadow("(?>ab|a)c", "(?:ab|a)c");
    try expectShadow("a++b", "a+b");
    try expectShadow("\\w{2,5}+x", "\\w{2,5}x");
    try expectShadow("a*?b", "a*?b"); // lazy copies through
}

test "comments erase but keep a following quantifier bound to the prior atom" {
    try expectShadow("a(?#note)+b", "a+b");
}

test "escaped angle brackets become bare literals (gist parses \\< as an assertion)" {
    try expectShadow("a\\<b\\>c", "a<b>c");
}

test "unprovable constructs bail to no shadow" {
    try expectShadow("(a)(?1)", null); // subroutine call
    try expectShadow("(?R)", null); // recursion
    try expectShadow("(?(1)a|b)", null); // conditional
    try expectShadow("(?i)abc", null); // inline flags
    try expectShadow("a\\v", null); // \v: space class in PCRE2, VT byte here
    try expectShadow("[\\b]a", null); // in-class \b = backspace
    try expectShadow("\\Qa.b\\E", null); // quoting
    try expectShadow("(a\\1)", null); // self-reference
    try expectShadow("\\0", null); // octal
    try expectShadow("\\99", null); // backref beyond group count
}

test "plain patterns pass through unchanged" {
    try expectShadow("foo(bar|baz)*[a-z]{3}", "foo(bar|baz)*[a-z]{3}");
    try expectShadow("\\p{L}+\\x{2028}", "\\p{L}+\\x{2028}");
}
