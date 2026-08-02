//! assay/brand — the program identity this engine answers as.
//!
//! This kernel is embeddable, and more than one program already rides it:
//! `gist`, `relate`, and `irregex` are three binaries over one library, and an
//! embedder may stand a fourth up under its own name. Three facts separate a
//! program from the engine inside it — the name that opens a diagnostic line,
//! the namespace its environment knobs live in, and the directory its artifacts
//! are written to — and every one of them used to be the literal string `gist`,
//! spelled out at ~80 call sites. The cost was visible: running `relate`, a bad
//! `GIST_HYPERLINK` was reported as `gist: note: …`, naming a program the user
//! was not running.
//!
//! Identity now arrives the way `std.options` does — the root module declares
//! it, the library reads it, a caller who declares nothing gets the default:
//!
//! ```zig
//! pub const irgx_brand: irregex.Brand = .{ .name = "relate" };
//! ```
//!
//! Because it resolves at comptime, a knob name is still a string literal by the
//! time `getenv` sees it and the tag is still concatenated into the format
//! string. The seam costs nothing at runtime, and a program that keeps the
//! default emits the bytes it always did.
//!
//! The three fields deliberately do NOT move together. `name` is per-binary:
//! `relate` should say `relate:`, because that is what the user typed.
//! `env_prefix` and `artifact_dir` are per-ECOSYSTEM: the sibling binaries share
//! one trigram index, one kinship atlas, and one `GIST_TRACE`, so they have to
//! agree on where those live or a warm tier written by one is invisible to the
//! next. Only an embedder standing the engine up under its own name moves those,
//! and it moves them together.

const std = @import("std");
const root = @import("root");

/// Who this program is. Defaults are the historical `gist` spellings, so a
/// compilation that declares nothing is byte-for-byte what it was.
pub const Brand = struct {
    /// Opens every diagnostic line this program signs: `<name>: note: …`.
    /// Per-binary — it should be the name the user typed.
    name: []const u8 = "gist",
    /// Namespace for environment knobs, trailing separator included, so
    /// `TRACE` resolves as `<env_prefix>TRACE`. Per-ecosystem.
    env_prefix: []const u8 = "GIST_",
    /// Where the index, atlas, shelf, freshness anchor, and daemon socket live,
    /// relative to the working directory. Per-ecosystem.
    artifact_dir: []const u8 = ".gist",
};

/// This compilation's identity: the root module's `irgx_brand` when it
/// declares one, else the default. A test runner, a C-ABI host, and any binary
/// that never opts in all land on `gist`.
pub const active: Brand = if (@hasDecl(root, "irgx_brand")) root.irgx_brand else .{};

/// The full name of a branded environment knob — `active.env_prefix ++ suffix`,
/// folded at comptime so the `getenv` still sees a literal.
pub fn knobName(comptime suffix: []const u8) [*:0]const u8 {
    const full = active.env_prefix ++ suffix;
    return (full ++ "\x00")[0..full.len :0].ptr;
}

test "the default identity is the historical gist spelling" {
    try std.testing.expectEqualStrings("gist", active.name);
    try std.testing.expectEqualStrings("GIST_", active.env_prefix);
    try std.testing.expectEqualStrings(".gist", active.artifact_dir);
}

test "a knob name folds the prefix in and stays null-terminated" {
    const k = knobName("TRACE");
    try std.testing.expectEqualStrings("GIST_TRACE", std.mem.span(k));
}
