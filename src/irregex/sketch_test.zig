//! irregex sketch — adversarial tests for the compression-kinship primitive.
//!
//! The contract under test is the DISTANCE's semantics, not the parse's
//! internals: identity → 0, disjoint → ~1, symmetry, determinism, robustness
//! to edits (a small edit moves the distance a little, not to 1), and the
//! load-bearing claim from the source papers — bytes cluster by KIND. The
//! fixtures are embedded (never the live tree) so the suite is deterministic
//! under ~10 agents editing the checkout concurrently.

const std = @import("std");
const sketch = @import("sketch.zig");
const Sketch = sketch.Sketch;

const gpa = std.testing.allocator;

// ── deterministic fixture text, embedded ──
// Two "languages": Zig-flavored and Python-flavored source, two samples each,
// plus an English prose sample. Kinship must pair like with like.

// NOTE on fixture size: the kinship signal is statistical — an LZ78
// dictionary over a few hundred bytes is mostly single-character phrases and
// carries no style. The source papers operate on kilobyte-scale texts; these
// fixtures are sized to match (~1 KiB each), DIFFERENT in content within a
// language, alike only in the language's own idiom.

const zig_a =
    \\const std = @import("std");
    \\
    \\pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Sketch {
    \\    var seen = try PhraseSet.init(gpa, bytes.len / 8);
    \\    defer seen.deinit(gpa);
    \\    var low: BottomK = .init;
    \\    var h: u64 = fnv_offset;
    \\    for (bytes) |b| {
    \\        h = (h ^ b) *% fnv_prime;
    \\        if (try seen.insert(gpa, h)) {
    \\            low.offer(finalize(h));
    \\            h = fnv_offset;
    \\        }
    \\    }
    \\    var out = Sketch.empty;
    \\    out.len = low.len;
    \\    @memcpy(out.h[0..low.len], low.heap[0..low.len]);
    \\    std.mem.sort(u64, out.h[0..out.len], {}, comptime std.sort.asc(u64));
    \\    return out;
    \\}
    \\
    \\test "sketch is deterministic" {
    \\    const a = try build(std.testing.allocator, "abc");
    \\    const b = try build(std.testing.allocator, "abc");
    \\    try std.testing.expectEqualSlices(u64, a.slots(), b.slots());
    \\}
;

const zig_b =
    \\const std = @import("std");
    \\
    \\pub fn load(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !Corpus {
    \\    var arena = std.heap.ArenaAllocator.init(gpa);
    \\    const a = arena.allocator();
    \\    var docs: std.ArrayList([]const u8) = .empty;
    \\    var paths: std.ArrayList([]const u8) = .empty;
    \\    var total: u64 = 0;
    \\    for (roots) |root_path| {
    \\        var w = haystack.Walker.init(io, a, root_path) catch |e| {
    \\            std.debug.print("  skip {s}: {s}\n", .{ root_path, @errorName(e) });
    \\            continue;
    \\        };
    \\        defer w.deinit(io);
    \\        while (try w.next(io)) |hay| {
    \\            const buf = hay.dir.readFileAlloc(io, hay.name, a, .limited(cap)) catch continue;
    \\            if (buf.len == 0 or isBinary(buf)) continue;
    \\            try docs.append(a, buf);
    \\            try paths.append(a, hay.path);
    \\            total += buf.len;
    \\        }
    \\    }
    \\    return .{ .docs = docs.items, .paths = paths.items, .bytes = total, .arena = arena };
    \\}
;

const py_a =
    \\import pathlib
    \\from collections import defaultdict
    \\
    \\
    \\def candidate_files(repo: pathlib.Path, literals: list[str]) -> list[str]:
    \\    """One batched scan; the caller re-classifies per literal."""
    \\    rows = [
    \\        rel.removeprefix("./")
    \\        for rel in scan(repo, literals).split("\0")
    \\        if rel and not rel.startswith(".git/")
    \\    ]
    \\    return sorted(set(rows))
    \\
    \\
    \\def classify(rows: list[str], literals: list[str]) -> dict[str, list[str]]:
    \\    """Group candidate paths by the literal that implicated them."""
    \\    hits: dict[str, list[str]] = defaultdict(list)
    \\    for row in rows:
    \\        for needle in literals:
    \\            if needle in row:
    \\                hits[needle].append(row)
    \\    return {needle: sorted(found) for needle, found in hits.items()}
    \\
    \\
    \\def main(argv: list[str]) -> int:
    \\    repo = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path.cwd()
    \\    for needle, found in classify(candidate_files(repo, argv[2:]), argv[2:]).items():
    \\        print(f"{needle}: {len(found)} files")
    \\    return 0
;

const py_b =
    \\import dataclasses
    \\import json
    \\import urllib.request
    \\from collections import Counter
    \\
    \\
    \\@dataclasses.dataclass(frozen=True)
    \\class LogRow:
    \\    """One structured log record from the VictoriaLogs tail endpoint."""
    \\
    \\    stream: str
    \\    level: str
    \\    message: str
    \\
    \\
    \\def fetch_rows(base_url: str, query: str, limit: int = 200) -> list[LogRow]:
    \\    """Pull up to *limit* rows for *query*, newest first."""
    \\    params = urllib.parse.urlencode({"query": query, "limit": limit})
    \\    with urllib.request.urlopen(f"{base_url}/select/logsql/query?{params}") as resp:
    \\        payload = [json.loads(line) for line in resp.read().splitlines() if line]
    \\    return [
    \\        LogRow(
    \\            stream=row.get("_stream", ""),
    \\            level=row.get("level", "info"),
    \\            message=row.get("_msg", ""),
    \\        )
    \\        for row in payload
    \\    ]
    \\
    \\
    \\def summarize(rows: list[LogRow]) -> dict[str, int]:
    \\    """Count rows per level, error-heavy streams first."""
    \\    counts: Counter[str] = Counter(row.level for row in rows)
    \\    return dict(counts.most_common())
;

const prose =
    \\In this letter we present a very general method to extract information
    \\from a generic string of characters, based on data-compression techniques,
    \\whose key point is a suitable measure of the remoteness of two bodies of
    \\knowledge. The zipper learns the language and changes its rules. Suppose
    \\we take a long English text and we append to it an Italian sentence: the
    \\compression program will start reading the new file using the rules it
    \\has learned from English, and only gradually will it adapt to the new
    \\language. The length of the compressed appended part measures, in bits,
    \\how far the second language sits from the first — a distance one can use
    \\to build phylogenetic trees of languages, to attribute a disputed text to
    \\its author, and generally to classify any sequence of symbols for which
    \\a dictionary can be learned, with no prior knowledge of the domain.
;

fn dist(x: []const u8, y: []const u8) !f64 {
    var sx = try sketch.build(gpa, x);
    var sy = try sketch.build(gpa, y);
    return sketch.distance(&sx, &sy);
}

test "identity is zero; symmetry holds; range is [0,1]" {
    const fixtures = [_][]const u8{ zig_a, zig_b, py_a, py_b, prose };
    for (fixtures) |x| {
        try std.testing.expectEqual(@as(f64, 0.0), try dist(x, x));
        for (fixtures) |y| {
            const dxy = try dist(x, y);
            const dyx = try dist(y, x);
            try std.testing.expectEqual(dxy, dyx);
            try std.testing.expect(dxy >= 0.0 and dxy <= 1.0);
        }
    }
}

test "determinism: the same bytes always sketch identically" {
    var first = try sketch.build(gpa, zig_a);
    var again = try sketch.build(gpa, zig_a);
    try std.testing.expectEqualSlices(u64, first.slots(), again.slots());
}

test "kinship clusters by kind: every fixture's nearest neighbor shares its language" {
    // The paper's claim, as a fail-closed precision@1 gate over the embedded
    // corpus: for each sample, the closest OTHER sample must be its same-kind
    // sibling — zig pairs with zig, python with python.
    const corpus = [_]struct { text: []const u8, kind: u8 }{
        .{ .text = zig_a, .kind = 'z' },
        .{ .text = zig_b, .kind = 'z' },
        .{ .text = py_a, .kind = 'p' },
        .{ .text = py_b, .kind = 'p' },
        .{ .text = prose, .kind = 'e' },
    };
    var sketches: [corpus.len]Sketch = undefined;
    for (&sketches, corpus) |*s, c| s.* = try sketch.build(gpa, c.text);

    for (corpus, 0..) |c, i| {
        if (c.kind == 'e') continue; // prose has no sibling in this corpus
        var best: usize = undefined;
        var best_d: f64 = 2.0;
        for (corpus, 0..) |_, j| {
            if (j == i) continue;
            const d = sketch.distance(&sketches[i], &sketches[j]);
            if (d < best_d) {
                best_d = d;
                best = j;
            }
        }
        try std.testing.expectEqual(c.kind, corpus[best].kind);
    }
}

test "a small edit is a small move — never a cliff" {
    // Rename one identifier in zig_a; the edited text must stay far closer to
    // the original than to a different-language file.
    const edited = try std.mem.replaceOwned(u8, gpa, zig_a, "PhraseSet", "LexiconSet");
    defer gpa.free(edited);
    const d_self = try dist(zig_a, edited);
    const d_cross = try dist(zig_a, py_b);
    try std.testing.expect(d_self < d_cross);
    try std.testing.expect(d_self < 0.5); // an edit is kinship, not estrangement
}

test "disjoint alphabets are near-maximally distant" {
    // Two texts sharing no byte vocabulary: dictionaries cannot overlap.
    var upper: [4096]u8 = undefined;
    var digit: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (&upper) |*b| b.* = 'A' + r.uintLessThan(u8, 26);
    for (&digit) |*b| b.* = '0' + r.uintLessThan(u8, 10);
    const d = try dist(&upper, &digit);
    try std.testing.expect(d > 0.95);
}

test "empty and tiny inputs are total, not panics" {
    // Below `min_phrase` bytes no phrase qualifies: the sketch is empty and
    // two sub-phrase inputs are indistinguishable (distance 0) — documented,
    // total behavior, never a panic.
    var e = try sketch.build(gpa, "");
    var tiny = try sketch.build(gpa, "x");
    var real = try sketch.build(gpa, zig_a);
    try std.testing.expectEqual(@as(u16, 0), tiny.len);
    try std.testing.expectEqual(@as(f64, 0.0), sketch.distance(&e, &e));
    try std.testing.expectEqual(@as(f64, 0.0), sketch.distance(&e, &tiny));
    try std.testing.expectEqual(@as(f64, 1.0), sketch.distance(&e, &real));
}

test "sketch is bounded and sorted regardless of input size" {
    // 256 KiB of pseudo-random bytes — worst-case incompressible input still
    // yields exactly k ascending slots and touches no more memory than scratch.
    const big = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(big);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(big);
    var s = try sketch.build(gpa, big);
    try std.testing.expectEqual(@as(u16, sketch.k), s.len);
    for (s.slots()[1..], s.slots()[0 .. s.len - 1]) |next, prev|
        try std.testing.expect(prev < next);
}
