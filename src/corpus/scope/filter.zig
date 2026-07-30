//! irregex path scoping — the `rg -g <glob>` / positional-`PATH` affordance an
//! agent reaches for to confine a search to a subtree. This is the one place
//! irregex can be *faster* than rg rather than merely matching it: rg applies a
//! glob filter while walking the whole tree, but irregex already holds the full
//! path list, so it prunes candidate ids *before* touching disk — a `-g '*.go'`
//! query reads only the Go files, not all 18k candidates.
//!
//! This module owns the resolved `PathFilter` (the grep verb's AND-combined
//! constraint set) and the positional-root scoping rules; the pure glob
//! **matcher** it evaluates against is `kernel/math/glob.zig`, and the language
//! `-t <lang>` type table is the sibling `types.zig` (a pure data concern).

const std = @import("std");
const glob = @import("../../kernel/math/glob.zig");
const globApplies = glob.globApplies;
const genus = @import("genus.zig");

/// Normalize a positional path arg to the corpus's repo-root-relative shape:
/// strip a leading `./` and any trailing `/` so `./services/` and `services`
/// both scope to the same prefix. Returned slice aliases the input (no alloc).
pub fn normalizeRoot(arg: []const u8) []const u8 {
    var s = arg;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

/// Is `path` at, or under, the directory/file `root`? `.`/`""` is the whole
/// corpus (matches all). An exact-length equality is a file arg; otherwise the
/// root must be a *directory* prefix (`services` admits `services/x.go` but not
/// `services_old/x.go`, hence the mandatory `/` boundary).
pub fn underRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or (root.len == 1 and root[0] == '.')) return true;
    if (path.len == root.len) return std.mem.eql(u8, path, root);
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// A resolved set of path constraints. All slices are caller-owned (they alias
/// argv / a small arena built at parse time); `PathFilter` only borrows them.
pub const PathFilter = struct {
    exts: []const []const u8 = &.{}, // union of every `-t` type's globs (see scope/types.zig)
    includes: []const []const u8 = &.{}, // `-g <glob>` (OR); empty ⇒ no constraint
    excludes: []const []const u8 = &.{}, // `-g !<glob>` (any match vetoes the path)
    roots: []const []const u8 = &.{}, // positional PATH args (OR); empty ⇒ whole corpus
    genera: genus.Set = .empty, // `--docs` / `-t docs` (see scope/genus.zig)
    neg_genera: genus.Set = .empty, // `--no-docs` / `-T docs`

    pub fn isEmpty(self: PathFilter) bool {
        return self.exts.len == 0 and self.includes.len == 0 and
            self.excludes.len == 0 and self.roots.len == 0 and
            !self.genera.any() and !self.neg_genera.any();
    }

    /// Does `path` survive the filter? An exclude veto wins; then the path must
    /// satisfy each *non-empty* constraint set (root ∧ type ∧ genus ∧ include),
    /// each OR-internal. Positional roots gate first — an agent's `grep pat dir/`.
    ///
    /// A genus gate is an AND here where cold ORs it with `exts`, so the warm
    /// classifier admits a genus only when no other positive family is present
    /// (`request.zig`); with one positive family, AND and OR coincide.
    pub fn admits(self: PathFilter, path: []const u8) bool {
        for (self.excludes) |g| if (globApplies(g, path)) return false;
        if (self.neg_genera.any() and self.neg_genera.has(genus.of(path))) return false;
        if (self.genera.any() and !self.genera.has(genus.of(path))) return false;
        if (self.roots.len > 0) {
            for (self.roots) |r| {
                if (underRoot(path, r)) break;
            } else return false;
        }
        if (self.exts.len > 0) {
            for (self.exts) |e| {
                if (globApplies(e, path)) break;
            } else return false;
        }
        if (self.includes.len > 0) {
            for (self.includes) |g| if (globApplies(g, path)) return true;
            return false;
        }
        return true;
    }

    /// Would this filter drag a DEFAULT-walk-skipped file back into the result
    /// set — the un-hide/un-ignore question the warm session asks of each
    /// reachable `Extra` (`serial.zig`)? A hidden dotfile is un-hidden by a `-t`
    /// type OR a `-g` glob match; a gitignored leaf (`ignored = true`) is
    /// un-ignored ONLY by a `-g` glob — a `-t` type never un-ignores
    /// (rg / `ignore.zig::skipFromVerdict`, where `-t` sets only `wl_hidden`).
    /// In both cases the path must still clear the positional roots and survive
    /// every exclude, so this front-loads the same root/exclude gate as `admits`
    /// and is a SUPERSET of the true result-set admission (the un-hide trigger
    /// is an OR, not `admits`'s type∧glob AND) — safe for a fail-closed decline:
    /// over-declining a warm query answers it cold (correct), never wrong. The
    /// resident session declines to cold when any extra answers true here, since
    /// its mirror (built from the hidden/ignore-excluding walk) cannot supply it.
    ///
    /// A genus is deliberately absent, matching cold (`intent.whitelistsHidden`):
    /// it only narrows what the walk produced. Since `code` is the partition's
    /// default, letting it un-hide would surface every unrecognized hidden path.
    pub fn surfacesHidden(self: PathFilter, path: []const u8, ignored: bool) bool {
        for (self.excludes) |g| if (globApplies(g, path)) return false;
        if (self.roots.len > 0) {
            for (self.roots) |r| {
                if (underRoot(path, r)) break;
            } else return false;
        }
        if (!ignored) for (self.exts) |e| if (globApplies(e, path)) return true;
        for (self.includes) |g| if (globApplies(g, path)) return true;
        return false;
    }

    /// Keep only the candidate ids whose path the filter admits, in place.
    /// Returns the surviving prefix. A no-op filter returns `ids` untouched, so
    /// the unscoped path pays nothing.
    pub fn prune(self: PathFilter, paths: []const []const u8, ids: []u32) []u32 {
        if (self.isEmpty()) return ids;
        var w: usize = 0;
        for (ids) |d| if (self.admits(paths[d])) {
            ids[w] = d;
            w += 1;
        };
        return ids[0..w];
    }
};
