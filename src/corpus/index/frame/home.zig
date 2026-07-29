//! home — where the persisted irregex artifacts live.
//!
//! One resolution of the artifact directory (`outDir`) and one per-artifact
//! path formatter (`ArtifactPath`), shared by everything that persists or
//! loads a blob there — the trigram index, kinship atlas, codex shelf,
//! freshness anchor, and daemon socket. It sits on the wire floor beside
//! `frame.zig` (whose `tree.root` binding is a property of exactly this
//! directory) so the codebook kernel and the corpus artifacts resolve the
//! same home without either importing the other.

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("../../../assay/assay.zig");

/// Default artifact home, relative to the working directory — where the
/// trigram index, kinship atlas, codex shelf, freshness anchor, and daemon
/// socket live. `GIST_DIR` overrides it per invocation (`outDir`).
pub const default_out_dir = ".local/gist-verify";

/// The artifact directory for THIS process: `GIST_DIR` when set (trailing
/// slashes trimmed), else `default_out_dir`. The env string outlives the
/// process, so the returned slice is borrow-safe everywhere.
pub fn outDir() []const u8 {
    const v = assay.envSpan("GIST_DIR") orelse return default_out_dir;
    // Both separators, not just `/`: on Windows a shell-completed directory
    // arrives as `C:\tmp\gist\`, and the artifact names are appended raw.
    const s = std.mem.trimEnd(u8, v, if (builtin.os.tag == .windows) "/\\" else "/");
    return if (s.len == 0) default_out_dir else s;
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
