The repo head was still the monorepo's search-product README with the product
filed off. It opened by explaining itself as a cut of somebody else's crate
layout, spent its inventory on the walk, the trigram index, and the rg-shaped
output frames, and got to the regex engine as one bullet in a list of eight.
Then it buried install, the bindings, and the build on page four, under an
engine deep-dive nobody reaches before they have the thing compiling.

`README.md` is rewritten and reordered around both problems.

**What it says it is.** This package is the toolkit for building a search
engine, not a search engine and not only a regex library, and the head now opens
with that. The engine is the center; around it are the SIMD literal scanners
that decide which bytes the matcher sees, the candidate indexes that decide
which files it opens, the freshness law that keeps those indexes correct under a
tree ten people are editing, the compiled query every transport lowers through,
the two runtimes, ranking, multi-pattern attribution, and the FM-index. Take the
whole stack and you have a grep; take three pieces and you have something else.

**It is shaped like a manual now, not an essay.** A contents list, then a
*Should I be using this?* table that routes you off this page if what you wanted
was a binding or a terminal tool, then install, then recipes. The engine deep
dive starts halfway down and the harnesses - build, proof, the measured bounds -
sit at the end with the other contributor material, because nobody reaches them
before they have the thing compiling.

**What you need first is first.** Install, all four ways in, is the section
after the routing table - Python, Rust, Go, Zig, and plain C, a
`build.zig.zon` snippet, and a C snippet that actually compiles against the
shipped header (`irgx_regex`, `irgx_compile`'s pointer+length signature, the
`IRGX_STALE` re-compile, `irgx_free`).

**Eight recipes, and the Zig in them is compiled against the module.** The
three regex ones (match bytes you hold, hoist the compile without hoisting the
scratch, escalate a pattern the grammar declines), the four you assemble an
engine out of (many patterns in one walk with per-pattern attribution, a trigram
candidate set, the crest sieve for patterns with no literal in them, one
compiled query feeding both the prefilter and the match), and the warm engine
with all of it already assembled behind a cancel token and a deadline.

**Two sections were promoted out of the deep dive because they are decisions,
not history.** *Choosing an engine* is the ladder as a menu - seven rungs, what
takes each one, and the measured coefficients and regret arm that keep the order
honest - so you can tell what your pattern is going to get. *Contracts* gathers
the seven rules that hold across the Zig API, the C ABI, every binding, and the
indexes: a refusal is a status rather than an error, the fault slot is
per-thread and pull-based, one handle one thread, versions are three axes, an
index accelerates and never answers, a stale artifact is still correct because
freshness is one rule, and a ceiling declines instead of degrading. Five are
promises; two are obligations you keep back if you build your own artifact on
these parts.

**A toolkit map that is actually an inventory.** What was one five-row table at
the bottom is a full section: every one of the eight kernel packages with what
it gives you, the five corpus packages, all seven persisted index artifacts by
what each one *eliminates*, the two runtimes with cold's seven concern packages
and the session's six planes, and the surface tier. It gives
`query/` and `scan/` their own paragraphs, since those are the two people assume
they have to build twice, and it defers the laws those tiers rest on to
*Contracts* rather than restating them, because they bind anything you build on
these parts and not only what ships here.

**The engine sections are unchanged in substance** and keep their order:
the eight-stage pipeline, the four front-end stages, Unicode, the two roads to a
deterministic table, the priced ladder, the escape rungs with their published
losses, spans, the PCRE2 handoff, crest, the proof strategy, and the bounds.

Every number was re-derived from the source or the harness README that mints it
rather than carried over. Two claims did not survive that: the roofline figures
the old head quoted no longer matched the artifact, and a passes-per-candidate-
byte range for the SIMD classes existed only in an untracked local baseline, so
both are stated qualitatively now against what the tracked harnesses assert. The
head also gains a `doc_radar` block it never had - six directory counts across
the regex stages, the kernel tiers, the corpus packages, the index artifacts,
and both `exec/` levels, plus twenty-three sentinel literals over the constants,
version strings, contract symbols, and recipe entry points the prose quotes - so
the next drift in any of it is a lint failure rather than a reading.
