//! Exact matches lifted into comparison-sized regions.
//!
//! File-level kinship hides a small implementation inside unrelated bytes.
//! This module keeps exact selection first, but changes the statistical unit:
//! every matching line becomes either a bounded match window or its enclosing
//! function. Multiple hits in one function collapse to one region. The
//! syntactic half — how a hit is windowed into a function/context span, and how
//! every function in a file is enumerated — lives in `spans.zig`; here we own
//! the exact selection and the dedup/merge that keeps one region per unit.

const std = @import("std");
const patterns = @import("../slate/patterns.zig");
const lexspan = @import("../anatomy/lexspan.zig");
const spans = @import("../anatomy/spans.zig");

pub const Unit = enum { file, function, match };

pub const Region = spans.Region;
pub const Lang = spans.Lang;
pub const languageOf = spans.languageOf;
pub const extractAll = spans.extractAll;

pub const Set = struct {
    gpa: std.mem.Allocator,
    items: []Region,

    pub fn deinit(self: *Set) void {
        self.gpa.free(self.items);
    }
};

const commentOnly = lexspan.commentOnly;

/// Select every exact-hit region. `context` bounds `match`; function mode emits
/// only a recognized enclosing function. Overlapping hits collapse to one unit.
pub fn select(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    set: *const patterns.PatternSet,
    unit: Unit,
    context: usize,
) !Set {
    var scratch = try set.scratch(gpa);
    defer scratch.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(set.len()));
    defer gpa.free(mask);

    var out: std.ArrayList(Region) = .empty;
    errdefer out.deinit(gpa);
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);

    for (docs, 0..) |doc, d| {
        if (unit == .file) {
            if (set.docMask(doc, &scratch, mask))
                try appendRegion(&out, gpa, spans.region(@intCast(d), doc, .{ .start = 0, .end = doc.len }, 0), false);
            continue;
        }

        var line_start: usize = 0;
        while (line_start < doc.len) {
            const nl = std.mem.indexOfScalarPos(u8, doc, line_start, '\n');
            const line_end = nl orelse doc.len;
            if (commentOnly(doc[line_start..line_end])) {
                if (nl == null) break;
                line_start = line_end + 1;
                continue;
            }
            hits.clearRetainingCapacity();
            try set.lineHits(doc[line_start..line_end], &scratch, gpa, &hits);
            if (hits.items.len > 0) {
                const selected = if (unit == .function)
                    spans.enclosing(gpa, doc, line_start)
                else
                    spans.contextRange(doc, line_start, line_end, context);
                if (selected) |r| try appendRegion(&out, gpa, spans.region(@intCast(d), doc, r, line_start), unit != .file);
            }
            if (nl == null) break;
            line_start = line_end + 1;
        }
    }
    return .{ .gpa = gpa, .items = try out.toOwnedSlice(gpa) };
}

fn appendRegion(out: *std.ArrayList(Region), gpa: std.mem.Allocator, item: Region, merge_overlap: bool) !void {
    for (out.items) |*seen| {
        if (seen.doc != item.doc) continue;
        if (seen.start == item.start and seen.end == item.end) return;
        if (merge_overlap and item.start < seen.end and seen.start < item.end) {
            seen.start = @min(seen.start, item.start);
            seen.end = @max(seen.end, item.end);
            seen.line_start = @min(seen.line_start, item.line_start);
            seen.line_end = @max(seen.line_end, item.line_end);
            return;
        }
    }
    try out.append(gpa, item);
}

test "function regions collapse repeated hits and separate same-file implementations" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\fn alpha() {
        \\    target();
        \\    target();
        \\}
        \\fn beta() {
        \\    target();
        \\}
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 5), found.items[1].line_start);
}

test "python function region ignores a nested control block" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\def alpha(value):
        \\    if value:
        \\        target(value)
        \\    return value
        \\
        \\def beta():
        \\    return 2
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 4), found.items[0].line_end);
}

test "function unit excludes top-level documentation and data literals" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\//! target() is documented here.
        \\const manifest =
        \\    \\{"call":"target()"}
        \\;
        \\
        \\fn real() {
        \\    target();
        \\}
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 6), found.items[0].line_start);
}

test "match unit merges overlapping windows from adjacent hits" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\before
        \\target()
        \\target_word()
        \\after
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .match, 1);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 4), found.items[0].line_end);
}

test "overlapping function discoveries collapse to the widest region" {
    const gpa = std.testing.allocator;
    var found: std.ArrayList(Region) = .empty;
    defer found.deinit(gpa);
    try appendRegion(&found, gpa, .{ .doc = 0, .start = 10, .end = 20, .match_start = 12, .line_start = 2, .line_end = 4 }, true);
    try appendRegion(&found, gpa, .{ .doc = 0, .start = 10, .end = 30, .match_start = 24, .line_start = 2, .line_end = 6 }, true);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(usize, 30), found.items[0].end);
    try std.testing.expectEqual(@as(u32, 6), found.items[0].line_end);
}

test "extractAll: brace methods surface, nested closures stay inside their function" {
    const gpa = std.testing.allocator;
    const doc =
        \\const Handler = struct {
        \\    fn serve(self: *Handler) void {
        \\        const inner = struct {
        \\            fn helper() void {}
        \\        };
        \\        inner.helper();
        \\    }
        \\    fn close(self: *Handler) void {
        \\        self.done = true;
        \\    }
        \\};
        \\fn free_standing() void {
        \\    work();
        \\}
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "handler.zig", doc, 0, &out);
    // serve (with its nested closure folded in), close, and free_standing —
    // three functions, never the inner closure as its own region.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line_start); // serve
    try std.testing.expectEqual(@as(u32, 7), out.items[0].line_end);
    try std.testing.expectEqual(@as(u32, 8), out.items[1].line_start); // close
    try std.testing.expectEqual(@as(u32, 12), out.items[2].line_start); // free_standing
}

test "extractAll: python methods and top-level defs, decorators included" {
    const gpa = std.testing.allocator;
    const doc =
        \\class Service:
        \\    @property
        \\    def alpha(self):
        \\        def closure():
        \\            return 1
        \\        return closure()
        \\    def beta(self):
        \\        return 2
        \\
        \\def top_level():
        \\    return 3
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "service.py", doc, 0, &out);
    // alpha (decorator + body + its closure), beta, top_level — the closure is
    // folded into alpha, never emitted alone.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line_start); // @property above alpha
    try std.testing.expectEqual(@as(u32, 7), out.items[1].line_start); // beta
    try std.testing.expectEqual(@as(u32, 10), out.items[2].line_start); // top_level
}

test "extractAll: a multi-line data literal is not a function, however many parens its prose carries" {
    const gpa = std.testing.allocator;
    // Shaped exactly like the flag catalogue that exposed this: each element
    // ends in `},` — which the header climb does not treat as a terminator — so
    // a later element's brace used to climb back onto the FIRST element's line,
    // and any prose paren in between read as its parameter list. Thirteen
    // elements then became thirteen "functions" all claiming line 2.
    const doc =
        \\pub const catalog = [_]Spec{
        \\    .{ .short = 'i', .action = .{ .case = .icase }, .note = "folding by default (full orbits); ASCII otherwise" },
        \\    .{ .short = 'S', .action = .{ .case = .smart }, .note = "uppercase detection (codepoint-aware)" },
        \\    .{ .short = 'w', .action = .{ .set = .word }, .note = "\\b uses Unicode (rg parity); (?-u) selects ASCII" },
        \\};
        \\fn real(a: u8) void {
        \\    work(a);
        \\}
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "catalog.zig", doc, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u32, 6), out.items[0].line_start); // real
}

test "extractAll: a keyword-free signature still surfaces, return type and all" {
    const gpa = std.testing.allocator;
    // The paren fallback is what carries C, Java, and TS methods. Rejecting the
    // data literal above must not cost them: each tail below (` `, `: void `,
    // ` -> Int `, ` (int, error) `) is a return type, not an assignment.
    const doc =
        \\int add(int a, int b) {
        \\    return a + b;
        \\}
        \\class S {
        \\    render(props: Props): void {
        \\        draw(props);
        \\    }
        \\}
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "widget.ts", doc, 0, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u32, 1), out.items[0].line_start); // add
    try std.testing.expectEqual(@as(u32, 5), out.items[1].line_start); // render
}

test "extractAll: unrecognized extension yields no fragments" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "notes.md", "fn looks_like_code() {}\n", 0, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
