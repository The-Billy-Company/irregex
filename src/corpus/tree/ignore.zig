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
//!     unless `--no-require-git`; `--no-ignore*` / `-u` disable the relevant tier;
//!   • a VCS rule governs only its OWN repository: rules from directories above
//!     the nearest enclosing `.git` stop at that boundary (ripgrep's `saw_git`).

const std = @import("std");
const gl = @import("../../kernel/math/glob.zig");
const paths = @import("../scope/paths.zig");
const assay = @import("../../assay/assay.zig");
const fault = @import("../../fault.zig");
const portal = @import("../../portal.zig");
const stripDot = paths.stripDot;
const join = paths.join;
const Dir = std.Io.Dir;

/// Allocation failure is the only fault this module can raise, and it RETURNS
/// rather than exiting: every entry below runs inside `irregex_open` /
/// `irregex_search` as well as inside the CLI, and a `process.exit(2)` there
/// kills the embedding host instead of handing it a status (fault-channel law 1).
/// The command plane absorbs it at its own top level with `catch oom()`, so the
/// CLI's exit code and OOM notice are unchanged.
///
/// It stops at the *verdict* path on purpose. `decide` / `decideAt` /
/// `shouldSkip` / `ruleMatch` / `applyChain` / `Compiled.matchRank` stay
/// infallible: they allocate only through `ruleGlob`'s case fold, which needs
/// `Options.ignore_case_insensitive`, and they are the per-entry inner loop of
/// both walkers. Threading an error union through them would price every
/// directory entry in the tree for a path the C seam cannot select.
const Oom = std.mem.Allocator.Error;

/// Filesystem-admission options independent of any CLI grammar. Gist lowers its
/// richer argv state through `from`; corpus/index consumers use the defaults.
pub const Options = struct {
    hidden: bool = false,
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
/// `vcs` marks a rule as belonging to ONE repository — a `.gitignore` or a
/// `.git/info/exclude`. Only those stop at a nested repository boundary (see
/// `boundary`); `.ignore`/`.rgignore`, `--ignore-file`, and git's *global*
/// excludes span every repo they are above, exactly as ripgrep's per-level
/// `saw_git` gate scopes `git_ignore`/`git_exclude` but never the custom
/// matchers or the one global matcher it keeps at the walk root.
pub const Rule = struct { glob: []const u8, base: []const u8, negated: bool, anchored: bool, dir_only: bool, vcs: bool = false };

/// Parse one gitignore-dialect line into a `Rule` (comments/blank lines → null).
/// The standalone core of `Ignore.addLine`: `base` anchors the rule to the
/// contributing directory; `strip` (non-empty only for an ancestor-directory
/// file) re-anchors an ancestor's anchored rules onto the search subtree.
/// `line` slices alias `raw` — the caller owns the backing bytes' lifetime,
/// and owning it is also where a glob's asterisk runs are normalized (see
/// `ownGlob`), since that is the step that can allocate.
pub fn parseRuleLine(raw: []const u8, base: []const u8, strip: []const u8) ?Rule {
    var line = raw;
    if (line.len == 0 or line[0] == '#') return null;
    const negated = line[0] == '!';
    // escaped leading '#'/'!' → literal
    if (negated or (line.len > 1 and line[0] == '\\' and (line[1] == '#' or line[1] == '!'))) line = line[1..];
    const dir_only = line.len > 0 and line[line.len - 1] == '/';
    if (dir_only) {
        line = line[0 .. line.len - 1];
        // rg #2236: a trailing `/` that was itself escaped (`foo\/`) still marks
        // the rule dir-only, but the escaping `\` must not survive into the glob —
        // drop it so the rule matches directory `foo`, not `foo\`.
        if (line.len > 0 and line[line.len - 1] == '\\') line = line[0 .. line.len - 1];
    }
    const anchored = (line.len > 0 and line[0] == '/') or std.mem.indexOfScalar(u8, line, '/') != null;
    if (line.len > 0 and line[0] == '/') line = line[1..];
    if (line.len == 0) return null;
    // Parent-file re-anchoring: an ANCHORED ancestor rule is anchored to that
    // ancestor, so only the slice under the search subtree (`strip` = CWD
    // relative to the ancestor) can affect the walk — strip that prefix, or
    // drop the rule if it targets a sibling. A slash-less rule matches a
    // basename at any depth, so it already applies under CWD unchanged.
    if (strip.len != 0 and anchored) {
        if (std.mem.startsWith(u8, line, "**/")) {
            // A leading `**/` is git's "in this directory or any subdirectory" —
            // depth-independent, so an anchored ancestor rule with this prefix
            // applies under the search subtree UNCHANGED. Never strip it to the
            // CWD-relative prefix (there is none to strip) nor drop it as a
            // sibling: `**/bar/*` at the repo root still governs `bar/*` from CWD.
        } else if (line.len > strip.len and std.mem.startsWith(u8, line, strip) and line[strip.len] == '/') {
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
pub fn ruleMatch(a: std.mem.Allocator, ci: bool, root_depth: usize, r: Rule, rel_in: []const u8, is_dir: bool) bool {
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
    // than the root) are still filtered normally. Multiple explicit roots
    // sharing a common ancestor evaluate that ancestor's rules against the
    // same CWD-relative path for EVERY root (rg 15.2's #3320/#3376 fix — the
    // parent matcher is keyed by absolute base, so it is order-independent),
    // which is exactly this single, un-reanchored path.
    const floor: usize = if (base.len == 0) root_depth else 0;
    if (base.len != 0) {
        if (rel.len <= base.len or !std.mem.startsWith(u8, rel, base) or rel[base.len] != '/') return false;
        sub = rel[base.len + 1 ..];
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

/// Take ownership of a parsed rule's glob, normalizing asterisk runs the way
/// git reads them: `**` is the "any number of path components" wildcard ONLY as
/// a whole component (`**/x`, `x/**`, `x/**/y`, or a bare `**`) — anywhere else
/// "consecutive asterisks are considered regular asterisks and will match
/// according to the previous rules" (gitignore(5)), i.e. one `*` that does not
/// cross a `/`. rust's `tests/rustdoc-gui/src/**.lock` is the live case: it
/// ignores `src/x.lock` and NOT `src/lib2/Cargo.lock`, which a component-blind
/// `**` swallowed — 13 files short of ripgrep on a rust checkout.
fn ownGlob(a: std.mem.Allocator, glob: []const u8) Oom![]const u8 {
    var i: usize = 0;
    var out: ?std.ArrayList(u8) = null;
    while (std.mem.indexOfScalarPos(u8, glob, i, '*')) |start| {
        var end = start;
        while (end < glob.len and glob[end] == '*') end += 1;
        const whole = end - start >= 2 and
            (start == 0 or glob[start - 1] == '/') and
            (end == glob.len or glob[end] == '/');
        if (end - start >= 2 and !whole) {
            // First offender in this glob — copy what precedes it, then keep
            // appending. Untouched globs (the overwhelming majority) never
            // build a list and take the plain `dupe` below.
            if (out == null) {
                var l: std.ArrayList(u8) = .empty;
                try l.appendSlice(a, glob[0..start]);
                out = l;
            }
            try out.?.append(a, '*');
        } else if (out) |*l| try l.appendSlice(a, glob[start..end]);
        if (out) |*l| {
            const stop = std.mem.indexOfScalarPos(u8, glob, end, '*') orelse glob.len;
            try l.appendSlice(a, glob[end..stop]);
        }
        i = end;
    }
    if (out) |*l| return l.toOwnedSlice(a);
    return a.dupe(u8, glob);
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
    pub fn build(a: std.mem.Allocator, ig: *const Ignore) Oom!?Compiled {
        if (ig.o.ignore_case_insensitive) return null;
        var keys = ig.groups.keyIterator();
        while (keys.next()) |k| if (k.len != 0) return null;
        const bucket = ig.groups.getPtr("") orelse return empty(a);
        return try compileBase(a, bucket.items, false);
    }

    /// The fast tier over a single CWD/ancestor ("" base) rule slice — the reusable
    /// core of `build`, also driven directly by the serial engine's per-tier
    /// `Ignore.base_compiled` so its `decideAt` folds the universal "" bucket in
    /// O(1) probes instead of a glob call per rule per path (ripgrep's globset
    /// parity on the single-threaded walk). Caller guarantees case-sensitive
    /// matching (the tier can't fold case) and base == "" rules (entity-only,
    /// see `matchRank`). `rules` must outlive the returned matcher.
    ///
    /// `skip_vcs` builds the same tier with every repository-scoped rule left
    /// out — the form a path BELOW a nested repository root is judged by (see
    /// `boundary`). It has to be its own matcher rather than a probe-time
    /// filter: a hash slot keeps one rank per key, so dropping a `.gitignore`
    /// rule at probe time would lose the lower-ranked `.ignore` rule it
    /// shadowed instead of falling back to it. Ranks stay indices into the
    /// FULL `rules` slice, so `matchRank`'s `rules[rank]` is unchanged.
    pub fn compileBase(a: std.mem.Allocator, rules: []const Rule, skip_vcs: bool) Oom!Compiled {
        var self = empty(a);
        self.rules = rules;
        var cx: std.ArrayList(u32) = .empty;
        for (rules, 0..) |r, i| {
            const rank: u32 = @intCast(i);
            if (skip_vcs and r.vcs) continue;
            if (!r.anchored and !hasMeta(r.glob)) {
                try slotPut(&self.lit, r.glob, rank, r.dir_only);
            } else if (if (r.anchored) null else extKey(r.glob)) |k| {
                try slotPut(&self.ext, k, rank, r.dir_only);
            } else {
                try cx.append(a, rank);
            }
        }
        self.complex = try cx.toOwnedSlice(a);
        return self;
    }

    fn empty(a: std.mem.Allocator) Compiled {
        return .{ .rules = &.{}, .lit = std.StringHashMap(Slot).init(a), .ext = std.StringHashMap(Slot).init(a), .complex = &.{}, .a = a };
    }

    /// Max rank matching `rel` (stripped, no `./`). Byte-equivalent to folding
    /// the whole bucket through `ruleMatch` (see `decideAt`) — the root-depth
    /// exemption is structural here: every walked entry sits strictly BELOW
    /// its root, so the entry itself is never the exempt root component.
    pub fn matchRank(self: *const Compiled, rel: []const u8, is_dir: bool) ?u32 {
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
            const hit = if (r.anchored) gl.globMatch(r.glob, rel) else gl.globMatch(r.glob, base);
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

    fn slotPut(map: *std.StringHashMap(Slot), key: []const u8, rank: u32, dir_only: bool) Oom!void {
        const gop = try map.getOrPut(key);
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
    // Directories (relative to the walk root; "" = CWD) that hold a `.git` —
    // i.e. repository roots this walk has SEEN. A `.gitignore` governs its own
    // repository only, so a path below a nested repo root is judged without the
    // VCS rules of anything above that root (`boundary`). Populated by `loadDir`
    // as the serial walk descends, one stat per directory — the same probe
    // ripgrep pays per level (`dir.join(".git").exists()`). The parallel walkers
    // read `.git` out of the directory listing they already have and carry it on
    // their `IgNode` chain instead, so they add no syscall at all.
    repos: std.StringHashMap(void),
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
    // The "" (CWD/ancestor) tier compiled to the globset fast path, or null when
    // this run can't use it (case-insensitive matching folds no case here). The
    // "" bucket is FINAL once `init` returns — `loadDir` only ever appends to
    // per-directory keys — so it is compiled once at construction and read
    // lock-free thereafter (safe for the parallel `decideAt` fallback, which runs
    // it from many threads against a frozen `Ignore`). `applyGroup` folds the ""
    // tier through this instead of a glob call per rule per path.
    base_compiled: ?Compiled = null,
    // The same tier with the repository-scoped rules dropped — what a path below
    // a nested repo root is judged by. Built beside `base_compiled` so crossing
    // a repository boundary costs a different matcher, not a slow path.
    base_novcs: ?Compiled = null,

    /// Build the matcher and load the root-level ignore sources (repo `.gitignore`
    /// + `.git/info/exclude`, `.ignore`/`.rgignore`, and every `--ignore-file`).
    /// `roots` are the search's positional path args (empty = walk CWD); each is
    /// probed for its own `.git` so a git repo (or worktree) named as a path arg is
    /// honored, not just CWD.
    pub fn init(a: std.mem.Allocator, io: std.Io, o: Options, roots: []const []const u8) Oom!Ignore {
        var self = Ignore{ .a = a, .io = io, .o = o, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a) };
        // `--ignore-file` is EXPLICIT user intent: lowest precedence (added first,
        // so an in-tree `.ignore`/`.gitignore` overrides it — rg's f45 rule) and
        // honored even under `-u`/`--no-ignore` (only `--no-ignore-files` drops it).
        // Explicit is also why this is the one source whose absence is REPORTED:
        // a missing `.gitignore` is the normal state of most directories, but a
        // named `--ignore-file` that will not open means the rules the user asked
        // for are not in force, and silence there is a wrong answer wearing a
        // clean exit. See `readNamedFile`.
        if (!o.no_ignore_files) for (o.ignore_files) |p| try self.readNamedFile(p);
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
        if (self.use_git and !o.no_ignore_global) try self.loadGlobalExclude();
        // Parent (ancestor) ignores — rg also reads `.gitignore`/`.ignore` from
        // every directory ABOVE the search root, unless `--no-ignore-parent`. VCS
        // ancestors stop at the git root; `.ignore`/`.rgignore` climb to `/`.
        if (!o.no_ignore_parent) try self.loadParents(git_depth);
        // `.git/info/exclude` (lowest-precedence VCS source) — resolved per repo
        // root, following a worktree's `.git`-file → `commondir` like ripgrep does.
        if (self.use_git and !o.no_ignore_exclude) {
            try self.loadGitExclude("", "");
            for (roots) |r| {
                if (std.mem.eql(u8, r, ".")) continue;
                const rel = std.mem.trimEnd(u8, r, "/");
                try self.loadGitExclude(rel, rel);
            }
        }
        try self.loadDir(".", "");
        // rg's `add_parents` for a NAMED path arg: a positional root nested below
        // CWD (`a/b`) is governed by the ignore files of every directory between
        // CWD and it (`a/`), not just CWD's own — so `a/.ignore` prunes `a/b`'s
        // descendants. CWD ("" tier) is already loaded above; the root leaf itself
        // is loaded by the walker as it descends; here we fill the strict middle.
        for (roots) |r| try self.loadRootAncestors(r);
        // The "" tier is now complete (every source above targets base ""); compile
        // it once for `applyGroup`'s O(1) fold. `loadRootAncestors` only touched
        // per-directory keys, so this slice is stable for the run.
        if (!o.ignore_case_insensitive) {
            if (self.groups.getPtr("")) |b| {
                self.base_compiled = try Compiled.compileBase(a, b.items, false);
                self.base_novcs = try Compiled.compileBase(a, b.items, true);
            }
        }
        return self;
    }

    /// Load the per-directory ignore files of every directory STRICTLY BETWEEN
    /// CWD and an explicit positional root — root `a/b` ⇒ `a`; `a/b/c` ⇒ `a`,
    /// `a/b`. Each is bucketed under its own path so `decideAt` scopes it to that
    /// subtree (a slash-less `a/.ignore` rule matches basenames only under `a/`).
    /// CWD and the leaf are loaded elsewhere (see `init`). An absolute root under
    /// CWD starts at that boundary; unrelated filesystem ancestors must not leak
    /// their ignore files into an explicitly named nested repository/worktree.
    fn loadRootAncestors(self: *Ignore, root: []const u8) Oom!void {
        if (self.o.no_ignore) return;
        const r = stripDot(std.mem.trimEnd(u8, root, "/"));
        var i: usize = if (std.fs.path.isAbsolute(r)) blk: {
            const cwd = Dir.cwd().realPathFileAlloc(self.io, ".", self.a) catch return;
            if (std.mem.eql(u8, r, cwd)) return;
            if (r.len <= cwd.len or !std.mem.startsWith(u8, r, cwd) or r[cwd.len] != '/') return;
            break :blk cwd.len + 1;
        } else 0;
        while (std.mem.indexOfScalarPos(u8, r, i, '/')) |slash| {
            const dir = r[0..slash];
            i = slash + 1;
            if (dir.len != 0) try self.loadDir(dir, dir);
        }
    }

    /// Read every ancestor directory's ignore files, shallow→deep so a deeper
    /// ancestor outranks a shallower one (git precedence). `git_depth` (levels
    /// from CWD up to the git root, null = not in a repo) bounds the VCS climb.
    fn loadParents(self: *Ignore, git_depth: ?usize) Oom!void {
        const cwd = Dir.cwd().realPathFileAlloc(self.io, ".", self.a) catch return;
        var comps: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, cwd, '/');
        while (it.next()) |c| if (c.len != 0) try comps.append(self.a, c);
        var k: usize = comps.items.len; // k levels up (1 = parent, len = filesystem root)
        while (k >= 1) : (k -= 1) {
            const anc = try ascend(self.a, k);
            // CWD's path relative to this ancestor = its last k components — an
            // anchored ancestor rule is re-anchored by stripping this prefix.
            const subpath = try std.mem.join(self.a, "/", comps.items[comps.items.len - k ..]);
            if (self.use_git and git_depth != null and k <= git_depth.?)
                try self.readFile(try join(self.a, anc, ".gitignore"), "", subpath, true);
            if (self.use_dot) {
                try self.readFile(try join(self.a, anc, ".ignore"), "", subpath, false);
                try self.readFile(try join(self.a, anc, ".rgignore"), "", subpath, false);
            }
        }
    }

    /// Read `<repo>/.git/info/exclude` for the repo rooted at `root` (rel path from
    /// CWD; "" = CWD), anchoring its rules to `base`. When `<root>/.git` is a
    /// worktree `.git`-FILE, resolve `gitdir:` → `commondir` (ripgrep's
    /// `resolve_git_commondir`) so a linked worktree honors the shared exclude.
    fn loadGitExclude(self: *Ignore, root: []const u8, base: []const u8) Oom!void {
        const git_dir = try self.resolveGitDir(root) orelse return;
        try self.readFile(try join(self.a, git_dir, "info/exclude"), base, "", true);
    }

    /// Read git's global excludes file into the CWD tier ("" bucket). The path is
    /// resolved exactly as ripgrep does (see `globalExcludesPath`); it may not
    /// exist, in which case `readFile` is a no-op. Like `.git/info/exclude`, it is
    /// an ancestor-tier source that spans the whole tree from the CWD.
    /// git's global gitignore path (ripgrep parity, `gitconfig_excludes_path`),
    /// reading `$HOME`/`$XDG_CONFIG_HOME` from the process env (stable for the
    /// per-user gist server's lifetime). The env-free resolution is delegated to
    /// `globalExcludesFrom`.
    fn loadGlobalExclude(self: *Ignore) Oom!void {
        const xdg = assay.envSpan("XDG_CONFIG_HOME");
        const path = try globalExcludesFrom(self.io, self.a, assay.envSpan("HOME"), if (xdg != null and xdg.?.len != 0) xdg else null) orelse return;
        // NOT stamped `vcs`: ripgrep keeps one global matcher at the walk root
        // and consults it for every path with a repo anywhere in its chain,
        // outside the per-level `saw_git` gate — a global exclude is the user's
        // machine-wide rule, not one repository's (see `Rule.vcs`).
        try self.readFile(path, "", "", false);
    }

    /// The git common-dir for the repo at `root` (a path openable from CWD), or
    /// null if `root` has no `.git`. A `.git` directory IS the git dir; a `.git`
    /// FILE (linked worktree) is followed through `gitdir:` then its `commondir`.
    fn resolveGitDir(self: *Ignore, root: []const u8) Oom!?[]const u8 {
        const dot_git = try join(self.a, root, ".git");
        if (dirExists(self.io, dot_git)) return dot_git; // plain repo: `.git` is the git dir
        const gitfile = Dir.cwd().readFileAlloc(self.io, dot_git, self.a, .limited(4096)) catch return null;
        const line0 = std.mem.trimEnd(u8, firstLine(gitfile), "\r");
        if (!std.mem.startsWith(u8, line0, "gitdir: ")) return null;
        const real_git_dir = std.mem.trim(u8, line0["gitdir: ".len..], " ");
        const commondir = Dir.cwd().readFileAlloc(self.io, try join(self.a, real_git_dir, "commondir"), self.a, .limited(4096)) catch return null;
        const cd = std.mem.trimEnd(u8, firstLine(commondir), "\r");
        // A relative commondir is joined to the worktree git dir; an absolute one
        // is used as-is (the OS resolves the embedded `..`).
        return if (cd.len > 0 and cd[0] == '.') try join(self.a, real_git_dir, cd) else try self.a.dupe(u8, cd);
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
    ///
    /// "Exactly once" is per DIRECTORY, not per spelling of it, so `rel` is
    /// normalized the same way `addLine` normalizes a bucket key. The walk root
    /// arrives as `""` from `init` and as `"."` from a walker that names its own
    /// root (`reconcile/delta.zig`); those are one directory, and loading it
    /// under both spellings appended its rules to the `""` bucket a second time
    /// — which the compiled `""` tier borrows, and an append reallocates.
    pub fn loadDir(self: *Ignore, disk: []const u8, rel_in: []const u8) Oom!void {
        if (self.o.no_ignore) return;
        const rel = stripDot(rel_in);
        const gop = try self.loaded.getOrPut(rel);
        if (gop.found_existing) return;
        {
            // `getOrPut` has already parked the caller's transient `rel` as the
            // key; own it before anything else can fail and strand a dangling one.
            errdefer _ = self.loaded.remove(rel);
            gop.key_ptr.* = try self.a.dupe(u8, rel);
        }
        if (self.use_git) {
            try self.readFile(try join(self.a, disk, ".gitignore"), rel, "", true);
            // This directory may be a repository root, which BOUNDS how far the
            // VCS rules above it reach (`boundary`) — and it is a fact about the
            // directory, not about it having a `.gitignore`, so it is learned
            // here rather than as a side effect of reading one.
            if (dotGitPresent(self.io, self.a, disk)) try self.repos.put(gop.key_ptr.*, {});
        }
        if (self.use_dot) {
            try self.readFile(try join(self.a, disk, ".ignore"), rel, "", false);
            try self.readFile(try join(self.a, disk, ".rgignore"), rel, "", false);
        }
    }

    /// The deepest repository root at or above `rel`, as the LENGTH of its
    /// walk-root-relative path (0 = the walk root itself), or null when this
    /// walk has seen no enclosing repository. Rules bucketed under a shorter
    /// path than this are outside `rel`'s repository, so their VCS half does
    /// not apply — git's own scoping, and the shape ripgrep gets from setting
    /// `saw_git` as it climbs. Only STRICT ancestors count: ripgrep judges a
    /// directory entry with the state of the level above it, so a repo root's
    /// own name is still filtered by the outer repo's rules (a checkout in a
    /// `dist/` directory stays ignored).
    fn repoFloor(self: *const Ignore, stripped: []const u8) ?usize {
        if (self.repos.count() == 0) return null;
        var best: ?usize = if (self.repos.contains("")) 0 else null;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, stripped, i, '/')) |slash| {
            if (self.repos.contains(stripped[0..slash])) best = slash;
            i = slash + 1;
        }
        return best;
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
        return self.decideWithin(rel, is_dir, root_depth, self.repoFloor(stripDot(rel)));
    }

    /// `decideAt` with the repository boundary supplied instead of derived —
    /// what a parallel walker calls, because it learns the boundary from its
    /// own `IgNode` chain (`boundary`) rather than from `repos`, which only the
    /// serial `loadDir` fills. `bound` is `repoFloor`'s answer: the deepest
    /// enclosing repo root's path length, null when there is none.
    pub fn decideWithin(self: *const Ignore, rel: []const u8, is_dir: bool, root_depth: usize, bound: ?usize) ?bool {
        var verdict: ?bool = null;
        // The CWD/ancestor tier (root `.gitignore`, parents, `.git/info/exclude`,
        // `--ignore-file`) governs every path; then each ANCESTOR directory of
        // `rel`, shallow→deep, so the deepest matching rule wins (git precedence).
        // A tier SHALLOWER than the enclosing repository root contributes only
        // its non-VCS rules — that repo's `.gitignore` is not the outer repo's
        // business, and vice versa.
        self.applyGroup("", rel, is_dir, root_depth, &verdict, outside(bound, 0));
        const stripped = stripDot(rel);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, stripped, i, '/')) |slash| {
            self.applyGroup(stripped[0..slash], rel, is_dir, root_depth, &verdict, outside(bound, slash));
            i = slash + 1;
        }
        return verdict;
    }

    /// Fold one directory bucket's rules into `verdict` (last match wins). The
    /// bucket key is a directory path relative to the walk root ("" = CWD tier);
    /// `match` still does its own base/anchor/dir-only work, so feeding it only
    /// ancestor-sourced rules changes which rules are *tried*, never the verdict.
    fn applyGroup(self: *const Ignore, base_key: []const u8, rel: []const u8, is_dir: bool, root_depth: usize, verdict: *?bool, skip_vcs: bool) void {
        // The universal "" tier folds through the compiled globset (one basename
        // probe + a short complex scan) when available — byte-identical to the
        // linear fold below (max-rank == last-match-wins), but O(1) per path where
        // the root `.gitignore`'s many `*.o`/anchored rules would otherwise cost a
        // glob call each, per path. Per-directory buckets stay linear on THIS
        // serial path, which decides one path at a time; the parallel walker,
        // which re-folds the same chain per entry, compiles them too
        // (`IgNode.tier`).
        const g = self.groups.getPtr(base_key) orelse return;
        // …and only while it still describes the bucket it was compiled from. The
        // tier BORROWS `g.items`, so a later `addLine` on this key both invalidates
        // that slice (the append reallocates) and leaves the tier a rule short. A
        // length disagreement is enough to see it: rules are only ever appended, so
        // the tier is either exactly the bucket or a prefix of it, and the linear
        // fold below is the same verdict either way.
        if (base_key.len == 0) if (if (skip_vcs) self.base_novcs else self.base_compiled) |*c| {
            if (c.rules.len == g.items.len) {
                if (c.matchRank(stripDot(rel), is_dir)) |rank|
                    verdict.* = !c.rules[rank].negated;
                return;
            }
        };
        for (g.items) |r| if (!(skip_vcs and r.vcs) and ruleMatch(self.a, self.o.ignore_case_insensitive, root_depth, r, rel, is_dir)) {
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
        return self.skipFromVerdict(self.decide(rel, is_dir), basename, wl_ignore, wl_hidden);
    }

    /// Certify one already-discovered file against the same ancestor-pruning
    /// semantics as a live walk. Freshness overlays use this after their
    /// metadata-only fan-out so a newly changed ignored file cannot enter an
    /// otherwise gitignore-clean persisted corpus.
    pub fn admitsPath(self: *Ignore, root: []const u8, rel_in: []const u8) Oom!bool {
        const rel = stripDot(rel_in);
        self.scopeToRoot(root);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
            const dir = rel[0..slash];
            i = slash + 1;
            if (dir.len == 0) continue;
            const name = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |s| dir[s + 1 ..] else dir;
            if (self.shouldSkip(dir, true, name, false, false)) return false;
            try self.loadDir(dir, dir);
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
    ///
    /// `.git` gets NO special case, because ripgrep has none: the git database
    /// is excluded for being a dotfile, which is why rg users reach for
    /// `--glob '!.git/*'` (rg #927/#2646, pinned in `preference_test.zig`) —
    /// so `--hidden`/`-uu` searches it there, and an unconditional prune here
    /// was the whole of gist's remaining `-uu` file-selection gap against rg
    /// (188 of ~356k files on this tree, every one of them under `.git/`).
    /// The corpus and index walks are unaffected: they prune `.git` structurally
    /// through `haystack.isSkipDir`, before any verdict is asked for.
    /// Nothing here is per-kind any more, so it no longer takes `is_dir`: the
    /// verdict already accounted for `dir_only` rules, and the hidden rule reads
    /// a dotfile the same whether it is a file or a directory.
    pub fn skipFromVerdict(self: *const Ignore, v: ?bool, basename: []const u8, wl_ignore: bool, wl_hidden: bool) bool {
        if (v == true) return !wl_ignore;
        const hidden = basename.len > 0 and basename[0] == '.';
        if (hidden and !self.o.hidden and v != false) return !wl_hidden;
        return false;
    }

    // ─────────────────────────── internals ───────────────────────────

    /// Read `path`'s ignore lines, anchoring each to `base`. `strip` (non-empty
    /// only for a parent-directory file) is CWD's path relative to that ancestor;
    /// it re-anchors the ancestor's anchored rules onto the search subtree.
    fn readFile(self: *Ignore, path: []const u8, base: []const u8, strip: []const u8, vcs: bool) Oom!void {
        const buf = readOpt(self.io, self.a, path) orelse return;
        try self.addLines(buf, base, strip, vcs);
    }

    /// Read an ignore file the user NAMED (`--ignore-file <path>`), reporting on
    /// stderr when it cannot be opened. ripgrep's `ignore_message!` lane, in
    /// wording and in disposition: the run is not errored by it (a missing
    /// `--ignore-file` alone still exits 0/1), and `--no-ignore-messages` — or
    /// `--no-messages`, which subsumes it — quiets the line.
    fn readNamedFile(self: *Ignore, path: []const u8) Oom!void {
        const buf = Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(1 << 20)) catch |e| switch (e) {
            // Running out of memory is this process failing, not this file being
            // unreadable — it belongs to the caller's `Oom`, never to a message.
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                assay.note(.ignore, assay.tag ++ "{s}: {s}\n", .{ path, fault.pathNoteOf(e) });
                return;
            },
        };
        try self.addLines(buf, "", "", false);
    }

    /// Fold one ignore file's bytes into the rule set — the shared tail of both
    /// readers above, so a named source and an in-tree one cannot come to parse
    /// the same dialect differently.
    fn addLines(self: *Ignore, buf: []const u8, base: []const u8, strip: []const u8, vcs: bool) Oom!void {
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |raw| try self.addLine(std.mem.trimEnd(u8, raw, "\r"), base, strip, vcs);
    }

    /// Parse one gitignore-dialect line into a `Rule` (comments/blank lines drop)
    /// and bucket it by source directory — the container half of `parseRuleLine`.
    fn addLine(self: *Ignore, raw: []const u8, base: []const u8, strip: []const u8, vcs: bool) Oom!void {
        const parsed = parseRuleLine(raw, base, strip) orelse return;
        // Bucket by the source directory (normalized like `ruleMatch` does, so a
        // "." / "./x" base and its rel-side counterpart collapse to the same key).
        const key = stripDot(base);
        const gop = try self.groups.getOrPut(key);
        // `key` still aliases the walker's bytes: a half-built bucket keyed on
        // them must not outlive this call (same hazard as `loadDir`'s).
        errdefer if (!gop.found_existing) {
            _ = self.groups.remove(key);
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.a.dupe(u8, key);
            gop.value_ptr.* = .empty;
        }
        var owned = parsed;
        owned.vcs = vcs;
        owned.glob = try ownGlob(self.a, parsed.glob);
        try gop.value_ptr.append(self.a, owned);
    }
};

// ─────────────────── parallel-walk ignore chain (shared) ───────────────────
// A serial walker folds each directory's ignore files into the shared `Ignore`
// as it descends (`loadDir`); a PARALLEL walker cannot mutate that shared state
// per directory concurrently, so it carries an immutable per-directory rule
// CHAIN instead — built from this module's same `parseRuleLine`/`ruleMatch`
// core, so the two walkers cannot drift (the reason this file is MONOLITHIC).
// Both the search engine (`exec/cold/engine/swarm/`) and the fused corpus
// loader (`loadpar.zig`) build and fold chains through these helpers.

/// One directory's own ignore rules (.gitignore + .ignore/.rgignore, in
/// `loadDir`'s load order), chained to the parent directory's node. Immutable
/// after construction; `rules` and the links live in the building worker's
/// arena, which must outlive the whole walk.
pub const IgNode = struct {
    parent: ?*const IgNode,
    rules: []const Rule,
    /// This directory's path relative to the walk root ("" = the root), so the
    /// fold can tell a node above a repository boundary from one below it.
    rel: []const u8 = "",
    /// This directory holds a `.git` — a repository root, which bounds how far
    /// the VCS rules above it reach. True even for a node with no rules of its
    /// own: the boundary is the `.git`, not the `.gitignore`.
    repo: bool = false,
    /// This node's own bucket compiled to the same hash-probing tier the ""
    /// bucket gets (`Compiled`), and its repository-scope-free twin. Without
    /// them a chain fold costs a glob call per rule per ENTRY, and a rule
    /// population is per-repository: a file deep in a kernel checkout is tested
    /// against every rule of every `.gitignore` above it, every time it is
    /// walked. Null only when the bucket would not compile (OOM) — the linear
    /// fold then answers identically, just slower.
    tier: ?Compiled = null,
    tier_novcs: ?Compiled = null,
};

/// Fold the chain's rules into `verdict`, parent-first (shallow→deep, so the
/// deepest matching rule wins — git precedence, same as `decideWithin`). Nodes
/// shallower than `bound` (see `boundary`) contribute only their non-VCS rules.
pub fn applyChain(node: ?*const IgNode, a: std.mem.Allocator, ci: bool, root_depth: usize, rel: []const u8, is_dir: bool, bound: ?usize, verdict: *?bool) void {
    const n = node orelse return;
    applyChain(n.parent, a, ci, root_depth, rel, is_dir, bound, verdict);
    const skip_vcs = outside(bound, stripDot(n.rel).len);
    if (nodeTier(n, ci, root_depth, skip_vcs)) |t| {
        // The tier decides this node OUTRIGHT — a miss is a proven no-match for
        // the whole bucket, never a reason to re-walk it linearly.
        if (nodeSub(n, rel)) |sub| if (t.matchRank(sub, is_dir)) |rank| {
            verdict.* = !t.rules[rank].negated;
        };
        return;
    }
    for (n.rules) |r| if (!(skip_vcs and r.vcs) and ruleMatch(a, ci, root_depth, r, rel, is_dir)) {
        verdict.* = !r.negated;
    };
}

/// This node's fast tier when it is byte-equivalent to folding the bucket
/// through `ruleMatch`, else null (fold linearly).
///
/// Two conditions. `matchRank` cannot fold case, so a caseless run declines it
/// exactly as `Compiled.build` does. And `matchRank` models `ruleMatch`'s depth
/// floor as 0 — structurally true for a node with its own `base`, which floors
/// at 0 by definition — so a BASE-LESS node (the walk root's own bucket, which
/// inherits `root_depth`) may use it only on a whole-CWD walk, where that floor
/// is 0 anyway. Under an explicit positional root the root component is exempt
/// and only the linear fold encodes that.
fn nodeTier(n: *const IgNode, ci: bool, root_depth: usize, skip_vcs: bool) ?*const Compiled {
    if (ci) return null;
    if (stripDot(n.rel).len == 0 and root_depth != 0) return null;
    return if (skip_vcs) (if (n.tier_novcs) |*t| t else null) else (if (n.tier) |*t| t else null);
}

/// `rel` re-expressed under this node's base — the prefix strip `ruleMatch`
/// repeats per rule, done once per node. Null when `rel` is not strictly below
/// the base, which is `ruleMatch`'s own `return false` for every rule in the
/// bucket.
fn nodeSub(n: *const IgNode, rel_in: []const u8) ?[]const u8 {
    const rel = stripDot(rel_in);
    const base = stripDot(n.rel);
    if (base.len == 0) return if (rel.len == 0) null else rel;
    if (rel.len <= base.len or !std.mem.startsWith(u8, rel, base) or rel[base.len] != '/') return null;
    const sub = rel[base.len + 1 ..];
    return if (sub.len == 0) null else sub;
}

/// Is a rule tier sourced at path-length `at` OUTSIDE the repository that
/// encloses the candidate — i.e. strictly above the boundary `bound`?
fn outside(bound: ?usize, at: usize) bool {
    return at < (bound orelse return false);
}

/// git's repository boundary for `rel` on this walk: the deepest enclosing
/// repository root's path length (null = none seen), taking the deeper of what
/// the serial `repos` map knows and what this directory's chain carries. One
/// call answers it for either walker, so the two cannot come to disagree about
/// where a repository ends.
pub fn boundary(ig: *const Ignore, chain: ?*const IgNode, rel: []const u8) ?usize {
    const from_map = ig.repoFloor(stripDot(rel));
    var n = chain;
    while (n) |node| : (n = node.parent) if (node.repo) {
        const len = stripDot(node.rel).len;
        return if (from_map) |m| @max(m, len) else len;
    };
    return from_map;
}

/// The frozen base tier's verdict for one entry, honoring the boundary: the
/// hash-probing fast tier when this walk has one (its VCS-free twin below a
/// nested repository root), else the linear fold. The parallel walkers' shared
/// first half — `applyChain` is the second.
pub fn baseVerdict(ig: *const Ignore, compiled: ?*const Compiled, rel: []const u8, is_dir: bool, root_depth: usize, bound: ?usize) ?bool {
    // The VCS-free twin substitutes for `compiled` only where `compiled` itself
    // was admissible: the fast tier exists exactly when every rule this walk
    // holds is in the "" bucket (`Compiled.build`), and stepping around that
    // check would silently drop the per-directory buckets `decideWithin` folds.
    if (compiled) |c| if (if (outside(bound, 0)) (if (ig.base_novcs) |*n| n else null) else c) |tier| {
        if (tier.matchRank(stripDot(rel), is_dir)) |r| return !tier.rules[r].negated;
        return null;
    };
    return ig.decideWithin(rel, is_dir, root_depth, bound);
}

/// Read one ignore file (raw POSIX, worker-thread safe) into `a`. Null when
/// absent/unreadable — the same silent degrade as `readFile`.
pub fn readIgnoreFile(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const fd = portal.openFile(portal.cwd(), path) catch return null;
    defer portal.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [16 * 1024]u8 = undefined;
    while (buf.items.len < (1 << 20)) {
        const r = portal.read(fd, &tmp) catch break;
        if (r == 0) break;
        buf.appendSlice(a, tmp[0..r]) catch return null;
    }
    return buf.toOwnedSlice(a) catch null;
}

pub fn appendRules(a: std.mem.Allocator, list: *std.ArrayList(Rule), path: []const u8, base: []const u8, vcs: bool) Oom!void {
    const buf = readIgnoreFile(a, path) orelse return;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (parseRuleLine(line, base, "")) |r| {
            var owned = r;
            owned.vcs = vcs;
            owned.glob = try ownGlob(a, r.glob);
            try list.append(a, owned);
        }
    }
}

/// Which ignore files a directory's LISTING says are present — the walk already
/// read every sibling name, so `loadNode` only `openat`s files that exist
/// instead of blind-probing all three in every directory (the biggest syscall
/// sink in the whole walk: ~3 failed opens × every dir).
/// It also carries `dotgit`, which is not an ignore file at all but the same
/// kind of free fact: the listing already names `.git`, so a parallel walker
/// learns this directory is a repository root (the `boundary` its VCS rules
/// reach to) without the per-directory stat the serial walker pays.
pub const IgPresent = struct { gitignore: bool = false, dotignore: bool = false, rgignore: bool = false, dotgit: bool = false };

/// Note whether `name` is one of the three ignore files — or the `.git` that
/// makes this directory a repository root — from a listing entry.
pub fn noteIgnoreFile(present: *IgPresent, name: []const u8, is_file: bool) void {
    if (name.len < 4 or name[0] != '.') return;
    // `.git` is a DIRECTORY in a plain checkout and a FILE in a linked
    // worktree; either one is a repository root, so this arm precedes the
    // is_file gate the three ignore files need.
    if (std.mem.eql(u8, name, ".git")) {
        present.dotgit = true;
        return;
    }
    if (!is_file or name.len < 7) return;
    if (std.mem.eql(u8, name, ".gitignore"))
        present.gitignore = true
    else if (std.mem.eql(u8, name, ".ignore"))
        present.dotignore = true
    else if (std.mem.eql(u8, name, ".rgignore"))
        present.rgignore = true;
}

/// Build the `IgNode` for a directory the walk just entered (its `.gitignore`
/// then `.ignore`/`.rgignore`, mirroring `loadDir`'s order so last-match-wins
/// precedence is identical). Returns `parent` unchanged when the directory
/// neither contributes rules nor roots a repository — the chain link is
/// skipped, not empty. A repository root DOES link even with no rules of its
/// own: it is where the VCS rules above it stop (`boundary`).
pub fn loadNode(ig: *const Ignore, a: std.mem.Allocator, parent: ?*const IgNode, disk: []const u8, rel: []const u8, present: IgPresent) Oom!?*const IgNode {
    var rules: std.ArrayList(Rule) = .empty;
    if (ig.use_git and present.gitignore) try appendRules(a, &rules, try join(a, disk, ".gitignore"), rel, true);
    if (ig.use_dot) {
        if (present.dotignore) try appendRules(a, &rules, try join(a, disk, ".ignore"), rel, false);
        if (present.rgignore) try appendRules(a, &rules, try join(a, disk, ".rgignore"), rel, false);
    }
    const repo = ig.use_git and present.dotgit;
    if (rules.items.len == 0 and !repo) return parent;
    const node = try a.create(IgNode);
    const owned = try rules.toOwnedSlice(a);
    node.* = .{ .parent = parent, .rules = owned, .rel = rel, .repo = repo };
    // Compile the bucket ONCE per directory rather than re-scanning it per
    // walked entry. A bucket with no repository-scoped rule at all decides the
    // same either side of a boundary, so the two tiers share; otherwise the
    // twin is its own matcher (an all-`.gitignore` bucket compiles to an empty
    // one, which is exactly the right answer below a nested repository root).
    // OOM degrades to the linear fold, never to a different verdict.
    node.tier = Compiled.compileBase(a, owned, false) catch null;
    node.tier_novcs = if (node.tier == null or !anyVcs(owned))
        node.tier
    else
        Compiled.compileBase(a, owned, true) catch null;
    return node;
}

/// Does this bucket hold any repository-scoped rule? Only then does dropping
/// them yield a different matcher than the plain tier.
fn anyVcs(rules: []const Rule) bool {
    for (rules) |r| if (r.vcs) return true;
    return false;
}

// The shared ASCII case fold (`paths.zig`) — one definition for gitignore's
// byte-wise caseless glob tier and args.zig's `--iglob` fold.
const lower = paths.lowerDup;

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
fn expandTilde(a: std.mem.Allocator, home: ?[]const u8, s: []const u8) Oom![]const u8 {
    const h = home orelse return a.dupe(u8, s);
    if (std.mem.indexOfScalar(u8, s, '~') == null) return a.dupe(u8, s);
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| try (if (c == '~') buf.appendSlice(a, h) else buf.append(a, c));
    return buf.toOwnedSlice(a);
}

/// Resolve git's global excludes path from explicit `home`/`xdg` (env-free, so
/// it is directly testable): `core.excludesfile` from `<home>/.gitconfig`, else
/// from `<xdg|home/.config>/git/config`, else that base's default `git/ignore`.
/// `~` in a configured value expands to `home`. The returned path need not exist
/// — the caller's `readFile` tolerates a miss.
fn globalExcludesFrom(io: std.Io, a: std.mem.Allocator, home: ?[]const u8, xdg: ?[]const u8) Oom!?[]const u8 {
    if (home) |h| if (readOpt(io, a, try join(a, h, ".gitconfig"))) |data| {
        if (parseExcludesFile(data)) |raw| return try expandTilde(a, home, raw);
    };
    // `<home>/.gitconfig` didn't decide it → the XDG (or `<home>/.config`) config,
    // then that same base's default `git/ignore`.
    const cfg_home = xdg orelse (if (home) |h| try join(a, h, ".config") else null);
    const c = cfg_home orelse return null;
    if (readOpt(io, a, try join(a, c, "git/config"))) |data| {
        if (parseExcludesFile(data)) |raw| return try expandTilde(a, home, raw);
    }
    return try join(a, c, "git/ignore");
}

/// The relative path `k` directories above CWD: 1→`..`, 2→`../..`, … .
fn ascend(a: std.mem.Allocator, k: usize) Oom![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (0..k) |i| try buf.appendSlice(a, if (i == 0) ".." else "/..");
    return buf.toOwnedSlice(a);
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

/// True if `dir` holds a `.git` of either shape — ripgrep's per-level
/// repository probe (`dir.join(".git").exists()`), one stat rather than
/// `hasDotGit`'s open-then-read pair, because a repository boundary does not
/// care whether the `.git` is a directory or a worktree file.
fn dotGitPresent(io: std.Io, a: std.mem.Allocator, dir: []const u8) bool {
    const path = join(a, dir, ".git") catch return false;
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
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

test "parseRuleLine: an escaped trailing slash stays dir-only but drops the escape (rg #2236)" {
    const t = std.testing;
    // `.ignore` line `foo\/` ⇒ rg strips the trailing `/` (dir-only) THEN the
    // escaping `\`, globbing on `foo` — so directory `foo` is pruned. A stray `\`
    // in the glob would make it match nothing and leave `foo/` searchable.
    const r = parseRuleLine("foo\\/", "", "").?;
    try t.expectEqualStrings("foo", r.glob);
    try t.expect(r.dir_only);
    try t.expect(!r.anchored); // slash-less ⇒ matches the `foo` basename at any depth
    try t.expect(!r.negated);
}

test "parseRuleLine: a leading **/ ancestor rule floats through re-anchoring (rg leading-doublestar)" {
    const t = std.testing;
    // A root `.gitignore` `**/bar/*` seen from CWD `foo` (strip = "foo"): git's
    // leading `**/` means "in this dir or any subdir", so it is depth-independent
    // and must survive UNCHANGED — not be dropped as a non-`foo/` sibling.
    const r = parseRuleLine("**/bar/*", "", "foo").?;
    try t.expectEqualStrings("**/bar/*", r.glob);
    try t.expect(r.anchored);
    // A plainly-anchored ancestor rule that does NOT target the CWD subtree is
    // still dropped (only the CWD-relative slice can affect the walk).
    try t.expectEqual(@as(?Rule, null), parseRuleLine("sib/bar", "", "foo"));
}

test "ownGlob keeps ** only as a whole component (gitignore's regular-asterisk rule)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The rust checkout's real rule: glued to a suffix, `**` is just `*`, so it
    // stays inside one component and `src/lib2/Cargo.lock` is NOT ignored.
    try t.expectEqualStrings("tests/rustdoc-gui/src/*.lock", try ownGlob(a, "tests/rustdoc-gui/src/**.lock"));
    try t.expectEqualStrings("*x*", try ownGlob(a, "**x***"));
    // …while every component-shaped form survives untouched.
    for ([_][]const u8{ "**/bar/*", "foo/**", "a/**/b", "**", "*.o", "a*b" }) |p|
        try t.expectEqualStrings(p, try ownGlob(a, p));
    // A collapsed run and a preserved one in the same glob, plus the tail after
    // the last run — the two-arm copy has to carry both.
    try t.expectEqualStrings("**/a*b/*.c", try ownGlob(a, "**/a**b/*.c"));
}

test "a VCS rule stops at a nested repository root (rg's saw_git boundary)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ig = Ignore{ .a = a, .io = undefined, .o = .{}, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a), .use_git = true };
    var bucket: std.ArrayList(Rule) = .empty;
    // An OUTER repo's `dist/` (VCS) and an outer `.ignore`'s `keep.log` (not).
    try bucket.append(a, .{ .glob = "dist", .base = "", .negated = false, .anchored = false, .dir_only = true, .vcs = true });
    try bucket.append(a, .{ .glob = "keep.log", .base = "", .negated = false, .anchored = false, .dir_only = false, .vcs = false });
    try ig.groups.put("", bucket);

    // No repository below the walk root: both tiers govern, as they always have.
    try t.expectEqual(@as(?bool, true), ig.decide("repo/src/dist", true));
    try t.expectEqual(@as(?bool, true), ig.decide("repo/src/keep.log", false));

    // `repo/` holds a `.git` ⇒ it is a repository of its own. The outer repo's
    // `.gitignore` no longer reaches inside it; the outer `.ignore` still does.
    try ig.repos.put("repo", {});
    try t.expectEqual(@as(?bool, null), ig.decide("repo/src/dist", true));
    try t.expectEqual(@as(?bool, true), ig.decide("repo/src/keep.log", false));
    // The boundary is only for what is INSIDE: the repository directory's own
    // name is still judged by the outer repo (a checkout in `dist/` stays gone),
    // and a sibling outside it is untouched.
    try t.expectEqual(@as(?bool, true), ig.decide("dist", true));
    try t.expectEqual(@as(?bool, true), ig.decide("plain/src/dist", true));

    // The parallel walkers learn the same boundary from their chain instead of
    // from `repos`, and must reach the identical verdict.
    var ig2 = Ignore{ .a = a, .io = undefined, .o = .{}, .groups = ig.groups, .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a), .use_git = true };
    const node = IgNode{ .parent = null, .rules = &.{}, .rel = "repo", .repo = true };
    const bound = boundary(&ig2, &node, "repo/src/dist");
    try t.expectEqual(@as(?usize, 4), bound);
    try t.expectEqual(@as(?bool, null), baseVerdict(&ig2, null, "repo/src/dist", true, 0, bound));
    try t.expectEqual(@as(?bool, true), baseVerdict(&ig2, null, "repo/src/keep.log", false, 0, bound));
}

test "an explicit nested root loads its intermediate ancestors' ignores (rg add_parents)" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = "gist_root_ancestor_fixture";
    fault.spare("clear leftover root-ancestor fixture", Dir.cwd().deleteTree(io, dir));
    try Dir.cwd().createDirPath(io, try join(a, dir, "a/b"));
    defer fault.spare("remove root-ancestor fixture", Dir.cwd().deleteTree(io, dir));
    // `a/.ignore` sits BETWEEN the fixture root and the explicit search root
    // `a/b`; rg loads it as a parent of the named path, so `a/b/.foo` is pruned.
    try Dir.cwd().writeFile(io, .{ .sub_path = try join(a, dir, "a/.ignore"), .data = ".foo\n" });

    var ig = Ignore{ .a = a, .io = io, .o = .{ .hidden = true }, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a), .use_dot = true };
    const abs_dir = try Dir.cwd().realPathFileAlloc(io, dir, a);
    const root = try join(a, abs_dir, "a/b");
    try ig.loadRootAncestors(root); // absolute-safe: starts at CWD, never ~/.cursor
    // The rule lives in the intermediate dir's bucket and prunes the descendant,
    // never the root's own components (only what is found beneath it).
    ig.scopeToRoot(root);
    try t.expectEqual(@as(?bool, true), ig.decide(try join(a, root, ".foo"), false));
}

test "one directory under two spellings loads once" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = "gist_dir_spelling_fixture";
    fault.spare("clear leftover dir-spelling fixture", Dir.cwd().deleteTree(io, dir));
    try Dir.cwd().createDirPath(io, dir);
    defer fault.spare("remove dir-spelling fixture", Dir.cwd().deleteTree(io, dir));
    try Dir.cwd().writeFile(io, .{ .sub_path = try join(a, dir, ".ignore"), .data = "*.o\nbuild/\n" });

    var ig = Ignore{ .a = a, .io = io, .o = .{}, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a), .use_dot = true };
    // `init` names the walk root `""`; a walker that names its own root says
    // `"."` (`reconcile/delta.zig`). One directory, so one load — the second
    // spelling must not append its rules to the `""` bucket again. That append
    // reallocates, and the compiled `""` tier borrows the slice it grew out of,
    // so the duplicate was a use-after-free the moment a path was judged.
    try ig.loadDir(dir, "");
    const after_first = ig.groups.getPtr("").?.items.len;
    try ig.loadDir(dir, ".");
    try t.expectEqual(after_first, ig.groups.getPtr("").?.items.len);
}

test "a named --ignore-file that will not open is reported, and muffled on demand" {
    const t = std.testing;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Capture the ignore lane instead of the test runner's stderr.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    const sc = assay.scope(.{ .buffer = .{ .list = &buf, .gpa = t.allocator } });
    defer sc.end();
    defer assay.muffle(true, true);

    const missing = "gist_absent_ignore_file_fixture.ignore";
    const o = Options{ .ignore_files = &.{missing}, .no_ignore = true };

    // Default run: the user named a source that is not in force, and says so
    // with ripgrep's errno phrasing rather than a clean silent exit.
    assay.muffle(true, true);
    var ig = try Ignore.init(a, io, o, &.{});
    try t.expectEqualStrings(assay.tag ++ "" ++ missing ++ ": No such file or directory (os error 2)\n", buf.items);

    // --no-ignore-messages quiets this class alone; --no-messages subsumes it.
    for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ false, false } }) |m| {
        buf.clearRetainingCapacity();
        assay.muffle(m[0], m[1]);
        ig = try Ignore.init(a, io, o, &.{});
        try t.expectEqualStrings("", buf.items);
    }

    // Quiet or loud, an unopenable ignore source never errors the RUN — rg's
    // ignore lane is advisory, unlike the walk errors that force exit 2.
    try t.expectEqual(@as(?bool, null), ig.decide("anything.txt", false));
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
    try t.expectEqualStrings("/home/u/foo/bar", try expandTilde(a, "/home/u", "~/foo/bar"));
    try t.expectEqualStrings("/home/u+/home/u", try expandTilde(a, "/home/u", "~+~")); // plain replace, not just leading
    try t.expectEqualStrings("/abs/path", try expandTilde(a, "/home/u", "/abs/path")); // no tilde ⇒ verbatim copy
    try t.expectEqualStrings("~/x", try expandTilde(a, null, "~/x")); // no HOME ⇒ left untouched
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
    fault.spare("clear leftover glob-excludes fixture", Dir.cwd().deleteTree(io, home));
    try Dir.cwd().createDirPath(io, home);
    defer fault.spare("remove glob-excludes fixture", Dir.cwd().deleteTree(io, home));

    // No config file anywhere ⇒ the default `<home>/.config/git/ignore` (a path
    // that need not exist), and an XDG override redirects that default base.
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/.config/git/ignore", .{home}), (try globalExcludesFrom(io, a, home, null)).?);
    const xdg = try std.fmt.allocPrint(a, "{s}/xdg", .{home});
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/git/ignore", .{xdg}), (try globalExcludesFrom(io, a, home, xdg)).?);

    // `<home>/.config/git/config`'s excludesfile beats the bare default…
    try Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/.config/git", .{home}));
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/.config/git/config", .{home}), .data = "[core]\n\texcludesfile = /explicit/cfg\n" });
    try t.expectEqualStrings("/explicit/cfg", (try globalExcludesFrom(io, a, home, null)).?);

    // …and `<home>/.gitconfig` outranks the XDG config, with `~` → home.
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/.gitconfig", .{home}), .data = "[core]\n\texcludesFile = ~/mygi\n" });
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/mygi", .{home}), (try globalExcludesFrom(io, a, home, null)).?);
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
    fault.spare("clear leftover global-rule fixture", Dir.cwd().deleteTree(io, dir));
    try Dir.cwd().createDirPath(io, dir);
    defer fault.spare("remove global-rule fixture", Dir.cwd().deleteTree(io, dir));
    const gi = try std.fmt.allocPrint(a, "{s}/globalignore", .{dir});
    try Dir.cwd().writeFile(io, .{ .sub_path = gi, .data = "*.log\n!keep.log\n" });

    var ig = Ignore{ .a = a, .io = io, .o = .{}, .groups = std.StringHashMap(std.ArrayList(Rule)).init(a), .loaded = std.StringHashMap(void).init(a), .repos = std.StringHashMap(void).init(a) };
    // Exactly what `loadGlobalExclude` does with the resolved path: fold the
    // global file into the "" (CWD/ancestor) tier, lowest precedence.
    try ig.readFile(gi, "", "", false);
    try t.expectEqual(@as(?bool, true), ig.decide("app.log", false)); // *.log ignored
    try t.expectEqual(@as(?bool, false), ig.decide("keep.log", false)); // later !keep.log re-includes
    try t.expectEqual(@as(?bool, null), ig.decide("app.txt", false)); // untouched
}

test "anchored ancestor rule matches its full path order-independently (rg 15.2 #3320/#3376)" {
    const t = std.testing;
    // An anchored CWD/ancestor-tier rule matches the full CWD-relative path the
    // same way regardless of how many explicit roots share the ancestor — no
    // per-root re-anchoring, matching rg 15.2's fixed multi-directory behavior.
    const rule = Rule{ .glob = "scripts/observe/build", .base = "", .negated = true, .anchored = true, .dir_only = true };
    try t.expect(ruleMatch(t.allocator, false, 1, rule, "scripts/observe/build", true));
}

test "compiled matcher folds the anchored ancestor rule by full path" {
    const t = std.testing;
    const rules = [_]Rule{
        .{ .glob = "build", .base = "", .negated = false, .anchored = false, .dir_only = true },
        .{ .glob = "scripts/observe/build", .base = "", .negated = true, .anchored = true, .dir_only = true },
    };
    var complex = [_]u32{1};
    var compiled = Compiled{ .rules = &rules, .lit = std.StringHashMap(Compiled.Slot).init(t.allocator), .ext = std.StringHashMap(Compiled.Slot).init(t.allocator), .complex = &complex, .a = t.allocator };
    defer compiled.lit.deinit();
    defer compiled.ext.deinit();
    try Compiled.slotPut(&compiled.lit, "build", 0, true);

    // The anchored rule (rank 1) matches the full path, so its rank wins over
    // the slash-less `build` (rank 0) — order-independent.
    try t.expectEqual(@as(?u32, 1), compiled.matchRank("scripts/observe/build", true));
}
