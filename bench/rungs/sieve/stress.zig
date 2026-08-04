//! Layer L's **planner-stress slate**, an extension of the shared probe registry
//! (`bench/apparatus/harness/probes.zig`) used by `indexq.zig` alone.
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
//! shape a real code search produces, and every one is chosen because csearch's
//! planner has a real, non-obvious answer for it that this harness lifts
//! verbatim (`csearch_plan.py`).
//!
//! ## The vocabulary is the corpus's, not a monorepo's
//!
//! These patterns were Go idioms until the packages went standalone, because
//! the tree they were cut against was the private monorepo that made every
//! receipt unpublishable. Measured against the corpora that survived the split
//! they had stopped asking anything: over the 16k-file synthetic Go corpus five
//! of eight classes matched nothing and `errcheck` matched every file, and over
//! this checkout alone `methodalt` and `nilassign` matched nothing at all. A
//! class at 0% and a class at 100% admit the identical candidate set under
//! every planner, so both are a row that cannot fail.
//!
//! The planner *shapes* below are the originals; only the vocabulary moved, onto
//! the declared `ecosystem-v1` corpus — the four sibling checkouts, which anyone
//! can clone (`bench/certificate/corpus.toml`). Selectivity there, over 1,486
//! files, is held between 2% and 26% by `csearch_plan.py --audit`, which fails
//! closed if a class goes vacuous or saturating. A pinned foreign tree could not
//! promise that: a class can quietly stop occurring between two tags while the
//! sweep stays green, measuring less than it claims.
//!
//! Nothing here changes the certificate's class↔claim mapping: these rows are
//! reported and spliced under their own heading, never merged into the twelve.

const probes_mod = @import("probes");

pub const Probe = probes_mod.Probe;

pub const probes = [_]Probe{
    // Multi-run conjunction: four disjoint mandatory literals, three of them
    // adjacent to a whitespace class. The one-literal planner sees `err`. Still
    // Go — the C-ABI examples and the Go binding carry it — and at ~2% of the
    // corpus it is now the *selective* end of this slate rather than the
    // saturating one it became on a synthetic Go tree.
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
    // Prefix literal + bounded character class: the `r [A` window is the
    // selective part, and a planner that stops at the literal keeps every file
    // containing the word. Replaces the `ADR-\d{3}` cite, which survived the
    // split in two files.
    .{ .class = "stress-sectioncite", .kind = .regex, .pattern = "Layer [A-L]" },
    // Alternation where one branch is a strict PREFIX of the other, inside a
    // shared mandatory affix. Strictly harder than two unrelated literals: the
    // long branch's trigram run subsumes the short one's, so a planner that
    // unions the branches emits a filter no more selective than `append` alone,
    // while one that notices the subsumption can charge for the suffix.
    .{ .class = "stress-prefixalt", .kind = .regex, .pattern = "\\.(appendSlice|append)\\(" },
    // A leading `\w+` wall: everything provable is to the RIGHT of it, and the
    // `=`/`undefined` runs are separated by a whitespace class.
    .{ .class = "stress-undefwall", .kind = .regex, .pattern = "\\w+\\s*=\\s*undefined" },
};
