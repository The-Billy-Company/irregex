# CREST exact run-spectrum automata oracle

This leaf is a corpus-independent referee for

\[
g_q(R,C)=\min_{w\in L(R)}\rho_q(w,C),
\]

where `rho_q` is the `q`-th-largest distinct maximal run of bytes satisfying
predicate `C`, padded with zero. It uses only the Python 3.13 standard library
and imports no irregex parser, matcher, CREST calculus, or production automaton.

## Frozen irregex projection

`contract.toml` is the self-contained source of truth for this oracle.
`contract.py` validates every frozen field and fails closed on drift. The
projection is explicitly bound to `src/kernel/math/crest.zig`:

- `Class` order: the current 15 byte predicates from `digit` through
  `assign_sep`;
- exact byte membership, including both quote bytes (`"`/`'`) and both slash
  bytes (`/`/`\`);
- supported ranks `q = {1,2,4}`, default `q = 1`;
- split budgets `B = {1,2,4,8}`, default `B = 8`;
- assertion policy `refuse`.

The focused tests compare the frozen class order and q/B declarations to the
production Zig source, but oracle startup remains self-contained. `B` bounds
the production calculus's Pareto disjunction; it does not alter the exact
single-language value `g_q`, so the CLI reports the frozen default without
pretending it is an automaton input.

## Exact algorithm

1. `syntax.py` parses a documented consuming byte-regex subset into an
   independent AST.
2. `nfa.py` compiles that AST to an independent Thompson epsilon-NFA.
3. For threshold `t >= 1`, monitor `M(C,q,t)` stores the current `C`-run
   length capped at `t` and the number of completed runs that reached `t`,
   capped before `q`.
4. Reachability in `NFA(R) × M(C,q,t)` decides whether an accepted word has
   fewer than `q` runs of length at least `t`, equivalently
   `rho_q(w,C) < t`. Epsilon edges preserve monitor state; mixed byte-set
   edges branch into member and nonmember transitions exactly.
5. A 0/1 shortest-path pass bounds the result by the shortest accepted word.
   Product nonemptiness is monotone in `t`, so binary search returns the exact
   threshold.

An empty language has no minimum and raises `EmptyLanguage`. Resource ceilings
and unsupported semantics return typed refusals, never estimates.

## Consuming byte syntax

```text
regex   := concat ("|" concat)*
concat  := repeat*
repeat  := atom (quantifier lazy-marker?)*
atom    := ASCII-literal | escape | "." | byte-class
         | "(" regex ")" | "(?:" regex ")"
         | "(?P<name>" regex ")" | "(?<name>" regex ")"
```

Quantifiers are `?`, `*`, `+`, `{m}`, `{m,n}`, and `{m,}`. A trailing `?`
changes only priority, so it is language-transparent. Classes support
negation, raw-byte ranges, `\xHH`, `\x{H..H}`, byte shorthands, controls, and
ASCII POSIX classes. Negated classes exclude LF in the fixed per-line model.

The oracle explicitly refuses rather than erases:

- every anchor, word-boundary, reset, and other zero-width assertion;
- positive or negative lookahead/lookbehind;
- numeric and named backreferences;
- inline flags, atomic/control groups, Unicode properties, nested/set-algebra
  classes, unknown escapes, and non-byte hexadecimal values;
- non-ASCII source literals whose byte encoding would otherwise be implicit.

Malformed syntax is distinct from unsupported semantics, but neither can
produce a threshold. Mode-changing syntax is refused because this oracle is
deliberately fixed to irregex's byte/per-line consuming lane.

## CLI

From the repository root:

```bash
python3 research/crest/oracle/oracle.py \
  '[0-9a-f]{8}' --predicate hex --rank 1

python3 research/crest/oracle/oracle.py \
  '(?:[0-9]{3}x){4}' --predicate digit --rank 4 --pretty

python3 research/crest/oracle/oracle.py \
  'AAA+' --ranges '0x41-0x5a' --rank 2
```

Every result or refusal is sorted-key JSON. Success includes the exact
threshold, normalized predicate, q/B projection, contract SHA-256, and product
automaton counters. Refusal includes the available context, `threshold: null`,
a stable typed error, and `refusal_reason`, and exits with status `2`.

## Checked Zig fixture

`export_zig.py` deterministically derives
`src/kernel/regex/analysis/oracle_cases.gen.zig` from `finite_asts()`/`render`,
`analyze`, and `contract.toml`. It partitions all 532 ASTs by exact `(q2,q1)`
thresholds, orders each partition by `(sha256(repr(node)), repr(node))`, and
selects 32 templates: 1 q2-positive, 2 q1=3, 10 q1=2, 9 q1=1, and 10 q1=0.
Each is independently evaluated at order statistics `1,2,3,4` for `{a}` and
projected onto all 15 contract predicates. The production compiler is invoked
once at supported rank `q = 4`; its four load-bearing lanes are compared with
the 480 exact, assertion-free oracle projections.

The embedded hashes are derived on every run: `source_sha256` hashes the raw
exporter, contract, parser, NFA, oracle, fixture-family, and TOML sources;
`family_sha256` hashes the concatenated `repr` of the ordered AST family; and
`contract_sha256` hashes the raw TOML bytes through `load_contract()`.

```bash
# --check is the default and exits nonzero on byte drift.
python3 research/crest/oracle/export_zig.py --check
python3 research/crest/oracle/export_zig.py

# Regeneration writes a sibling temporary file, fsyncs it, then atomically replaces.
python3 research/crest/oracle/export_zig.py --write
```

## Independent tests

The test suite carries hand-derived reset/epsilon/alternation/repetition
adversaries, all refusal families, contract-drift mutations, deterministic CLI
and generator checks, and a separate finite-language denotational interpreter. The
differential exhausts a depth-two regex family over `{a,b}`, compares NFA
acceptance to independently enumerated languages, then compares independently
scanned run spectra for five predicates at all four order statistics.

```bash
uv run --project bindings/python --python 3.13 --only-group dev \
  python -m pytest research/crest/oracle/tests -q
```

## Deliberate limits

- Pattern source is limited to 4,096 Python characters, group nesting to 128,
  explicit repetition bounds to 1,000, Thompson NFAs to 20,000 states, and
  each product search to 2,000,000 states.
- The fixed byte/per-line model has no external caseless, multiline, dotall,
  or Unicode mode inputs.
- Scalar, codepoint, and exact-UCD production lanes are intentionally outside
  this byte oracle. They are not reinterpreted as ASCII aliases.
