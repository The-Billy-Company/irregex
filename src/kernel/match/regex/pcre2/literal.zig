//! gist — sound required-literal extraction for the PCRE2 trigram prefilter.
//!
//! The trigram index prunes a query's read set to files whose bytes could
//! contain the pattern's *required literal* — the longest contiguous run of
//! bytes present in EVERY match. For the linear engine this falls out of the
//! NFA (`analysis.zig`); PCRE2 gives us no such structure, so we derive it from
//! the pattern text with one guarantee that dominates every other concern:
//! **never over-claim.** A required literal the index trusts must be provably
//! present in every possible match — if it isn't, the index silently elides a
//! file the `-P` query would have matched, a correctness failure with no error.
//! So this extractor is deliberately conservative: any construct whose
//! contribution to "present in every match" is not trivially provable
//! (alternation at top level, groups, character classes, class escapes,
//! case-folding, non-ASCII) flushes the current run or bails to empty.
//! Under-claiming only costs prefilter selectivity; over-claiming is a bug.
//!
//! Returns "" when nothing ≥3 bytes (the trigram floor) is provably required.

const std = @import("std");

/// A quantifier's effect on the atom it follows.
const Quant = struct {
    kind: enum { none, optional, mandatory },
    /// Index just past the quantifier (== the probe index when `none`).
    next: usize,
};

/// Classify a possible quantifier at `p[at..]`. `*`/`?`/`{0,..}` make the
/// preceding atom optional; `+`/`{n>=1,..}` keep ≥1 copy (mandatory). A `{…}`
/// that is not valid quantifier syntax is a literal brace → `none`. A trailing
/// lazy/possessive `?`/`+` is folded into `next`.
fn classifyQuant(p: []const u8, at: usize) Quant {
    if (at >= p.len) return .{ .kind = .none, .next = at };
    switch (p[at]) {
        '*', '?' => return .{ .kind = .optional, .next = foldSuffix(p, at + 1) },
        '+' => return .{ .kind = .mandatory, .next = foldSuffix(p, at + 1) },
        '{' => return classifyBrace(p, at),
        else => return .{ .kind = .none, .next = at },
    }
}

/// Skip a trailing `?` (lazy) or `+` (possessive) after a `*`/`+`/`?`/`{}`.
fn foldSuffix(p: []const u8, at: usize) usize {
    return if (at < p.len and (p[at] == '?' or p[at] == '+')) at + 1 else at;
}

/// Parse a `{n}` / `{n,}` / `{n,m}` / `{,m}` interval at `p[at]=='{'`. Optional
/// iff the lower bound is absent or zero; mandatory otherwise. Not a valid
/// interval ⇒ `none` (the `{` is a literal brace, left for the caller to drop).
fn classifyBrace(p: []const u8, at: usize) Quant {
    var i = at + 1;
    const lo_start = i;
    while (i < p.len and std.ascii.isDigit(p[i])) i += 1;
    const lo_digits = p[lo_start..i];
    if (i < p.len and p[i] == ',') {
        i += 1;
        while (i < p.len and std.ascii.isDigit(p[i])) i += 1;
    }
    if (i >= p.len or p[i] != '}' or (lo_digits.len == 0 and p[at + 1] != ',')) {
        // `{abc}` or unterminated — a literal brace, not a quantifier.
        return .{ .kind = .none, .next = at };
    }
    const lo: usize = std.fmt.parseInt(usize, lo_digits, 10) catch 0;
    const kind: @FieldType(Quant, "kind") = if (lo == 0) .optional else .mandatory;
    return .{ .kind = kind, .next = foldSuffix(p, i + 1) };
}

/// Index just past a `[...]` class beginning at `p[i]=='['` (handles a leading
/// `^`, a first-position literal `]`, and `\]` escapes). Class contents never
/// contribute to the required literal — a class matches one of several bytes.
fn skipClass(p: []const u8, i: usize) usize {
    var j = i + 1;
    if (j < p.len and p[j] == '^') j += 1;
    if (j < p.len and p[j] == ']') j += 1;
    while (j < p.len) : (j += 1) {
        if (p[j] == '\\') {
            j += 1;
            continue;
        }
        if (p[j] == ']') return j + 1;
    }
    return p.len;
}

/// Index just past a balanced group beginning at `p[i]=='('` (nesting-, class-,
/// and escape-aware). A group is treated as opaque: it may be optional,
/// alternated, or a zero-width assertion, so it contributes no required bytes.
fn skipGroup(p: []const u8, i: usize) usize {
    var depth: usize = 0;
    var j = i;
    while (j < p.len) : (j += 1) {
        switch (p[j]) {
            '\\' => j += 1,
            '[' => j = skipClass(p, j) - 1,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return j + 1;
            },
            else => {},
        }
    }
    return p.len;
}

/// The escaped-atom literal byte for `\<e>`, or null if `\<e>` is a class
/// shorthand / boundary / backreference (`\d`, `\w`, `\b`, `\1`, `\x..`, …)
/// that is not a single fixed byte we can safely require.
fn escapedLiteral(e: u8) ?u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        // An escaped ASCII punctuation/metacharacter denotes that literal byte.
        '\\', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '/', '-', '"', '\'', '`', '#', '@', '%', '&', '=', '~', ':', ';', ',', '<', '>', '!', ' ' => e,
        else => null,
    };
}

/// Accumulates literal runs, tracking the longest proven-mandatory one.
const Runner = struct {
    a: std.mem.Allocator,
    cur: std.ArrayListUnmanaged(u8) = .empty,
    best: []u8 = &.{},

    fn push(self: *Runner, b: u8) std.mem.Allocator.Error!void {
        try self.cur.append(self.a, b);
    }
    /// End the current run, promoting it if it is the longest seen so far.
    fn flush(self: *Runner) std.mem.Allocator.Error!void {
        if (self.cur.items.len > self.best.len) {
            const owned = try self.a.dupe(u8, self.cur.items);
            self.a.free(self.best);
            self.best = owned;
        }
        self.cur.clearRetainingCapacity();
    }
    fn deinit(self: *Runner) void {
        self.cur.deinit(self.a);
    }
};

/// The longest ASCII literal PCRE2 provably requires in every match of
/// `pattern`, or "" when none ≥3 bytes can be proven. `caseless` short-circuits
/// to "" — a case-folded literal is not a fixed byte sequence the byte-oriented
/// index can key on. Caller owns the returned slice.
pub fn required(a: std.mem.Allocator, pattern: []const u8, caseless: bool) std.mem.Allocator.Error![]u8 {
    if (caseless) return a.alloc(u8, 0);
    var r = Runner{ .a = a };
    defer r.deinit();
    errdefer a.free(r.best);

    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            // Top-level alternation ⇒ different branches, nothing common proven.
            '|' => {
                a.free(r.best);
                return a.alloc(u8, 0);
            },
            '(' => {
                try r.flush();
                i = foldQuantAfter(pattern, skipGroup(pattern, i));
            },
            '[' => {
                try r.flush();
                i = foldQuantAfter(pattern, skipClass(pattern, i));
            },
            // Any-char / anchors: zero or non-literal; end the run, drop a quant.
            '.', '^', '$' => {
                try r.flush();
                i = foldQuantAfter(pattern, i + 1);
            },
            // A stray quantifier / brace with no literal atom before it.
            '*', '+', '?', '{', '}' => {
                try r.flush();
                i += 1;
            },
            '\\' => {
                if (i + 1 >= pattern.len) {
                    try r.flush();
                    break;
                }
                if (escapedLiteral(pattern[i + 1])) |b| {
                    i = try emitLiteral(&r, b, pattern, i + 2);
                } else {
                    try r.flush(); // \d \w \b \1 … — not a fixed byte
                    i += 2;
                }
            },
            else => i = try emitLiteral(&r, c, pattern, i + 1),
        }
    }
    try r.flush();

    if (r.best.len >= 3) {
        const out = r.best;
        r.best = &.{};
        return out;
    }
    a.free(r.best);
    return a.alloc(u8, 0);
}

/// Emit literal byte `b` (whose atom ends at `after`) honoring any quantifier:
/// optional ⇒ drop it and flush; mandatory (≥1) ⇒ append one guaranteed copy
/// then flush (a repeat count >1 could split the run); none ⇒ append and
/// continue. Non-ASCII bytes end the run (we do not reason about multi-byte
/// codepoints under a quantifier). Returns the next scan index.
fn emitLiteral(r: *Runner, b: u8, pattern: []const u8, after: usize) std.mem.Allocator.Error!usize {
    const q = classifyQuant(pattern, after);
    if (b >= 0x80) {
        try r.flush();
        return q.next;
    }
    switch (q.kind) {
        .none => try r.push(b),
        .optional => try r.flush(),
        .mandatory => {
            try r.push(b);
            try r.flush();
        },
    }
    return q.next;
}

/// Skip a quantifier that binds to a just-consumed group/class/anchor (it does
/// not add any required byte). `at` points just past the atom.
fn foldQuantAfter(pattern: []const u8, at: usize) usize {
    return classifyQuant(pattern, at).next;
}
