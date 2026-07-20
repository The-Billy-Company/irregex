// MONOLITHIC: one ignore protocol owns parsing, precedence, root scoping, compiled matching, and hidden-file folding so serial and parallel walkers cannot drift
//! irregex — the shared gitignore / .ignore / .rgignore corpus boundary.
//!
//! Split from `run.zig` (the walk shell) the way `args`/`output` are: this
//! module owns ONLY the ignore-rule model — parsing `.gitignore`-dialect lines
//! into anchored/negated/dir-only globs, accumulating them per directory as the
//! walk descends, and deciding whether a candidate path is ignored. It reuses
//! the shared `scope/glob.zig` matcher for the segment-aware `*`/`**`/`?`/`[…]`
//! matching, so gist search, every persisted index, relate, and composed
//! irregex all enumerate the same files.
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
const paths = @import("../scope/paths.zig");
const stripDot = paths.stripDot;
const join = paths.join;
const Dir = std.Io.Dir;
const oom = paths.allocFailure;

/// Filesystem-admission options independent of any CLI grammar. Gist lowers its
/// richer argv state through `from`; corpus/index consumers use the defaults.
pub const Options = struct {
    hidden: bool = false,
    sorted: bool = false,
    no_ignore: bool = false,
    no_ignore_vcs: bool = false,
    no_ignore_dot: bool = false,
    no_ignore_parent: bool = false,
    no_ignore_exclude: bool = false,
    no_ignore_global: bool = false,
    no_ignore_files: bool = false,
    no_require_git: bool = false,
    ignore_case_insensitive: bool = false,
    ignore_files: []const []const u8 = &.{},

    pub fn from(o: anytype) Options {
        return .{
            .hidden = o.hidden,
            .sorted = o.sorted,
            .no_ignore = o.no_ignore,
            .no_ignore_vcs = o.no_ignore_vcs,
            .no_ignore_dot = o.no_ignore_dot,
            .no_ignore_parent = o.no_ignore_parent,
            .no_ignore_exclude = o.no_ignore_exclude,
            .no_ignore_global = o.no_ignore_global,
            .no_ignore_files = o.no_ignore_files,
            .no_require_git = o.no_require_git,
            .ignore_case_insensitive = o.ignore_case_insensitive,
            .ignore_files = o.ignore_files,
        };
    }
};

/// One compiled ignore rule. `glob` is the pattern core (leading `/` and trailing
/// `/` stripped); `base` is the directory (relative to the walk root, "" = root)
/// whose ignore file contributed it. `rank` sorts rules into precedence order —
/// but because rules are appended shallow→deep, low-source→high-source, the list
/// is already ascending, so `decide` just takes the last matching rule's verdict.
/// `pub` (with `parseRuleLine`/`ruleMatch` below) so the parallel pipeline can
/// build immutable per-directory rule chains out of the same parse + match core.
pub const Rule = struct { glob: []const u8, base: []const u8, negated: bool, anchored: bool, dir_only: bool, reanchor_multi_root: bool = false };

/// Parse one gitignore-dialect line into a `Rule` (comments/blank lines → null).
/// The standalone core of `Ignore.addLine`: `base` anchors the rule to the
/// contributing directory; `strip` (non-empty only for an ancestor-directory
/// file) re-anchors an ancestor's anchored rules onto the search subtree.
/// `line` slices alias `raw` — the caller owns the backing bytes' lifetime.
pub fn parseRuleLine(raw: []const u8, base: []const u8, strip: []const u8) ?Rule {
    var line = raw;
    if (line.len == 0 or line[0] == '#') return null;
    const negated = line[0] == '!';
    // escaped leading '#'/'!' → literal
    if (negated or (line.len > 1 and line[0] == '\\' and (line[1] == '#' or line[1] == '!'))) line = line[1..];
    const dir_only = line.len > 0 and line[line.len - 1] == '/';
    if (dir_only) line = line[0 .. line.len - 1];
    const anchored = (line.len > 0 and line[0] == '/') or std.mem.indexOfScalar(u8, line, '/') != null;
    if (line.len > 0 and line[0] == '/') line = line[1..];
    if (line.len == 0) return null;
    // Parent-file re-anchoring: an ANCHORED ancestor rule is anchored to that
    // ancestor, so only the slice under the search subtree (`strip` = CWD
    // relative to the ancestor) can affect the walk — strip that prefix, or
    // drop the rule if it targets a sibling. A slash-less rule matches a
    // basename at any depth, so it already applies under CWD unchanged.
    if (strip.len != 0 and anchored) {
        if (line.len > strip.len and std.mem.startsWith(u8, line, strip) and line[strip.len] == '/') {
            line = line[strip.len + 1 ..];
        } else return null;
    }
    if (line.len == 0) return null;
    return .{ .glob = line, .base = base, .negated = negated, .anchored = anchored, .dir_only = dir_only };
}

/// Does rule `r` match candidate `rel` (a dir when `is_dir`)? The standalone
/// core of `Ignore.match`, parameterized on the two bits of walk state the
/// method drew from `self` — explicit-root depth/re-anchoring and
/// case-insensitive matching (`a` backs the lowercase copies; only touched when
/// `ci` is set). Thread-safe: reads only its arguments.
pub fn ruleMatch(a: std.mem.Allocator, ci: bool, root_depth: usize, reanchor_root: bool, r: Rule, rel_in: []const u8, is_dir: bool) bool {
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
    var floor: usize = if (base.len == 0) root_depth else 0;
    if (base.len != 0) {
        if (rel.len <= base.len or !std.mem.startsWith(u8, rel, base) or rel[base.len] != '/') return false;
        sub = rel[base.len + 1 ..];
    } else if (reanchor_root and r.reanchor_multi_root and root_depth != 0 and r.anchored) {
        // ripgrep builds a separate parent-ignore matcher when argv names
        // multiple roots. Its anchored CWD rules are therefore evaluated
        // relative to each root (`scripts/foo` → `foo`), unlike the one-root
        // walker, which preserves the CWD-relative prefix.
        sub = stripComponents(rel, root_depth);
        floor = 0;
    }
    if (sub.len == 0) return false;
    // ENTITY-ONLY matching (git model): a rule is tested against the candidate
    // itself — its full path (anchored) or its final component (slash-less) —
    // never against ancestor components or path prefixes. Ancestor exclusion
    // is the WALK's job: an ignored directory is pruned when entered, so its
    // descendants are never enumerated; re-testing ancestors here would OR
    // matches across levels and lose per-level last-match-wins (a
    // `!scripts/observe/build/` re-include must not leak down to the
    // `__pycache__/` inside it, and a `build/` exclude must not resurrect
    // against children of that re-included directory).
    if (r.anchored) {
        const depth = std.mem.count(u8, sub, "/") + 1;
        return depth > floor and ruleGlob(a, ci, r.glob, sub) and (!r.dir_only or is_dir);
    }
    // Slash-less: match the basename; dir-only rules require a directory.
    const base_idx = if (std.mem.lastIndexOfScalar(u8, sub, '/')) |s| s + 1 else 0;
    const comp_idx = std.mem.count(u8, sub[0..base_idx], "/");
    return comp_idx >= floor and ruleGlob(a, ci, r.glob, sub[base_idx..]) and (!r.dir_only or is_dir);
}

fn ruleGlob(a: std.mem.Allocator, ci: bool, pat: []const u8, str: []const u8) bool {
    return if (ci) gl.globMatch(lower(a, pat), lower(a, str)) else gl.globMatch(pat, str);
}

/// The CWD/ancestor rule tier ("" bucket) compiled for O(1)-per-entry
/// evaluation — the parallel pipeline's answer to ripgrep's globset. Verdicts
/// are RANKS (rule indices): last-match-wins becomes max-rank-wins, so a
/// literal-basename rule is one hash probe instead of a glob call. Matching
/// is entity-only (`ruleMatch`'s model): basename for slash-less rules, full
/// path for anchored ones — ancestor exclusion is the walk's pruning, never
/// re-derived here. Built once before fan-out; immutable and lock-free.
pub const Compiled = struct {
    rules: []const Rule,
    lit: std.StringHashMap(Slot), // slash-less, meta-free glob → exact basename
    ext: std.StringHashMap(Slot), // slash-less `*.X` (X dot/meta-free) → basename extension
    complex: []const u32, // everything else, ascending rank
    a: std.mem.Allocator,

    /// Best (max) rank per key, split by dir-only: a dir-only rule is
    /// eligible only when the entry itself is a directory.
    const Slot = struct { plain: ?u32 = null, dironly: ?u32 = null };

    /// Compile the "" bucket, or null when this run can't use the fast tier
    /// (case-insensitive matching, or ANY rules bucketed under an explicit
    /// root — e.g. a positional-root repo's `.git/info/exclude`, whose bucket
    /// this tier doesn't model).
    pub fn build(a: std.mem.Allocator, ig: *const Ignore) ?Compiled {
        if (ig.o.ignore_case_insensitive) return null;
        var keys = ig.groups.keyIterator();
        while (keys.next()) |k| if (k.len != 0) return null;
        var self = Compiled{ .rules = &.{}, .lit = std.StringHashMap(Slot).init(a), .ext = std.StringHashMap(Slot).init(a), .complex = &.{}, .a = a };
        const bucket = ig.groups.getPtr("") orelse return self;
        self.rules = bucket.items;
        var cx: std.ArrayList(u32) = .empty;
        for (bucket.items, 0..) |r, i| {
            const rank: u32 = @intCast(i);
            if (!r.anchored and !hasMeta(r.glob)) {
                slotPut(&self.lit, r.glob, rank, r.dir_only);
            } else if (if (r.anchored) null else extKey(r.glob)) |k| {
                slotPut(&self.ext, k, rank, r.dir_only);
            } else {
                cx.append(a, rank) catch oom();
            }
        }
        self.complex = cx.toOwnedSlice(a) catch oom();
        return self;
    }

    /// Max rank matching `rel` (stripped, no `./`). Byte-equivalent to folding
    /// the whole bucket through `ruleMatch` (see `decideAt`) — the root-depth
    /// exemption is structural here: every walked entry sits strictly BELOW
    /// its root, so the entry itself is never the exempt root component.
    pub fn matchRank(self: *const Compiled, rel: []const u8, is_dir: bool, root_depth: usize, reanchor_root: bool) ?u32 {
        var best: ?u32 = null;
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| rel[s + 1 ..] else rel;
        fold(&best, self.lit.get(base), is_dir);
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            if (dot + 1 < base.len) fold(&best, self.ext.get(base[dot + 1 ..]), is_dir);
        }
        // Descending scan with early exit: the first (highest-rank) match wins,
        // and no rule at-or-below `best` can change the verdict.
        var i = self.complex.len;
        while (i > 0) {
            i -= 1;
            const rank = self.complex[i];
            if (best != null and rank <= best.?) break;
            const r = self.rules[rank];
            if (r.dir_only and !is_dir) continue;
            const anchored_rel = if (reanchor_root and r.reanchor_multi_root and root_depth != 0) stripComponents(rel, root_depth) else rel;
            const hit = if (r.anchored) gl.globMatch(r.glob, anchored_rel) else gl.globMatch(r.glob, base);
            if (hit) {
                best = rank;
                break;
            }
        }
        return best;
    }

    fn fold(best: *?u32, slot: ?Slot, is_dir: bool) void {
        const s = slot orelse return;
        if (s.plain) |r| best.* = @max(best.* orelse r, r);
        if (is_dir) if (s.dironly) |r| {
            best.* = @max(best.* orelse r, r);
        };
    }

    fn slotPut(map: *std.StringHashMap(Slot), key: []const u8, rank: u32, dir_only: bool) void {
        const gop = map.getOrPut(key) catch oom();
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (dir_only) gop.value_ptr.dironly = rank else gop.value_ptr.plain = rank;
    }

    fn hasMeta(s: []const u8) bool {
        return std.mem.indexOfAny(u8, s, "*?[\\") != null;
    }

    /// `*.X` with a dot/meta-free X — matchable by basename-extension lookup
    /// (a component matches `*.X` iff its final `.`-suffix is exactly X).
    fn extKey(glob: []const u8) ?[]const u8 {
        if (glob.len < 3 or glob[0] != '*' or glob[1] != '.') return null;
        const x = glob[2..];
        if (hasMeta(x) or std.mem.indexOfScalar(u8, x, '.') != null) return null;
        return x;
    }
};

pub const Ignore = struct {
    a: std.mem.Allocator,
    io: std.Io,
    o: Options,
    // Ignore rules bucketed by the directory (relative to the walk root; "" = the
    // CWD/ancestor tier) whose ignore file contributed them. A candidate path can
    // only be governed by rules from its OWN ANCESTOR directories — a `.gitignore`
    // scopes its subtree, never a sibling's — so `decide` consults just the ""
    // tier plus each ancestor dir's bucket: O(path depth), not O(total rules). A
    // single flat list (the old shape) forced every path to be tested against
    // every rule ever loaded anywhere in the tree, since rules were never scoped
    // back out as the DFS unwound — O(paths × rules), the whole-tree latency wall.
    // Within a bucket, insertion order IS precedence order; across buckets,
    // shallow→deep with last-match-wins (git precedence) — byte-identical verdicts
    // to the old single scan (the same rule sequence, minus the sibling rules that
    // could never match anyway).
    groups: std.StringHashMap(std.ArrayList(Rule)),
    loaded: std.StringHashMap(void), // dirs whose ignore files were read (dedupe)
    use_git: bool = false,
    use_dot: bool = false,
    // ripgrep's unsorted parallel walker re-anchors parent ignore rules for each
    // positional root; its sorted walker and one-root path retain the
    // CWD-relative prefix. This affects anchored `!path/to/root/...` exceptions.
    reanchor_root_rules: bool = false,
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
    pub fn init(a: std.mem.Allocator, io: std.Io, o: Options, roots: []const []const u8) Ignore {
        var self = Ignore{ .a = a, .io = io, .o = o, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .reanchor_root_rules = roots.len > 1 and !o.sorted };
        // `--ignore-file` is EXPLICIT user intent: lowest precedence (added first,
        // so an in-tree `.ignore`/`.gitignore` overrides it — rg's f45 rule) and
        // honored even under `-u`/`--no-ignore` (only `--no-ignore-files` drops it).
        if (!o.no_ignore_files) for (o.ignore_files) |p| self.readFile(p, "", "", false);
        if (o.no_ignore) return self; // -u / --no-ignore: honor nothing else on disk
        // Detect the repo by ASCENDING from CWD — ripgrep finds `.git` at any
        // ancestor, not just CWD; the depth bounds how far VCS ignores climb.
        const git_depth = gitRootDepth(io);
        const git_repo = o.no_require_git or git_depth != null or anyRootRepo(io, roots);
        self.use_git = git_repo and !o.no_ignore_vcs;
        self.use_dot = !o.no_ignore_dot;
        // git's global excludes (`core.excludesFile`) is the LOWEST-precedence VCS
        // ignore tier, so it loads before every repo source below and is overridden
        // by them (last-match-wins). Gated with the rest of the VCS tier (`use_git`),
        // disabled on its own by `--no-ignore-global`.
        if (self.use_git and !o.no_ignore_global) self.loadGlobalExclude();
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
        while (it.next()) |c| if (c.len != 0) comps.append(self.a, c) catch oom();
        var k: usize = comps.items.len; // k levels up (1 = parent, len = filesystem root)
        while (k >= 1) : (k -= 1) {
            const anc = ascend(self.a, k);
            // CWD's path relative to this ancestor = its last k components — an
            // anchored ancestor rule is re-anchored by stripping this prefix.
            const subpath = std.mem.join(self.a, "/", comps.items[comps.items.len - k ..]) catch oom();
            if (self.use_git and git_depth != null and k <= git_depth.?)
                self.readFile(join(self.a, anc, ".gitignore"), "", subpath, true);
            if (self.use_dot) {
                self.readFile(join(self.a, anc, ".ignore"), "", subpath, false);
                self.readFile(join(self.a, anc, ".rgignore"), "", subpath, false);
            }
        }
    }

    /// Read `<repo>/.git/info/exclude` for the repo rooted at `root` (rel path from
    /// CWD; "" = CWD), anchoring its rules to `base`. When `<root>/.git` is a
    /// worktree `.git`-FILE, resolve `gitdir:` → `commondir` (ripgrep's
    /// `resolve_git_commondir`) so a linked worktree honors the shared exclude.
    fn loadGitExclude(self: *Ignore, root: []const u8, base: []const u8) void {
        const git_dir = self.resolveGitDir(root) orelse return;
        self.readFile(join(self.a, git_dir, "info/exclude"), base, "", true);
    }

    /// Read git's global excludes file into the CWD tier ("" bucket). The path is
    /// resolved exactly as ripgrep does (see `globalExcludesPath`); it may not
    /// exist, in which case `readFile` is a no-op. `reanchor_multi_root = true`
    /// mirrors `.git/info/exclude`: an ancestor-tier source, re-anchored per root.
    /// git's global gitignore path (ripgrep parity, `gitconfig_excludes_path`),
    /// reading `$HOME`/`$XDG_CONFIG_HOME` from the process env (stable for the
    /// per-user gist server's lifetime). The env-free resolution is delegated to
    /// `globalExcludesFrom`.
    fn loadGlobalExclude(self: *Ignore) void {
        const xdg = envSpan("XDG_CONFIG_HOME");
        const path = globalExcludesFrom(self.io, self.a, envSpan("HOME"), if (xdg != null and xdg.?.len != 0) xdg else null) orelse return;
        self.readFile(path, "", "", true);
    }

    /// The git common-dir for the repo at `root` (a path openable from CWD), or
    /// null if `root` has no `.git`. A `.git` directory IS the git dir; a `.git`
    /// FILE (linked worktree) is followed through `gitdir:` then its `commondir`.
    fn resolveGitDir(self: *Ignore, root: []const u8) ?[]const u8 {
        const dot_git = join(self.a, root, ".git");
        if (dirExists(self.io, dot_git)) return dot_git; // plain repo: `.git` is the git dir
        const gitfile = Dir.cwd().readFileAlloc(self.io, dot_git, self.a, .limited(4096)) catch return null;
        const line0 = std.mem.trimEnd(u8, firstLine(gitfile), "\r");
        if (!std.mem.startsWith(u8, line0, "gitdir: ")) return null;
        const real_git_dir = std.mem.trim(u8, line0["gitdir: ".len..], " ");
        const commondir = Dir.cwd().readFileAlloc(self.io, join(self.a, real_git_dir, "commondir"), self.a, .limited(4096)) catch return null;
        const cd = std.mem.trimEnd(u8, firstLine(commondir), "\r");
        // A relative commondir is joined to the worktree git dir; an absolute one
        // is used as-is (the OS resolves the embedded `..`).
        return if (cd.len > 0 and cd[0] == '.') join(self.a, real_git_dir, cd) else self.a.dupe(u8, cd) catch oom();
    }

    /// Scope subsequent `decide`/`shouldSkip` calls to a positional root path
    /// (`prefix`, as passed to the walker — may carry a leading `./`) about to
    /// be walked; `""`/`"."` means the implicit whole-CWD walk. Must be called
    /// before walking each explicit root (`gather` does this per positional
    /// PATH arg) so ancestor/CWD-sourced rules (`Rule.base == ""`) can't match
    /// the root's own path components — only its descendants.
    pub fn scopeToRoot(self: *Ignore, prefix: []const u8) void {
        self.explicit_root_depth = paths.rootDepth(prefix);
    }

    /// Load the per-directory ignore files for `rel` (relative to the walk root;
    /// on-disk path `disk`) exactly once, as the walk is about to descend into it.
    pub fn loadDir(self: *Ignore, disk: []const u8, rel: []const u8) void {
        if (self.o.no_ignore) return;
        const gop = self.loaded.getOrPut(rel) catch oom();
        if (gop.found_existing) return;
        gop.key_ptr.* = self.a.dupe(u8, rel) catch oom(); // own the key (rel may be transient)
        if (self.use_git) self.readFile(join(self.a, disk, ".gitignore"), rel, "", true);
        if (self.use_dot) {
            self.readFile(join(self.a, disk, ".ignore"), rel, "", false);
            self.readFile(join(self.a, disk, ".rgignore"), rel, "", false);
        }
    }

    /// The ignore verdict for a candidate path (relative to the walk root): null =
    /// no rule matched, true = ignored, false = explicitly whitelisted. Last
    /// matching rule wins (the list is pre-ordered by precedence).
    pub fn decide(self: *const Ignore, rel: []const u8, is_dir: bool) ?bool {
        return self.decideAt(rel, is_dir, self.explicit_root_depth);
    }

    /// `decide` with the explicit-root depth passed per call instead of read from
    /// the (mutable) `explicit_root_depth` field — the thread-safe form the
    /// parallel pipeline uses against a FROZEN `Ignore` (no `loadDir`/`scopeToRoot`
    /// after the walk fans out): every task carries its own root depth, so
    /// interleaved tasks from different positional roots can't race the field.
    pub fn decideAt(self: *const Ignore, rel: []const u8, is_dir: bool, root_depth: usize) ?bool {
        var verdict: ?bool = null;
        // The CWD/ancestor tier (root `.gitignore`, parents, `.git/info/exclude`,
        // `--ignore-file`) governs every path; then each ANCESTOR directory of
        // `rel`, shallow→deep, so the deepest matching rule wins (git precedence).
        self.applyGroup("", rel, is_dir, root_depth, &verdict);
        const stripped = stripDot(rel);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, stripped, i, '/')) |slash| {
            self.applyGroup(stripped[0..slash], rel, is_dir, root_depth, &verdict);
            i = slash + 1;
        }
        return verdict;
    }

    /// Fold one directory bucket's rules into `verdict` (last match wins). The
    /// bucket key is a directory path relative to the walk root ("" = CWD tier);
    /// `match` still does its own base/anchor/dir-only work, so feeding it only
    /// ancestor-sourced rules changes which rules are *tried*, never the verdict.
    fn applyGroup(self: *const Ignore, base_key: []const u8, rel: []const u8, is_dir: bool, root_depth: usize, verdict: *?bool) void {
        const g = self.groups.getPtr(base_key) orelse return;
        for (g.items) |r| if (ruleMatch(self.a, self.o.ignore_case_insensitive, root_depth, self.reanchor_root_rules, r, rel, is_dir)) {
            verdict.* = !r.negated;
        };
    }

    /// Should the walk drop this entry? Folds `.git` + gitignore + the dotfile
    /// skip, each with ripgrep's whitelist-override asymmetry (proven against rg's
    /// own walk): `wl_ignore` (a `-g`/`--iglob` override match) bypasses `.git`
    /// AND gitignore; `wl_hidden` (a `-g`/`--iglob` OR `-t`/`-t all` match)
    /// bypasses only the hidden-dotfile skip. A type filter un-hides but never
    /// un-ignores; an override does both. `wl_hidden ⊇ wl_ignore` by construction.
    pub fn shouldSkip(self: *const Ignore, rel: []const u8, is_dir: bool, basename: []const u8, wl_ignore: bool, wl_hidden: bool) bool {
        return self.skipFromVerdict(self.decide(rel, is_dir), is_dir, basename, wl_ignore, wl_hidden);
    }

    /// Certify one already-discovered file against the same ancestor-pruning
    /// semantics as a live walk. Freshness overlays use this after their
    /// metadata-only fan-out so a newly changed ignored file cannot enter an
    /// otherwise gitignore-clean persisted corpus.
    pub fn admitsPath(self: *Ignore, root: []const u8, rel_in: []const u8) bool {
        const rel = stripDot(rel_in);
        self.scopeToRoot(root);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
            const dir = rel[0..slash];
            i = slash + 1;
            if (dir.len == 0) continue;
            const name = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |s| dir[s + 1 ..] else dir;
            if (self.shouldSkip(dir, true, name, false, false)) return false;
            self.loadDir(dir, dir);
        }
        const name = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |s| rel[s + 1 ..] else rel;
        return !self.shouldSkip(rel, false, name, false, false);
    }

    /// Fold a base-tier verdict (`decideAt`) with the hidden-dotfile rule the same
    /// way `shouldSkip` does, but from an ALREADY-COMPUTED verdict — the parallel
    /// pipeline computes the base verdict and its per-directory chain verdicts
    /// separately (deepest wins), then applies this shared final step. Takes the
    /// same `wl_ignore`/`wl_hidden` override pair as `shouldSkip` (see its doc
    /// comment) so a `-g`/`--iglob`/`-t` whitelist force-searches identically on
    /// both engines — the parallel pipeline must never regress this asymmetry
    /// just because it derives the verdict differently.
    pub fn skipFromVerdict(self: *const Ignore, v: ?bool, is_dir: bool, basename: []const u8, wl_ignore: bool, wl_hidden: bool) bool {
        if (is_dir and std.mem.eql(u8, basename, ".git")) return !wl_ignore;
        if (v == true) return !wl_ignore;
        const hidden = basename.len > 0 and basename[0] == '.';
        if (hidden and !self.o.hidden and v != false) return !wl_hidden;
        return false;
    }

    // ─────────────────────────── internals ───────────────────────────

    /// Read `path`'s ignore lines, anchoring each to `base`. `strip` (non-empty
    /// only for a parent-directory file) is CWD's path relative to that ancestor;
    /// it re-anchors the ancestor's anchored rules onto the search subtree.
    fn readFile(self: *Ignore, path: []const u8, base: []const u8, strip: []const u8, reanchor_multi_root: bool) void {
        const buf = readOpt(self.io, self.a, path) orelse return;
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |raw| self.addLine(std.mem.trimEnd(u8, raw, "\r"), base, strip, reanchor_multi_root);
    }

    /// Parse one gitignore-dialect line into a `Rule` (comments/blank lines drop)
    /// and bucket it by source directory — the container half of `parseRuleLine`.
    fn addLine(self: *Ignore, raw: []const u8, base: []const u8, strip: []const u8, reanchor_multi_root: bool) void {
        const parsed = parseRuleLine(raw, base, strip) orelse return;
        // Bucket by the source directory (normalized like `ruleMatch` does, so a
        // "." / "./x" base and its rel-side counterpart collapse to the same key).
        const key = stripDot(base);
        const gop = self.groups.getOrPut(key) catch oom();
        if (!gop.found_existing) {
            gop.key_ptr.* = self.a.dupe(u8, key) catch oom();
            gop.value_ptr.* = .empty;
        }
        var owned = parsed;
        owned.glob = self.a.dupe(u8, parsed.glob) catch oom();
        owned.reanchor_multi_root = reanchor_multi_root;
        gop.value_ptr.append(self.a, owned) catch oom();
    }
};

// The shared ASCII case fold (`paths.zig`) — one definition for gitignore's
// byte-wise caseless glob tier and args.zig's `--iglob` fold.
const lower = paths.lowerDup;

// HOME/XDG resolution borrows libc's process-stable environment storage.
fn envSpan(key: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(key) orelse return null);
}

/// Best-effort whole-file read (≤1 MiB); null on any error (missing/unreadable),
/// matching git/ripgrep's "absent global config is simply no rules" behavior.
fn readOpt(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch null;
}

/// Extract `core.excludesfile` from raw git-config bytes, ripgrep's deliberately
/// lazy `(?im-u)^\s*excludesfile\s*=\s*"?\s*(\S+?)\s*"?\s*$`: the FIRST line whose
/// (case-insensitive) key is `excludesfile`, one optional quote + surrounding
/// whitespace stripped from each side, and a value that is a single whitespace-free
/// token (an interior space fails the anchor, so scanning continues). Section
/// headers are ignored exactly as ripgrep ignores them. Returned slice aliases
/// `data`; the caller tilde-expands and owns the copy.
fn parseExcludesFile(data: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| if (excludesValue(std.mem.trimEnd(u8, raw, "\r"))) |v| return v;
    return null;
}

fn excludesValue(line: []const u8) ?[]const u8 {
    const ws = " \t";
    const key = "excludesfile";
    var s = std.mem.trimStart(u8, line, ws);
    if (s.len < key.len or !std.ascii.eqlIgnoreCase(s[0..key.len], key)) return null;
    s = std.mem.trimStart(u8, s[key.len..], ws);
    if (s.len == 0 or s[0] != '=') return null;
    s = std.mem.trim(u8, s[1..], ws);
    if (s.len != 0 and s[0] == '"') s = std.mem.trimStart(u8, s[1..], ws);
    if (s.len != 0 and s[s.len - 1] == '"') s = std.mem.trimEnd(u8, s[0 .. s.len - 1], ws);
    if (s.len == 0 or std.mem.indexOfAny(u8, s, ws) != null) return null;
    return s;
}

/// Expand every `~` to `$HOME` (ripgrep's `expand_tilde`: a plain `replace`, not
/// just a leading-`~` rule). Always returns an arena-owned copy so the caller can
/// hold it past `data`'s lifetime.
fn expandTilde(a: std.mem.Allocator, home: ?[]const u8, s: []const u8) []const u8 {
    const h = home orelse return a.dupe(u8, s) catch oom();
    if (std.mem.indexOfScalar(u8, s, '~') == null) return a.dupe(u8, s) catch oom();
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| (if (c == '~') buf.appendSlice(a, h) else buf.append(a, c)) catch oom();
    return buf.toOwnedSlice(a) catch oom();
}

/// Resolve git's global excludes path from explicit `home`/`xdg` (env-free, so
/// it is directly testable): `core.excludesfile` from `<home>/.gitconfig`, else
/// from `<xdg|home/.config>/git/config`, else that base's default `git/ignore`.
/// `~` in a configured value expands to `home`. The returned path need not exist
/// — the caller's `readFile` tolerates a miss.
fn globalExcludesFrom(io: std.Io, a: std.mem.Allocator, home: ?[]const u8, xdg: ?[]const u8) ?[]const u8 {
    if (home) |h| if (readOpt(io, a, join(a, h, ".gitconfig"))) |data| {
        if (parseExcludesFile(data)) |raw| return expandTilde(a, home, raw);
    };
    // `<home>/.gitconfig` didn't decide it → the XDG (or `<home>/.config`) config,
    // then that same base's default `git/ignore`.
    const cfg_home = xdg orelse (if (home) |h| join(a, h, ".config") else null);
    const c = cfg_home orelse return null;
    if (readOpt(io, a, join(a, c, "git/config"))) |data| {
        if (parseExcludesFile(data)) |raw| return expandTilde(a, home, raw);
    }
    return join(a, c, "git/ignore");
}

/// Remove `count` leading path components, counting a leading `/` as the empty
/// component exactly as `rootDepth` does for absolute positional roots.
fn stripComponents(path: []const u8, count: usize) []const u8 {
    var rest = path;
    for (0..count) |_| rest = rest[(std.mem.indexOfScalar(u8, rest, '/') orelse return "") + 1 ..];
    return rest;
}

/// The relative path `k` directories above CWD: 1→`..`, 2→`../..`, … .
fn ascend(a: std.mem.Allocator, k: usize) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (0..k) |i| buf.appendSlice(a, if (i == 0) ".." else "/..") catch oom();
    return buf.toOwnedSlice(a) catch oom();
}

/// Levels from CWD up to the nearest ancestor (inclusive of CWD = 0) holding a
/// `.git`, or null if none within a bounded climb — ripgrep's repo discovery.
/// The `../..` probe path grows incrementally in one stack buffer (k=0 = "").
fn gitRootDepth(io: std.Io) ?usize {
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    for (0..64) |k| {
        if (k > 0) {
            const seg: []const u8 = if (k == 1) ".." else "/..";
            @memcpy(buf[w..][0..seg.len], seg);
            w += seg.len;
        }
        if (hasDotGit(io, buf[0..w])) return k;
    }
    return null;
}

/// The first line of `buf` (without the terminator), or all of `buf` if none.
fn firstLine(buf: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse return buf;
    return buf[0..nl];
}

/// True if `path` opens as a directory — the shared `.git` dir probe.
fn dirExists(io: std.Io, path: []const u8) bool {
    var d = Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// True if `path/.git` exists as a dir or a worktree `.git`-file.
fn hasDotGit(io: std.Io, path: []const u8) bool {
    var buf: [512]u8 = undefined;
    const dg = if (path.len == 0) ".git" else std.fmt.bufPrint(&buf, "{s}/.git", .{path}) catch return false;
    if (dirExists(io, dg)) return true;
    const b = Dir.cwd().readFileAlloc(io, dg, std.heap.page_allocator, .limited(4096)) catch return false;
    std.heap.page_allocator.free(b);
    return true;
}

/// True if any positional search root is itself a git repo/worktree — so
/// `rg <flags> some-repo` honors that repo's VCS ignores even when CWD isn't one.
fn anyRootRepo(io: std.Io, roots: []const []const u8) bool {
    for (roots) |r| if (!std.mem.eql(u8, r, ".") and hasDotGit(io, std.mem.trimEnd(u8, r, "/"))) return true;
    return false;
}

test "parseExcludesFile mirrors ripgrep's core.excludesfile extraction" {
    const t = std.testing;
    // rg parse_excludes_file 1–5, byte-for-byte on the same inputs.
    try t.expectEqualStrings("/foo/bar", parseExcludesFile("[core]\nexcludesFile = /foo/bar").?);
    try t.expectEqualStrings("~/foo/bar", parseExcludesFile("[core]\nexcludesFile = ~/foo/bar").?);
    try t.expectEqual(@as(?[]const u8, null), parseExcludesFile("[core]\nexcludeFile = /foo/bar")); // missing 's'
    try t.expectEqualStrings("~/foo/bar", parseExcludesFile("[core]\nexcludesFile = \"~/foo/bar\"").?);
    try t.expectEqual(@as(?[]const u8, null), parseExcludesFile("[core]\nexcludesFile = \" \"~/foo/bar \" \"")); // interior space fails the anchor
    // Case-insensitive key, section-agnostic (rg's lazy regex ignores headers),
    // and a malformed earlier line does not shadow a valid later one.
    try t.expectEqualStrings("/a", parseExcludesFile("EXCLUDESFILE=/a").?);
    try t.expectEqualStrings("/good", parseExcludesFile("excludesfile = a b\nexcludesfile = /good").?);
    try t.expectEqual(@as(?[]const u8, null), parseExcludesFile("[core]\n\tpager = less\n"));
}

test "expandTilde replaces every tilde with $HOME, else copies verbatim" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/home/u/foo/bar", expandTilde(a, "/home/u", "~/foo/bar"));
    try t.expectEqualStrings("/home/u+/home/u", expandTilde(a, "/home/u", "~+~")); // plain replace, not just leading
    try t.expectEqualStrings("/abs/path", expandTilde(a, "/home/u", "/abs/path")); // no tilde ⇒ verbatim copy
    try t.expectEqualStrings("~/x", expandTilde(a, null, "~/x")); // no HOME ⇒ left untouched
}

test "globalExcludesFrom: gitconfig ≻ xdg config ≻ default, tilde-expanded" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const home = "/tmp/gist_glob_excludes_fixture";
    Dir.cwd().deleteTree(io, home) catch {};
    try Dir.cwd().createDirPath(io, home);
    defer Dir.cwd().deleteTree(io, home) catch {};

    // No config file anywhere ⇒ the default `<home>/.config/git/ignore` (a path
    // that need not exist), and an XDG override redirects that default base.
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/.config/git/ignore", .{home}), globalExcludesFrom(io, a, home, null).?);
    const xdg = try std.fmt.allocPrint(a, "{s}/xdg", .{home});
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/git/ignore", .{xdg}), globalExcludesFrom(io, a, home, xdg).?);

    // `<home>/.config/git/config`'s excludesfile beats the bare default…
    try Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/.config/git", .{home}));
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/.config/git/config", .{home}), .data = "[core]\n\texcludesfile = /explicit/cfg\n" });
    try t.expectEqualStrings("/explicit/cfg", globalExcludesFrom(io, a, home, null).?);

    // …and `<home>/.gitconfig` outranks the XDG config, with `~` → home.
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/.gitconfig", .{home}), .data = "[core]\n\texcludesFile = ~/mygi\n" });
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/mygi", .{home}), globalExcludesFrom(io, a, home, null).?);
}

test "a global-sourced ignore file drives the CWD-tier verdict (loadGlobalExclude mechanic)" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = "/tmp/gist_globrule_fixture";
    Dir.cwd().deleteTree(io, dir) catch {};
    try Dir.cwd().createDirPath(io, dir);
    defer Dir.cwd().deleteTree(io, dir) catch {};
    const gi = try std.fmt.allocPrint(a, "{s}/globalignore", .{dir});
    try Dir.cwd().writeFile(io, .{ .sub_path = gi, .data = "*.log\n!keep.log\n" });

    var ig = Ignore{ .a = a, .io = io, .o = .{}, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a) };
    // Exactly what `loadGlobalExclude` does with the resolved path: fold the
    // global file into the "" (CWD/ancestor) tier, lowest precedence.
    ig.readFile(gi, "", "", true);
    try t.expectEqual(@as(?bool, true), ig.decide("app.log", false)); // *.log ignored
    try t.expectEqual(@as(?bool, false), ig.decide("keep.log", false)); // later !keep.log re-includes
    try t.expectEqual(@as(?bool, null), ig.decide("app.txt", false)); // untouched
}

test "multi-root VCS rules re-anchor without changing one-root semantics" {
    const t = std.testing;
    const rule = Rule{ .glob = "scripts/observe/build", .base = "", .negated = true, .anchored = true, .dir_only = true, .reanchor_multi_root = true };
    try t.expect(ruleMatch(t.allocator, false, 1, false, rule, "scripts/observe/build", true));
    try t.expect(!ruleMatch(t.allocator, false, 1, true, rule, "scripts/observe/build", true));
}

test "compiled matcher preserves multi-root VCS re-anchoring" {
    const t = std.testing;
    const rules = [_]Rule{
        .{ .glob = "build", .base = "", .negated = false, .anchored = false, .dir_only = true },
        .{ .glob = "scripts/observe/build", .base = "", .negated = true, .anchored = true, .dir_only = true, .reanchor_multi_root = true },
    };
    var complex = [_]u32{1};
    var compiled = Compiled{ .rules = &rules, .lit = std.StringHashMap(Compiled.Slot).init(t.allocator), .ext = std.StringHashMap(Compiled.Slot).init(t.allocator), .complex = &complex, .a = t.allocator };
    defer compiled.lit.deinit();
    defer compiled.ext.deinit();
    Compiled.slotPut(&compiled.lit, "build", 0, true);

    try t.expectEqual(@as(?u32, 1), compiled.matchRank("scripts/observe/build", true, 1, false));
    try t.expectEqual(@as(?u32, 0), compiled.matchRank("scripts/observe/build", true, 1, true));
}
