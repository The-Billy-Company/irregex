//! gist resident session — the eligible-request classifier (ADR-352 rung 2.5).
//!
//! Warm surface: `-l` / `-c` / bare `lines`, literal (`-F`), linear regex, or
//! `-P`/`--pcre2` (`--engine=pcre2`) PCRE2 regex, ±case (`-i`/`-s`/`-S`),
//! optional `-w` / `-n`, `-A`/`-B`/`-C` context windows,
//! a clean relative PATH scope, `-g <glob>` / `-t <type>` file scoping, and the
//! gist-native `--rank[=N]` definition-first view (regex pattern + case + PATH
//! roots only — see the `rank_k` guard below). Everything else (`--json`,
//! `--iglob`, `-T`, stdin, …) → cold.
//!
//! Scope: a bare `gist <pattern>` searches the rootless CWD tree the daemon was
//! born serving. An explicit positional PATH is admitted only when it is a clean
//! repo-root-relative subtree/file (`gist pat pkg/kernels`) — the resident
//! mirror stores CWD-relative paths with no `./` prefix, so a root cold would
//! render with a prefix the mirror lacks (`.`, `./libs`, an absolute path, a
//! `..` escape) still declines to cold. `-g`/`-t` add glob/type constraints
//! (case-sensitive include, `!`-exclude, type→extension globs) — only the forms
//! the shared `PathFilter` models identically to cold; an anchored/unterminated
//! glob, `--iglob`, `-t all`, or an unknown type declines. A scoped answer is a
//! strict subset of the served corpus, pruned through that same `PathFilter`.
//! `classify` is a narrow argv scanner (not a fork of `args.zig`); it returns
//! typed errors and never calls `die()`.

const std = @import("std");
// `hasUpper` only — shared smart-case authority with cold's finalize fold.
// One-way edge: args.zig never imports session.
const args = @import("../../cold/argv/args.zig");
// The resolved path-scope constraint (roots ∧ `-g` globs ∧ `-t` types) — the
// SAME `PathFilter` the cold engine and relate's warm twin apply, so a scoped
// warm answer prunes candidates by the identical rule cold walks with.
const scope = @import("../../../../corpus/scope/glob.zig");
// The `-t <lang>` name → globs table (`extsForType`), the same registry the
// cold argv parser resolves a type against.
const types = @import("../../../../corpus/scope/types.zig");

/// Eligible answer shapes — shared with the search core (`kernel/match/query/query.zig`).
pub const Mode = @import("../../../../kernel/match/query/query.zig").Mode;

/// The resolved path-scope filter a classified request carries (empty ⇒ the
/// rootless whole-CWD search). Re-exported so call sites name one type.
pub const PathFilter = scope.PathFilter;

/// Per-kind cap on scope tokens `classify` collects before declining to cold.
/// Generous vs any realistic `gist pat a b c` shape, and a wall that keeps the
/// wire frame + the client's stack scratch bounded: more scope tokens than this
/// simply fall back to the certified cold path (fail-open, never wrong).
pub const max_scope = 64;

/// Caller-owned scratch backing a classified request's `PathFilter` slices. The
/// tokens themselves alias argv (or the immutable `types` table, for `exts`),
/// but the slice-of-slices HEADERS live here, so this must outlive every use of
/// the returned `Request`. One per `classify` call — a stack local in the warm
/// client, a throwaway everywhere else.
pub const ScopeArgs = struct {
    roots: [max_scope][]const u8 = undefined, // positional PATH args
    includes: [max_scope][]const u8 = undefined, // `-g <glob>`
    excludes: [max_scope][]const u8 = undefined, // `-g '!<glob>'`
    exts: [max_scope][]const u8 = undefined, // `-t <type>` → its globs (flattened)
};

/// Classified eligible request. `pattern` aliases into argv / the frame buffer.
pub const Request = struct {
    pattern: []const u8,
    mode: Mode,
    fixed: bool = false,
    ignore_case: bool = false,
    /// `-n`/`--line-number` (ignored for `-l`/`-c`, as cold does).
    line_num: bool = false,
    /// `-S`/`--smart-case`, raw on the wire; resolved via `effectiveIgnoreCase`.
    smart_case: bool = false,
    /// `-w`/`--word-regexp` — see `kernel/match/query/query.zig::wordOk`.
    word: bool = false,
    /// `-P`/`--pcre2` (or `--engine=pcre2`): realize the regex body with the
    /// vendored PCRE2 JIT backend (lookaround, backreferences, Unicode
    /// properties) behind the shared `Matcher` seam. Inert under `-F` (fixed
    /// wins). Declined alongside `--rank` (linear-only) at classify time; a
    /// pattern PCRE2 rejects falls to cold at compile.
    pcre: bool = false,
    /// `-v`/`--invert-match` — select lines with no matching span. The FFI
    /// record stream supports this; the rootless daemon classifier stays narrow.
    invert: bool = false,
    /// Effective context window. Python resolves `-C` into both sides unless
    /// explicit `-A`/`-B` take precedence, matching the cold argv fold.
    before: u64 = 0,
    after: u64 = 0,
    /// Unicode matching semantics. Resident-daemon requests stay at the rg
    /// default (`true`); the in-process FFI may explicitly select ASCII.
    unicode: bool = true,
    /// `-q`/`--quiet` — print nothing, exit 0 on the first match, else 1. The
    /// session answers this as an early-halting existence query.
    quiet: bool = false,
    /// `-m N`/`--max-count N` — cap matching lines per file at N (`null` = unset,
    /// the unlimited default; `0` = rg's explicit "match nothing", see `matchNothing`).
    max_count: ?u64 = null,
    /// Positional-PATH / glob / type scope. Empty (the default) is the rootless
    /// whole-CWD search the daemon was born serving; a non-empty filter confines
    /// the answer to a subtree the resident mirror already holds (a strict subset
    /// of the served corpus — the daemon re-checks that before answering). Applied
    /// through the shared `PathFilter.prune`/`admits`, so warm scoping is the same
    /// rule cold walks with.
    filter: PathFilter = .{},
    /// `--rank[=N]`: gist's definition-first ranked view (`ranked.zig`), the one
    /// shape rg can't express. `null` ⇒ not a rank query; `Some(k)` ⇒ surface the
    /// top-k rows (`0` ⇒ cold's default 20). Carried ONLY by `query_ext` (never a
    /// flag bit), and the daemon dispatches on it before the mode. `classify`
    /// admits it only alongside a regex pattern, case flags, and PATH roots —
    /// every richer combo (`-F`/`-w`/`-v`/`-q`/`-l`/`-c`/`-n`/`-m`/`-g`/`-t`)
    /// declines to cold, whose own index-vs-live rank paths own those edges.
    rank_k: ?usize = null,

    /// Engine-effective caseless state. `-S` folds only when the pattern has no
    /// (Unicode) uppercase (`args.hasUpper`). Compile sites must use this, not
    /// raw `ignore_case`.
    pub fn effectiveIgnoreCase(self: Request) bool {
        return self.ignore_case or (self.smart_case and !args.hasUpper(self.pattern));
    }

    /// `-m0`: ripgrep short-circuits before emitting or counting a single hit —
    /// no output, exit 1, in every mode. The session honors it before compiling.
    pub fn matchNothing(self: Request) bool {
        return self.max_count == 0;
    }
};

pub const ClassifyError = error{
    /// Outside the resident fast path — answer cold.
    Unsupported,
    /// No pattern (a bare `-l`) — also cold.
    NoPattern,
};

/// A positional PATH the warm path can serve byte-identically to cold: a clean
/// repo-root-relative subtree or file. Returns the trailing-slash-stripped root
/// to store, or null to decline (→ cold). Declines an absolute path, a `./`- or
/// `../`-prefixed one (cold renders that exact prefix, which the CWD-relative
/// mirror lacks), any `..` segment, `.`/empty (the rootless path already serves
/// the whole CWD), and a glob (that is `-g`, resolved separately).
fn cleanRoot(arg: []const u8) ?[]const u8 {
    if (arg.len == 0 or arg[0] == '/') return null;
    if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../")) return null;
    if (std.mem.indexOfAny(u8, arg, "*?[]") != null) return null; // a glob, not a plain root
    var r = arg;
    while (r.len > 1 and r[r.len - 1] == '/') r = r[0 .. r.len - 1]; // rg parity: `libs/` == `libs`
    if (r.len == 0 or std.mem.eql(u8, r, ".") or std.mem.eql(u8, r, "..")) return null;
    var it = std.mem.splitScalar(u8, r, '/');
    while (it.next()) |seg| if (seg.len == 0 or std.mem.eql(u8, seg, "..")) return null;
    return r;
}

/// A running slice-of-slices builder over a fixed `ScopeArgs` array: appends a
/// token, declining (→ cold) once the array is full so the wire frame + the
/// client's stack scratch stay bounded (`max_scope`).
const Collector = struct {
    buf: *[max_scope][]const u8,
    n: usize = 0,
    fn push(self: *Collector, s: []const u8) ClassifyError!void {
        if (self.n == self.buf.len) return ClassifyError.Unsupported;
        self.buf[self.n] = s;
        self.n += 1;
    }
    fn slice(self: *const Collector) []const []const u8 {
        return self.buf[0..self.n];
    }
};

/// Route one `-g <glob>` token: a leading `!` is an exclude, else an include.
/// Declines (→ cold) the forms the warm `PathFilter` does not model identically
/// to the cold engine — an empty glob, an unterminated `[…]` class (rg errors on
/// it; cold owns that exit 2), a leading-`/` anchored glob (cold strips the
/// anchor against the search root, a rule the flat prune does not reproduce),
/// and a `{a,b}` alternation, which cold expands into one glob per branch
/// (`argv.braceExpand`) before matching. The flat filter has no expansion step,
/// so a braced glob pushed raw here matches nothing rather than the branches the
/// user asked for — a wrong answer, not a slow one. Any `{` declines: an
/// unbalanced one is a literal to cold, and conserving warm eligibility for a
/// rare glob shape is never worth diverging from cold's result.
fn addGlob(inc: *Collector, exc: *Collector, raw: []const u8) ClassifyError!void {
    if (raw.len == 0) return ClassifyError.Unsupported;
    const neg = raw[0] == '!';
    const g = if (neg) raw[1..] else raw;
    if (g.len == 0 or g[0] == '/' or scope.unterminatedClass(g)) return ClassifyError.Unsupported;
    if (std.mem.indexOfScalar(u8, g, '{') != null) return ClassifyError.Unsupported;
    try (if (neg) exc else inc).push(g);
}

/// Route one `-t <type>` token: resolve it to its extension globs and flatten
/// them into the `exts` OR-set. An unknown type declines (→ cold, which emits
/// rg's exit-2 "unrecognized type"); `all` (every known type) is outside the
/// flat `PathFilter` model and also declines.
fn addType(ext: *Collector, name: []const u8) ClassifyError!void {
    if (name.len == 0 or std.mem.eql(u8, name, "all")) return ClassifyError.Unsupported;
    const globs = types.extsForType(name) orelse return ClassifyError.Unsupported;
    for (globs) |g| try ext.push(g);
}

/// Resolve an `--engine <name>` value to whether the warm path uses PCRE2:
/// `pcre2` ⇒ true, `default` ⇒ false (the linear engine). `auto` — rg's
/// linear-first hybrid that escalates to PCRE2 only for a pattern the linear
/// engine declines — and any unknown name decline to cold, which owns the
/// escalation decision (and rg's exit-2 diagnostic for a bad name).
fn engineIsPcre(v: []const u8) ClassifyError!bool {
    if (std.mem.eql(u8, v, "pcre2")) return true;
    if (std.mem.eql(u8, v, "default")) return false;
    return ClassifyError.Unsupported;
}

/// Parse a `-A`/`-B`/`-C` (or `--after/before-context`) decimal window value. A
/// non-decimal / overflowing tail is not the fast path's to reinterpret — decline
/// so cold parses (and diagnoses with rg's exit-2) whatever the user actually meant.
fn ctxNum(s: []const u8) ClassifyError!u64 {
    return std.fmt.parseInt(u64, s, 10) catch ClassifyError.Unsupported;
}

/// Classify rg-style argv into an eligible `Request`, or fail → cold.
/// Recognizes `-l`/`-c`/`-F`, case family `-i`/`-s`/`-S`, `-w`, `-n`/`-N`,
/// pattern via bare token or `-e`/`--regexp`, and clean relative PATH roots
/// (`cleanRoot`) collected into `sa`. Bare pattern → `mode = .lines`. An
/// ineligible PATH (`.`, `./x`, absolute, glob) or other flag → ineligible.
/// `sa` backs `req.filter.roots` and must outlive the returned `Request`.
pub fn classify(argv: []const []const u8, sa: *ScopeArgs) ClassifyError!Request {
    var pattern: ?[]const u8 = null;
    var mode: ?Mode = null;
    var fixed = false;
    var ignore_case = false;
    var smart_case = false;
    var word = false;
    var pcre = false;
    var invert = false;
    var line_num = false;
    var quiet = false;
    var max_count: ?u64 = null;
    var rank_k: ?usize = null;
    // `-A`/`-B`/`-C` windows recorded separately so `-A`/`-B` outrank `-C` at
    // the fold regardless of argv order — cold's exact rule (`args.zig`).
    var a_val: ?u64 = null;
    var b_val: ?u64 = null;
    var c_val: ?u64 = null;
    var end_of_flags = false;
    var roots: Collector = .{ .buf = &sa.roots };
    var includes: Collector = .{ .buf = &sa.includes };
    var excludes: Collector = .{ .buf = &sa.excludes };
    var exts: Collector = .{ .buf = &sa.exts };

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) return ClassifyError.Unsupported;
        if (!end_of_flags and std.mem.eql(u8, arg, "--")) {
            end_of_flags = true; // rg parity: everything after `--` is a path
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches"))) {
            if (mode != null and mode.? != .files) return ClassifyError.Unsupported;
            mode = .files;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count"))) {
            if (mode != null and mode.? != .count) return ClassifyError.Unsupported;
            mode = .count;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings"))) {
            fixed = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case"))) {
            // Case mode is last-wins across -i/-s/-S (each clears the other two).
            ignore_case, smart_case = .{ true, false };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--case-sensitive"))) {
            ignore_case, smart_case = .{ false, false };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--smart-case"))) {
            ignore_case, smart_case = .{ false, true };
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp"))) {
            word = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--pcre2"))) {
            pcre = true; // the vendored PCRE2 JIT backend behind the shared seam
        } else if (!end_of_flags and std.mem.eql(u8, arg, "--engine")) {
            // `--engine <name>`: pcre2 ⇒ warm PCRE2; default ⇒ warm linear;
            // `auto` (linear→PCRE escalation) / unknown ⇒ cold owns it.
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            pcre = try engineIsPcre(argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--engine=")) {
            pcre = try engineIsPcre(arg["--engine=".len..]);
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match"))) {
            invert = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet"))) {
            quiet = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-count"))) {
            // Value in the next token. A missing or non-decimal value is not the
            // fast path's to reinterpret — decline so cold parses (and diagnoses) it.
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            max_count = std.fmt.parseInt(u64, argv[i], 10) catch return ClassifyError.Unsupported;
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "-m=")) {
            max_count = std.fmt.parseInt(u64, arg["-m=".len..], 10) catch return ClassifyError.Unsupported;
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--max-count=")) {
            max_count = std.fmt.parseInt(u64, arg["--max-count=".len..], 10) catch return ClassifyError.Unsupported;
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-m")) {
            // rg's glued short form `-mN` (e.g. `-m1`). A non-decimal tail is
            // cold's to diagnose, so decline rather than reinterpret.
            max_count = std.fmt.parseInt(u64, arg[2..], 10) catch return ClassifyError.Unsupported;
        } else if (!end_of_flags and std.mem.eql(u8, arg, "--rank")) {
            // Bare `--rank` REQUESTS the ranked view but does not set the cap —
            // cold keeps whatever `o.rank_k` holds, so a prior `--rank=5` survives
            // a trailing bare `--rank` (only `null` ⇒ cold's default-20 sentinel 0).
            if (rank_k == null) rank_k = 0;
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--rank=")) {
            rank_k = std.fmt.parseInt(usize, arg["--rank=".len..], 10) catch return ClassifyError.Unsupported; // explicit, last-wins
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context"))) {
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            a_val = try ctxNum(argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--after-context=")) {
            a_val = try ctxNum(arg["--after-context=".len..]);
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-A")) {
            a_val = try ctxNum(arg[2..]); // glued `-A2`
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context"))) {
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            b_val = try ctxNum(argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--before-context=")) {
            b_val = try ctxNum(arg["--before-context=".len..]);
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-B")) {
            b_val = try ctxNum(arg[2..]); // glued `-B2`
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context"))) {
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            c_val = try ctxNum(argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--context=")) {
            c_val = try ctxNum(arg["--context=".len..]);
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-C")) {
            c_val = try ctxNum(arg[2..]); // glued `-C2`
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number"))) {
            line_num = true;
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-line-number"))) {
            line_num = false; // rg's left-to-right undo rule
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp"))) {
            i += 1;
            if (i >= argv.len or pattern != null) return ClassifyError.Unsupported;
            pattern = argv[i];
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--regexp=")) {
            if (pattern != null) return ClassifyError.Unsupported;
            pattern = arg["--regexp=".len..];
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob"))) {
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            try addGlob(&includes, &excludes, argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--glob=")) {
            try addGlob(&includes, &excludes, arg["--glob=".len..]);
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-g")) {
            try addGlob(&includes, &excludes, arg[2..]); // glued `-gGLOB`
        } else if (!end_of_flags and (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type"))) {
            i += 1;
            if (i >= argv.len) return ClassifyError.Unsupported;
            try addType(&exts, argv[i]);
        } else if (!end_of_flags and std.mem.startsWith(u8, arg, "--type=")) {
            try addType(&exts, arg["--type=".len..]);
        } else if (!end_of_flags and arg.len > 2 and std.mem.startsWith(u8, arg, "-t")) {
            try addType(&exts, arg[2..]); // glued `-tTYPE`
        } else if (!end_of_flags and arg[0] == '-') {
            // Any other flag (context, --json, --iglob, -T, --hidden, …) is
            // outside the fast path — hand the whole request to cold.
            return ClassifyError.Unsupported;
        } else if (pattern == null) {
            pattern = arg; // the first bare token is the pattern
        } else {
            // A positional PATH: served warm only when it is a clean relative
            // root the resident mirror can render byte-identically to cold (see
            // `cleanRoot`); anything else — or more roots than the scratch holds
            // — falls back to the certified cold path unchanged.
            try roots.push(cleanRoot(arg) orelse return ClassifyError.Unsupported);
        }
    }

    const m = mode orelse Mode.lines; // no -l/-c ⇒ the default line search
    const p = pattern orelse return ClassifyError.NoPattern;
    if (p.len == 0) return ClassifyError.Unsupported;
    // A pattern carrying a newline or NUL steps outside rg's per-line model
    // (warm whole-doc gates would match ACROSS lines where cold cannot; a NUL
    // interacts with binary detection) — the cold engine owns those bytes.
    if (std.mem.indexOfAny(u8, p, "\n\x00") != null) return ClassifyError.Unsupported;
    // Fold the context windows exactly as cold's argv parser does: an explicit
    // `-A`/`-B` outranks `-C` on its own side, and `-C` fills the side left
    // unset (`args.zig`). A window only matters for the `lines` render.
    const after = a_val orelse c_val orelse 0;
    const before = b_val orelse c_val orelse 0;
    // `--rank` is the definition-first regex view: it IGNORES `-F`/`-w`/`-l`/
    // `-c`/`-n`/`-m`/`-v`/`-q` and context in cold and gates only by PATH roots
    // (its index path even bypasses `-g`/`-t`). Rather than mirror those quirks
    // warm, admit only the clean rank surface — pattern + case + roots — and
    // decline every richer combo to cold, which owns its index-vs-live rank.
    if (rank_k != null and (fixed or word or pcre or invert or quiet or line_num or max_count != null or before != 0 or after != 0 or m != .lines or includes.n != 0 or excludes.n != 0 or exts.n != 0))
        return ClassifyError.Unsupported;
    // Context only shapes the `lines` render; `-l`/`-c` never emit a window (rg
    // parity), so a context request under those modes stays cold-free of it.
    return .{ .pattern = p, .mode = m, .fixed = fixed, .ignore_case = ignore_case, .line_num = line_num, .smart_case = smart_case, .word = word, .pcre = pcre, .invert = invert, .quiet = quiet, .max_count = max_count, .before = before, .after = after, .rank_k = rank_k, .filter = .{ .roots = roots.slice(), .includes = includes.slice(), .excludes = excludes.slice(), .exts = exts.slice() } };
}
