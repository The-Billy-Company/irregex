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
//!
//! And it answers a second question the first one turns out to depend on:
//! WHETHER this is a checkout at all — see `confines`. A tree is a project; a
//! person's home directory is not one, and the difference stopped being
//! academic when these binaries started shipping inside a product that runs in
//! the user's own folders rather than in a repository.

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
        if (anchored.len.load(.acquire) == 0) anchored.len.store(seek(portal.cwd(), &anchored.buf, confines().levels).len, .release);
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

// ── a tree is a project, and a person's computer is not one ──────────────────

/// How far the climb may look, and whether what it finds may be written to.
///
/// The climb's original stopping rule was `max_climb` and nothing else, which
/// is the right rule for the only place these binaries ran: a checkout, nested
/// somewhere under a person's home, whose boundary is always found long before
/// forty levels. It is the wrong rule the moment the working directory is a
/// folder the *user* named rather than a repository — which is what happens
/// when this engine ships inside a product that operates on someone's own
/// Documents, Desktop, and Downloads.
///
/// Two failures follow from the same missing boundary, and both were observed:
///
///   * **Adoption from above.** One stray artifact directory at `$HOME` — and
///     one `index` run standing there puts it exactly there — is then found by
///     every later climb from anywhere beneath it. Every project on the machine
///     silently shares one home, one index, and one daemon socket.
///   * **A corpus with no edge.** With no boundary above, `index` anchors at
///     the working directory and takes the whole tree beneath it as the corpus.
///     Run once from `$HOME`, that is the person's entire computer: their mail,
///     their photo library, every dependency tree they have ever installed.
///
/// So the climb stops below the dwelling, and a working directory that IS the
/// dwelling (or a filesystem root) is `hosted = false`: there is no project
/// here, so there is nothing to persist an artifact set for. Searching is
/// untouched — it never needed an artifact and the live walk answers the same
/// bytes — which is the usual shape of everything in this family: the
/// accelerator declines, the answer does not move.
pub const Confines = struct {
    /// Levels of ascent the climb may probe. Zero looks only at the working
    /// directory itself.
    levels: usize,
    /// May an artifact set be written for this tree? False at the dwelling and
    /// at a filesystem root, where a corpus has no edge to be bounded by.
    hosted: bool,

    /// What a caller that holds a handle rather than a path has to assume: the
    /// old rule, `max_climb` and no dwelling. It is the honest answer there —
    /// confinement is derived from an absolute path, and a handle is the one
    /// thing here that cannot portably be turned back into one.
    pub const unconfined: Confines = .{ .levels = max_climb, .hosted = true };
};

/// This process's confines, memoized like the anchor it bounds (both are
/// properties of a working directory that the CLI never changes after startup;
/// `standAtRoot` republishes all three together).
pub fn confines() Confines {
    if (confined.len.load(.acquire) == 0) {
        while (confined.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer confined.locked.store(false, .release);
        if (confined.len.load(.acquire) == 0) {
            var here: [portal.max_path]u8 = undefined;
            var there: [portal.max_path]u8 = undefined;
            const cwd_abs: ?[]const u8 = if (portal.realpath(".", &here)) |p| p else null;
            const c = confinesOf(cwd_abs, dwelling(&there));
            confined.hosted.store(c.hosted, .release);
            confined.len.store(c.levels + 1, .release);
        }
    }
    return .{ .levels = confined.len.load(.acquire) - 1, .hosted = confined.hosted.load(.acquire) };
}

/// May this tree carry a persisted artifact set at all? The one question every
/// mutating lifecycle action asks before it writes.
pub fn hosted() bool {
    return confines().hosted;
}

/// `+1` on the published length for the same reason `stationed` carries one: a
/// legitimate zero (standing one level under the dwelling) must read as a
/// FILLED memo rather than as a miss re-resolved on every call.
const confined = struct {
    var locked: std.atomic.Value(bool) = .init(false);
    var len: std.atomic.Value(usize) = .init(0);
    var hosted: std.atomic.Value(bool) = .init(true);
};

/// The rule itself, pure — so every edge is testable without a home directory
/// to stand in, and so a sibling package can state the same boundary rather
/// than re-derive it.
///
/// `cwd` is the canonicalized working directory and `dwell` the canonicalized
/// home, either of which the platform may decline to name. A null `cwd` is the
/// fail-closed case — a process that cannot say where it is standing gets the
/// tightest confines, not the loosest — while a null `dwell` only removes the
/// dwelling rule and leaves the filesystem root still binding.
pub fn confinesOf(cwd: ?[]const u8, dwell: ?[]const u8) Confines {
    const here = trimmed(cwd orelse return .{ .levels = 0, .hosted = false });
    if (here.len == 0) return .{ .levels = 0, .hosted = false }; // the root itself
    if (dwell) |d| {
        const home_dir = trimmed(d);
        // Standing IN the dwelling: no project, and nowhere above worth asking.
        if (std.mem.eql(u8, here, home_dir)) return .{ .levels = 0, .hosted = false };
        if (home_dir.len < here.len and
            std.mem.startsWith(u8, here, home_dir) and here[home_dir.len] == '/')
            return .{ .levels = depth(here[home_dir.len + 1 ..]) - 1, .hosted = true };
    }
    // Outside the dwelling (`/opt/src`, a CI checkout, a mounted volume): the
    // filesystem root is the only boundary left, and probing it would ask the
    // same adoption question of every user on the machine at once.
    return .{ .levels = depth(here[1..]) - 1, .hosted = true };
}

/// Separator-trimmed, and `""` for a root — so `/` and `/Users/x/` compare the
/// way a reader expects without a special case at every site.
fn trimmed(p: []const u8) []const u8 {
    return std.mem.trimEnd(u8, p, "/");
}

/// How many components `rel` (already separator-free at both ends) names.
/// Always at least one, so a caller may subtract the level that would land on
/// the boundary itself without underflowing.
fn depth(rel: []const u8) usize {
    return std.mem.count(u8, rel, "/") + 1;
}

/// This machine's home directory, canonicalized into `buf`.
///
/// `HOME` before the Windows spelling for the same reason the preferences
/// lookup orders them that way: a Windows shell that sets `HOME` (Git for
/// Windows, MSYS2) is one where the person's own files genuinely live there.
/// Canonicalized because the comparison is against a canonicalized working
/// directory, and on macOS `/tmp`, `/var`, and every home under a mounted
/// volume resolve through a symlink that a raw string compare would miss.
fn dwelling(buf: *[portal.max_path]u8) ?[]const u8 {
    var raw: [portal.max_path]u8 = undefined;
    const named_home = assay.envSpan("HOME") orelse
        (if (comptime builtin.os.tag == .windows) assay.envSpan("USERPROFILE") else null) orelse
        return null;
    const z = std.fmt.bufPrintZ(&raw, "{s}", .{named_home}) catch return named_home;
    if (portal.realpath(z, buf)) |resolved| return resolved;
    return named_home;
}

/// One uncached resolution into `buf` (at least `min_buf` bytes), climbing from
/// `at` — what `anchor` memoizes over the working directory. Uncached and
/// handle-taking because the answer is a property of a directory, not of the
/// process: a caller holding several checkouts open (an embedder walking a
/// fleet, a test) has to be able to ask about each of them.
///
/// `ceiling` is how many levels the climb may probe, which `anchor` takes from
/// `confines` and a handle-holding caller supplies itself. It is a separate
/// argument rather than a lookup because confinement is a fact about a path,
/// and a handle is the one thing in this module that cannot be resolved back
/// to one portably — so the caller that knows where it is standing is the
/// caller that gets to say.
pub fn seek(at: portal.Handle, buf: []u8, ceiling: usize) []const u8 {
    std.debug.assert(buf.len >= min_buf);
    var scratch: [max_climb * 3 + 32]u8 = undefined;
    var up: usize = 0;
    while (up <= @min(ceiling, max_climb)) : (up += 1) {
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
    // All three memos were filled against the old directory and every one of
    // their answers just changed. Republished under the same spinlocks that
    // fill them. `confined` goes too: moving to the tree root moves this
    // process's distance from the dwelling, and a stale ceiling here would let
    // a later resolution climb past the boundary it was hired to stop at.
    forget(anchored);
    forget(stationed);
    forget(confined);
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
