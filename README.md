# irregex: A Search Engine Toolkit

> [!NOTE]
> No binary ships from this repository. `zig build` produces `libirgx` and
> installs [`include/irgx.h`](include/irgx.h); the product faces built on it
> (`gist`, `relate`, `blast`) are separate packages.
>
> That line is deliberate. Argv grammar, daemon lifecycle, distribution, and any
> promise a user can hold you to belong to whoever ships an executable.
> Everything below that line is here.

 - [Overview](#overview)
 - [Should I Be Using This?](#should-i-be-using-this)
 - [Support](#support)
 - [Install](#install)
   - [Zig](#zig)
   - [C](#c)
 - [Recipes](#recipes)
 - [Choosing an Engine](#choosing-an-engine)
 - [Contracts](#contracts)
 - [What's in the Toolkit](#whats-in-the-toolkit)
   - [The Kernels](#the-kernels)
   - [The Corpus](#the-corpus)
   - [The Runtimes](#the-runtimes)
   - [The Surface](#the-surface)
 - [The Engine, Stage by Stage](#the-engine-stage-by-stage)
 - [The C ABI](#the-c-abi)
 - [Build and Test](#build-and-test)
 - [How It Is Proven](#how-it-is-proven)
 - [What It Is Measured Against](#what-it-is-measured-against)
 - [Provenance](#provenance)

## Overview

irregex is the toolkit for building a search engine. It is not a search engine,
and not only a regex library: it is the set of parts that sit under one, each
usable on its own, none of them holding an opinion about your product.

At the center is the irregular-expression engine. A pattern arrives as text and
leaves as a machine that reads each candidate byte once, and everything between
those two facts lives here.

That covers the parser and its class algebra, an interned analysis graph, the
Thompson lowering, two independent routes to a deterministic automaton, a priced
ladder of cheaper machines allowed to answer instead of it, captures, spans, and
a vendored PCRE2 for the grammar the linear tier cannot express.

Around the engine is everything a matcher alone cannot do:

 - the SIMD literal scanners that decide which bytes the matcher ever sees
 - the candidate indexes that decide which *files* it ever opens
 - the freshness law that lets those indexes stay correct while ten people edit
 the tree underneath them
 - the compiled query every transport lowers through, so none of them can
 disagree about what a hit is
 - the tree walk, the two runtimes, the ranking fusion, the multi-pattern
 attribution, and the FM-index

Take the whole stack and you have a grep. Take three pieces and you have
something else.

The default engine cannot backtrack. It is a Thompson construction over bytes,
so an innocent-looking pattern cannot detonate on an unlucky input, and the cost
per byte is bounded no matter how ambiguous the pattern is. The
[technical report](https://proof.billylives.com/software/irregex/tech-report)
carries the algebra, history, and search-engine lineage behind that choice.

The seam here mirrors the decomposition Rust's regex ecosystem arrived at,
because it is the right one. `kernel/regex/` is the syntax and automata half,
sibling `kernel/scan/` is the literal accelerator half, and sibling
`kernel/query/` is the meta engine that picks between them.

PCRE2 is available for lookaround and backreferences, and it is opted into
rather than disguised.

## Should I Be Using This?

 - **To search a repository from a terminal** – `gist` for patterns, `relate`
 for similarity, `blast` for blast radius. Those are separate packages, built
 on this one.
 - **For a linear-time regex in Python, Rust, or Go** – the
 [bindings](#install). Each wears the surface that language already expects,
 and you never see this repository.
 - **For a regex in C, C++, Swift, or anything with an FFI** –
 [`include/irgx.h`](include/irgx.h). One header, one library, and no corpus
 behind it.
 - **To build a search engine**, with your own index, your own walk, your own
 ranking and your own product – here. Start at [Recipes](#recipes), then the
 [toolkit map](#whats-in-the-toolkit).
 - **To read how a regex engine is put together** – [The Engine, Stage by
 Stage](#the-engine-stage-by-stage). Every stage is a folder with its own
 README.
 - **To take one piece and leave the rest** – also here. The
 [kernels](#the-kernels) are eight packages that do not need each other.

The dividing line is whether you want *answers* or *parts*. A binding hands you
answers and hides every decision below it.

This repository hands you the decisions: which files to open, which bytes to
look at, which machine to run, and what a stale index is allowed to claim. If
none of those are questions you have, take a binding and stop reading.

## Support

 - Bugs and feature requests go through the
 [issue templates](.github/ISSUE_TEMPLATE), which ask for the pattern, the
 bytes, the flags, and the surface you drove. A regex bug without its subject
 is a bug nobody can reproduce.
 - Security vulnerabilities never go in a public issue. See
 [SECURITY.md](SECURITY.md).
 - `gist`, `relate`, and `blast` are separate repositories with their own issue
 trackers. File a command-line problem there; it moves here if the cause turns
 out to be the engine.

## Install

Four bindings, plus the header everything else speaks. Each binding ships the
native library with it, so installing needs no Zig and no compiler.

 - **[Python](bindings/python/README.md)** – `pip install irregex` (3.12+), then
 `import irgx`. Transport is `ctypes` over a shared library inside the wheel.
 - **[Rust](bindings/rust/README.md)** – `cargo add irgx`, then `use irgx::`. A
 static archive is vendored per target triple.
 - **[Go](bindings/go/README.md)** – `go get github.com/The-Billy-Company/irregex/bindings/go`,
 then cgo. A prebuilt archive ships per platform, so no toolchain is needed.
 - **[Zig](src/root.zig)** – a `build.zig.zon` dependency, then
 `@import("irregex")`. Source, built with your project.
 - **C, and anything else** – `zig build`, then
 [`include/irgx.h`](include/irgx.h). One library and one header.

You type `irgx` everywhere except PyPI, where the distribution is still
`irregex` because that name was free and the import is `irgx` anyway - the
bs4 / PIL split. On crates.io `irregex` is an unrelated 2023 crate and names
there are permanent, so the Rust package is `irgx`, which is the prefix the C
ABI and the header already use.

The surface in each is the one that language already expects: `Pattern`,
`finditer` and `sub` in Python, `Regex`, `RegexBuilder` and `captures_iter` in
Rust, and the `regexp`-shaped Find/Split/Replace family in Go.

Each is oracled rather than assumed. Python is differentialed against `re`, and
Go and Rust replay a byte-offset oracle generated from the Python binding, so
three implementations of "where did that match start" cannot drift apart
quietly.

### Zig

```zig
// build.zig.zon
.irregex = .{ .path = "../irregex" },  // dev: sibling checkout; releases pin url + hash

// build.zig
const irregex = b.dependency("irregex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("irregex", irregex.module("irregex"));
```

The module surface is [`src/root.zig`](src/root.zig): the engine tiers (`regex`,
`regex_dfa`, `matcher`, `captures`), the corpus and index families, the compiled
query, `api` for the curated hosted Zig vocabulary, and `ffi` for the C-ABI
substrate.

Note that the `inner` namespace is the product seam. Those modules are internal
but stable, they version together with this package, and they are explicitly not
semver-stable for anyone but the sibling faces that consume them.

### C

`zig build` writes `libirgx` and installs the header. From there:

```c
#include "irgx.h"

static const char pat[] = "\\bwallet[A-Za-z_]*";
#define PAT (const uint8_t *)pat, sizeof pat - 1

irgx_regex *re = NULL;
int32_t rc = irgx_compile(PAT, 0, &re);              /* flags: 0 is the default grammar */
if (rc == IRGX_STALE)                                /* declined here, PCRE2 will take it */
  rc = irgx_compile(PAT, IRGX_PCRE, &re);
if (rc != IRGX_OK) {
  irgx_fault f = { .struct_size = sizeof f };
  irgx_last_fault(&f);                               /* f.name, f.at, f.at_space */
  return rc;
}

int32_t hit = irgx_is_match(re, text, len);          /* IRGX_MATCH / IRGX_OK */
irgx_free(re);
```

The four properties worth knowing before you bind it are under
[Contracts](#contracts).

## Recipes

Eight things people actually come here to do. The first three are "I want a
regex", the next four are the pieces you assemble into a search engine, and the
last one is that engine already assembled.

Every Zig snippet in this section is compiled against the module.

### Match Bytes You Already Hold

The cheapest question is `is_match`. It is the same walk the iterator runs,
stopped at the first span rather than materializing the rest, so the two can
never disagree about the same text.

```zig
const irregex = @import("irregex");
const Regex = irregex.regex.Regex;

var re = try Regex.compile(gpa, "\\bwallet[A-Za-z_]*");
defer re.deinit();

var sim = try Regex.Sim.init(gpa, &re);  // per-thread simulation scratch
defer sim.deinit();

if (re.lineMatch(&sim, line)) { … }
```

When you need *where* rather than *whether*, ask for a span. It is a separate
handle on purpose, since the boolean path never allocates the per-state
start-offset maps a span needs.

```zig
var span_sim = try Regex.SpanSim.init(gpa, &re);
defer span_sim.deinit();

if (re.matchSpan(&span_sim, line, 0)) |s| { … }  // ?Span{ .start, .end }
```

In the other four languages this is the surface you already know:

```python
for m in irgx.finditer(r"(\w+)@(\w+\.\w+)", text):
    print(m.span(), m.group(1), m.group(2))
```

```rust
let re = irgx::Regex::new(r"(\w+)@(\w+\.\w+)")?;
for caps in re.captures_iter(text) { … }
```

```go
mailbox := irgx.MustCompile(`(?P<user>\w+)@(\w+)`)
mailbox.FindAllStringSubmatch(text, -1)
```

### Compile Once, Search Many Times

Compiling in a loop is the classic way to make a fast engine slow, and here it
costs more than usual. A compile runs the parser, the analysis sweep, the
Thompson lowering, and, budget permitting, a determinization, and then throws
away the tables. Hoist the handle.

What you must not hoist across threads is the handle's *scratch*. A compiled
pattern owns the simulation state its searches run in, which is why `Sim` is a
separate value you make one of per thread.

Two threads sharing one scratch corrupt a match rather than race a counter; see
[thread affinity](#thread-affinity). The compile itself is pure, so compiling
once and building N scratches is the shape you want.

### Escalate a Pattern the Grammar Declines

Lookaround, backreferences, and atomic groups are outside the linear grammar and
always will be, because they are the constructs that force backtracking.

Rather than guess up front which of your patterns need them, let the engine rule
and retry:

```rust
match RegexBuilder::new(pattern).build() {
    Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
    other => other,
}
```

```python
try:
    pattern = irgx.compile(r"(?<=\$)\d+")
except irgx.UnsupportedPattern:
    pattern = irgx.compile(r"(?<=\$)\d+", pcre=True)  # this always works
```

Go spells the declinature `irgx.ErrNeedsPCRE` and C spells it `IRGX_STALE`. All
four are the same ruling, and none of them is an error; see
[refusals](#refusals).

What you get back is decided by asking PCRE2, not by matching your pattern
against a hardcoded list of constructs, so it tracks whatever the linked PCRE2
actually supports.

### Ask Many Patterns in One Walk

N patterns over one document should cost one walk, not N. A `PatternSet`
compiles the whole slate and returns a bitmask of exactly which patterns hit,
which is attribution rather than just a boolean.

Its answer is required to equal what N independent single-pattern runs would
have said.

```zig
const irregex = @import("irregex");
const slate = irregex.irregex;   // the set-shaped tier over the engine

const specs = [_]irregex.engine.query.Spec{
    .{ .pattern = "WalletService" },
    .{ .pattern = "billing_check", .fixed = true },
    .{ .pattern = "grant", .word = true },
};
var set = try slate.patterns.PatternSet.compile(gpa, &specs);
defer set.deinit(gpa);

var sc = try set.scratch(gpa);
defer sc.deinit(gpa);

const mask = try gpa.alloc(u64, slate.patterns.maskWords(specs.len));
defer gpa.free(mask);

if (set.docMask(doc, &sc, mask)) {
    for (specs, 0..) |spec, i| if (slate.patterns.maskHas(mask, i)) {
        // this pattern is in this document
    };
}
```

Two prefilter tiers sit behind that, dispatched on slate width: a SIMD sieve
under 18 literals, and an Aho-Corasick trawl at or above, so per-byte cost stops
growing with N.

Both are accelerators. Strip them and the mask is identical, which is what the
parity suite asserts on every document.

### Skip Files That Cannot Match

This is the first piece of an actual engine: do not open a file that provably
holds no match. Build a trigram index over your documents and ask it for
candidates.

```zig
var idx = try irregex.trigram.Index.build(gpa, docs);
defer idx.deinit();

const candidates = try idx.queryLiteral(gpa, "WalletService");
defer gpa.free(candidates);   // doc ids: a sound SUPERSET, never a verdict
```

The result is a candidate set, and that word is load-bearing. It may contain a
document that does not match, and it may never omit one that does.

Serialize it with `writeInto`, map it back with `fromMappedBytes` (zero-copy,
where the postings alias your mapping), and you have a persisted index.
Everything you are allowed to conclude from it is under [index
authority](#index-authority).

### Prune When the Pattern Has No Literal in It

Every candidate index in the field tests presence, so `[0-9a-f]{12}`, a hash or
a MAC address, proves nothing about any document and concedes the whole corpus.

The crest sieve closes that hole. Derive from the pattern the class *runs* it is
forced to contain, index each document by its longest run per class, and prune
anything that never crests that high.

```zig
const swell = Regex.forcedSwell(gpa, "[0-9a-f]{12}", .{});   // ĝ per top-level alternative
if (swell.active() and swell.prunes(irregex.crest.crest(doc))) {
    // this document provably cannot match - skip the read
}
```

`active()` is the honesty check. A swell that analyzed nothing, or one
alternative demanding nothing, prunes nothing and says so rather than pruning
anyway.

Thirty-two bytes a document buys it. The theorem is in
[`research/crest/`](research/crest).

### Compile the Intent Once

The two questions an engine asks about a document, whether it *may* match so the
index can prune and whether it *does* match so the reader can emit, have to come
from one compilation, or they can disagree. `CompiledQuery` is that one form.

```zig
const query = @import("irregex").engine.query;

var q = try query.CompiledQuery.compile(gpa, .{ .pattern = "\\bwallet\\w*", .mode = .lines });
defer q.deinit(gpa);

var one: [1][]const u8 = undefined;
const required = q.prefilter(&one);   // literals an index may require, or empty

var sc = try q.scratch(gpa);
defer sc.deinit();
const hit = q.docMatches(bytes, &sc);
```

An empty `prefilter` is the safe answer, and you will get one for a caseless
regex. Folding changes which bytes appear, so a required literal stops being a
sound proxy for "can match", and the query declines to offer one rather than
prune wrongly.

`error.Unsupported` from `compile` is the same declinature the bindings spell
`NeedsPcre`. Answer it cold, or recompile with `.pcre = true`.

### Stand Up a Warm Engine Over a Tree

All of the above, assembled, held in memory across queries, and bounded. This is
the hosted Zig API, and it is the same warm engine the resident daemon and the C
ABI ride.

```zig
const api = @import("irregex").api;

var engine = try api.Engine.open(gpa, &.{"."});
defer engine.close();

var stop = api.CancelToken{};           // trip it from any thread
const answer = try engine.search(
    .{ .pattern = "\\bwallet\\w*", .ignore_case = true },
    .{ .cancel = &stop, .timeout_ns = 2 * std.time.ns_per_s, .max_results = 500 },
);
switch (answer) {
    .declined => |d| { … },             // the warm tier stepped aside: run it cold
    .got => |cur| {
        defer cur.deinit();
        while (cur.next()) |m| { … }    // m.path, m.line_number, m.column(), m.text, m.spans
    },
}
```

Three things in that snippet are the whole design.

The budgets are fail-safe. A cancel or a lapsed deadline stops the scan at a
record boundary, so the cursor keeps what it gathered and never holds a torn
record.

The declinature arrives on the *success* channel, so a `try` cannot mistake "run
this cold" for a failure. That also means the `.declined` arm owns nothing and
the `.got` arm owns the cursor.

And `anyMatched()` is separate from `count()`, because "did anything match"
survives a budget that stopped you early.

## Choosing an Engine

Nothing here asks you to pick. The ladder picks, cheapest sound rung first, and
a rung is taken only where its precondition makes it exact, so which rung ran is
a performance fact and never a semantic one.

You read this list to know what your pattern is going to get, and to know which
shapes are worth writing. Order lives in exactly one place,
[`ladder/verdict.zig`](src/kernel/regex/linear/ladder/verdict.zig):

 1. **Zero-width end of line** – the pattern matches empty at every line end
 (`\d*$`).
 2. **Literal engine** – the language *is* a literal set, or required literals
 form a necessary cover. One needle takes a rare-byte-pair `memchr`, up to 64
 take Teddy's vector bucket scan, and wider sets take sparse Aho-Corasick. Every
 result carries an authority: an exact set decides, a cover only nominates.
 3. **Class-run kernel** – the pattern reduces to "at least *n* consecutive
 members of a byte set" (`\w+`, `[a-z]{3,}`), which skips both the serial table
 walk and the powerset compile.
 4. **Accelerator tier** – one of the [escape rungs](#the-escape-rungs) admits
 the pattern and wins the auction.
 5. **Eager DFA** – the general case, one pass over the candidate.
 6. **Lazy DFA** – the eager construction declined on states or visits.
 7. **Pike VM** – multiline, Unicode word boundaries, captures, and the
 differential oracle.

Rungs 3 and 4 return a three-valued verdict (`hit`, `miss`, `unproven`) and
`unproven` falls through. The DFA family *quits* to the Pike VM on the one thing
it cannot resolve, a Unicode word boundary straddling a non-ASCII gap. Nothing
in this ladder guesses.

The order is measured rather than assumed.
[`ladder/price.zig`](src/kernel/regex/linear/ladder/price.zig) carries minted
per-mechanism coefficients (an eager DFA step at 1.373 cycles a byte, lazy at
9.519, Pike at 29.574, a 25× spread), and the accelerator tier runs a cost
auction over them rather than a preference list.

Two things keep that honest. A vector rung arms only when the machine is native
*and* the price table was actually calibrated for it, so an uncalibrated host
gets the plain ladder rather than an estimate.

And [`bench/rungs/price/`](bench/rungs/price/README.md) includes a `regret` arm
that ignores the model entirely, builds every machine each pattern admits,
measures all of them, and reports chosen ÷ measured-best. The gate fails past
1.25×, and worst regret across the slate is currently **1.00×**.

The one choice that *is* yours is the grammar: the linear ladder above, or PCRE2
via the `pcre` flag. That is a real trade, since you are exchanging the
linear-time bound for lookaround and backreferences, which is why it is a flag
you type rather than a fallback that happens to you. Everything else is the
ladder's.

## Contracts

Seven rules hold across every layer of this: the Zig API, the C ABI, the
bindings, and the indexes. Five of them are promises the library makes you, and
two are obligations you keep back.

### Refusals

A refusal is a status, not an error. Every entry point returns a status instead
of aborting, so a bad pattern can never terminate an embedding host.

Status codes carry three dispositions: non-negative is a result, `IRGX_STALE` is
a declinature the caller should route around, and the rest are faults.

A declinature is the shape every optional tier in this repository has, and it is
deliberately *not* on the error channel. `IRGX_STALE` in C, `Error::NeedsPcre`
in Rust, `irgx.UnsupportedPattern` in Python, `irgx.ErrNeedsPCRE` in Go,
`error.Unsupported` from a compiled query, and `fault.Answer.declined` from the
hosted API all mean the same thing: this tier stepped aside, and something
slower here can answer.

The output handle is untouched and the fault slot stays silent, because a tier
that stepped aside has nothing to confess.

### Fault Detail

The fault detail is per-thread and pull-based. `irgx_last_fault` fills a
`struct_size`-guarded record with a name, an optional path, an offset, and,
since ABI 2, the *space* that offset is measured in, so a caret can never be
pointed at the wrong string.

Reading does not consume. The next work call on that thread is the deadline.

### Thread Affinity

A compiled handle is single-threaded, because it owns the scratch its searches
run in. Compile one per thread; the compile itself is pure.

In Zig the scratch is explicit (`Regex.Sim`, `CompiledQuery.Scratch`,
`PatternSet.Scratch`) and the same rule applies to each: one per thread, never
shared.

The hosted `Engine` is the exception and says so. It is shareable for queries,
and a `CancelToken` is the one handle another thread may touch while a query
runs.

### Versioning

Versions are three separate axes, and the header exposes all three:
`irgx_abi_version()` for layout compatibility (currently 2), `irgx_version()`
for the engine semver, and `irgx_pcre2_version()`, because "which regex grammar
do I have" is genuinely two numbers.

Gate on the ABI integer, never on a struct size. ABI 1's `has_at` boolean was
widened *in place* into ABI 2's `at_space`, so the sizes match and the meanings
do not.

### Index Authority

An index may accelerate, never answer. This is the one law, and it is the reason
any of this is safe: an index is an accelerator, not an authority. It may elide
a read, and it may never answer one.

`--no-index`, a missing anchor, or a corrupt artifact always degrades to
slower-but-identical answers, and a parity gate asserts that indexed and
unindexed runs produce byte-exact line multisets and exit codes.

If you build your own artifact on these parts, this is the rule to keep. Every
pruning primitive here is designed to be wrong in one direction only: a trigram
candidate set is a sound superset, a crest swell that analyzed nothing prunes
nothing, a `.candidate` literal cover nominates rather than decides, and a
caseless query declines to offer a prefilter at all.

### Freshness

A stale artifact is still correct, because freshness is one rule. Every
persisted accelerator folds through that rule rather than inventing a private
clock.

A dual-clock build anchor is stamped *before* the corpus is read, and any file
whose mtime or ctime reaches the anchor is re-verified live. A days-old artifact
therefore still answers correctly under a tree ten agents are editing.

Absence of a clock counts as change. An OS change journal accelerates the sweep
and is never a correctness dependency.

The exact model, and what falls outside it, is in
[`src/corpus/fresh/`](src/corpus/fresh/README.md).

### Ceilings

Ceilings decline, they do not degrade. Every budget in this repository is a
cliff you are told about rather than a slope you slide down.

The parser caps counted repetition at `max_repeat = 1000`. The determinizer caps
at `max_states = 4096` and `max_visits = 750_000`. The symbolic road caps at 512
predicates, the alternation cover at 64 alternatives, and the one-pass capture
engine at 2048 states and 16384 transitions.

In every case hitting the ceiling *declines to a slower exact tier*, and it
never returns a weaker answer.

PCRE2 is the exception that proves it. An unbounded backtracker gets hard
resource caps instead, because there is no slower exact tier below it.

## What's in the Toolkit

Four tiers, low to high. Nothing above may be imported by anything below, and
[`contract/irregex.ward`](contract/irregex.ward) enforces that against the real
`@import` graph rather than against anybody's memory of it.

 - **kernels** ([`src/kernel/`](src/kernel/README.md)) – algorithms and math. No
 argv, no walk, no emit, no filesystem.
 - **corpus** ([`src/corpus/`](src/corpus/README.md)) – which bytes are
 eligible, and their persisted shadows.
 - **runtimes** ([`src/exec/`](src/exec/README.md)) – where a compiled query
 meets a corpus.
 - **surface** ([`src/surface/`](src/surface/README.md)) – the hosted Zig API,
 the C ABI, and the shared CLI vocabulary.

Plus [`tools/`](tools/README.md), the generated-table builders for Unicode,
encodings, byte rarity and the row schema, along with their pinned upstream
inputs.

### The Kernels

Eight packages, each usable without the others. This is most of what you would
otherwise write yourself.

 - **[`math/`](src/kernel/math)** – the product-free floor: bit identities over
 `u64` limbs, hash mixing, a pure glob matcher, Damerau-Levenshtein with a
 did-you-mean, a path-halving disjoint-set forest, byte-balanced shard bounds,
 reader/writer leases, the hash-consed DAG, the crest sieve calculus, and a
 succinct sublayer (SA-IS, RRR, Huffman wavelet).
 - **[`scan/`](src/kernel/scan)** – the SIMD literal tier: rare-byte-pair
 `memmem`, Teddy to 64 needles at two loads a block, sparse Aho-Corasick past
 that, a class-run kernel, the byte-shuffle lane algebra, and the anchor
 decision as a value you can re-price on one document.
 - **[`regex/`](src/kernel/regex/README.md)** – the engine. Eight stages and one
 seal, [detailed below](#the-engine-stage-by-stage).
 - **[`query/`](src/kernel/query)** – a search intent compiled once: the
 prefilter every index prunes with and the match decision every transport runs,
 both from one lowering.
 - **[`rank/`](src/kernel/rank)** – weighted Reciprocal Rank Fusion over
 intrinsic byte signals: declaration confidence, codegen demotion, match-line
 shape rarity, and canonical-duplicate resolution.
 - **[`slate/`](src/kernel/slate)** – many patterns in one walk with exact
 per-pattern attribution, plus a closed filter, group, sort and limit plan over
 the attributed rows.
 - **[`anatomy/`](src/kernel/anatomy)** – source anatomy: comment spans,
 identifier tokens, and structural leans.
 - **[`codex/`](src/kernel/codex)** – FM-index composition over the succinct
 floors, sealed to the wire protocol.

Two of those are worth calling out, because they are the ones people assume they
have to build twice.

`query/` is what prevents drift. A `(pattern, fixed, ignore_case, pcre, mode)`
spec lowers once into an immutable matcher, and every face draws its two answers
from that one form: the sound prefilter that prunes index candidates, and the
per-document match and line-count decision.

No caller learns which engine backs the query, so none of them can drift on what
matches or on which literals are safe to skip.

The stronger prunings come from one call as well. `winnow` returns the
conjunctive cover plan and the crest sieve's forced swell off a single parse,
because the parse is the expensive half and both faces need both. That it is one
function rather than two is a soundness property, not a tidiness one.

`cover.zig` derives the whole boolean query a pattern forces rather than just its
best single literal, under cost ceilings it declines at rather than weakens past.
Its soundness is brute-forced against the production matcher over an
exhaustively enumerated document space instead of argued.

`scan/` is where the per-byte cost actually goes. `literal_set.zig` is one engine
over the whole size range, and every result it returns carries an `Authority`: an
`.exact` pure-literal set decides presence and position outright, while a
`.candidate` cover only nominates. That two-valued return is what lets a
prefilter be aggressive without ever being wrong.

`anchor.zig` picks which two needle offsets the block filter compares, minimizing
summed byte rarity and breaking ties toward the widest separation. It carries its
own recorded defect in the source: ranking marginals prices a conjunction as
`P(a)·P(b)` and so assumes probe independence, which text badly violates.

`calibrate.zig` makes the same decision priced on the buffer in hand instead of a
shipped table. It samples 64 KB in 256-byte stratified windows and lands at
1.03-1.04× of the best possible pair, where the static table is 1.39-2.21×.

Note that it is reached as an *improvement test* rather than an override.
Adopting the sample's favorite unconditionally was a measured CPU tax, and a
purely relative accept margin is a winner's curse.

### The Corpus

The corpus tier decides which paths and bytes are eligible for search or
indexing, and owns their persisted pre-chewed forms.

It knows nothing about matching, ranking, transports, or presentation. That is
what lets engines and every surface share it, and what keeps walk policy from
forking.

 - **[`scope/`](src/corpus/scope)** – path eligibility: the committed
 `.irregex.toml` charter, ignore precedence, and the path filter.
 - **[`read/`](src/corpus/read)** – byte legibility: encodings, inode identity,
 and whether a file is readable text.
 - **[`tree/`](src/corpus/tree)** – the walk itself, the corpus it materializes,
 and the stdout cadence.
 - **[`fresh/`](src/corpus/fresh/README.md)** – the freshness law: build anchor,
 change journal, and sweep.
 - **[`index/`](src/corpus/index/README.md)** – the persisted artifacts and the
 wire floor under them.

One walk skeleton feeds the parallel search, the index build, and the freshness
stat-walk, with a different per-file action plugged into each. The committed
charter is what makes every clone search the same corpus without per-machine
folklore.

There are seven index packages, five artifacts and two substrate, and the useful
way to read them is by what each one eliminates:

 - **[`trigrams/`](src/corpus/index/trigrams)** – files that cannot match. This
 is the T0 candidate index, plus a sliver tier for 1-2 byte needles and a
 codicil amend.
 - **[`crest/`](src/corpus/index/crest)** – files a **literal-free** pattern
 cannot match, which no trigram index can rule out.
 - **[`phantom/`](src/corpus/index/phantom)** – directory listing syscalls.
 - **[`content/`](src/corpus/index/content)** – per-file open, read and close,
 via an mmap of unchanged bodies.
 - **[`shelf/`](src/corpus/index/shelf)** – the corpus itself, for count, find
 and restore, over the kernel FM-index.
 - **[`frame/`](src/corpus/index/frame)** – substrate: framing, integrity
 signet, artifact home, and `mapArtifact`.
 - **[`postings/`](src/corpus/index/postings)** – substrate: the LEB128 and CSR
 blob codecs the trigram bodies ride.

Both of the laws these artifacts live under, that an index accelerates rather
than answers and that a stale artifact is still correct, are stated under
[Contracts](#contracts). They bind anything you build on these parts, and not
only what ships here.

### The Runtimes

There are two runtimes, and the second is not allowed to be a second opinion.

 - **[`cold/`](src/exec/cold/README.md)** – one subprocess per query. The
 pipeline is argv, writ, quarry, read, engine, emit.
 - **[`session/`](src/exec/session/README.md)** – a resident daemon over a Unix
 socket, holding corpus bytes and index in memory across queries.

Cold is seven concern packages that read as the pipeline in order: `argv/` (flag
grammar), `writ/` (what the patterns decide), `quarry/` (what is in the tree and
what must be read), `read/` (per-file ingest and binary policy), `emit/`
(framing, color, JSON, multiline), and `engine/` (which scheduler walks it:
serial control plane, fused work-stealing swarm, or the ranked definition-first
view).

The seventh is `view/`, which sits beside the pipeline rather than in it, so a
native lens can branch off without weakening the parity certificate.

The warm session holds the corpus and index resident so an eligible request skips
process startup. It decomposes into six planes: what may be asked warm and what
comes back, what is held across queries, the four faces one answer can wear,
whether the session may serve the bytes it already holds, whether the watcher
lets that barrier skip the walk, and how a request reaches the daemon.

Three invariants keep the second runtime honest:

 - **It does not reimplement matching.** Both rungs lower through
 `kernel/query/query.zig`, and the session reuses cold's own emitter and read
 plane.
 - **It re-derives its file set** from cold's certified walk on every reconcile.
 - **It fails open.** Any warm decline, timeout, wedged daemon, or reconcile
 doubt falls back to the cold subprocess.

The invariant that falls out of those three is `resident matches ≡ unindexed
matches`.

### The Surface

[`cli/`](src/surface/cli) is the shared vocabulary: flags, emit, manifest, grade,
guide, the `die` and `oom` outcome path, the answer keep, and the generated man
page and completions.

`api.zig` is the hosted analytic Zig API, and `ffi/` is the C-ABI plane over it.
Engines never import a face.

## The Engine, Stage by Stage

Eight stages under [`src/kernel/regex/`](src/kernel/regex/README.md), flowing
front to back, for reading or for forking. `unicode` feeds the class lowering,
`pcre2` is the escape hatch, and `oracle` stands outside the whole thing and
disagrees with it.

 - **syntax** ([`syntax/`](src/kernel/regex/syntax)) – pattern bytes become an
 AST over byte sets and scalar ranges, plus the NFA instruction vocabulary every
 later stage speaks.
 - **ast** ([`ast/`](src/kernel/regex/ast)) – the same tree, hash-consed into a
 canonical DAG and swept once for every synthesized fact a planner would
 otherwise re-walk for.
 - **analysis** ([`analysis/`](src/kernel/regex/analysis)) – the AST becomes
 sound accelerator facts: required literals, an alternation cover, first-byte
 sets, and the forced class-run bound.
 - **compile** ([`compile/`](src/kernel/regex/compile)) – the AST becomes a flat
 Thompson program, and separately a capture engine.
 - **linear** ([`linear/`](src/kernel/regex/linear)) – that program becomes the
 machine that runs it: determinization, the ladder, the accelerator rungs, and
 spans.
 - **unicode** ([`unicode/`](src/kernel/regex/unicode)) – pinned UCD data
 becomes scalar classes, fold orbits, and the UTF-8 byte ranges a class lowers
 to.
 - **pcre2** ([`pcre2/`](src/kernel/regex/pcre2)) – a pattern the linear grammar
 declines goes to the vendored JIT, plus a linear over-approximation so it can
 still be prefiltered.
 - **oracle** ([`oracle/`](src/kernel/regex/oracle)) – a pattern and a haystack
 become an independent second opinion.

There is exactly one grammar, and that is a property rather than a promise. Every
one of those stages is an internal, callers enter through
[`regex.zig`](src/kernel/regex/regex.zig), and
[`contract/irregex.ward`](contract/irregex.ward) seals the package so an import
cannot reach past it.

The seal is soundness, not tidiness. The crest sieve once carried a second,
smaller parser of its own; the two grammars disagreed about the zero-width `\<`
and `\>` boundaries, and it silently pruned two thirds of the matching corpus.

A fork can only diverge if it can reach the internals it would need.

### Syntax

The grammar is recursive descent in four levels (`alt → concat → repeat →
atom`), producing a tree of byte classes, scalar classes, groups, anchors, and
word assertions.

Greedy and lazy differ only in the priority order of a split, which decides which
span you get and never whether one exists.

Counted repetition is desugared at parse time and capped at `max_repeat = 1000`,
which is where a compiled program stops being a reasonable thing to hand a
determinizer.

Backreferences, lookaround, and inline scoped flags are refused outright rather
than half-supported, and an assertion escape inside a character class (`[\b]`) is
an error instead of a surprise. A refusal carries the byte offset in the pattern
where it was detected.

Two invariants in the class algebra earn their own mention, because both were
bugs first:

 - **Fold before complement** – under `-i` a negated class must be folded while
 it is still positive, or `[^k]` quietly stops excluding `K`.
 - **Complement in the mode's own universe** – `(?-u)` complements over 256
 bytes and Unicode mode complements over the whole scalar space. Conflating them
 produces a class that matches half a codepoint.

Word assertions are stored as four-bit truth tables over (left is word, right is
word). That is how six spellings, `\b`, `\B`, `\<`, `\>`, and the braced
`\b{start}` and `\b{end}` forms, become one comparison instead of six branches.

### The Analysis Graph

Ask the language once. The parser's tree answers questions by re-walking, and
every consumer that wants a pattern's required literal, its first-byte set,
whether it is nullable, whether it is anchored, its length bounds, its star
height, or whether it names a real codepoint class walks the tree again. A
planner runs several of them back to back.

So the tree is interned once into a hash-consed DAG
([`src/kernel/math/dag.zig`](src/kernel/math/dag.zig)), canonicalized by the
operator identities (`ε·x = x`, `x|x = x`, closure composition, union of adjacent
classes), and swept once in topological order for all of those facts at the same
time.

Interning is memoized on the parse node's address rather than a structural hash,
which is what keeps `((a{10}){10}){10}` from re-converting exponentially.
`a{1000}` interns to about nineteen distinct nodes.

The graph costs roughly 1.7 µs a pattern to build and breaks even at two
consumers, measured walker by walker in
[`bench/rungs/sweep/`](bench/rungs/sweep/README.md).

Note that the DAG re-associates. That is safe for questions about the *language*
and unsafe for questions about *which span you get*, so `compile/` still lowers
the parser's own bracketing and this graph is analysis-only. It is a deliberate
split, not a duplication.

### Accelerator Analysis

Everything in `analysis/` exists to let a later stage skip work, so everything in
it may only under-claim. A missed opportunity costs time, and a false claim costs
a match.

The required-literal and alternation-cover extraction is the lineage of Cox's
[regexp-to-trigram translation](https://swtch.com/~rsc/regexp/regexp4.html),
capped at `max_cover = 64` alternatives so a wide alternation degrades to "no
requirement" instead of to a combinatorial walk.

First-byte sets become a `Prefilter` with three tiers. A singleton is a `memchr`,
up to eight contiguous ranges are a vector compare, and anything wider falls back
to a scalar set probe, because at that point the compares cost more than the
probe.

`swell.zig` is the query half of the crest sieve, and it reads the same AST the
matcher does, for the reason the seal above exists.

### Compilation

Lowering is the 1968 Thompson construction, emitting a flat program of `consume`,
`split`, the zero-width assertions, and `match`. Two things happen on the way
down that matter later.

An alternation of single-byte branches folds into one `consume` over the union,
which is span-safe and removes a whole layer of splits from a common shape.

A scalar range lowers through
[`src/kernel/regex/unicode/utf8seq.zig`](src/kernel/regex/unicode/utf8seq.zig)
into a prefix-merged, hash-consed minimal UTF-8 byte trie, woven into the same
byte NFA, so a Unicode class is still something the byte determinizer can
flatten.

Captures are a separate arm, because paying for them on every boolean question is
absurd. Patterns whose group assignment is never ambiguous get a determinized
one-pass engine, capped at 2048 states, 16384 transitions, and sixteen budget
trips before it gives up; everything else gets a priority-ordered Pike VM.

The one-pass engine *declines* rather than faults when it cannot prove
unambiguity, which is the same shape every optional tier in this repository has.

### Unicode

Unicode is the default, and the engine says which fold it did. In the default
mode the parser decodes codepoints; non-ASCII literals, `[...]`, `\p{…}`,
`\w \d \s`, and `.` become scalar-range classes; and case folding expands each to
its full **simple** (`C+S`) orbit.

Simple, not full: `café` and `CAFÉ` fold together and `ß` and `SS` do not,
because full folding is one-to-many and this engine does not perform it. Saying
so is the point, since a folding claim you have to discover experimentally is
worse than a narrower one you can read.

The tables are generated by
[`tools/build_unicode_tables.py`](tools/build_unicode_tables.py) from UCD
**16.0.0**, pinned as actual data files under [`tools/ucd/`](tools/ucd). The
property, category, script, and fold answers are therefore reproducible rather
than whatever the host libc believes this year.

Unicode `\b` has to decode the codepoint straddling the boundary, so it stays on
the Pike VM and rides the prefilter instead. `(?-u)` reverts every surface to
ASCII bytes.

### Determinization

Determinization is the whole performance story, and the byte alphabet pays for
Unicode twice. `\w` lowers to a roughly thousand-state UTF-8 trie, and subset
construction re-walks that trie on every closure.

`\w+X` is a 318-state automaton that costs **8,386,778 NFA-state visits** to
discover through bytes, against **90** for its `(?-u)` ASCII twin. Under
[`dfa/powerset.zig`](src/kernel/regex/linear/dfa/powerset.zig)'s budget
(`max_states = 4096`, `max_visits = 750_000`) that tax declines essentially every
Unicode class pattern down to the on-demand tier.

The tax is not inherent. It comes from choosing the alphabet before
determinizing, so [`symbolic/`](src/kernel/regex/linear/symbolic) chooses the
other one.

Intern the pattern's own classes as scalar-range predicates, sweep them into
**minterms** (the coarsest partition no predicate splits, capped at 512),
determinize over *those*, then cross the result with a hash-consed UTF-8 decoder
trie to transcribe it back into an ordinary byte DFA.

`\w+X` has three minterms. The automaton is discovered at ASCII price and the
scan loop stays byte-shaped.

Lineage is symbolic automata (Veanes et al., 2010) and the derivative alphabet of
RE# (2024); the product-with-a-decoder step is this engine's own. Anything it
cannot say exactly, it declines to the byte road.

Both roads converge on [`automata/`](src/kernel/regex/linear/automata), which
owns the passes only a *finished* determinization admits, so neither road
transcribes them twice: match-first renumbering (a match test becomes
`state < match_hi` rather than a second table read), start acceleration, an
optional byte-indexed wide mirror, and premultiplied row offsets so the hot step
is `state = trans[state + class[byte]]`.

Eager determinization runs to fixpoint when the budget allows. Otherwise a lazy
tier determinizes per visited state into a per-thread cache sized between 256 KiB
and 4 MiB, tolerates two generation resets, and then quits *stickily*, so the
same failed construction is never paid for twice.

A quit is not a wrong answer. It is a fall through to the Pike VM.

### The Escape Rungs

These are rung 4 of the [ladder](#choosing-an-engine). The DFA's cost is a
loop-carried dependent load, it runs at load-use latency, and no amount of work
on the table touches that.

Each optional rung escapes the dependence chain differently rather than
shortening it. Each declines at compile time by simply being absent, and each
answers identically to the Pike VM.

 - **[`shuffle/`](src/kernel/regex/linear/shuffle)** – makes a byte's transition
 a transformation of the whole state set and folds those with a SIMD table
 shuffle, so the loop carries a register instead of a load. Small automata only,
 since 31 states plus a match lane is the vector width. Measured **3.36× to
 6.75×** on the armed family.
 - **[`parabix/`](src/kernel/regex/linear/parabix)** – transposes 128 bytes into
 bit planes and advances a marker stream with shifts and masks (PACT 2014,
 icGrep), so the dependence is as long as the pattern rather than the text. Flat
 languages only, since star height becomes runtime iteration. Measured **2.10×
 to 3.42×**, agreeing with the ladder on every one of ~20.9k corpus documents.
 - **[`sieve/`](src/kernel/regex/linear/sieve)** – the one that cannot say yes.
 It harvests an SP-closed quotient of the DFA (Hartmanis and Stearns, 1966),
 which over-approximates, so a survivor proves nothing and a rejection proves
 everything. Zero soundness violations over 1.60 billion byte positions.

Every one of those harnesses publishes its losses. The shuffle bench prints a
0.15× row, parabix prints 0.31× and 0.07× rows, and the sieve gate declines six
of nine slate patterns and still ships one measured 0.89× loss it chose not to
hide.

A rung that only ever prints wins is a rung whose gate has not been tested.

### Spans

A boolean is enough for a line filter and useless for `-o`, replacement, or
anything that wants the span.

[`caliper/`](src/kernel/regex/linear/caliper) determinizes that question the way
`dfa/` determinized the boolean one. A forward leftmost-first jaw finds the end,
and a backward anchored jaw over the reversed program finds the start.

The result is spans at a table lookup a byte instead of a Pike walk, declining to
the Pike span it is fuzzed against.

### PCRE2

[PCRE2](https://www.pcre.org/current/doc/html/) **10.47** is physically vendored
under `vendor/pcre2/` and built from source. The `build.zig.zon` entry exists
only to pin the upstream release by URL and hash.

It runs with the JIT and with resource caps: a ten-million match limit, a
ten-thousand depth limit, and a 10 MiB JIT stack. An unbounded backtracker inside
a library is a denial of service with extra steps.

The interesting part is the handoff. When the linear grammar declines a pattern,
the caller gets back the one thing it can act on, on the return value:

 - **`IRGX_STALE`** – the linear tier cannot express this, and PCRE2 can.
 Recompile with `IRGX_PCRE` and it succeeds. This is a declinature, not a
 failure: the output handle is untouched and the fault slot stays silent,
 because a tier that stepped aside has nothing to confess.
 - **`IRGX_INVALID`** – nothing here accepts it, with the offending byte offset
 in the pattern.

Which one you get is decided by asking PCRE2, not by matching the pattern against
a hardcoded list of constructs, so the answer tracks whatever the linked PCRE2
actually supports. `--engine auto` at the face layer is that same handshake with
the escalation automated.

`pcre2/shadow.zig` then does something worth stealing. It builds a
language-*growing* linear over-approximation of a PCRE pattern by erasing
assertions, splicing backreferences, and relaxing atomic groups, so even a
lookaround query can extract required literals and ride the prefilter. It bails
rather than guess on recursion, subroutine calls, and conditionals.

### Crest

Crest is the AST-derived necessary condition for literal-free class runs, the
blind spot a presence index cannot close. The
[technical report](https://proof.billylives.com/software/irregex/tech-report#crest)
carries the calculus, lineage, and soundness argument.

The implementation remains deliberately split across the seam it proves: the
kernel is [`src/kernel/math/crest.zig`](src/kernel/math/crest.zig), the query
half is `analysis/swell.zig`, and the production harness is `zig build crest`.

The theorem, calculus, refereed prior-art review, and falsification strategy are
in [`research/crest/`](research/crest).

## The C ABI

[`include/irgx.h`](include/irgx.h) is deliberately small. Compile a pattern, then
ask `is_match`, `find_all` or `captures` about bytes the host already holds.

There is no corpus, no walk, no index, and no session. A host that wants those
links a sibling library.

The four properties worth knowing before you bind it, which are status instead of
abort, per-thread pull-based faults, one handle per thread, and three version
axes, are stated under [Contracts](#contracts).

The header is also the substrate the rest of the ecosystem speaks. The sibling
libraries each link this one and return these status codes, this fault struct,
these pattern flags, and the same self-describing row cursor, so a host linking
two of them reads one vocabulary rather than two spellings of "declined".

Row schemas are declared once in
[`contract/analytic.toml`](contract/analytic.toml) and lowered by
[`tools/build_schema_tables.py`](tools/build_schema_tables.py) into a generated
decoder per language, guarded by a digest a binding checks at load.

## Build and Test

To build and test irregex you need Zig 0.16 and no network. PCRE2 and libsais
are physically vendored.

```bash
zig build                # libirgx + include/irgx.h
zig build check          # compile everything, run nothing
zig build test           # the full sharded suite (ReleaseSafe)
zig build test-quick     # the same minus the declared long poles
zig build coverage       # per-function coverage
```

`check-linux` and `check-windows` fold into `test`, so a push is judged against
every target the library claims.

The test binary is pinned to ReleaseSafe on purpose. The suite that tries to
break the safety checks needs them present, and the faces built downstream
compile them out.

Narrow a run with `-Dtest-filter=<substring>`, and put it back in one process for
a debugger with `-Dtest-shards=1`.

One trap is worth knowing before you trust a filtered run twice: `zig build test`
caches the run, and the environment is part of the cache key. The filter reaches
the harness as an environment variable, so a second run under an environment you
have already used is replayed rather than executed.

A replayed shard still reports its test count. The only token that distinguishes
the two is `cached`, where an executed step says `success <n>ms`.

To probe whether the tree is sensitive to an environment variable, drive the
compiled test binary directly, since it sits under no cache layer. Set
`BRIGADE_TIMES=1`, which prints a line per test and is therefore evidence the run
happened rather than a claim that it did.

## How It Is Proven

 - **An oracle that shares only the parser.** Pike-versus-DFA fuzzing is
 in-family, since both machines descend from the same lowering, so a lowering
 bug is invisible to it. [`oracle/`](src/kernel/regex/oracle) therefore holds an
 independent AST backtracker that touches nothing but `syntax/`. It walks the
 tree directly, memoizes on (node, position), and returns the *set* of end
 positions as a `u64`, which is why its lines are capped under 64 bytes. It
 decodes its own UTF-8 and implements each word-assertion spelling separately,
 on purpose, so it cannot inherit a shared mistake.
 - **Prefilter soundness against brute force**, plus external differentials
 against `rg` and `grep -oP` at their own default semantics.
 - **Pike as the in-family reference.** Every optional rung is differentialed
 against the VM at scale before it is allowed to arm: 350,200 cases for the
 composition rung, 419,250 for symbolic, and 16,320 for the one-pass capture
 engine.
 - **Structure as law.** [`contract/irregex.ward`](contract/irregex.ward)
 declares the tier order, the seals, a five-hop reach ceiling, and a cycle ban
 over the real `@import` graph.
 - **Five baseline-guarded scanners** in
 [`quality/ratchets/`](quality/ratchets/README.md): inline asm must be
 predicated on the CPU feature it needs rather than the architecture, OOM paths
 must use the canonical helper, error values must be declared in the fault
 taxonomy, no raw `std.debug.print`, and no duplicated function bodies.
 - **A test runner that admits what it ran.**
 [`brigade`](https://github.com/The-Billy-Company/brigade), pinned by url and
 hash in [`build.zig.zon`](build.zig.zon), shards `zig build test` across cores,
 gives each test a fresh leak-detecting allocator, and answers to
 `BRIGADE_FILTER`, `BRIGADE_SHARD` and `BRIGADE_TIMES`. A filter matching
 nothing is loud, naming the count it searched, rather than quietly green.

## What It Is Measured Against

A performance claim in a README is a wish. The
[technical report](https://proof.billylives.com/software/irregex/tech-report#evidence)
states the argument and its limits; the repository keeps the executable proof.

The harnesses measure fit against explicit floors: a static microarchitectural
budget, real PMU cycles where the host exposes them, measured memory bandwidth,
and the information-theoretic candidate-byte minimum. They refuse a machine or
build mode they cannot judge honestly rather than manufacturing a number.

```bash
zig build lab                                # every harness → zig-out/bin
zig build -Doptimize=ReleaseFast crest       # one production rung
zig build -Doptimize=ReleaseFast lowerbound  # the candidate-byte floor
zig build -Doptimize=ReleaseFast portbound   # the µarch budget, real cycles
```

The full inventory is in [`bench/README.md`](bench/README.md). Theory dossiers,
each separating what we built from what the world already knew from what would
prove us wrong, are in [`research/`](research/README.md).

## Provenance

Extracted from a private monorepo, cut at `ce430bbaab`. Apache-2.0.

[`NOTICE`](NOTICE) attributes the vendored and borrowed work: PCRE2, libsais, the
pinned UCD and WHATWG data, and the ripgrep integration-test corpus that serves
as a correctness oracle for the faces.

Algorithms implemented from published descriptions rather than borrowed source
are credited where they are used, in the module headers and in each
`research/*/PRIOR_ART.md`.

The changelog is towncrier: fragments in
[`changelog.d/`](changelog.d/README.md) fold into
[`CHANGELOG.md`](CHANGELOG.md) on release.
