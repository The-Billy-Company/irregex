# `src/kernel/regex/` — the regex package

Everything regular-expression lives in one first-class home here, promoted out of the old `match/` wrapper. The engine is a linear-time Thompson NFA over bytes (RE2 / ripgrep philosophy), with a byte-class DFA as the primary O(1)/byte engine, a Pike VM fallback, optional accelerator rungs, and opt-in PCRE2.

The tree is organized by real pipeline stage and flows front-to-back: `syntax → analysis / ast → compile → linear`, with `unicode` feeding the class lowering, `pcre2` the opt-in escape hatch, [`matcher.zig`](matcher.zig) the meta dispatcher, and `oracle` the independent correctness backstop.

The ambition is to beat rust-regex, and the seam mirrors that ecosystem: `regex/` plays the role of regex-syntax plus regex-automata, sibling `scan/` plays memchr plus aho-corasick plus Teddy, and sibling `query/` plays the meta engine.

## One Door In

These eight stages are internals: every caller outside this folder enters through [`regex.zig`](regex.zig), which re-exports the compiled handle, the engine-neutral `Matcher` seam, captures, and the leaf data namespaces the surface shares.

The seal in [`contract/irregex.zone`](../../../contract/irregex.zone) makes that a build-time law — [`zoning verify`](https://github.com/The-Billy-Company/zoning) fails any import that reaches past it.

The reason is soundness, not tidiness. The crest sieve once carried a second, smaller parser, the two grammars disagreed on the zero-width `\<` / `\>` boundaries, and it silently pruned two thirds of the matching corpus.

A single entry point is how "there is exactly one grammar" becomes a property instead of a promise — a fork cannot reach the internals it would need.

Competition for this engine is other _engines_ (Rust `regex`, RE2, PCRE2, Hyperscan), measured in `bench/`. It is never a second parser inside this tree.

## Pipeline Stages

- **syntax** ([`syntax/`](syntax)) — byte/scalar classes, the AST, the recursive-descent parser, Unicode-aware case folding, and the compiled NFA instruction: the vocabulary every stage shares.
- **analysis** ([`analysis/`](analysis)) — sound, conservative accelerator analyses: required-literal / cover extraction for the trigram prefilter, first-byte sets, and the scan-skip `Prefilter`.
- **ast** ([`ast/`](ast)) — the same tree hash-consed into a DAG, canonicalized by the operator identities, and swept once for every synthesized fact at the same time, so a planner asks the language instead of re-walking the parser's bracketing. Worth measured in `bench/rungs/sweep/`.
- **compile** ([`compile/`](compile)) — Thompson AST→NFA lowering, and capture extraction: a one-pass engine for the patterns whose group assignment is never ambiguous, the Pike VM for the rest.
- **linear** ([`linear/`](linear)) — the engine itself: the compiled handle (`program/`), engine selection (`ladder/`), the two machines that answer (`pike/`, `dfa/`), a second route to the same DFA table (`symbolic/`), and the optional rungs that beat it where they apply (`shuffle/`, `parabix/`, `sieve/`, `caliper/`).
- **pcre2** ([`pcre2/`](pcre2)) — the opt-in vendored PCRE2 JIT backend for lookaround / backreferences the linear tier can't express; `--engine auto` escalates to it only on demand.
- **unicode** ([`unicode/`](unicode)) — the pinned-UCD data plus UTF-8 leaf: scalar-range → byte-range decomposition, codepoint decode for `\b`, and the `\w \d \s` / `\p{…}` / fold tables.
- **oracle** ([`oracle/`](oracle)) — adversarial differential tests against an _independent_ oracle (and `rg` at default semantics), catching bugs the in-family Pike-vs-DFA fuzz would share.

A ninth tier sits outside this pipeline. [`glean/`](glean) is the consumer face: a compiled `Pattern` and everything a caller asks of it — match, find, walk, capture, replace, split. It is shaped by who is asking rather than by which automaton answers, adds no engine of its own, and lowers every verb to a call the `Matcher` above it already makes. See [`glean/README.md`](glean/README.md).

## Unicode Is Default-On (rg-parity)

In Unicode mode the parser decodes codepoints, non-ASCII literals / `[...]` / `\p{…}` / `\w \d \s` / `.` become a `uclass` (scalar ranges), and case folding expands each to its full simple-fold orbit.

`compile/` lowers a `uclass` through `unicode/utf8seq.zig` into a hash-consed minimal UTF-8 byte trie woven into the same byte NFA, so the DFA still determinizes it at the O(1)/byte floor. Unicode `\b`/`-w` decode the straddling codepoint via `unicode/tables.zig` and stay on the Pike VM, prefiltered.

`(?-u)` / `--no-unicode` revert every surface to ASCII bytes.
