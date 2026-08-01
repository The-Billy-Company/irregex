//! gist bench — Layer L's **planner-stress slate**, an extension of the shared
//! probe registry (`bench/apparatus/harness/probes.zig`) used by `indexq.zig` alone.
//!
//! Why a second slate exists. The shared registry is the certificate's own
//! twelve classes, and Layer L reports every one of them first — it is the
//! table nobody can accuse of being chosen to flatter gist. But that slate was
//! designed to span *scan* cost (Layers A and D), and on the planner axis eight
//! of its twelve classes cannot separate two planners at all: four are
//! single-literal (any planner emits the same one trigram run), and four are
//! structurally unfilterable — literal-free (`\w{3,8}`), sub-trigram (`})`,
//! `;$`), or an alternation with a sub-trigram branch (`panic|0x`), where the
//! only sound answer is "no filter". A slate that cannot distinguish the two
//! planners on ⅔ of its rows is the wrong instrument for the question
//! "is this planner better than csearch's".
//!
//! So these rows exist to make the comparison *hard*, not easy. Every one is a
//! shape a real code search produces — a Go nil-check, a Zig signature, an ISO
//! date, a hex constant, a URL, an ADR cite, a method alternation — and every
//! one is chosen because csearch's planner has a real, non-obvious answer for
//! it that this harness lifts verbatim (`csearch_plan.py`). Two of them csearch
//! wins outright before Layer L; publishing those is the point.
//!
//! Nothing here changes the certificate's class↔claim mapping: these rows are
//! reported and spliced under their own heading, never merged into the twelve.

const probes_mod = @import("probes");

pub const Probe = probes_mod.Probe;

pub const probes = [_]Probe{
    // Multi-run conjunction: four disjoint mandatory literals, three of them
    // adjacent to a whitespace class. The one-literal planner sees `err`.
    .{ .class = "stress-errcheck", .kind = .regex, .pattern = "if\\s+err\\s*!=\\s*nil" },
    // Two keyword+whitespace adjacencies. `pub` and `fn` are both common; the
    // adjacency is what is rare.
    .{ .class = "stress-zigfn", .kind = .regex, .pattern = "pub\\s+fn\\s+\\w+\\(" },
    // Literal-free, but the two dashes make three separable windows. csearch
    // emits one of them and stops.
    .{ .class = "stress-isodate", .kind = .regex, .pattern = "\\d{4}-\\d{2}-\\d{2}" },
    // A sub-trigram literal (`0x`) glued to a 22-member class. csearch declines
    // the whole pattern (`query: +`, no filter); the run `0x`+hex is 3 B.
    .{ .class = "stress-hexlit", .kind = .regex, .pattern = "0x[0-9a-fA-F]{6}" },
    // A quest inside a literal run — the optional `s` splits the scheme into
    // two provable prefixes that must be handled as an alternation, not a wall.
    .{ .class = "stress-url", .kind = .regex, .pattern = "https?://[\\w.]+" },
    // Prefix literal + digit class: the `R-<digit>` window is the selective part.
    .{ .class = "stress-adr", .kind = .regex, .pattern = "ADR-\\d{3}" },
    // Alternation of two literals of different lengths inside a literal context,
    // where the shared suffix (`Err(`) is also mandatory.
    .{ .class = "stress-methodalt", .kind = .regex, .pattern = "\\.(Unwrap|Wrap)Err\\(" },
    // A leading `\w+` wall: everything provable is to the RIGHT of it, and the
    // `:=`/`nil` runs are separated by a whitespace class.
    .{ .class = "stress-nilassign", .kind = .regex, .pattern = "\\w+\\s*:=\\s*nil" },
};
