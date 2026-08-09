//! irregex — gleaning: what you do with a pattern once it is compiled.
//!
//! The rest of `kernel/regex/` is named for what it *is* — the syntax, the ast,
//! the linear engines, the caliper, the ladder. This tier is named for what a
//! caller *does*: hold a compiled pattern and take matches out of a haystack,
//! one at a time, with their groups, replacing or splitting on the way. It is
//! the only tier here whose shape is set by the person asking rather than by the
//! automaton answering, which is why it did not exist until the export surface
//! was audited and the largest audience turned out to be the one with no door.
//!
//! Four pieces, and the seam between them is the match stream:
//!
//!   pool.zig    who owns the memory a search reuses (so no signature says `Sim`)
//!   pattern.zig the handle: compile · isMatch · find · matches · groups · rewrite
//!   cursor.zig  successive matches, with the zero-width advance written once
//!   groups.zig  what a capture caught, by ordinal or by name, over flat slots
//!   rewrite.zig replace and split, both walks over one cursor
//!
//! Nothing here is an engine. Every verb lowers to a call `exec/cold` already
//! makes on the same `Matcher`, so an answer from this door and an answer from
//! `gist` are the same answer by construction rather than by agreement.

pub const Pattern = @import("pattern.zig").Pattern;
pub const Options = @import("pattern.zig").Options;
pub const BoundError = @import("pattern.zig").BoundError;

/// What an earliest ask can fail with — a compile with no machine that can halt
/// at an acceptance (`Pattern.halts`), which is refused rather than answered
/// leftmost-first under an earliest label.
pub const EarliestError = @import("pattern.zig").EarliestError;

/// Borrowed per-search scratch, for a caller driving many patterns or many
/// threads and wanting one shelf between them. A `Pattern` already owns one; you
/// need this only when you are building the layer above.
pub const Pool = @import("pool.zig").Pool;

pub const Cursor = @import("cursor.zig").Cursor;
pub const Groups = @import("groups.zig").Groups;

/// How many matches a rewrite acts on — `.all`, or `.{ .first = n }`.
pub const Reach = @import("rewrite.zig").Reach;

/// The rewrite verbs over a cursor you already hold, for a caller that wants to
/// share one walk between a replace and something else. `Pattern` wraps these.
pub const rewrite = @import("rewrite.zig");
