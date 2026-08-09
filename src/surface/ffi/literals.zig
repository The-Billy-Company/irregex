//! What a pattern promises about the bytes it can match — the plane that lets a
//! host build its own prefilter instead of asking this one to be fast enough.
//!
//! The engine already extracts this for itself: before it runs, it asks the AST
//! for required literals, a prefix set, an inner set, and whether the pattern is
//! anchored, and it uses the answer to skip most of the haystack. A host indexing
//! a corpus needs the same facts and has no way to get them, so it either
//! re-implements literal extraction against a grammar it does not own, or it
//! gives up and scans everything. `regex-syntax`'s `hir::literal` is a separate
//! crate in the Rust ecosystem for exactly this reason — the extractor is
//! valuable on its own, apart from the engine that consumes it.
//!
//! Two properties make an answer here usable rather than merely interesting, and
//! both must ride every response:
//!
//!   * **Exact or inexact.** A literal set is EXACT when a match implies one of
//!     these literals is present and its absence therefore proves no match — the
//!     property a prefilter needs to be allowed to eliminate a file. It is
//!     INEXACT when the set is merely a hint. `mark.Authority` is this
//!     distinction already spelled as a type, and the plane must return it
//!     rather than leave the caller to assume.
//!   * **Where it may sit.** A prefix literal admits an anchored index probe; an
//!     inner literal only admits a substring search. Collapsing the two into one
//!     "literals" list would let a host anchor a probe that was never anchored.
//!
//! **Position is the request, not the response**, which is how the second
//! property is enforced rather than documented: there is no verb that hands back
//! "the literals". A caller names a `Place` — `required`, `prefix`, `suffix`,
//! `whole` — and gets that place's set and nothing else, so a set can only be
//! read by a caller who already said where it believed the literals sat.
//!
//! **Every set is graded on one ladder** (`Verdict`), written on every `set`
//! call through an out-parameter that cannot be omitted. It is `mark.Authority`
//! plus the one state a two-valued authority cannot spell — the *absent* set.
//! That third state is the whole reason this is not the enum itself: an empty
//! set carrying `.candidate` reads as a filter a host may use, and using it
//! eliminates every file. `none` < `candidate` < `exact` is ordered by strength,
//! so `verdict >= IRGX_LITERALS_CANDIDATE` is the "safe to eliminate on" test.
//!
//! **`prefix` and `suffix` are sets, and the set is exhaustive.** Every match
//! starts with SOME member of `prefix`, which is what licenses a host to run one
//! anchored probe per member and conclude nothing matched when all of them miss.
//! A shape whose starts cannot be enumerated answers with an EMPTY set rather
//! than with some of them, because "here are a few literals seen at the start of
//! some matches" licenses nothing and a host mistaking it for the exhaustive
//! claim would silently miss matches. Exhaustive is still not `exact`: a
//! member's presence proves nothing on its own, so both places grade
//! `candidate`, and `whole` remains the only place allowed to decide.
//!
//! Two weakenings are free, and a host short on probe budget should know them:
//! a member may be SHORTENED (anything starting with `foobar` starts with
//! `foo`), and a member already covered by a shorter one is dropped here before
//! you see it. Nothing else may be dropped.
//!
//! **A pattern with no provable literal still says where a match can open.**
//! `Promise.first_bytes` is the 256-bit start-byte set, and it is the fact that
//! survives a fold or a bare character class — the two shapes that leave every
//! literal set empty and would otherwise send a host back to a full walk.
//!
//! **The facts are read off the pattern the engine actually compiled.** `open`
//! takes a compiled `irgx_regex` rather than pattern text, so the AST analyzed
//! here is the one the matcher runs: `-F` escaping, `IRGX_SMART_CASE`, a leading
//! `(?i)`/`(?ms)` directive, `-w` word bounding and `--crlf` stripping have all
//! already resolved, and this plane cannot disagree with the engine about what
//! the pattern means because it never re-decides any of it. A second copy of
//! that flag resolution is precisely the drift `pureLiterals`' own soundness
//! rests on not having.
//!
//! Ownership: an `irgx_literals` owns every byte it hands back, in one arena
//! freed by `irgx_literals_free`. The `irgx_text` rows point INTO that arena —
//! not into the pattern, not into the caller's pattern text — so they outlive
//! the `irgx_regex` they were derived from and die with the literals handle. The
//! Unicode verbs borrow from static tables compiled into the library and are
//! valid for the life of the process.
//!
//! `kernel/regex` is sealed, so the engine is entered through `regex.zig` (the
//! seal's entry file) exactly as the sibling planes do. No `export fn` lives
//! here: `exports.zig` is the `libirgx` artifact's root and the three bindings
//! are landed with it.

const std = @import("std");
const contract = @import("contract.zig");
const mark = @import("../../mark.zig");
const pat = @import("pattern.zig");
const rows = @import("rows.zig");
const rx = @import("../../kernel/regex/regex.zig");

const Status = contract.Status;
const gpa = std.heap.c_allocator;

/// Where in a match a literal may sit — the request half of the position
/// property, and the only way to reach a set.
///
/// `required` is the *cover*: every match contains at least one member, and
/// nothing says where. That is the set an inverted index queries. The three
/// others are strictly stronger claims about placement, and `whole` is stronger
/// still about the match itself.
pub const Place = enum(u32) {
    /// Every match contains at least one of these, anywhere in it.
    required = 0,
    /// Every match STARTS with one of these — an EXHAUSTIVE set, so a host may
    /// probe once per member and conclude nothing matched when all of them miss.
    /// `foo|bar` answers `{foo, bar}`; a shape whose starts cannot be enumerated
    /// answers with nothing rather than with a partial list. Pair with
    /// `Promise.anchored` before anchoring an index probe: this says a member
    /// opens the match, not that the match opens the line.
    prefix = 1,
    /// Every match ENDS with one of these, exhaustively, mirroring `prefix`.
    suffix = 2,
    /// The pattern is an alternation of pure literals, so containment and
    /// matching are the same question and the engine can be skipped outright.
    whole = 3,

    const count = 4;

    fn of(v: u32) ?Place {
        return if (v < count) @enumFromInt(v) else null;
    }
};

/// What each place's set settles when it holds anything.
///
/// Only `whole` decides: `analysis.pureLiterals` is a match-EQUIVALENCE (a line
/// matches iff it contains one of the literals), which is what `mark.Authority`
/// calls `.exact`. The other three are mandatory-presence claims — sound to
/// *eliminate* on and never to *conclude* from, which is `.candidate`. Keeping
/// them apart is this package's central promise, not a nicety: an index may
/// eliminate work and may never overrule bytes.
const settles: [Place.count]mark.Authority = .{ .candidate, .candidate, .candidate, .exact };

/// How much a set of literals settles — `mark.Authority`, plus the state it
/// cannot spell.
pub const Verdict = enum(u32) {
    /// No set. Proves nothing in either direction; scan.
    none = 0,
    /// `mark.Authority.candidate`. Absence of every member PROVES no match;
    /// presence of one proves nothing and must still be verified.
    candidate = 1,
    /// `mark.Authority.exact`. Containment and matching are the same question.
    exact = 2,

    /// The grade a set of `count` members earns under `authority`. Emptiness
    /// outranks the authority because an empty set witnesses nothing to be
    /// authoritative about. Exhaustive on the authority on purpose: a third
    /// `mark.Authority` member is a compile error here rather than a silent
    /// grade.
    fn of(authority: mark.Authority, count: usize) Verdict {
        if (count == 0) return .none;
        return switch (authority) {
            .exact => .exact,
            .candidate => .candidate,
        };
    }
};

/// A length no bounded repetition reaches — `Promise.max_len` under a closure.
pub const len_unbounded: u32 = rx.ast.unbounded;

/// The whole-pattern verdict, and the size of every set, in one read.
///
/// The four `count` entries are here so a host sizes all four buffers with one
/// call instead of four counting probes. `struct_size` is FAIL-CLOSED: a size
/// this build does not recognize is `.invalid`, never a best-effort read of the
/// prefix it thinks it recognizes.
pub const Promise = extern struct {
    struct_size: u32,
    /// `Verdict` per `Place`, indexed by the place's own value.
    verdict: [Place.count]u32,
    /// Members in each place's set.
    count: [Place.count]u32,
    /// 1 when every match must begin at a line start. What turns a `prefix` run
    /// into an anchored probe; without it a prefix only admits a substring
    /// search that happens to know where the match will start.
    anchored: u32,
    /// 1 when the pattern matches the empty string — so it matches at every
    /// position of every haystack and NO literal can eliminate anything. Every
    /// set is empty when this is set; it is published because a host that only
    /// reads counts should still be told why they are zero.
    nullable: u32,
    /// Shortest and longest match in bytes; `max_len == len_unbounded` under an
    /// unbounded closure. A bounded-window prefilter needs both.
    min_len: u32,
    max_len: u32,
    /// The bytes a match may BEGIN with, as a 256-bit set — bit `b` of
    /// `first_bytes[b >> 6]` at position `b & 63`.
    ///
    /// The one prefilter fact that survives when no literal does. `(?i)foo`
    /// folds to three classes before analysis and `[a-z]+@[a-z]+` never had a
    /// literal at all, so both leave every set above empty — and both still
    /// admit a `memchr`-class scan over two or twenty-six start bytes instead of
    /// a walk. A conservative SUPERSET, like everything here: a byte in the set
    /// need not begin any real match, and a byte outside it cannot begin one.
    ///
    /// Meaningful only when `nullable == 0`, and zeroed otherwise, for the same
    /// reason the sets are: a pattern matching the empty string begins a match at
    /// every position without consuming a byte, so no set of bytes describes it.
    first_bytes: [4]u64,
    /// The structural name of the whole pattern: two patterns agreeing here
    /// denote the same LANGUAGE, to within a 128-bit collision.
    ///
    /// Not a hash of the pattern text — `a|b` and `b|a` agree, and `(?:ab)` and
    /// `ab` agree, because the digest is taken over the interned DAG after
    /// lowering rather than over the bytes a host typed. That is what makes it
    /// useful to the one caller who needs it: a wide `-e`/`-f` slate dropping
    /// duplicate INTENTS before it compiles one engine each.
    ///
    /// Two `u64` rather than a `u128` because C has no portable 128-bit integer;
    /// `[0]` is the low half. It rides this struct instead of earning a verb,
    /// since a host asking what a pattern promises is already holding the only
    /// thing that could answer.
    signature: [2]u64,
};

/// One closed scalar range `[lo, hi]`, as `\p{…}` resolves to.
pub const Range = extern struct { lo: u32, hi: u32 };

/// The largest Unicode scalar value. A codepoint above it is a caller
/// arithmetic bug, not a question with an empty answer.
pub const max_scalar: u32 = 0x10FFFF;

/// The literal facts of one compiled pattern, and the arena holding them.
pub const Literals = struct {
    arena: std.heap.ArenaAllocator,
    promise: Promise,
    /// Indexed by `Place`. Every string is arena-owned.
    sets: [Place.count][]const []const u8,
};

/// Analyze what `re` promises about its matches.
///
/// `.stale` for a PCRE2-compiled pattern: that arm has no AST in this tree to
/// under-claim from, and the remedy is real rather than nominal — recompile the
/// same text without `IRGX_PCRE` and ask again, which is the tier down a
/// declinature names. A declinature installs no fault.
pub fn open(re: ?*pat.Regex, out: ?**Literals) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const handle = re orelse return .invalid;
    if (handle.inner.sel.pcre) return .stale;

    const lits = gpa.create(Literals) catch return contract.report(.{ .code = error.OutOfMemory });
    lits.* = .{ .arena = .init(gpa), .promise = undefined, .sets = @splat(&.{}) };
    // No `errdefer`: this entry returns a Status, not an error union, so one
    // would never fire. The two allocations above are unwound by hand.
    fill(lits, handle.inner.src, handle.inner.sel) catch |e| {
        lits.arena.deinit();
        gpa.destroy(lits);
        return contract.reportAny(e, .invalid);
    };
    slot.* = lits;
    return .ok;
}

/// Parse and sweep in scratch; keep only the answers.
///
/// The intermediate AST, the interned DAG and the fact array are an order of
/// magnitude larger than the handful of short strings they prove, and a host
/// holding one of these handles across a corpus walk would be holding all of it.
/// So everything temporary lives in one arena that dies here, and the four
/// answer sets are copied into the handle's own — which is also what lets the
/// rows outlive the `irgx_regex` they came from.
fn fill(lits: *Literals, src: []const u8, sel: rx.Caps.Selection) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Read off the selection the engine resolved, so these literals are extracted
    // under the options the matcher was compiled under and not a second opinion.
    const tree = try rx.lower.parse(sa, src, sel.lowerOptions());

    var ast = try rx.ast.analyze(gpa, sa, tree, .{});
    defer ast.deinit();
    const facts = ast.root();

    const keep = lits.arena.allocator();
    // A nullable pattern matches everywhere, so nothing can be mandatory in a
    // match — the sweep already returns empty runs for one, and this is the
    // fail-closed floor under that rather than a second derivation of it.
    if (!facts.nullable) {
        // Both flanks come from one sweep, and each is already at least as strong
        // as the single mandatory run `facts.lit` proves — `Ast.flanks` sharpens
        // them against it, so widening a run into a set can never have cost the
        // host the run it used to get.
        const flanks = try ast.flanks(sa);
        lits.sets[@intFromEnum(Place.required)] = try keepSet(keep, try ast.cover(sa) orelse &.{});
        lits.sets[@intFromEnum(Place.prefix)] = try keepSet(keep, flanks.leading orelse &.{});
        lits.sets[@intFromEnum(Place.suffix)] = try keepSet(keep, flanks.trailing orelse &.{});
        lits.sets[@intFromEnum(Place.whole)] = try keepSet(keep, try rx.analysis.pureLiterals(sa, tree) orelse &.{});
    }

    lits.promise = .{
        .struct_size = @sizeOf(Promise),
        .verdict = @splat(@intFromEnum(Verdict.none)),
        .count = @splat(0),
        .anchored = @intFromBool(facts.anchored),
        .nullable = @intFromBool(facts.nullable),
        .min_len = facts.min_len,
        .max_len = facts.max_len,
        .first_bytes = if (facts.nullable) @splat(0) else facts.first.bits,
        // Split low-half-first, which is the half a host reaching for one word
        // wants, and the order it would guess.
        .signature = halves(ast.signature()),
    };
    for (&lits.promise.verdict, &lits.promise.count, lits.sets, settles) |*v, *n, s, authority| {
        v.* = @intFromEnum(Verdict.of(authority, s.len));
        n.* = @intCast(s.len);
    }
}

/// A `u128` as the two `u64`s the C seam can carry, low half first.
fn halves(v: u128) [2]u64 {
    return .{ @truncate(v), @truncate(v >> 64) };
}

/// Copy a set and its bytes into the handle's arena, dropping empty runs.
///
/// The sweep spells "nothing provable here" as `""` rather than as an absent
/// field, and an empty literal read as a set member is a filter that admits
/// every byte string — so the emptiness is answered once, here, instead of at
/// each of the four call sites and again in every binding.
fn keepSet(arena: std.mem.Allocator, from: []const []const u8) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (from) |lit| if (lit.len != 0) try kept.append(arena, try arena.dupe(u8, lit));
    return kept.items;
}

/// Release the handle and every literal it lent out.
///
/// No `beginCall`: teardown leaves the fault slot alone, so a host can still
/// report the detail behind the failure it is cleaning up after.
pub fn free(lits: *Literals) void {
    lits.arena.deinit();
    gpa.destroy(lits);
}

/// The whole-pattern promise. Reading does not consume — ask as often as you
/// like, and the answer never moves.
///
/// It calls `beginCall` despite doing no work, because it can still REFUSE (a
/// `struct_size` this build does not know), and a refusal that left the previous
/// call's fault standing would hand the host a detail about the wrong call.
pub fn promise(lits: *const Literals, out: ?*Promise) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(Promise)) return .invalid;
    slot.* = lits.promise;
    return .ok;
}

/// The literals that may sit at `place`, and what they settle.
///
/// `verdict` is not optional: it is how the exact-versus-inexact property rides
/// every response, and a caller who would not read it is a caller about to
/// treat a hint as a decision. NULL is `.invalid`.
///
/// `*written` is the TRUE member count whatever `cap` was, so `cap = 0` with a
/// null buffer is the sizing probe. `.match` when the set holds anything, `.ok`
/// when it is empty — the status is about the set, never about the window.
pub fn set(
    lits: *const Literals,
    place: u32,
    verdict: ?*u32,
    out: ?[*]rows.Text,
    cap: usize,
    written: ?*usize,
) Status {
    contract.beginCall();
    const which = Place.of(place) orelse return .invalid;
    const grade = verdict orelse return .invalid;
    var sink = contract.Sink(rows.Text).open(out, cap, written) orelse return .invalid;
    grade.* = lits.promise.verdict[@intFromEnum(which)];
    for (lits.sets[@intFromEnum(which)]) |lit| sink.push(rows.Text.of(lit));
    return sink.close();
}

/// The simple case-fold orbit of `cp` — every scalar case-equivalent to it,
/// `cp` first.
///
/// CLOSED over `cp` deliberately, where the kernel's own `foldOrbit` returns
/// only the OTHERS: across a C ABI an empty answer would have to mean both "no
/// table entry" and "folds to itself", and a host expanding a class wants the
/// class. So this always writes at least one member and always returns `.match`,
/// and a caller can use the answer without a special case for the common
/// scalar. Members after the first are in table order, which is the generated
/// table's own and not sorted.
///
/// A `cp` above `max_scalar` is `.invalid`. Surrogates are answered rather than
/// refused — they fold to themselves and belong to no property, which is the
/// truthful answer and the one that keeps this verb agreeing with
/// `propertyHas`.
pub fn foldOrbit(cp: u32, out: ?[*]u32, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    if (cp > max_scalar) return .invalid;
    var sink = contract.Sink(u32).open(out, cap, written) orelse return .invalid;
    sink.push(cp);
    for (rx.unicode.foldOrbit(@intCast(cp))) |member| sink.push(member);
    return sink.close();
}

/// The scalar ranges `\p{name}` resolves to, ascending and coalesced.
///
/// `name` is the property BODY, not the `\p{…}` spelling: `Lu`, `Letter`,
/// `Greek`, `gc=Nd`, `script=Latin`, `Any`. Matched case- and
/// separator-insensitively, and through Unicode's own alias tables, so it takes
/// every spelling the parser takes — because it is the same resolver.
///
/// An unrecognized name is `error.BadPattern`, the same fault `\p{Nope}` earns
/// inside a pattern. It is NOT an empty answer: a property that resolves to
/// nothing and a property this build has never heard of are different facts, and
/// a host building a character class from the first would silently build an
/// empty one from the second.
pub fn propertyRanges(
    name: ?[*]const u8,
    len: usize,
    out: ?[*]Range,
    cap: usize,
    written: ?*usize,
) Status {
    contract.beginCall();
    const body = contract.view(name, len) orelse return .invalid;
    var sink = contract.Sink(Range).open(out, cap, written) orelse return .invalid;
    const ranges = rx.unicode.property(body) orelse return contract.report(.{ .code = error.BadPattern });
    for (ranges) |r| sink.push(.{ .lo = r[0], .hi = r[1] });
    return sink.close();
}

/// Whether `cp` belongs to `\p{name}`: `.match` yes, `.ok` no.
///
/// The single-codepoint question, answered by binary search over the same table
/// `propertyRanges` hands back whole. Both exist because a host expanding a
/// class wants the table once and a host classifying a stream wants neither the
/// table nor a copy of the search.
pub fn propertyHas(name: ?[*]const u8, len: usize, cp: u32) Status {
    contract.beginCall();
    const body = contract.view(name, len) orelse return .invalid;
    if (cp > max_scalar) return .invalid;
    const ranges = rx.unicode.property(body) orelse return contract.report(.{ .code = error.BadPattern });
    return if (rx.unicode.inRanges(ranges, @intCast(cp))) .match else .ok;
}

/// Which Unicode revision the two verbs above answer from, e.g. `"16.0.0"`.
///
/// Parity with the tables is not a claim a host can make without this: a binding
/// that folds `ſ` because this library does needs to know which revision said
/// so. Borrowed from static storage — valid for the life of the process, and
/// never freed.
pub fn unicodeVersion(out: ?*rows.Text) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    slot.* = rows.Text.of(rx.unicode.version);
    return .ok;
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// Every claim below is checked against a source that knows nothing about this
// file: `std.mem.indexOf` for containment, the compiled engine for whether a
// haystack matches, `analysis.requiredAny`'s recursive descent for the cover the
// DAG sweep computes forward, and the regex parser's own `\p{…}` path for the
// property tables. Asserting the literals this plane returned would only prove
// it is consistent with itself.

const testing = std.testing;

/// Compile through the pattern plane — the same door a host uses, so the flag
/// resolution under test is the real one.
fn compiled(src: []const u8, flags: u32) !*pat.Regex {
    var re: *pat.Regex = undefined;
    try testing.expectEqual(Status.ok, pat.compile(src.ptr, src.len, flags, &re));
    return re;
}

fn analyzed(re: *pat.Regex) !*Literals {
    var lits: *Literals = undefined;
    try testing.expectEqual(Status.ok, open(re, &lits));
    return lits;
}

/// Read one place into an owned list of slices, asserting the sizing probe and
/// the filled read agree — the `cap = 0` contract, exercised on every read
/// rather than once.
fn read(lits: *Literals, place: Place, buf: []rows.Text) ![]const []const u8 {
    var sized: usize = 0;
    var grade: u32 = 0xFFFF_FFFF;
    const probe = set(lits, @intFromEnum(place), &grade, null, 0, &sized);
    try testing.expectEqual(grade, lits.promise.verdict[@intFromEnum(place)]);
    try testing.expectEqual(probe, if (sized == 0) Status.ok else Status.match);

    var written: usize = 0;
    try testing.expectEqual(probe, set(lits, @intFromEnum(place), &grade, buf.ptr, buf.len, &written));
    try testing.expectEqual(sized, written);

    const lits_out = try testing.allocator.alloc([]const u8, @min(written, buf.len));
    for (lits_out, buf[0..lits_out.len]) |*dst, row| dst.* = row.slice();
    return lits_out;
}

fn holdsAny(hay: []const u8, set_of: []const []const u8) bool {
    for (set_of) |lit| if (std.mem.indexOf(u8, hay, lit) != null) return true;
    return false;
}

/// The haystacks every soundness property below is quantified over. Deliberately
/// includes near-misses, wrong case, and the empty text.
const hays = [_][]const u8{
    "",                    "a",
    "foo",                 "bar",
    "xfoox",               "FOO",
    "foobar",              "0x1f",
    "panic",               "PANIC: 0x0",
    "fo o",                "\nfoo\n",
    "the quick brown fox", "foo\nbar",
    "barfoo",              "f",
};

test "literal analysis: a required cover can only eliminate, never conclude" {
    // The property that makes a prefilter legal: if no member occurs, there is
    // no match. Checked against the engine's verdict and std's substring search,
    // neither of which knows how the cover was derived.
    for ([_][]const u8{ "foo", "foo|bar", "panic|0x", "^func", "a(bc|bd)e", "fo+bar", "x[0-9]y" }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const cover = try read(lits, .required, &buf);
        defer testing.allocator.free(cover);
        if (cover.len == 0) continue;

        for (hays) |hay| {
            const matched = pat.isMatch(re, hay.ptr, hay.len) == .match;
            if (matched) try testing.expect(holdsAny(hay, cover));
        }
    }
}

test "literal analysis: the DAG sweep's cover agrees with the recursive descent" {
    // Two independent implementations of one contract — `ast.zig` sweeps the
    // interned DAG forward, `analysis.requiredAny` descends the parse tree — and
    // the package's own comment says they must reach the identical verdict.
    for ([_][]const u8{ "foo", "foo|bar", "panic|0x", "a(bc|bd)e", "^func", "fo+bar", "(ab|cd)(ef|gh)", "x" }) |src| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const sa = arena.allocator();

        const tree = try rx.lower.parse(sa, src, .{ .multiline = true, .unicode = true });
        var ast = try rx.ast.analyze(testing.allocator, sa, tree, .{});
        defer ast.deinit();

        const swept = try ast.cover(sa);
        const walked = try rx.analysis.requiredAny(sa, tree);
        try testing.expectEqual(swept == null, walked == null);
        if (swept) |s| {
            try testing.expectEqualDeep(walked.?, s);
        }
    }
}

/// Whether every span the engine found starts (or ends) with a member of `set`
/// — the exhaustiveness claim itself, read off the engine's own spans rather
/// than off the machinery that produced the set.
fn flanksEverySpan(re: *pat.Regex, side: Place, set_of: []const []const u8) !void {
    for (hays) |hay| {
        var spans: [16]pat.Span = undefined;
        var found: usize = 0;
        if (pat.findAll(re, hay.ptr, hay.len, &spans, spans.len, &found) != .match) continue;
        for (spans[0..@min(found, spans.len)]) |span| {
            const at: usize = @intCast(span.start);
            const end: usize = @intCast(span.end);
            var covered = false;
            for (set_of) |lit| {
                covered = covered or switch (side) {
                    .prefix => std.mem.startsWith(u8, hay[at..], lit),
                    .suffix => std.mem.endsWith(u8, hay[0..end], lit),
                    else => unreachable,
                };
            }
            try testing.expect(covered);
        }
    }
}

test "literal analysis: a prefix set really opens every match, exhaustively" {
    // The property that makes an anchored probe legal, and the reason the set
    // form exists at all: SOME member opens every match. An alternation is the
    // shape a single run had no answer for, so the spread leads with them.
    for ([_][]const u8{
        "foo",           "foo|bar",
        "foo|foobar",    "fo+",
        "^func",         "foo[0-9]",
        "(ab|cd)ef",     "a(bc|bd)e",
        "panic|0x",      "(foo|bar)+",
        "x?y",           "quick|brown|[0-9]",
        "[0-9]foo",      "a+bar",
        "(?:ab|c)(d|e)", "f(o|0)o",
    }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const prefix = try read(lits, .prefix, &buf);
        defer testing.allocator.free(prefix);
        if (prefix.len == 0) continue;
        // A member that admits every position would make the set exhaustive and
        // useless; the plane must never hand one out.
        for (prefix) |lit| try testing.expect(lit.len != 0);
        try flanksEverySpan(re, .prefix, prefix);
    }
}

test "literal analysis: a suffix set really closes every match, exhaustively" {
    for ([_][]const u8{
        "foo",       "foo|bar",
        "[0-9]foo",  "a+bar",
        "ab(c|d)",   "(foo|bar)",
        "x(?:y|zz)", "alpha|bravo|charlie",
    }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const suffix = try read(lits, .suffix, &buf);
        defer testing.allocator.free(suffix);
        if (suffix.len == 0) continue;
        for (suffix) |lit| try testing.expect(lit.len != 0);
        try flanksEverySpan(re, .suffix, suffix);
    }
}

test "literal analysis: an alternation now has a prefix set where it had no run" {
    // The gap this closes, stated as the difference it makes: `foo|bar` used to
    // report no prefix at all, because the two branches share no common run.
    const re = try compiled("foo|bar", 0);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var buf: [8]rows.Text = undefined;
    const prefix = try read(lits, .prefix, &buf);
    defer testing.allocator.free(prefix);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    try testing.expectEqualStrings("foo", prefix[0]);
    try testing.expectEqualStrings("bar", prefix[1]);
    // Exhaustive, and still only a CANDIDATE: `xfoox` holds "foo" without the
    // match opening where the probe would have looked.
    try testing.expectEqual(@intFromEnum(Verdict.candidate), lits.promise.verdict[@intFromEnum(Place.prefix)]);
    try testing.expectEqual(@as(u32, 2), lits.promise.count[@intFromEnum(Place.prefix)]);
}

test "literal analysis: a set is never weaker than the run it replaced" {
    // Widening a run into a set may not lose the run. Two shapes where the set
    // analysis declines — an unbounded closure on the left, and a repetition
    // longer than one member is allowed to be — and both keep answering.
    for ([_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "a*function", .want = "" }, // no enumerable start: nothing either way
        .{ .src = "fo+", .want = "fo" }, // the run the closure leaves behind
        .{ .src = "^func", .want = "func" },
    }) |c| {
        const re = try compiled(c.src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const prefix = try read(lits, .prefix, &buf);
        defer testing.allocator.free(prefix);
        if (c.want.len == 0) {
            try testing.expectEqual(@as(usize, 0), prefix.len);
            continue;
        }
        try testing.expectEqual(@as(usize, 1), prefix.len);
        try testing.expectEqualStrings(c.want, prefix[0]);
    }

    // A repetition whose members would exceed the flank analysis's byte cap: the
    // cross is declined partway up, and the mandatory run is longer than any
    // member it did build — so the run is what a host gets.
    const long = try compiled("(a{40}){40}", 0);
    defer pat.free(long);
    const lits = try analyzed(long);
    defer free(lits);
    var buf: [8]rows.Text = undefined;
    const prefix = try read(lits, .prefix, &buf);
    defer testing.allocator.free(prefix);
    try testing.expectEqual(@as(usize, 1), prefix.len);
    try testing.expectEqual(@as(usize, 1600), prefix[0].len);
}

test "literal analysis: a set too wide to enumerate is withheld, never truncated" {
    // A truncated set is not exhaustive, so it is not the fact the caller was
    // promised: past the cap the answer is nothing at all. `.` is 255 bytes wide
    // is 255 bytes wide, and the fact that outlives it is `first_bytes`.
    for ([_][]const u8{ ".x", ".+bar", "a*function" }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const prefix = try read(lits, .prefix, &buf);
        defer testing.allocator.free(prefix);
        try testing.expectEqual(@as(usize, 0), prefix.len);
        try testing.expectEqual(@intFromEnum(Verdict.none), lits.promise.verdict[@intFromEnum(Place.prefix)]);
        var any = false;
        for (lits.promise.first_bytes) |word| any = any or word != 0;
        try testing.expect(any);
    }
}

test "literal analysis: a declined cross degrades to the weaker exhaustive claim" {
    // Twenty-six squared is past the cap, so `[a-z][a-z]` cannot be enumerated
    // whole — and the LEFT class still opens every match, which is a weaker
    // exhaustive claim and therefore still an answer. Degrading beats refusing,
    // and both beat truncating.
    const re = try compiled("[a-z][a-z]", 0);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var buf: [64]rows.Text = undefined;
    const prefix = try read(lits, .prefix, &buf);
    defer testing.allocator.free(prefix);
    try testing.expectEqual(@as(usize, 26), prefix.len);
    for (prefix) |lit| try testing.expectEqual(@as(usize, 1), lit.len);
    try flanksEverySpan(re, .prefix, prefix);
}

test "literal analysis: an exact whole set decides a match both ways" {
    // The only verdict allowed to DECIDE, so it is held to the equivalence and
    // not merely to elimination: containment iff match, over every haystack.
    for ([_][]const u8{ "foo", "foo|bar", "panic|0x" }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [64]rows.Text = undefined;
        const whole = try read(lits, .whole, &buf);
        defer testing.allocator.free(whole);
        try testing.expectEqual(@intFromEnum(Verdict.exact), lits.promise.verdict[@intFromEnum(Place.whole)]);

        for (hays) |hay| {
            const matched = pat.isMatch(re, hay.ptr, hay.len) == .match;
            try testing.expectEqual(matched, holdsAny(hay, whole));
        }
    }
}

test "literal analysis: a word-bounded or folded pattern withholds the exact set" {
    // Containment stops being equivalent to matching the moment the engine
    // lowers a boundary or a fold into the AST, and the withholding has to
    // happen for the RIGHT reason — so the equivalence is tested for failure on
    // a real haystack rather than the empty set merely being observed.
    for ([_]struct { src: []const u8, flags: u32, hay: []const u8 }{
        .{ .src = "foo", .flags = contract.flag_word, .hay = "foobar" },
        .{ .src = "foo", .flags = contract.flag_ignore_case, .hay = "FOO" },
    }) |c| {
        const re = try compiled(c.src, c.flags);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        var buf: [8]rows.Text = undefined;
        const whole = try read(lits, .whole, &buf);
        defer testing.allocator.free(whole);
        try testing.expectEqual(@as(usize, 0), whole.len);
        try testing.expectEqual(@intFromEnum(Verdict.none), lits.promise.verdict[@intFromEnum(Place.whole)]);

        // Naive containment of the raw source would have been wrong here, which
        // is what the withheld set is protecting the host from.
        const matched = pat.isMatch(re, c.hay.ptr, c.hay.len) == .match;
        try testing.expect(matched != (std.mem.indexOf(u8, c.hay, c.src) != null));
    }
}

test "literal analysis: a fixed pattern's metacharacters are data" {
    // `-F` resolves in the pattern plane, so the AST analyzed here is the
    // ESCAPED one. Nothing in this file knows that; it falls out of reading the
    // compiled handle instead of the caller's text.
    const src = "a.c(";
    const re = try compiled(src, contract.flag_fixed);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var buf: [8]rows.Text = undefined;
    const whole = try read(lits, .whole, &buf);
    defer testing.allocator.free(whole);
    try testing.expectEqual(@as(usize, 1), whole.len);
    try testing.expectEqualStrings(src, whole[0]);
    try testing.expect(pat.isMatch(re, "xa.c(y", 6) == .match);
    try testing.expect(pat.isMatch(re, "xabc(y", 6) == .ok);
}

test "literal analysis: a nullable pattern promises nothing and says so" {
    for ([_][]const u8{ "a*", "", "(foo)?" }) |src| {
        const re = try compiled(src, 0);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        // Matches every haystack, so no absence can prove anything.
        try testing.expectEqual(@as(u32, 1), lits.promise.nullable);
        for (hays) |hay| try testing.expect(pat.isMatch(re, hay.ptr, hay.len) == .match);
        for (0..Place.count) |i| {
            try testing.expectEqual(@intFromEnum(Verdict.none), lits.promise.verdict[i]);
            try testing.expectEqual(@as(u32, 0), lits.promise.count[i]);
        }
    }
}

test "literal analysis: the signature names the language, not the pattern text" {
    const sigOf = struct {
        fn f(src: []const u8) ![2]u64 {
            const re = try compiled(src, 0);
            defer pat.free(re);
            const lits = try analyzed(re);
            defer free(lits);
            return lits.promise.signature;
        }
    }.f;

    // The whole point: spellings that denote one language agree, so a slate can
    // drop the duplicate before it compiles a second engine for it.
    try testing.expectEqual(try sigOf("(?:ab)"), try sigOf("ab"));
    try testing.expectEqual(try sigOf("a|b"), try sigOf("b|a"));
    // And a hash of the TEXT would have agreed here, where the languages differ.
    try testing.expect(!std.meta.eql(try sigOf("ab"), try sigOf("ba")));
    try testing.expect(!std.meta.eql(try sigOf("a+"), try sigOf("a*")));
    // Stable across two analyses of the same source — a digest that moved would
    // make the dedup it exists for silently stop deduping.
    try testing.expectEqual(try sigOf("^ab[cd]"), try sigOf("^ab[cd]"));
    // Both halves are real: a 64-bit truncation would leave one word always zero
    // across a spread of shapes.
    var seen_low: u64 = 0;
    var seen_high: u64 = 0;
    for ([_][]const u8{ "a", "ab", "a|b", "^x$", "[0-9]+", "(?:foo)*bar" }) |src| {
        const sig = try sigOf(src);
        seen_low |= sig[0];
        seen_high |= sig[1];
    }
    try testing.expect(seen_low != 0 and seen_high != 0);
}

test "literal analysis: the promise carries anchoring and match length" {
    const re = try compiled("^ab[cd]", 0);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var got: Promise = .{
        .struct_size = @sizeOf(Promise),
        .verdict = @splat(0),
        .count = @splat(0),
        .anchored = 0,
        .nullable = 0,
        .min_len = 0,
        .max_len = 0,
        .first_bytes = @splat(0),
        .signature = @splat(0),
    };
    try testing.expectEqual(Status.ok, promise(lits, &got));
    try testing.expectEqual(@as(u32, 1), got.anchored);
    try testing.expectEqual(@as(u32, 0), got.nullable);
    // Three bytes exactly, on any branch — checked against the engine's spans.
    try testing.expectEqual(@as(u32, 3), got.min_len);
    try testing.expectEqual(@as(u32, 3), got.max_len);
    var spans: [4]pat.Span = undefined;
    var found: usize = 0;
    try testing.expectEqual(Status.match, pat.findAll(re, "abcx", 4, &spans, spans.len, &found));
    try testing.expectEqual(@as(i64, 3), spans[0].end - spans[0].start);

    // An unbounded closure saturates rather than lying about a bound.
    const star = try compiled("ab+", 0);
    defer pat.free(star);
    const loose = try analyzed(star);
    defer free(loose);
    try testing.expectEqual(len_unbounded, loose.promise.max_len);
    try testing.expectEqual(@as(u32, 0), loose.promise.anchored);
}

test "literal analysis: the start-byte set holds every match's first byte" {
    // The fact that outlives the literals: two of these patterns prove no
    // literal at all, and all four still name where a match can open. The oracle
    // is the engine's own spans — the set is checked against the bytes matches
    // actually started on, never against how the set was derived.
    for ([_]struct { src: []const u8, flags: u32 }{
        .{ .src = "foo", .flags = 0 },
        .{ .src = "foo", .flags = contract.flag_ignore_case },
        .{ .src = "[a-c]x", .flags = 0 },
        .{ .src = "quick|brown|[0-9]", .flags = 0 },
    }) |c| {
        const re = try compiled(c.src, c.flags);
        defer pat.free(re);
        const lits = try analyzed(re);
        defer free(lits);

        const first = lits.promise.first_bytes;
        try testing.expectEqual(@as(u32, 0), lits.promise.nullable);
        var any = false;
        for (first) |word| any = any or word != 0;
        try testing.expect(any);

        for (hays) |hay| {
            var spans: [16]pat.Span = undefined;
            var found: usize = 0;
            if (pat.findAll(re, hay.ptr, hay.len, &spans, spans.len, &found) != .match) continue;
            for (spans[0..@min(found, spans.len)]) |span| {
                const b = hay[@intCast(span.start)];
                try testing.expect(first[b >> 6] >> @intCast(b & 63) & 1 == 1);
            }
        }
    }

    // A nullable pattern names no start byte, because it starts a match without
    // consuming one.
    const empty = try compiled("a*", 0);
    defer pat.free(empty);
    const loose = try analyzed(empty);
    defer free(loose);
    try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, loose.promise.first_bytes);
}

test "literal analysis: the plane refuses what it cannot read" {
    // A size this build does not know is fail-closed, never a prefix read.
    const re = try compiled("foo", 0);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var stale_shape: Promise = undefined;
    stale_shape.struct_size = @sizeOf(Promise) - 4;
    try testing.expectEqual(Status.invalid, promise(lits, &stale_shape));
    try testing.expectEqual(Status.invalid, promise(lits, null));

    // A place this build does not define, a verdict slot it cannot write, and a
    // buffer promised but not given.
    var grade: u32 = 0;
    var written: usize = 0;
    var buf: [4]rows.Text = undefined;
    try testing.expectEqual(Status.invalid, set(lits, Place.count, &grade, &buf, buf.len, &written));
    try testing.expectEqual(Status.invalid, set(lits, 0, null, &buf, buf.len, &written));
    try testing.expectEqual(Status.invalid, set(lits, 0, &grade, null, buf.len, &written));
    try testing.expectEqual(Status.invalid, set(lits, 0, &grade, &buf, buf.len, null));
    try testing.expectEqual(Status.invalid, open(null, null));

    // PCRE2 has no AST here — a declinature, and it installs no fault.
    const pcre = try compiled("(?<=a)b", contract.flag_pcre);
    defer pat.free(pcre);
    var declined: *Literals = undefined;
    try testing.expectEqual(Status.stale, open(pcre, &declined));
    try testing.expectEqual(contract.Disposition.declinature, Status.stale.disposition());
}

test "literal analysis: a truncated read still reports the true total" {
    const re = try compiled("alpha|bravo|charlie", 0);
    defer pat.free(re);
    const lits = try analyzed(re);
    defer free(lits);

    var one: [1]rows.Text = undefined;
    var grade: u32 = 0;
    var written: usize = 0;
    try testing.expectEqual(Status.match, set(lits, @intFromEnum(Place.required), &grade, &one, 1, &written));
    // Three literals, room for one, and the host is told three.
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqualStrings("alpha", one[0].slice());
    try testing.expectEqual(@intFromEnum(Verdict.candidate), grade);
}

test "literal analysis: fold orbits are closed and mutually consistent" {
    // Independent oracle: Unicode's own published equivalences. K / k / KELVIN
    // SIGN are one orbit and ſ / s / S is another — facts about Unicode, not
    // about this table.
    var buf: [8]u32 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Status.match, foldOrbit('k', &buf, buf.len, &written));
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(@as(u32, 'k'), buf[0]);
    for ([_]u32{ 'K', 0x212A }) |want| {
        try testing.expect(std.mem.indexOfScalar(u32, buf[0..written], want) != null);
    }

    try testing.expectEqual(Status.match, foldOrbit(0x17F, &buf, buf.len, &written));
    for ([_]u32{ 0x17F, 's', 'S' }) |want| {
        try testing.expect(std.mem.indexOfScalar(u32, buf[0..written], want) != null);
    }

    // Symmetry over the whole table: an orbit is an equivalence class, so every
    // member must name every other. A one-way entry would silently fold one
    // spelling of a word and not its twin.
    var probe: [16]u32 = undefined;
    var back: [16]u32 = undefined;
    var seen: usize = 0;
    var cp: u32 = 0;
    while (cp <= 0xFFFF) : (cp += 1) {
        if (foldOrbit(cp, &probe, probe.len, &seen) != .match) continue;
        if (seen == 1) continue;
        try testing.expect(seen <= probe.len);
        for (probe[1..seen]) |member| {
            var n: usize = 0;
            try testing.expectEqual(Status.match, foldOrbit(member, &back, back.len, &n));
            try testing.expect(std.mem.indexOfScalar(u32, back[0..n], cp) != null);
        }
    }

    // A scalar that folds only to itself is still a one-member answer, never an
    // empty one that a host would have to interpret.
    try testing.expectEqual(Status.match, foldOrbit('7', &buf, buf.len, &written));
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u32, '7'), buf[0]);
    try testing.expectEqual(Status.invalid, foldOrbit(max_scalar + 1, &buf, buf.len, &written));
}

test "literal analysis: property membership agrees with the engine's own class" {
    // The independent oracle is the whole regex pipeline: parse `\p{NAME}`,
    // compile it, and match the codepoint's UTF-8. Every step is a different
    // implementation from the binary search this verb runs.
    const cases = [_]struct { name: []const u8, cp: u21 }{
        .{ .name = "Lu", .cp = 'A' },      .{ .name = "Lu", .cp = 'a' },
        .{ .name = "Ll", .cp = 'a' },      .{ .name = "L", .cp = 0x3B1 },
        .{ .name = "Nd", .cp = '7' },      .{ .name = "Nd", .cp = 'x' },
        .{ .name = "Greek", .cp = 0x3B1 }, .{ .name = "Greek", .cp = 'a' },
        .{ .name = "Letter", .cp = 'q' },  .{ .name = "gc=Nd", .cp = '3' },
        .{ .name = "Any", .cp = 0x1F600 }, .{ .name = "Cyrillic", .cp = 0x410 },
    };
    for (cases) |c| {
        var src: [32]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&src, "^\\p{{{s}}}$", .{c.name});
        const re = try compiled(pattern, 0);
        defer pat.free(re);

        var utf8: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(c.cp, &utf8);
        const engine = pat.isMatch(re, &utf8, n) == .match;
        try testing.expectEqual(engine, propertyHas(c.name.ptr, c.name.len, c.cp) == .match);
    }

    // The table read whole must answer the same question as the point read.
    var ranges: [4096]Range = undefined;
    var written: usize = 0;
    try testing.expectEqual(Status.match, propertyRanges("Nd", 2, &ranges, ranges.len, &written));
    try testing.expect(written > 0 and written <= ranges.len);
    var covered = false;
    for (ranges[0..written]) |r| {
        try testing.expect(r.lo <= r.hi);
        if ('7' >= r.lo and '7' <= r.hi) covered = true;
    }
    try testing.expect(covered);
    try testing.expectEqual(Status.match, propertyHas("Nd", 2, '7'));

    // Ranges arrive sorted and disjoint, which is what makes a host's own
    // binary search over them legal.
    for (ranges[1..written], ranges[0 .. written - 1]) |next, prev| {
        try testing.expect(next.lo > prev.hi);
    }

    // An unknown name is a fault, not an empty class.
    const nope = "NotAProperty";
    try testing.expectEqual(Status.invalid, propertyHas(nope.ptr, nope.len, 'a'));
    try testing.expectEqual(Status.invalid, propertyRanges(nope.ptr, nope.len, &ranges, ranges.len, &written));
    try testing.expectEqual(@as(usize, 0), written);
    try testing.expectEqual(Status.invalid, propertyRanges(null, 3, &ranges, ranges.len, &written));
}

test "literal analysis: the Unicode revision is nameable" {
    var got: rows.Text = undefined;
    try testing.expectEqual(Status.ok, unicodeVersion(&got));
    // A version a host can compare against its own tables: dotted digits.
    try testing.expect(got.len >= 3);
    for (got.slice()) |c| try testing.expect(std.ascii.isDigit(c) or c == '.');
    try testing.expectEqual(Status.invalid, unicodeVersion(null));
}
