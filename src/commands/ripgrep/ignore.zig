//! gist `rg` — the gitignore / .ignore / .rgignore filter that makes gist's
//! directory walk honor the same "what's tracked" boundary ripgrep does.
//!
//! Split from `run.zig` (the walk shell) the way `args`/`output` are: this
//! module owns ONLY the ignore-rule model — parsing `.gitignore`-dialect lines
//! into anchored/negated/dir-only globs, accumulating them per directory as the
//! walk descends, and deciding whether a candidate path is ignored. It reuses
//! the shared `scope/glob.zig` matcher for the segment-aware `*`/`**`/`?`/`[…]`
//! matching, so there is one glob dialect across `-g` scoping and ignore rules.
//!
//! Semantics implemented (ripgrep/git parity):
//!   • a leading or embedded `/` anchors the pattern to the ignore file's dir;
//!     a slash-less pattern matches a basename at any depth;
//!   • `!pat` re-includes (whitelist), last matching rule wins, deeper dirs and
//!     `.ignore`/`.rgignore`/`--ignore-file` outrank a shallower `.gitignore`;
//!   • a trailing `/` restricts a rule to directories;
//!   • a `!`-whitelisted hidden file is un-hidden (overrides the dotfile skip);
//!   • VCS rules (`.gitignore`, `.git/info/exclude`) apply only inside a git repo
//!     unless `--no-require-git`; `--no-ignore*` / `-u` disable the relevant tier.

const std = @import("std");
const gl = @import("../scope/glob.zig");
const args = @import("args.zig");
const die = args.die;
const Opts = args.Opts;
const Dir = std.Io.Dir;

/// One compiled ignore rule. `glob` is the pattern core (leading `/` and trailing
/// `/` stripped); `base` is the directory (relative to the walk root, "" = root)
/// whose ignore file contributed it. `rank` sorts rules into precedence order —
/// but because rules are appended shallow→deep, low-source→high-source, the list
/// is already ascending, so `decide` just takes the last matching rule's verdict.
const Rule = struct {
    glob: []const u8,
    base: []const u8,
    negated: bool,
    anchored: bool,
    dir_only: bool,
};

pub const Ignore = struct {
    a: std.mem.Allocator,
    io: std.Io,
    o: Opts,
    rules: std.ArrayList(Rule) = .empty,
    loaded: std.ArrayList([]const u8) = .empty, // dirs whose ignore files were read
    use_git: bool = false,
    use_dot: bool = false,
    // Component-depth of the positional root currently being walked (0 for the
    // implicit whole-CWD walk). ripgrep NEVER ignore-filters a root path named
    // explicitly on argv — only entries strictly BELOW it (see `walk.rs`'s
    // `add_parents`: ancestor ignore state is loaded at depth 0, but the depth-0
    // entry itself is never matched against it, only its depth>0 descendants
    // are). gist's rules are matched against one path string spanning root+rel
    // (`Rule.base == ""` covers CWD/ancestor-sourced rules), so `match` must
    // floor slash-less/anchored matching at this depth to reproduce the same
    // "the root itself is exempt, its subtree is not" boundary.
    explicit_root_depth: usize = 0,

    /// Build the matcher and load the root-level ignore sources (repo `.gitignore`
    /// + `.git/info/exclude`, `.ignore`/`.rgignore`, and every `--ignore-file`).
    /// `roots` are the search's positional path args (empty = walk CWD); each is
    /// probed for its own `.git` so a git repo (or worktree) named as a path arg is
    /// honored, not just CWD.
    pub fn init(a: std.mem.Allocator, io: std.Io, o: Opts, roots: []const []const u8) Ignore {
        var self = Ignore{ .a = a, .io = io, .o = o };
        // `--ignore-file` is EXPLICIT user intent: lowest precedence (added first,
        // so an in-tree `.ignore`/`.gitignore` overrides it — rg's f45 rule) and
        // honored even under `-u`/`--no-ignore` (only `--no-ignore-files` drops it).
        if (!o.no_ignore_files) for (o.ignore_files) |p| self.readFile(p, "", "");
        if (o.no_ignore) return self; // -u / --no-ignore: honor nothing else on disk
        // Detect the repo by ASCENDING from CWD — ripgrep finds `.git` at any
        // ancestor, not just CWD; the depth bounds how far VCS ignores climb.
        const git_depth = gitRootDepth(io);
        const git_repo = o.no_require_git or git_depth != null or anyRootRepo(io, roots);
        self.use_git = git_repo and !o.no_ignore_vcs;
        self.use_dot = !o.no_ignore_dot;
        // Parent (ancestor) ignores — rg also reads `.gitignore`/`.ignore` from
        // every directory ABOVE the search root, unless `--no-ignore-parent`. VCS
        // ancestors stop at the git root; `.ignore`/`.rgignore` climb to `/`.
        if (!o.no_ignore_parent) self.loadParents(git_depth);
        // `.git/info/exclude` (lowest-precedence VCS source) — resolved per repo
        // root, following a worktree's `.git`-file → `commondir` like ripgrep does.
        if (self.use_git and !o.no_ignore_exclude) {
            self.loadGitExclude("", "");
            for (roots) |r| {
                if (std.mem.eql(u8, r, ".")) continue;
                const rel = std.mem.trimEnd(u8, r, "/");
                self.loadGitExclude(rel, rel);
            }
        }
        self.loadDir(".", "");
        return self;
    }

    /// Read every ancestor directory's ignore files, shallow→deep so a deeper
    /// ancestor outranks a shallower one (git precedence). `git_depth` (levels
    /// from CWD up to the git root, null = not in a repo) bounds the VCS climb.
    fn loadParents(self: *Ignore, git_depth: ?usize) void {
        const cwd = Dir.cwd().realPathFileAlloc(self.io, ".", self.a) catch return;
        var comps: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, cwd, '/');
        while (it.next()) |c| if (c.len != 0) comps.append(self.a, c) catch die("oom\n", .{});
        var k: usize = comps.items.len; // k levels up (1 = parent, len = filesystem root)
        while (k >= 1) : (k -= 1) {
            const anc = ascend(self.a, k);
            // CWD's path relative to this ancestor = its last k components — an
            // anchored ancestor rule is re-anchored by stripping this prefix.
            const subpath = joinComps(self.a, comps.items[comps.items.len - k ..]);
            if (self.use_git and git_depth != null and k <= git_depth.?)
                self.readFile(join(self.a, anc, ".gitignore"), "", subpath);
            if (self.use_dot) {
                self.readFile(join(self.a, anc, ".ignore"), "", subpath);
                self.readFile(join(self.a, anc, ".rgignore"), "", subpath);
            }
        }
    }

    /// Read `<repo>/.git/info/exclude` for the repo rooted at `root` (rel path from
    /// CWD; "" = CWD), anchoring its rules to `base`. When `<root>/.git` is a
    /// worktree `.git`-FILE, resolve `gitdir:` → `commondir` (ripgrep's
    /// `resolve_git_commondir`) so a linked worktree honors the shared exclude.
    fn loadGitExclude(self: *Ignore, root: []const u8, base: []const u8) void {
        const git_dir = self.resolveGitDir(root) orelse return;
        self.readFile(join(self.a, git_dir, "info/exclude"), base, "");
    }

    /// The git common-dir for the repo at `root` (a path openable from CWD), or
    /// null if `root` has no `.git`. A `.git` directory IS the git dir; a `.git`
    /// FILE (linked worktree) is followed through `gitdir:` then its `commondir`.
    fn resolveGitDir(self: *Ignore, root: []const u8) ?[]const u8 {
        const dot_git = join(self.a, root, ".git");
        if (Dir.cwd().openDir(self.io, dot_git, .{})) |d_const| {
            var d = d_const;
            d.close(self.io);
            return dot_git; // plain repo: `.git` is the git dir
        } else |_| {}
        const gitfile = Dir.cwd().readFileAlloc(self.io, dot_git, self.a, .limited(4096)) catch return null;
        const line0 = std.mem.trimEnd(u8, firstLine(gitfile), "\r");
        if (!std.mem.startsWith(u8, line0, "gitdir: ")) return null;
        const real_git_dir = std.mem.trim(u8, line0["gitdir: ".len..], " ");
        const commondir = Dir.cwd().readFileAlloc(self.io, join(self.a, real_git_dir, "commondir"), self.a, .limited(4096)) catch return null;
        const cd = std.mem.trimEnd(u8, firstLine(commondir), "\r");
        // A relative commondir is joined to the worktree git dir; an absolute one
        // is used as-is (the OS resolves the embedded `..`).
        return if (cd.len > 0 and cd[0] == '.') join(self.a, real_git_dir, cd) else self.a.dupe(u8, cd) catch die("oom\n", .{});
    }

    /// Scope subsequent `decide`/`shouldSkip` calls to a positional root path
    /// (`prefix`, as passed to the walker — may carry a leading `./`) about to
    /// be walked; `""`/`"."` means the implicit whole-CWD walk. Must be called
    /// before walking each explicit root (`gather` does this per positional
    /// PATH arg) so ancestor/CWD-sourced rules (`Rule.base == ""`) can't match
    /// the root's own path components — only its descendants.
    pub fn scopeToRoot(self: *Ignore, prefix: []const u8) void {
        var s = prefix;
        while (std.mem.startsWith(u8, s, "./")) s = s[2..];
        self.explicit_root_depth = if (s.len == 0 or std.mem.eql(u8, s, ".")) 0 else std.mem.count(u8, s, "/") + 1;
    }

    /// Load the per-directory ignore files for `rel` (relative to the walk root;
    /// on-disk path `disk`) exactly once, as the walk is about to descend into it.
    pub fn loadDir(self: *Ignore, disk: []const u8, rel: []const u8) void {
        if (self.o.no_ignore) return;
        for (self.loaded.items) |d| if (std.mem.eql(u8, d, rel)) return;
        self.loaded.append(self.a, self.a.dupe(u8, rel) catch die("oom\n", .{})) catch die("oom\n", .{});
        if (self.use_git) self.readFile(join(self.a, disk, ".gitignore"), rel, "");
        if (self.use_dot) {
            self.readFile(join(self.a, disk, ".ignore"), rel, "");
            self.readFile(join(self.a, disk, ".rgignore"), rel, "");
        }
    }

    /// The ignore verdict for a candidate path (relative to the walk root): null =
    /// no rule matched, true = ignored, false = explicitly whitelisted. Last
    /// matching rule wins (the list is pre-ordered by precedence).
    pub fn decide(self: *const Ignore, rel: []const u8, is_dir: bool) ?bool {
        var verdict: ?bool = null;
        for (self.rules.items) |r| if (self.match(r, rel, is_dir)) {
            verdict = !r.negated;
        };
        return verdict;
    }

    /// Should the walk drop this entry? Folds three rules: `.git` is never walked;
    /// an ignored path is dropped; a dotfile stays hidden unless `--hidden` or an
    /// explicit `!`-whitelist un-hides it.
    pub fn shouldSkip(self: *const Ignore, rel: []const u8, is_dir: bool, basename: []const u8) bool {
        if (is_dir and std.mem.eql(u8, basename, ".git")) return true;
        const v = self.decide(rel, is_dir);
        if (v == true) return true;
        const hidden = basename.len > 0 and basename[0] == '.';
        if (hidden and !self.o.hidden and v != false) return true;
        return false;
    }

    // ─────────────────────────── internals ───────────────────────────

    /// Read `path`'s ignore lines, anchoring each to `base`. `strip` (non-empty
    /// only for a parent-directory file) is CWD's path relative to that ancestor;
    /// it re-anchors the ancestor's anchored rules onto the search subtree.
    fn readFile(self: *Ignore, path: []const u8, base: []const u8, strip: []const u8) void {
        const buf = Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(1 << 20)) catch return;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |raw| self.addLine(std.mem.trimEnd(u8, raw, "\r"), base, strip);
    }

    /// Parse one gitignore-dialect line into a `Rule` (comments/blank lines drop).
    fn addLine(self: *Ignore, raw: []const u8, base: []const u8, strip: []const u8) void {
        var line = raw;
        if (line.len == 0 or line[0] == '#') return;
        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
        } else if (line.len > 1 and line[0] == '\\' and (line[1] == '#' or line[1] == '!')) {
            line = line[1..]; // escaped leading '#'/'!' → literal
        }
        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        var anchored = false;
        if (line.len > 0 and line[0] == '/') {
            anchored = true;
            line = line[1..];
        } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
            anchored = true;
        }
        if (line.len == 0) return;
        // Parent-file re-anchoring: an ANCHORED ancestor rule is anchored to that
        // ancestor, so only the slice under the search subtree (`strip` = CWD
        // relative to the ancestor) can affect the walk — strip that prefix, or
        // drop the rule if it targets a sibling. A slash-less rule matches a
        // basename at any depth, so it already applies under CWD unchanged.
        if (strip.len != 0 and anchored) {
            if (line.len > strip.len and std.mem.startsWith(u8, line, strip) and line[strip.len] == '/') {
                line = line[strip.len + 1 ..];
            } else return;
        }
        if (line.len == 0) return;
        self.rules.append(self.a, .{
            .glob = self.a.dupe(u8, line) catch die("oom\n", .{}),
            .base = base,
            .negated = negated,
            .anchored = anchored,
            .dir_only = dir_only,
        }) catch die("oom\n", .{});
    }

    /// Does rule `r` match candidate `rel` (a dir when `is_dir`)? Applies the
    /// rule's base scoping, then anchored full/ancestor matching or slash-less
    /// any-component matching, honoring the directory-only restriction.
    fn match(self: *const Ignore, r: Rule, rel_in: []const u8, is_dir: bool) bool {
        const rel = stripDot(rel_in); // a `./root` positional prefixes every path
        var sub = rel;
        const base = stripDot(r.base);
        // A `base==""` rule is CWD/ancestor-sourced (root `.gitignore`, every
        // `loadParents` row, `.git/info/exclude`): it spans the whole tree, so
        // `sub` starts at rel's first component same as a whole-CWD walk. When
        // the walk root is instead an explicit positional path, `rel` carries
        // that root's own components as its prefix — floor the match at that
        // depth so a rule can't fire against the root's own path (ripgrep
        // exempts a depth-0/root entry from every ignore check; see
        // `scopeToRoot`'s doc comment) while its genuine descendants (deeper
        // than the root) are still filtered normally.
        const floor: usize = if (base.len == 0) self.explicit_root_depth else 0;
        if (base.len != 0) {
            if (rel.len <= base.len or !std.mem.startsWith(u8, rel, base) or rel[base.len] != '/') return false;
            sub = rel[base.len + 1 ..];
        }
        if (sub.len == 0) return false;
        if (r.anchored) {
            var s = sub;
            var full = true;
            while (true) {
                const depth = std.mem.count(u8, s, "/") + 1;
                if (depth > floor and self.glob(r.glob, s) and (!r.dir_only or !full or is_dir)) return true;
                const slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse return false;
                s = s[0..slash];
                full = false;
            }
        }
        // Slash-less: match any single path component (basename at any depth). A
        // non-final component is always a directory; the final one only counts for
        // a dir-only rule when the entry itself is a directory.
        var it = std.mem.splitScalar(u8, sub, '/');
        var idx: usize = 0;
        while (it.next()) |comp| : (idx += 1) {
            const last = it.index == null;
            if (idx >= floor and self.glob(r.glob, comp) and (!r.dir_only or !last or is_dir)) return true;
        }
        return false;
    }

    fn glob(self: *const Ignore, pat: []const u8, str: []const u8) bool {
        if (!self.o.ignore_case_insensitive) return gl.globMatch(pat, str);
        return gl.globMatch(lower(self.a, pat), lower(self.a, str));
    }
};

fn lower(a: std.mem.Allocator, s: []const u8) []const u8 {
    const o = a.alloc(u8, s.len) catch die("oom\n", .{});
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) []const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch die("oom\n", .{});
}

/// Drop a leading `./` (or a bare `.`) so a `./root` positional's paths compare
/// against ignore rules the same as a bare `root` positional's do.
fn stripDot(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "./")) return s[2..];
    if (std.mem.eql(u8, s, ".")) return "";
    return s;
}

/// The relative path `k` directories above CWD: 1→`..`, 2→`../..`, … .
fn ascend(a: std.mem.Allocator, k: usize) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < k) : (i += 1) buf.appendSlice(a, if (i == 0) ".." else "/..") catch die("oom\n", .{});
    return buf.toOwnedSlice(a) catch die("oom\n", .{});
}

/// Join path components with `/` (e.g. `["a","b"]` → `a/b`).
fn joinComps(a: std.mem.Allocator, comps: []const []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (comps, 0..) |c, i| {
        if (i != 0) buf.append(a, '/') catch die("oom\n", .{});
        buf.appendSlice(a, c) catch die("oom\n", .{});
    }
    return buf.toOwnedSlice(a) catch die("oom\n", .{});
}

/// Levels from CWD up to the nearest ancestor (inclusive of CWD = 0) holding a
/// `.git`, or null if none within a bounded climb — ripgrep's repo discovery.
fn gitRootDepth(io: std.Io) ?usize {
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        var buf: [256]u8 = undefined;
        const path = if (k == 0) "." else blk: {
            var w: usize = 0;
            var i: usize = 0;
            while (i < k) : (i += 1) {
                const seg = if (i == 0) ".." else "/..";
                @memcpy(buf[w .. w + seg.len], seg);
                w += seg.len;
            }
            break :blk buf[0..w];
        };
        if (hasDotGit(io, if (std.mem.eql(u8, path, ".")) "" else path)) return k;
    }
    return null;
}

/// The first line of `buf` (without the terminator), or all of `buf` if none.
fn firstLine(buf: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return buf;
    return buf[0..nl];
}

/// True if `path/.git` exists as a dir or a worktree `.git`-file.
fn hasDotGit(io: std.Io, path: []const u8) bool {
    var buf: [512]u8 = undefined;
    const dg = if (path.len == 0) ".git" else std.fmt.bufPrint(&buf, "{s}/.git", .{path}) catch return false;
    if (Dir.cwd().openDir(io, dg, .{})) |d_const| {
        var d = d_const;
        d.close(io);
        return true;
    } else |_| {}
    const b = Dir.cwd().readFileAlloc(io, dg, std.heap.page_allocator, .limited(4096)) catch return false;
    std.heap.page_allocator.free(b);
    return true;
}

/// True if any positional search root is itself a git repo/worktree — so
/// `rg <flags> some-repo` honors that repo's VCS ignores even when CWD isn't one.
fn anyRootRepo(io: std.Io, roots: []const []const u8) bool {
    for (roots) |r| {
        if (std.mem.eql(u8, r, ".")) continue;
        if (hasDotGit(io, std.mem.trimEnd(u8, r, "/"))) return true;
    }
    return false;
}
