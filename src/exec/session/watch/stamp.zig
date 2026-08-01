//! gist resident session — the instant a watcher delivery is stamped with.
//!
//! The POSIX backends must read the wall clock at DELIVERY, not at drain: the
//! annals compare a noted path against `base.ns` instants minted from the SAME
//! realtime clock, and an instant taken a drain later would date the change to
//! after the reader that should have seen it. So the reading sits beside each
//! event loop rather than inside the ledger, which stays free of any platform
//! clock — and it is spelled once, here, because two arms that could drift on
//! what "now" means is precisely the parity bug the ledger cannot detect.
//!
//! Windows is not a third copy of this. A notify record carries the changed
//! file's timestamps in-band, so `notify.zig` stamps a delivery with that
//! file's own `max(mtime, ctime)` and reads a clock only for a removal, where
//! no surviving file remains to ask — a different question, answered there.

const std = @import("std");

/// Wall-clock nanoseconds off the raw libc clock — the watcher's OS thread has
/// no `std.Io` handle. Null when the clock is unreadable, in which case the
/// caller poisons the ledger (doubt, or coverage left unopened) rather than
/// guessing an instant.
pub fn wallNowNs() ?i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
