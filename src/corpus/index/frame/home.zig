//! home — where the persisted irregex artifacts live.
//!
//! One resolution of the artifact directory (`outDir`) and one per-artifact
//! path formatter (`ArtifactPath`), shared by everything that persists or
//! loads a blob there — the trigram index, kinship atlas, codex shelf,
//! freshness anchor, and daemon socket. It sits on the wire floor beside
//! `frame.zig` (whose `tree.root` binding is a property of exactly this
//! directory) so the codebook kernel and the corpus artifacts resolve the
//! same home without either importing the other.
//!
//! The home belongs to the TREE, not to the directory you typed the command in
//! — see `anchor`. The climb that finds it (`ascent`, `probe`, `max_climb`) is
//! the same one the charter walk performs one tier up, and lives here because
//! this is the lowest tier that has to answer "which checkout is this?".

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("../../../assay/assay.zig");
const portal = @import("../../../portal.zig");

/// The artifact directory's NAME — where the trigram index, kinship atlas,
/// codex shelf, freshness anchor, and daemon socket live. `anchor()` decides
/// which directory wears it; `<prefix>DIR` overrides both per invocation.
pub const default_out_dir = assay.identity.artifact_dir;

/// How far up a walk may look for the checkout it is standing in. Bounded for
/// the same reason the charter's climb is: a deep working directory must not be
/// able to turn one resolution into an unbounded storm of opens.
pub const max_climb: usize = 40;

/// `""`, `"../"`, `"../../"`, … — `up` levels of relative ascent. Relative
/// throughout, which keeps the walk free of `getcwd` and makes what it yields
/// usable directly as a path prefix.
pub fn ascent(buf: []u8, up: usize) []const u8 {
    for (0..up) |i| @memcpy(buf[i * 3 ..][0..3], "../");
    return buf[0 .. up * 3];
}

/// Is `<dir><name>` there, resolved against `at`? Probed by opening rather than
/// by `access`, so a `.git` FILE (a worktree or submodule pointer) counts as a
/// boundary exactly like a `.git` directory does — both are the edge of a
/// checkout.
pub fn probe(at: portal.Handle, buf: []u8, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.bufPrint(buf, "{s}{s}", .{ dir, name }) catch return false;
    const fd = portal.openFile(at, path) catch return false;
    portal.close(fd);
    return true;
}

/// The artifact directory for THIS process: `<prefix>DIR` when set (trailing
/// slashes trimmed), else the checkout's own home (`anchor`). Both outlive the
/// process — the env string by definition, the anchor in a static buffer — so
/// the returned slice is borrow-safe everywhere.
pub fn outDir() []const u8 {
    const v = assay.knob("DIR") orelse return anchor();
    // Both separators, not just `/`: on Windows a shell-completed directory
    // arrives as `C:\tmp\artifacts\`, and the artifact names are appended raw.
    const s = std.mem.trimEnd(u8, v, if (builtin.os.tag == .windows) "/\\" else "/");
    return if (s.len == 0) anchor() else s;
}

/// Where the artifacts go when nothing overrides it: the artifact directory of
/// the TREE, named relative to the working directory.
///
/// CWD-relative was the wrong anchor for a per-tree artifact set. It cannot
/// collide across trees — which is all `frame.socketBindingPath` ever needed —
/// but within one tree it made the home a property of where you happened to
/// stand: a search from `services/ai` and a search from the root built two
/// indexes, ran two daemons, and each paid a cold walk the other had already
/// paid for. Worse, it parked a daemon socket in whatever source directory was
/// current, and a file watcher that cannot watch a socket (chokidar's
/// `fs.watch` throws EUNKNOWN) takes a dev server down with it.
///
/// So the walk climbs, and the first of these wins: an artifact directory
/// already sitting there (a placement is a decision, and adopting it is how a
/// nested workspace opts out), then a checkout boundary. Finding neither within
/// `max_climb`, it stays where it stood — the historical behavior, which is the
/// right answer for a tree that is not a checkout at all.
pub fn anchor() []const u8 {
    if (anchored.len.load(.acquire) == 0) {
        while (anchored.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer anchored.locked.store(false, .release);
        if (anchored.len.load(.acquire) == 0) anchored.len.store(seek(portal.cwd(), &anchored.buf).len, .release);
    }
    return anchored.buf[0..anchored.len.load(.acquire)];
}

/// Env-stable like `ArtifactPath`, so the first fill is final and a spinlock +
/// release-published length make it race-free without an `std.Io` handle.
const anchored = struct {
    var locked: std.atomic.Value(bool) = .init(false);
    var len: std.atomic.Value(usize) = .init(0);
    var buf: [min_buf]u8 = undefined;
};

/// The smallest buffer `seek` can always answer into: the deepest ascent it may
/// write, plus the directory name appended to it.
pub const min_buf: usize = max_climb * 3 + default_out_dir.len;

/// One uncached resolution into `buf` (at least `min_buf` bytes), climbing from
/// `at` — what `anchor` memoizes over the working directory. Uncached and
/// handle-taking because the answer is a property of a directory, not of the
/// process: a caller holding several checkouts open (an embedder walking a
/// fleet, a test) has to be able to ask about each of them.
pub fn seek(at: portal.Handle, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= min_buf);
    var scratch: [max_climb * 3 + 32]u8 = undefined;
    var up: usize = 0;
    while (up <= max_climb) : (up += 1) {
        const dir = ascent(buf, up);
        if (probe(at, &scratch, dir, default_out_dir) or probe(at, &scratch, dir, ".git")) return named(buf, dir);
    }
    return named(buf, ascent(buf, 0));
}

/// The ascent is already at the front of `buf`, so naming the home is appending
/// the directory to the prefix sitting there.
fn named(buf: []u8, dir: []const u8) []const u8 {
    @memcpy(buf[dir.len..][0..default_out_dir.len], default_out_dir);
    return buf[0 .. dir.len + default_out_dir.len];
}

/// How to reach the checkout root from the working directory — `""` when you are
/// already standing in it, else `"../"`, `"../../"`, … . It is `anchor()` with
/// the directory name taken back off, so the home and the root it hangs from can
/// never be derived two different ways.
pub fn treePrefix() []const u8 {
    const a = anchor();
    return a[0 .. a.len - default_out_dir.len];
}

/// Where the working directory sits INSIDE the checkout, with no leading or
/// trailing separator: `""` at the root, `"services/ai"` two levels down.
///
/// This is the OTHER half of anchoring the home at the tree, and the half that
/// keeps it honest. Everything persisted in the home — the trigram path table,
/// the content shard's document names, the phantom tree map — is written in
/// CHECKOUT coordinates, while a walk emits paths relative to the working
/// directory because that is what rg does and output parity is not negotiable.
/// Those are two different coordinate systems for the same file, and the station
/// is the offset between them. An index-keyed lookup rebases through it
/// (`inTree`); output never does.
///
/// Getting this wrong is not a missed optimization. `content.shard` answers
/// BY RELATIVE PATH, so a lookup that forgets to rebase asks for `README.md`
/// and is handed the checkout root's copy — real bytes, real path, wrong file.
/// Empty on any doubt, which costs acceleration and never correctness.
pub fn station() []const u8 {
    if (stationed.len.load(.acquire) == 0) {
        while (stationed.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer stationed.locked.store(false, .release);
        if (stationed.len.load(.acquire) == 0) stationed.len.store(offset() + 1, .release);
    }
    return stationed.buf[0 .. stationed.len.load(.acquire) - 1];
}

/// `+1` on the published length so that a genuine `""` (standing at the root,
/// the common case) is still a FILLED cache rather than a miss re-walked on
/// every call.
const stationed = struct {
    var locked: std.atomic.Value(bool) = .init(false);
    var len: std.atomic.Value(usize) = .init(0);
    var buf: [portal.max_path]u8 = undefined;
};

fn offset() usize {
    const pre = treePrefix();
    if (pre.len == 0) return 0; // already at the root — no offset to compute
    var here_buf: [portal.max_path]u8 = undefined;
    var root_buf: [portal.max_path]u8 = undefined;
    var prez: [portal.max_path]u8 = undefined;
    const here = portal.realpath(".", &here_buf) orelse return 0;
    const p = std.fmt.bufPrintZ(&prez, "{s}", .{pre}) catch return 0;
    const root = portal.realpath(p, &root_buf) orelse return 0;
    // A root that is not a prefix of here means the two resolved through
    // different symlink legs; refuse rather than guess at an offset.
    if (here.len <= root.len or !std.mem.startsWith(u8, here, root) or here[root.len] != '/') return 0;
    const rel = here[root.len + 1 ..];
    if (rel.len > stationed.buf.len) return 0;
    @memcpy(stationed.buf[0..rel.len], rel);
    return rel.len;
}

/// Stand at the checkout root, so that what this process walks and what the
/// artifacts are addressed in are the same coordinates. For BUILD verbs only.
///
/// A build publishes into the tree's home a path table, a content shard, and a
/// directory-membership snapshot that every later query reads as tree-relative.
/// Run from `services/ai` without this, an index build records `notes.md` for a
/// file that is really `services/ai/notes.md` and binds the result to the tree
/// — and the next query at the root faithfully tries to open a `notes.md` that
/// was never there. Not a missed acceleration: an error and an empty answer.
///
/// The alternative was to walk `../..` and strip the prefix back off on the way
/// into every artifact, which is the same translation done three more times, in
/// three more places, each able to be forgotten. Moving once costs one syscall
/// and leaves nothing downstream to remember: `station` becomes `""`, `inTree`
/// becomes the identity, the phantom snapshot sees the single `.` root it
/// requires, and `roots.list` and the tree binding say what they mean.
///
/// Callers naming roots explicitly must rebase them (`inTree`) BEFORE calling —
/// an `index services/ai` invocation names a path relative to where the user
/// typed it. Returns false when there was nowhere to go or the move was refused,
/// leaving the process exactly where it was.
pub fn standAtRoot(io: std.Io) bool {
    const pre = treePrefix();
    if (pre.len == 0) return false;
    std.process.setCurrentPath(io, pre) catch return false;
    // Both memos were filled against the old directory and every one of their
    // answers just changed. Republished under the same spinlocks that fill them.
    forget(anchored);
    forget(stationed);
    return true;
}

fn forget(comptime memo: type) void {
    while (memo.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer memo.locked.store(false, .release);
    memo.len.store(0, .release);
}

/// A walk's path (relative to the working directory) as the artifacts spell it
/// (relative to the checkout root). Returns `rel` untouched at the root, so the
/// overwhelmingly common case costs a length check and no copy.
///
/// The working directory itself — spelled `""` or `"."` by the callers that
/// name a root rather than a file — is the station and nothing else, so it
/// joins to no trailing separator.
pub fn inTree(buf: []u8, rel: []const u8) ?[]const u8 {
    const st = station();
    if (st.len == 0) return rel;
    if (rel.len == 0 or std.mem.eql(u8, rel, ".")) return st;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ st, rel }) catch null;
}

/// A named artifact's full path (`<outDir()>/<name>`), formatted once per
/// process into a static buffer. Env-stable, so the first fill is final; a
/// spinlock + release-published length make the fill race-free without an
/// `std.Io` handle (same idiom as `exec/session/reconcile/dirty.zig` — these are
/// per-command lookups, never a hot loop). Instantiate per artifact:
/// `const atlas_path = corpus.ArtifactPath("kinship.atlas");` → `.get()`.
pub fn ArtifactPath(comptime name: []const u8) type {
    return struct {
        var locked: std.atomic.Value(bool) = .init(false);
        var len: std.atomic.Value(usize) = .init(0);
        var buf: [1024]u8 = undefined;
        pub fn get() []const u8 {
            if (len.load(.acquire) == 0) {
                while (locked.swap(true, .acquire)) std.atomic.spinLoopHint();
                defer locked.store(false, .release);
                if (len.load(.acquire) == 0) {
                    const d = outDir();
                    std.debug.assert(d.len + 1 + name.len <= buf.len);
                    @memcpy(buf[0..d.len], d);
                    buf[d.len] = '/';
                    @memcpy(buf[d.len + 1 ..][0..name.len], name);
                    len.store(d.len + 1 + name.len, .release);
                }
            }
            return buf[0..len.load(.acquire)];
        }
    };
}
