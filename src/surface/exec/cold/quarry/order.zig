//! gist — canonical file order: ripgrep's `--sort`/`--sortr`, exactly.
//!
//! `pathLess` is the load-bearing piece: Rust's `Path::cmp` compares
//! component-by-component, which is byte order with `/` ranked BELOW every other
//! byte. Get that wrong and `warroom/service.go` sorts after `warroom.go`,
//! and gist's ordered output stops being byte-identical to ripgrep's.
//!
//! Every consumer that emits an ordered answer routes through here — the cold
//! engine's sort, the fused parallel engine's, and the warm session's FFI match
//! stream — so one caller cannot drift into a different order for the same
//! corpus.

const std = @import("std");
const args = @import("../argv/args.zig");
const grepfile = @import("../read/grepfile.zig");
const intake = @import("intake.zig");

const Dir = std.Io.Dir;
const InFile = intake.InFile;

fn lessAsc(key: args.SortKey, x: InFile, y: InFile) bool {
    return switch (key) {
        .none, .path => pathLess(x.path, y.path),
        .modified, .accessed, .created => if (x.sort_time == y.sort_time)
            pathLess(x.path, y.path)
        else
            x.sort_time < y.sort_time,
    };
}

/// Ascending `--sort path` — the ONE sort rg applies during traversal
/// (`sort_by_file_name` on the walker, hiargs.rs), so PATH arguments keep
/// their argv order and only the files WITHIN each root sort (a DFS with
/// name-sorted siblings is exactly component-wise path order). Every other
/// mode — `--sortr path` and all time keys — is rg's collect-then-sort over
/// the whole haystack set, which IS global (a probe: `rg --sortr path aa zz`
/// interleaves roots; `rg --sort path aa zz` never does).
fn lessAscPathWalk(x: InFile, y: InFile) bool {
    if (x.root != y.root) return x.root < y.root;
    return pathLess(x.path, y.path);
}

/// Path order matching ripgrep's `--sort path` — Rust `Path::cmp`, which compares
/// component-by-component. That is byte order with the separator `/` ranked BELOW
/// every other byte: `warroom/service.go` sorts before `warroom.go`, where a raw
/// byte compare would flip them (`.`=0x2e < `/`=0x2f). Mapping `/`→0 and every
/// other byte→byte+1 keeps all other orderings intact while making the separator
/// the smallest, so gist's ordered output stays byte-identical to ripgrep's.
/// `pub` so the in-process FFI match stream (`surface/exec/session/warm/resident.zig::search`)
/// emits docs in the SAME order the cold `--json` file sort produces — a caller
/// gets one byte-identical record order across both transports.
pub fn pathLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| if (ca != cb) return pathOrd(ca) < pathOrd(cb);
    return a.len < b.len;
}

inline fn pathOrd(c: u8) u16 {
    return if (c == '/') 0 else @as(u16, c) + 1;
}

/// `--sort`/`--sortr` comparator. `--sortr` is a true reverse: swapping the
/// operands flips the path tiebreak too, so descending order is the exact
/// mirror of ascending (no adjacent-equal reordering left over) — matching
/// rg's `ordering.reverse()` / `.cmp().reverse()` collect-and-sort. The one
/// asymmetry is ascending `path`, which rg sorts in the WALKER (per root, see
/// `lessAscPathWalk`); its reverse is NOT that order mirrored but a global
/// descending `Path::cmp`.
pub fn cmpFiles(ctx: SortCtx, x: InFile, y: InFile) bool {
    if (ctx.key == .path and !ctx.reverse) return lessAscPathWalk(x, y);
    return if (ctx.reverse) lessAsc(ctx.key, y, x) else lessAsc(ctx.key, x, y);
}

pub const SortCtx = struct { key: args.SortKey, reverse: bool };

/// The nanosecond timestamp `--sort <key>` orders `path` by. `modified` and
/// `accessed` come from the portable `statFile` (accessed degrades to modified
/// when the platform doesn't record atime); `created` uses the birth time where
/// the OS exposes it (macOS today) and falls back to the status-change time
/// (ctime) elsewhere, matching the flag note. A stat failure sorts LAST when
/// ascending (max sentinel) — rg's rule ("things that error should appear
/// later"); the mirrored reverse then puts it first, exactly like rg's
/// `ordering.reverse()`.
pub fn sortTimeOf(io: std.Io, key: args.SortKey, path: []const u8) i96 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return std.math.maxInt(i96);
    return switch (key) {
        .modified => st.mtime.nanoseconds,
        .accessed => if (st.atime) |t| t.nanoseconds else st.mtime.nanoseconds,
        .created => createdTimeNs(path) orelse st.ctime.nanoseconds,
        .none, .path => 0,
    };
}

/// File birth time in ns, or null where the platform/filesystem doesn't record
/// one (then the caller falls back to ctime). macOS carries it in `struct
/// stat`, Linux in `statx` BTIME; gist declines to invent one elsewhere rather
/// than silently mislabel ctime as creation.
fn createdTimeNs(path: []const u8) ?i96 {
    return (grepfile.statPath(path) orelse return null).birthtime_ns;
}
test "sort comparator: path + time keys, ascending and reversed, path-tiebroken" {
    const t = std.testing;
    const a = InFile{ .path = "a.zig", .scope = "a.zig", .bytes = "", .sort_time = 100 };
    const b = InFile{ .path = "b.zig", .scope = "b.zig", .bytes = "", .sort_time = 200 };
    const c = InFile{ .path = "c.zig", .scope = "c.zig", .bytes = "", .sort_time = 100 }; // ties a on time

    // Path key: separator-aware order (see pathLess); reverse is the exact mirror.
    try t.expect(cmpFiles(.{ .key = .path, .reverse = false }, a, b));
    try t.expect(!cmpFiles(.{ .key = .path, .reverse = false }, b, a));
    try t.expect(cmpFiles(.{ .key = .path, .reverse = true }, b, a));

    // Time key: earlier stamp sorts first; equal stamps fall back to path so the
    // order is total (a before c even though both are t=100).
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = false }, a, b));
    try t.expect(!cmpFiles(.{ .key = .modified, .reverse = false }, b, a));
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = false }, a, c));
    try t.expect(!cmpFiles(.{ .key = .modified, .reverse = false }, c, a));
    // Reversed time is the full mirror, tiebreak included.
    try t.expect(cmpFiles(.{ .key = .modified, .reverse = true }, c, a));

    // A full sort lands the expected total order and its reverse.
    var asc = [_]InFile{ b, c, a };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .modified, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("a.zig", asc[0].path);
    try t.expectEqualStrings("c.zig", asc[1].path);
    try t.expectEqualStrings("b.zig", asc[2].path);
    var desc = [_]InFile{ a, c, b };
    std.mem.sort(InFile, &desc, SortCtx{ .key = .modified, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("b.zig", desc[0].path);
    try t.expectEqualStrings("c.zig", desc[1].path);
    try t.expectEqualStrings("a.zig", desc[2].path);
}

test "sort path: ascending is per-root walk order, descending is global (rg parity)" {
    const t = std.testing;
    // argv `zz aa`: zz's files sort within zz, aa's within aa, roots keep argv
    // order — rg's walker sort. Descending ignores roots entirely (global
    // collect-and-sort with `.reverse()`).
    const z0 = InFile{ .path = "zz/0.txt", .scope = "zz/0.txt", .bytes = "", .root = 0 };
    const z2 = InFile{ .path = "zz/2.txt", .scope = "zz/2.txt", .bytes = "", .root = 0 };
    const a1 = InFile{ .path = "aa/1.txt", .scope = "aa/1.txt", .bytes = "", .root = 1 };
    var asc = [_]InFile{ a1, z2, z0 };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .path, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("zz/0.txt", asc[0].path);
    try t.expectEqualStrings("zz/2.txt", asc[1].path);
    try t.expectEqualStrings("aa/1.txt", asc[2].path);
    var desc = [_]InFile{ a1, z2, z0 };
    std.mem.sort(InFile, &desc, SortCtx{ .key = .path, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("zz/2.txt", desc[0].path);
    try t.expectEqualStrings("zz/0.txt", desc[1].path);
    try t.expectEqualStrings("aa/1.txt", desc[2].path);
}

test "pathLess: separator ranks below every byte (ripgrep Path::cmp parity)" {
    const t = std.testing;
    // The adversarial collision `--sortr path` surfaced against rg: a raw byte
    // compare puts `.`(0x2e) < `/`(0x2f), but ripgrep compares component-wise, so
    // the directory `warroom/…` sorts before the file `warroom.go`.
    try t.expect(pathLess("dir/warroom/service.go", "dir/warroom.go"));
    try t.expect(!pathLess("dir/warroom.go", "dir/warroom/service.go"));
    // A prefix path still sorts before its extension, and before a deeper child.
    try t.expect(pathLess("a/b", "a/b.go"));
    try t.expect(pathLess("a/b", "a/b/c"));
    // Non-separator bytes keep their natural order; equal paths are not `<`.
    try t.expect(pathLess("a/x.go", "a/y.go"));
    try t.expect(!pathLess("a/x.go", "a/x.go"));
    // A full sort of the collision set is the exact mirror under reverse.
    const wr = InFile{ .path = "svc/warroom.go", .scope = "svc/warroom.go", .bytes = "", .sort_time = 0 };
    const ws = InFile{ .path = "svc/warroom/service.go", .scope = "svc/warroom/service.go", .bytes = "", .sort_time = 0 };
    var asc = [_]InFile{ wr, ws };
    std.mem.sort(InFile, &asc, SortCtx{ .key = .path, .reverse = false }, cmpFiles);
    try t.expectEqualStrings("svc/warroom/service.go", asc[0].path);
    try t.expectEqualStrings("svc/warroom.go", asc[1].path);
    var desc2 = [_]InFile{ ws, wr };
    std.mem.sort(InFile, &desc2, SortCtx{ .key = .path, .reverse = true }, cmpFiles);
    try t.expectEqualStrings("svc/warroom.go", desc2[0].path);
    try t.expectEqualStrings("svc/warroom/service.go", desc2[1].path);
}
