// MONOLITHIC: live blast radius — the seed, dependents, dependencies, twins, ripple, and comment stages all derive from one on-demand corpus pass; readability depends on their co-location
//! blast radius — a live symbol neighborhood computed from current bytes.
//!
//! Answers "if I change SYMBOL, what else moves?" without a precomputed graph:
//! every edge is derived on demand from the corpus as it is RIGHT NOW, so a
//! file an agent is mid-edit is reflected the instant it is saved. The tiers
//! compose the kernel's existing strengths — exact word-bounded search, the
//! parser-free def/use classifier, function-region extraction, and compression
//! kinship — into one bounded report, exact and statistical evidence kept in
//! separate fields (the compose-face covenant: never a single fused score):
//!
//!   seed         — the symbol's definition site(s) and a byte-shape kind guess
//!   direct.dependents   — functions that reference the symbol (def/use marked)
//!   direct.dependencies — identifiers used INSIDE the seed's body, resolved to
//!                         their own definition sites (what the seed leans on)
//!   tangential.twins    — corpus-wide compression kin of the seed's file
//!                         (parallel-edit risk: near-duplicates move together)
//!   tangential.ripple   — second-hop callers of the seed's dependents (hops=2)
//!   comments     — doc / inline comments that MENTION the symbol: the stale-doc,
//!                  TODO, and invariant surface a change would falsify
//!
//! Pure kernel: no I/O, no argv. The caller loads the corpus and renders; every
//! allocation lands in the returned `Report`'s arena, freed by `deinit`.

const std = @import("std");
const patterns = @import("../slate/patterns.zig");
const regions = @import("regions.zig");
const spans = @import("../anatomy/spans.zig");
const lexspan = @import("../anatomy/lexspan.zig");
const leans = @import("../anatomy/leans.zig");
const signals = @import("../rank/signals.zig");
const sketch = @import("../kinship/metric/sketch.zig");
const query = @import("../query/query.zig");

/// Output caps — the report is bounded by construction so an agent's context is
/// never flooded. The driver may trim further with a token `--budget`.
pub const Options = struct {
    max_dependents: usize = 40,
    max_dependencies: usize = 24,
    max_twins: usize = 5,
    max_ripple: usize = 20,
    max_comments: usize = 20,
    /// Compression distance under which a corpus file is a "twin" of the seed
    /// file (1 − Jaccard over LZ78 phrase sketches; ≤ 0.25 near-duplicate,
    /// ≤ 0.55 same-thing-drifted). Above this, kinship is style not substance.
    twin_max_distance: f64 = 0.55,
    /// Enclosing-function names sampled from the dependents to seed the ripple
    /// (second-hop) scan. Bounds the PatternSet the ripple pass compiles.
    ripple_seed_names: usize = 12,
};

/// A byte-shape guess at what the seed is, from its definition line — a hint,
/// never a parse (the def/use classifier is already parser-free).
pub const Kind = enum { function, type, value, unknown };

pub const Site = struct { doc: u32, line: u32 };

/// A function that references the seed. `enclosing` is its header headline
/// (empty for a top-level reference); `defines` marks a reference that is
/// itself a (re)definition of the seed rather than a use.
pub const Dependent = struct { doc: u32, line: u32, enclosing: []const u8, defines: bool };

/// An identifier the seed's body leans on, resolved to its own definition site
/// — extracted and homed by `leans.zig`, which owns the precision discipline
/// (own bindings excluded, package boundary respected, members resolved inside
/// the module their qualifier names).
pub const Dependency = leans.Dependency;

/// A corpus file structurally kin to the seed's file (parallel-edit risk).
pub const Twin = struct { doc: u32, distance: f64 };

/// A second-hop file: it references `via` (one of the seed's dependents), so a
/// change rippling through that dependent can reach here (hops = 2).
pub const Ripple = struct { doc: u32, via: []const u8 };

/// A comment that mentions the seed — the stale-doc / TODO / invariant surface.
pub const Comment = struct { doc: u32, line: u32, text: []const u8 };

pub const Stats = struct {
    files_scanned: usize = 0,
    files_with_symbol: usize = 0,
    dependents_total: usize = 0,
    dependencies_total: usize = 0,
    comments_total: usize = 0,
    twins_total: usize = 0,
    ripple_total: usize = 0,
    omitted: usize = 0,
    short_name: bool = false,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    symbol: []const u8,
    kind: Kind,
    def: []const Site,
    dependents: []const Dependent,
    dependencies: []const Dependency,
    twins: []const Twin,
    ripple: []const Ripple,
    comments: []const Comment,
    stats: Stats,
    notes: []const []const u8,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }
};

/// Common single/multi-character identifiers whose blast radius is the whole
/// tree — flagged low-confidence so the report says so rather than flooding.
const common_names = std.StaticStringMap(void).initComptime(.{
    .{"run"},  .{"get"},  .{"set"},  .{"new"},  .{"add"},  .{"put"}, .{"has"},
    .{"key"},  .{"val"},  .{"out"},  .{"err"},  .{"ok"},   .{"id"},  .{"name"},
    .{"data"}, .{"item"}, .{"self"}, .{"this"}, .{"init"}, .{"len"}, .{"idx"},
    .{"tmp"},  .{"buf"},  .{"ctx"},  .{"res"},  .{"req"},  .{"do"},
});

/// Generic method / verb names whose bare-name call sites collide across every
/// unrelated type in the tree — useless as a ripple bridge because `deinit(` or
/// `compile(` matches hundreds of unrelated implementations. Filtered from the
/// ripple seed set so a second-hop row means a genuinely distinctive caller.
const generic_methods = std.StaticStringMap(void).initComptime(.{
    .{"init"},   .{"deinit"}, .{"compile"}, .{"parse"},  .{"build"},  .{"format"},
    .{"write"},  .{"read"},   .{"next"},    .{"close"},  .{"open"},   .{"free"},
    .{"clone"},  .{"hash"},   .{"reset"},   .{"clear"},  .{"append"}, .{"scratch"},
    .{"encode"}, .{"decode"}, .{"load"},    .{"store"},  .{"count"},  .{"value"},
    .{"items"},  .{"slice"},  .{"update"},  .{"insert"}, .{"remove"}, .{"resolve"},
});

/// Compute the blast radius of `symbol` over the loaded corpus (`docs`/`paths`,
/// parallel slices; `paths` selects language for region extraction). Pure — the
/// result owns its own arena.
pub fn compute(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    symbol: []const u8,
    opts: Options,
) !Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var stats: Stats = .{ .files_scanned = docs.len, .short_name = isShort(symbol) };
    var notes: std.ArrayList([]const u8) = .empty;
    if (stats.short_name) try notes.append(a, "short/common name — dependents may be broad; prefer a qualified form");

    var def: std.ArrayList(Site) = .empty;
    var comments: std.ArrayList(Comment) = .empty;

    // Pass A — one gated line scan: definition sites, comment mentions, and the
    // total code-reference count, all classified by the parser-free confidence
    // signal and the comment mask (so a mention in a string is neither).
    for (docs, paths, 0..) |doc, path, d| {
        if (std.mem.indexOf(u8, doc, symbol) == null) continue; // cheap literal gate
        stats.files_with_symbol += 1;
        // Only a source file can declare anything: prose and data files are read
        // for mentions alone, so a changelog sentence or a spec table cannot pose
        // as the symbol's home the way a `name type` pair otherwise would.
        const declarable = isSourcePath(path);
        const mask = try lexspan.commentMask(a, doc);
        var seen_comment_line: u32 = 0;
        var seen_def_line: u32 = 0;
        var pos: usize = 0;
        while (nextWord(doc, symbol, pos)) |p| : (pos = p + symbol.len) {
            const ls = lineStart(doc, p);
            const le = lineEnd(doc, p);
            const lineno = spans.lineAt(doc, p);
            if (mask[p]) {
                if (lineno != seen_comment_line and comments.items.len < opts.max_comments) {
                    try comments.append(a, .{ .doc = @intCast(d), .line = lineno, .text = trimDup(a, doc[ls..le]) });
                }
                seen_comment_line = lineno;
                stats.comments_total += 1;
            } else if (declarable and lineno != seen_def_line and
                signals.declarationConfidence(defWindow(doc, ls, le), symbol) > 0)
            {
                // One def row per line: repeated hits on a signature (a return
                // type AND a parameter of the same name) are one definition.
                try def.append(a, .{ .doc = @intCast(d), .line = lineno });
                seen_def_line = lineno;
            }
        }
    }

    // Kind from the STRONGEST definition line, not the first: a `pub const X =
    // struct {` outranks an incidental `const X = other.X` alias in a test, so
    // the guess reflects the real declaration wherever it sits in corpus order.
    const kind = strongestKind(docs, def.items);

    // Pass B — dependents at function granularity. A word-bounded PatternSet
    // drives `regions.select`, so each row is a whole function that references
    // the seed (repeated hits in one function collapse to one row); its hit
    // line is classified def-vs-use by the same confidence signal.
    var wset = try patterns.wordSet(a, &.{symbol});
    const source = try sourceView(a, docs, paths);
    var picked = try regions.select(a, source, &wset, .function, 0);
    defer picked.deinit();
    stats.dependents_total = picked.items.len;

    var dependents: std.ArrayList(Dependent) = .empty;
    for (picked.items) |r| {
        if (dependents.items.len >= opts.max_dependents) break;
        const hit_line = docs[r.doc][lineStart(docs[r.doc], r.match_start)..lineEnd(docs[r.doc], r.match_start)];
        try dependents.append(a, .{
            .doc = r.doc,
            .line = spans.lineAt(docs[r.doc], r.match_start),
            .enclosing = funcName(headline(a, docs[r.doc], r) catch ""),
            .defines = signals.declarationConfidence(hit_line, symbol) > 0,
        });
    }

    // Direct dependencies — identifiers used inside the seed's function body,
    // resolved to their own definition sites. Only meaningful when the seed is
    // itself a function; a type/value has no body to lean on anything, so the
    // pass is skipped entirely (never counted into stats, so the emitted rows
    // and `dependencies_total` can never disagree). The `source` view is passed
    // rather than raw docs so a non-source file is never a resolution target.
    const dependencies: []const Dependency = if (kind == .function) deps: {
        const seed = seedRegion(docs, symbol, picked.items, def.items) orelse break :deps &.{};
        const found = try leans.resolve(a, source, paths, seed.doc, docs[seed.doc][seed.start..seed.end], symbol, opts.max_dependencies);
        stats.dependencies_total = found.total;
        break :deps found.items;
    } else &.{};

    // Tangential twins — corpus-wide compression kin of the seed's file.
    const twins = if (def.items.len == 0) &[_]Twin{} else try computeTwins(a, gpa, docs, def.items[0].doc, dependents.items, opts, &stats);

    // Tangential ripple — second-hop callers of the seed's dependents, confined
    // to the seed's own language (a Zig `compile` is not called from a .py doc).
    const seed_path = if (def.items.len > 0) paths[def.items[0].doc] else if (dependents.items.len > 0) paths[dependents.items[0].doc] else "";
    const ripple = try computeRipple(a, docs, paths, spans.extensionOf(seed_path), dependents.items, symbol, opts, &stats);

    stats.omitted = (stats.dependents_total -| dependents.items.len) +
        (stats.dependencies_total -| dependencies.len) +
        (stats.comments_total -| comments.items.len) +
        (stats.twins_total -| twins.len) +
        (stats.ripple_total -| ripple.len);
    if (def.items.len == 0) try notes.append(a, "no definition site found — symbol may be external or a partial name");

    return .{
        .arena = arena,
        .symbol = try a.dupe(u8, symbol),
        .kind = kind,
        .def = try def.toOwnedSlice(a),
        .dependents = try dependents.toOwnedSlice(a),
        .dependencies = dependencies,
        .twins = twins,
        .ripple = ripple,
        .comments = try comments.toOwnedSlice(a),
        .stats = stats,
        .notes = try notes.toOwnedSlice(a),
    };
}

/// Corpus-wide compression kin of the seed file, closest first, excluding files
/// already surfaced as direct dependents (kept sections disjoint).
fn computeTwins(
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    seed_doc: u32,
    dependents: []const Dependent,
    opts: Options,
    stats: *Stats,
) ![]Twin {
    const anchor = sketch.build(gpa, docs[seed_doc]) catch return &[_]Twin{};
    var out: std.ArrayList(Twin) = .empty;
    for (docs, 0..) |doc, d| {
        if (d == seed_doc or doc.len == 0) continue;
        if (isDirect(dependents, @intCast(d))) continue;
        var other = sketch.build(gpa, doc) catch continue;
        const dist = sketch.distance(&anchor, &other);
        if (dist > opts.twin_max_distance) continue;
        stats.twins_total += 1;
        try out.append(a, .{ .doc = @intCast(d), .distance = dist });
    }
    std.mem.sort(Twin, out.items, {}, struct {
        fn less(_: void, x: Twin, y: Twin) bool {
            return x.distance < y.distance;
        }
    }.less);
    if (out.items.len > opts.max_twins) out.shrinkRetainingCapacity(opts.max_twins);
    return out.toOwnedSlice(a);
}

/// Second-hop callers: extract the seed's dependent function names, batch-scan
/// for files that reference them but are not already direct, and record the
/// bridging name. `via` is the dependent that connects the two hops.
fn computeRipple(
    a: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    seed_ext: []const u8,
    dependents: []const Dependent,
    symbol: []const u8,
    opts: Options,
    stats: *Stats,
) ![]Ripple {
    var names: std.ArrayList([]const u8) = .empty;
    var direct_docs: std.ArrayList(u32) = .empty;
    for (dependents) |dep| {
        try appendUnique(a, &direct_docs, dep.doc);
        if (names.items.len >= opts.ripple_seed_names) continue;
        const nm = dep.enclosing; // already the enclosing function's name
        // A bridge name must be distinctive: skip the seed itself, short/common
        // names, and generic method verbs (deinit/compile/len/…) whose bare-name
        // call sites collide across every unrelated type in the tree.
        if (nm.len < 4 or std.mem.eql(u8, nm, symbol) or common_names.has(nm) or generic_methods.has(nm)) continue;
        try appendUniqueStr(a, &names, nm);
    }
    if (names.items.len == 0) return &[_]Ripple{};

    // Call-shaped patterns (`\bNAME\s*\(`), not bare word mentions: a second-hop
    // file earns a ripple row only where it CALLS the bridging function, so a
    // prose "compile" in a shell script or a docstring never counts as a caller.
    var wset = try callSet(a, names.items);
    defer wset.deinit(a);
    var scratch = try wset.scratch(a);
    defer scratch.deinit(a);
    const mask = try a.alloc(u64, patterns.maskWords(wset.len()));

    var out: std.ArrayList(Ripple) = .empty;
    var seen: std.ArrayList(u32) = .empty;
    for (docs, paths, 0..) |doc, path, d| {
        if (containsAny(direct_docs.items, @intCast(d))) continue;
        if (seed_ext.len > 0 and !std.mem.endsWith(u8, path, seed_ext)) continue; // same-language
        if (!isSourcePath(path)) continue;
        if (!wset.docMask(doc, &scratch, mask)) continue;
        const which = firstSet(mask, names.items.len) orelse continue;
        stats.ripple_total += 1;
        if (containsAny(seen.items, @intCast(d))) continue;
        try seen.append(a, @intCast(d));
        if (out.items.len < opts.max_ripple) try out.append(a, .{ .doc = @intCast(d), .via = names.items[which] });
    }
    return out.toOwnedSlice(a);
}

// ── shared helpers ───────────────────────────────────────────────────────────

fn isShort(symbol: []const u8) bool {
    return symbol.len < 3 or common_names.has(symbol);
}

/// A call-shaped PatternSet over `names`: each becomes `\bNAME\s*\(`, matching a
/// CALL site (`name(` / `name (`) rather than any mention — so the ripple pass
/// counts genuine second-hop callers, not a prose word that happens to be a
/// function name elsewhere in the tree.
fn callSet(a: std.mem.Allocator, names: []const []const u8) !patterns.PatternSet {
    const specs = try a.alloc(patterns.Spec, names.len);
    for (names, specs) |nm, *s| {
        const esc = try query.escapeLiteral(a, nm);
        s.* = .{ .pattern = try std.fmt.allocPrint(a, "\\b{s}\\s*\\(", .{esc}), .fixed = false };
    }
    return patterns.PatternSet.compile(a, specs);
}

/// The most specific declaration kind across all definition lines: a real
/// type/function declaration outranks an incidental `const alias = …` so the
/// seed's kind reflects its true nature even when a weaker line sorts first.
fn strongestKind(docs: []const []const u8, def_sites: []const Site) Kind {
    var best = Kind.unknown;
    for (def_sites) |s| {
        const k = kindOf(lineTextAt(docs, s));
        best = switch (k) {
            .type => return .type, // nothing outranks a type declaration
            .function => .function,
            .value => if (best == .function) best else .value,
            .unknown => best,
        };
    }
    return best;
}

/// A per-doc view that blanks non-source files to "" so `regions.select` walks
/// only real code (its language table already yields nothing for other files,
/// but blanking skips the walk entirely).
fn sourceView(a: std.mem.Allocator, docs: []const []const u8, paths: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, docs.len);
    for (docs, paths, out) |doc, path, *dst| dst.* = if (isSourcePath(path)) doc else "";
    return out;
}

/// The seed's enclosing function region: the picked region holding the
/// STRONGEST definition site, for the same reason `strongestKind` reads every
/// line. Corpus order is alphabetical, so first-wins hands the body to whatever
/// weak declaration shape sorts earliest — a component's `pgvector recall
/// tester` reads as a bare `name type` pair and would outrank the real
/// `def recall(…)` further down the tree. Ties keep corpus order.
fn seedRegion(
    docs: []const []const u8,
    symbol: []const u8,
    picked: []const regions.Region,
    def_sites: []const Site,
) ?regions.Region {
    var best: ?regions.Region = null;
    var strength: u8 = 0;
    for (def_sites) |s| {
        for (picked) |r| {
            if (r.doc != s.doc or s.line < r.line_start or s.line > r.line_end) continue;
            const confidence = signals.declarationConfidence(defWindowAt(docs, s), symbol);
            if (best == null or confidence > strength) {
                best = r;
                strength = confidence;
            }
            break;
        }
        if (strength == 3) break; // nothing outranks a body-bearing declaration
    }
    return best;
}

/// The name a function header introduces: the identifier after an fn/func/def/
/// function keyword, else the one immediately before `(`. "" when neither reads.
/// A `test "…"` header names no callable function — its `(` lives inside the
/// description string — so it returns "" rather than a word from the prose.
fn funcName(head: []const u8) []const u8 {
    const kw = [_][]const u8{ "fn ", "func ", "function ", "def " };
    for (kw) |k| if (std.mem.indexOf(u8, head, k)) |at| {
        const rest = std.mem.trimStart(u8, head[at + k.len ..], " \t");
        return identPrefix(rest);
    };
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, head, " \t"), "test ")) return "";
    if (std.mem.indexOfScalar(u8, head, '(')) |lp| {
        // A quote before the `(` means the paren is inside a string, not a call
        // head (e.g. a test/describe label) — no reliable name to read.
        if (std.mem.indexOfScalar(u8, head[0..lp], '"') != null) return "";
        var e = lp;
        while (e > 0 and (head[e - 1] == ' ' or head[e - 1] == '\t')) e -= 1;
        var s = e;
        while (s > 0 and isIdentByte(head[s - 1])) s -= 1;
        if (s < e and isIdentStart(head[s])) return head[s..e];
    }
    return "";
}

fn identPrefix(s: []const u8) []const u8 {
    if (s.len == 0 or !isIdentStart(s[0])) return "";
    var e: usize = 0;
    while (e < s.len and isIdentByte(s[e])) e += 1;
    return s[0..e];
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The next word-bounded occurrence of `needle` in `hay` at/after `from`
/// (ASCII word chars — identifiers), or null. Bounds keep `run` out of `runner`.
fn nextWord(hay: []const u8, needle: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |p| : (i = p + 1) {
        const before_ok = p == 0 or !isIdentByte(hay[p - 1]);
        const after = p + needle.len;
        const after_ok = after >= hay.len or !isIdentByte(hay[after]);
        if (before_ok and after_ok) return p;
    }
    return null;
}

fn kindOf(line: []const u8) Kind {
    const t = std.mem.trimStart(u8, line, " \t");
    if (contains(t, "fn ") or contains(t, "func ") or contains(t, "function ") or contains(t, "def ")) return .function;
    if (contains(t, "struct") or contains(t, "class") or contains(t, "interface") or
        contains(t, "enum") or contains(t, "trait") or contains(t, "type ")) return .type;
    if (contains(t, "const") or contains(t, "let ") or contains(t, "var ") or contains(t, "=")) return .value;
    return .unknown;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// The first code (non-comment) line of a region — its human header.
fn headline(a: std.mem.Allocator, doc: []const u8, r: regions.Region) ![]const u8 {
    var start = r.start;
    while (start < r.end) {
        const end = std.mem.indexOfScalarPos(u8, doc, start, '\n') orelse r.end;
        const line = std.mem.trim(u8, doc[start..@min(end, r.end)], " \t\r");
        if (line.len > 0 and !lexspan.commentOnly(line)) return a.dupe(u8, line);
        start = @min(end + 1, r.end);
    }
    return "";
}

fn lineStart(bytes: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..@min(at, bytes.len)], '\n')) |p| p + 1 else 0;
}
fn lineEnd(bytes: []const u8, at: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, bytes, @min(at, bytes.len), '\n')) |p| p else bytes.len;
}

/// The logical definition line starting at `ls`. A single physical line is
/// enough for most declarations, but a wrapped signature (`fn f(\n a,\n b,\n)
/// !T {`) leaves the def line with an open `(` and no body, so the shared
/// parser-free confidence signal reads it as a plain use. When the line opens
/// more parens than it closes, this joins continuation lines until the parens
/// balance (plus the body-opening line), bounded to keep the scan cheap — so
/// declarationConfidence sees the whole signature and scores it as a def.
fn defWindow(doc: []const u8, ls: usize, le: usize) []const u8 {
    var depth: i32 = 0;
    for (doc[ls..le]) |c| {
        if (c == '(') depth += 1 else if (c == ')') depth -= 1;
    }
    if (depth <= 0) return doc[ls..le];
    const cap = @min(doc.len, ls + 800); // ≤ ~16 wrapped lines
    var end = le;
    while (end < cap) {
        const nl = std.mem.indexOfScalarPos(u8, doc, end, '\n') orelse cap;
        for (doc[end..nl]) |c| {
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
        }
        end = @min(nl + 1, cap);
        if (depth <= 0) break; // params closed; this line carries the body opener
    }
    return doc[ls..end];
}

fn lineTextAt(docs: []const []const u8, s: Site) []const u8 {
    const doc = docs[s.doc];
    const start = lineStartOf(doc, s.line) orelse return "";
    return doc[start..lineEnd(doc, start)];
}

/// The window Pass A classified when it recorded this site, so re-reading a
/// site's strength can never disagree with the read that admitted it.
fn defWindowAt(docs: []const []const u8, s: Site) []const u8 {
    const doc = docs[s.doc];
    const start = lineStartOf(doc, s.line) orelse return "";
    return defWindow(doc, start, lineEnd(doc, start));
}

fn lineStartOf(doc: []const u8, line: u32) ?usize {
    var at: usize = 0;
    var n: u32 = 1;
    while (n < line) : (n += 1) {
        at = (std.mem.indexOfScalarPos(u8, doc, at, '\n') orelse return null) + 1;
    }
    return at;
}

fn trimDup(a: std.mem.Allocator, line: []const u8) []const u8 {
    return a.dupe(u8, std.mem.trim(u8, line, " \t\r\n")) catch "";
}

fn isDirect(dependents: []const Dependent, d: u32) bool {
    for (dependents) |dep| if (dep.doc == d) return true;
    return false;
}
fn containsAny(list: []const u32, d: u32) bool {
    for (list) |x| if (x == d) return true;
    return false;
}
fn appendUnique(a: std.mem.Allocator, list: *std.ArrayList(u32), d: u32) !void {
    if (!containsAny(list.items, d)) try list.append(a, d);
}
fn appendUniqueStr(a: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
    try list.append(a, s);
}
fn firstSet(mask: []const u64, n: usize) ?usize {
    for (0..n) |i| if (patterns.maskHas(mask, i)) return i;
    return null;
}

fn isSourcePath(path: []const u8) bool {
    const exts = [_][]const u8{
        ".c",  ".cc",  ".cpp", ".cxx", ".ex",    ".exs", ".go",  ".h",     ".hpp", ".java",
        ".js", ".jsx", ".kt",  ".kts", ".m",     ".mm",  ".php", ".proto", ".py",  ".pyx",
        ".rb", ".rs",  ".sh",  ".sql", ".swift", ".ts",  ".tsx", ".zig",
    };
    for (exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

test "blast finds def, dependents, dependencies, and comment mentions" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\// Target orchestrates the widget flow.
        \\pub fn Target(x: u32) u32 {
        \\    return helper(x);
        \\}
        \\fn helper(v: u32) u32 {
        \\    return v + 1;
        \\}
        ,
        \\fn caller() u32 {
        \\    return Target(3);
        \\}
    };
    const paths = [_][]const u8{ "a.zig", "b.zig" };
    var report = try compute(gpa, &docs, &paths, "Target", .{});
    defer report.deinit();

    try std.testing.expectEqual(Kind.function, report.kind);
    try std.testing.expect(report.def.len >= 1);
    try std.testing.expectEqual(@as(u32, 2), report.def[0].line);

    // caller() is a dependent (references Target); the def function is too.
    var saw_caller = false;
    for (report.dependents) |dep| if (dep.doc == 1) {
        saw_caller = true;
    };
    try std.testing.expect(saw_caller);

    // helper is a dependency (used inside Target's body, defined elsewhere).
    var saw_helper = false;
    for (report.dependencies) |dep| if (std.mem.eql(u8, dep.symbol, "helper")) {
        saw_helper = true;
    };
    try std.testing.expect(saw_helper);

    // The doc comment mentioning Target is captured as a comment, not a dependent.
    try std.testing.expect(report.comments.len >= 1);
}

test "short-name guard flags common identifiers" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{"fn run() void {}"};
    const paths = [_][]const u8{"a.zig"};
    var report = try compute(gpa, &docs, &paths, "run", .{});
    defer report.deinit();
    try std.testing.expect(report.stats.short_name);
    try std.testing.expect(report.notes.len >= 1);
}

test "kind reflects the strongest definition, not corpus order" {
    const gpa = std.testing.allocator;
    // The alias line sorts first, but the real struct declaration must win.
    const docs = [_][]const u8{
        "const Widget = other.Widget;",
        "pub const Widget = struct {\n    x: u32,\n};",
    };
    const paths = [_][]const u8{ "alias.zig", "def.zig" };
    var report = try compute(gpa, &docs, &paths, "Widget", .{});
    defer report.deinit();
    try std.testing.expectEqual(Kind.type, report.kind);
}

test "a wrapped multi-line signature is still recognized as a definition" {
    const gpa = std.testing.allocator;
    // The seed's signature wraps one parameter per line, so its def line ends
    // in an open `(` with no body — the exact shape that reads as a plain use
    // unless the logical signature is rejoined. The caller on the last doc is a
    // dependent that references it.
    const docs = [_][]const u8{
        \\fn wideSignature(
        \\    first: u32,
        \\    second: u32,
        \\    third: u32,
        \\) u32 {
        \\    return first + second + third;
        \\}
        ,
        \\fn caller() u32 {
        \\    return wideSignature(1, 2, 3);
        \\}
    };
    const paths = [_][]const u8{ "wide.zig", "call.zig" };
    var report = try compute(gpa, &docs, &paths, "wideSignature", .{});
    defer report.deinit();

    try std.testing.expectEqual(Kind.function, report.kind);
    try std.testing.expect(report.def.len >= 1);
    try std.testing.expectEqual(@as(u32, 1), report.def[0].line);
}

test "the body comes from the strongest definition, not the first in corpus order" {
    const gpa = std.testing.allocator;
    // A component's copy reads as a bare `name type` pair — the weakest shape
    // that still declares in some syntax families — and sorts first. The real
    // function further down must own the body, or the dependencies reported are
    // the neighboring words of a sentence.
    const docs = [_][]const u8{
        \\export function Panel() {
        \\  return (
        \\    <div>
        \\      pgvector recall tester
        \\    </div>
        \\  )
        \\}
        ,
        \\def recall(query, limit):
        \\    return ranker(query, limit)
        ,
        \\def ranker(query, limit):
        \\    return []
    };
    const paths = [_][]const u8{ "a/ui/Panel.tsx", "z/engine.py", "z/ranker.py" };
    var report = try compute(gpa, &docs, &paths, "recall", .{});
    defer report.deinit();

    var saw_words = false;
    var saw_ranker = false;
    for (report.dependencies) |dep| {
        if (std.mem.eql(u8, dep.symbol, "tester") or std.mem.eql(u8, dep.symbol, "pgvector")) saw_words = true;
        if (std.mem.eql(u8, dep.symbol, "ranker")) saw_ranker = true;
    }
    try std.testing.expect(!saw_words);
    try std.testing.expect(saw_ranker);
}

test "prose and data files are mentioned, never definitions" {
    const gpa = std.testing.allocator;
    // A definition list in prose and a key in a spec both wear shapes the
    // confidence signal reads as declarations — `name:` and `name =` — and both
    // sort before the code that actually declares the symbol.
    const docs = [_][]const u8{
        "ledger: the append-only wallet log\n",
        "ledger = \"charges\"\n",
        "fn ledger() u32 {\n    return 1;\n}",
    };
    const paths = [_][]const u8{ "docs/wallet.md", "spec/wallet.socket", "z/wallet.zig" };
    var report = try compute(gpa, &docs, &paths, "ledger", .{});
    defer report.deinit();

    try std.testing.expect(report.def.len >= 1);
    for (report.def) |site| try std.testing.expectEqual(@as(u32, 2), site.doc);
}

test "a type seed reports no dependencies, and stats never disagree with the slice" {
    const gpa = std.testing.allocator;
    // A struct type with a constructor whose body leans on `helper` — a naive
    // pass would resolve `helper` as a "dependency" of the type and count it in
    // stats while the driver blanks the slice, so stats.dependencies_total and
    // the emitted array must both be zero for a non-function seed.
    const docs = [_][]const u8{
        "pub const Thing = struct {\n    x: u32,\n    pub fn make() Thing {\n        return .{ .x = helper() };\n    }\n};\nfn helper() u32 {\n    return 7;\n}",
    };
    const paths = [_][]const u8{"a.zig"};
    var report = try compute(gpa, &docs, &paths, "Thing", .{});
    defer report.deinit();

    try std.testing.expectEqual(Kind.type, report.kind);
    try std.testing.expectEqual(@as(usize, 0), report.dependencies.len);
    try std.testing.expectEqual(@as(usize, 0), report.stats.dependencies_total);
}

test "ripple counts only same-language call sites, never prose or foreign files" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        "fn Sigil() u32 {\n    return 0;\n}\nfn widgetFlow(x: u32) u32 {\n    return Sigil() + x;\n}", // defines Sigil + a distinctive dependent
        "fn topLevel() u32 {\n    return widgetFlow(2);\n}", // second-hop caller of widgetFlow
        "widgetFlow is a great function to read about.", // prose mention, wrong language
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.md" };
    var report = try compute(gpa, &docs, &paths, "Sigil", .{});
    defer report.deinit();

    var saw_caller = false;
    for (report.ripple) |rp| {
        try std.testing.expect(!std.mem.eql(u8, paths[rp.doc], "c.md")); // prose/foreign never ripples
        if (std.mem.eql(u8, paths[rp.doc], "b.zig")) {
            saw_caller = true;
            try std.testing.expectEqualStrings("widgetFlow", rp.via);
        }
    }
    try std.testing.expect(saw_caller);
}
