# Crest — a forced-class-run necessary condition for regex indexing

**Status:** theory + soundness proof + Zig implementation + production
integration. Kernel: `src/kernel/math/crest.zig` (pure, engine-free;
tests `src/kernel/math/crest_test.zig`). Persisted sidecar:
`src/corpus/index/crest/sidecar.zig`
(`crest.bin`, generation-atomic with the trigram pair). Wiring: both
read-elision oracles (`src/exec/cold/engine/serial.zig` +
`parallel.zig`).
Proof harness: `bench/rungs/crest/bench.zig` (links the real engine, walks
the real corpus, fail-closed). Run: `zig build crest` from the repository root;
unit tests ride `zig build test`. Prior art: `PRIOR_ART.md`; test inventory:
`TESTING.md`.

**One sentence.** Index each document by the _vector of its longest
consecutive runs per byte-class_ (its **crest vector**), derive from any regex
the _vector of runs it is forced to contain_ (its **forced crest**) via a
min-of-max run calculus over the pattern AST — one such vector per top-level
alternative, since a match satisfies one branch rather than all of them — and
prune a document whose crest falls below **every** alternative's forced crest:
a sound necessary condition that fires
precisely on the literal-free class-repetition patterns where this engine's
required-literal extractor currently yields no trigram candidates to
intersect. An n-gram engine could instead union every class n-gram; that is a
different, potentially exponential implementation trade-off, not impossible.

The name: the maximal class-run is the _crest_ — the peak height — of that
class's run-profile across the document. A query demands a minimum crest; a
document that never crests that high cannot contain a match.

---

## 0. Why this is a new object (the novelty claim, pinned to prior art)

The full adversarial review — every neighboring family, the load-bearing
difference to each, and the referee trail — lives in `PRIOR_ART.md`; this
section is the summary. The surveyed production document-candidate
implementations reduce the pattern to **required substrings** and test
substring _presence_. In those specific extractors, no required substring
means an unfiltered scan:

- Cox, _Regular Expression Matching with a Trigram Index_ (2012) — required
  trigrams, AND/OR query; a pattern with no extractable trigrams degenerates
  to a full scan. our own prefilter is this family
  (`src/kernel/query/query.zig`), and the Certificate records the hole
  honestly: `cand% = 100%` on `regex-classcount`.
- PostgreSQL `pg_trgm` (`trgm_regexp.c`) — color-trigram graph; same
  degeneration.
- RE2 `FilteredRE2` / `PrefilterTree` — atoms of `min_atom_len ≥ 3`; patterns
  yielding no atom are `unfiltered_` (always scanned).
- Zoekt, GitHub Blackbird, and the recent n-gram-selection literature
  (REI SIGMOD'25, the VLDB'25 selection study) — n-gram _presence_ filters;
  the reviewed implementations do not enumerate the OR-union of all class
  n-grams for literal-free repetitions.

The closest published neighbor is Bannai et al., _Text Indexing for Simple
Regular Expressions_ (CPM 2025) — a positional, near-linear-space index over
one text for exact occurrence reporting on the restricted **anchored** forms
`P₁D*P₂` and `P₁D^{[l,r]}P₂`. Indexing text by class-run structure is therefore
prior art and this work does not claim it. Two things still separate them, and
the second is the sharper one. Their indexed object is a **k-run** — a window
containing exactly `k` _distinct symbols_, alphabet discovered from the text —
not the longest stretch of a fixed class, and they store no per-document
signature nor derive forced runs from a general regex AST. And their Theorem 1
_requires_ an anchor: a literal outside `D`. They prove the anchorless case
admits no efficient index unless Set Disjointness fails — and the anchorless
case, `[0-9a-f]{12}`, is precisely Crest's motivating query. A lower bound on
indexed exact reporting does not bind a sieve that admits false positives and
rescans survivors. `PRIOR_ART.md` §2 gives the full comparison.

Scan-time counting automata are a different layer entirely: MIN-MAX counter
automata (TPDS 2012) and synchronizing counting-set automata (CAV 2023) make
the _matcher_ cheap on `C{n,m}`; they build **no per-document index** and prune
**no documents**. Run-length structures in the string-index literature
(SBC-tree, RLE-BWT long-match) index runs of _one repeated character_ to answer
_substring_ queries — not a per-document max-run-**per-class** vector used as a
regex necessary condition.

> **Search-qualified novelty proposition (as of 2026-07-20):** a per-document
> signature `ρ(d) ∈ ℕ^k` of maximal
> _consecutive-class-run_ lengths over a fixed class family, paired with a
> sound lower-bound _forced-crest_ functional `ĝ(R,·) ∈ ℕ^k` extracted from
> the regex by a segment-composition run algebra, such that `R` can match
> inside `d` **only if** `ρ(d) ≥ ĝ(R)` componentwise. The novel claim is this
> exact composite—not class-run indexing by itself—and the necessary condition
> is not a substring test.
>
> The dated adversarial search in `PRIOR_ART.md` found no instance of that
> composite. This is a reproducible search result, not proof that no earlier
> publication, patent, source repository, thesis, or private system exists.

Deliberately **non**-claimed: Crest does not subsume the trigram index (it is
complementary — literals still win where they exist); it is a _filter_, never a
matcher; and the calculus is sound, not tight (§3.6).

---

## 1. Definitions

Fix the byte alphabet `Σ = {0,…,255}`. A **class** `C ⊆ Σ` is a set of bytes.
Fix a small **predicate family** `𝒞 = {C₁,…,C_k}`. The implementation ships
15 byte predicates: the original superclass family plus seven workload-derived
token predicates. Each is measured over three alphabets (ASCII, scalar-closed,
and codepoint), followed by exact pinned-UCD `Nd`, `Letter`, and `White_Space`
lanes, for `K = 48`. The scalar-closed twin `C+u = C ∪ [0x80,0xFF]` is what
lets a Unicode codepoint class certify anything over a byte sieve; §3.7 derives
it. `K` is fixed and query-independent. The family is not claimed to contain
every pairwise meet and join, so "lattice" would be mathematically inaccurate.

For a string `w = w₁…w_L` and class `C`, a **C-run** is a maximal contiguous
substring all of whose bytes lie in `C`. The **crest of `w` at `C`**

    ρ(w, C) = max { length of a C-run in w }        (0 if w has no C-byte)

is the length of the longest such run.

**Definition 1 (crest vector).**

    ρ(d) = ( ρ(d,C₁), …, ρ(d,C_k) ) ∈ ℕ^k.

One small integer per class: `O(k)` bytes per document, computed in a single
`O(L·k)` pass (`k` a constant; in the implementation the inner dimension is a
comptime-unrolled 8-lane update against a 256-entry membership bit-table).

**Definition 2 (forced crest of a regex).** For a regex `R` with language
`L(R) ⊆ Σ*`,

    g(R, C) = min_{ w ∈ L(R) } ρ(w, C).

`g(R,C)` is the largest `r` such that **every** accepted string contains a
C-run of length `≥ r`. §3 computes a sound lower bound `ĝ(R,C) ≤ g(R,C)`;
write `ĝ(R) = (ĝ(R,C₁),…,ĝ(R,C_k))`.

---

## 2. The Sieve Theorem (soundness — no false negatives)

> **Theorem 1 (Sieve).** If regex `R` matches some substring of document `d`,
> then `ρ(d,C) ≥ g(R,C)` for every class `C`. Equivalently: if
> `ρ(d,C) < g(R,C)` for some `C`, then `R` matches nowhere in `d`.

_Proof._ Suppose `R` matches a substring of `d`: there is `w ∈ L(R)` occurring
contiguously in `d`, say `d = x·w·y`. Let `u` be a longest `C`-run inside `w`,
so `|u| = ρ(w,C)`. Since `w` is contiguous in `d`, `u` is a contiguous all-`C`
substring of `d`, and the (maximal) `C`-run of `d` containing `u` has length
`≥ |u|`. Hence

    ρ(d,C) ≥ |u| = ρ(w,C) ≥ min_{w'∈L(R)} ρ(w',C) = g(R,C).            ∎

> **Corollary 1 (sound sieve).** Since `ĝ(R,C) ≤ g(R,C)`, the decision
>
>     prune d  ⟺  ∃ C ∈ 𝒞 : ρ(d,C) < ĝ(R,C)
>
> never prunes a document `R` matches. Cost: `k` integer compares per document
> (one 8-lane vector `≥`), independent of document length.

Boundary sanity: `ĝ ≡ 0` prunes nothing (always sound); over-estimating `ĝ`
(`ĝ > g`) is the **only** path to a false negative, so §3 is engineered to
round exclusively down.

A single vector `ĝ(R)` is, however, a **weaker query language than the grammar
supplies**: `R₁|R₂` obliges a match to satisfy one branch, and folding the
branches into one componentwise min discards which. §3.9 replaces Corollary 1
with its disjunctive form, which is what the implementation ships.

### 2.1 Read elision requires three separate theorems

The calculus alone cannot justify skipping a filesystem read. The production
claim is the conjunction of three obligations with different assumptions:

> **Calculus theorem.** For every analyzed regex `R`, class `C`, and emitted
> `w ∈ L(R)`, the root profile satisfies
> `ĝ(R,C) = F(root) ≤ cap(ρ(w,C))`. Unsupported or alphabet-ambiguous syntax
> contributes zero, never epsilon. Therefore a matcher-visible occurrence in
> the indexed bytes cannot be pruned by their crest vector. §3 proves this by
> structural induction in the same saturated `u16` domain the code compares.

> **Artifact theorem.** If the `GISTCRS6` sidecar decoder accepts generation
> `g`, row `i` is the q-ranked spectrum of the exact byte string assigned to
> document ID `i` when the generation was built. The producer computes spectra
> from the same ordered corpus used for `paths.list`; `pair.gen` publishes the
> index, paths, roots, and sidecar together. The header binds document count,
> q, semantic schema, dictionary identity, and an index/path-content build ID;
> the decoder validates every column offset and sorted overflow record, then
> spends a whole-artifact BLAKE3 seal before exposing a view. Rejection disables
> CREST. Codicil overlays carry full spectra and are re-materialized as a sealed
> in-memory v6 view, with tombstones saturated to never prune.

> **Freshness theorem (conditional filesystem model).** Let the build anchor
> predate the indexed reads. Assume a local filesystem where every completed
> ordinary content or path replacement advances reported `mtime` or inode
> change-time `ctime` to the anchor tick or later; timestamps are not
> adversarially restored; and the corpus is quiescent between the freshness
> stat and the skipped read. Then an indexed path whose two timestamps strictly
> predate the anchor still denotes the indexed bytes. Equality, unavailable
> metadata, a missing/future anchor, or any walk uncertainty forces a live
> read. This is not snapshot consistency and does not cover privileged
> timestamp rollback, unreliable remote/virtual filesystems, or a concurrent
> mutation after the stat.

Only the conjunction supports read elision:

    calculus(R) ∧ artifact(g,i) ∧ freshness(path_i,g)
      ⇒ path_i may be skipped when ρ_g(i) < ĝ(R)

Failure of any one obligation degrades to a live read. The guarantee is
no false-negative file omission under these stated assumptions, not equality
of diagnostics, transient I/O errors, or behavior under concurrent mutation.

---

## 3. The forced-crest calculus (computing `ĝ` soundly from the AST)

The obstruction to computing `g(R,C)` compositionally is that a C-run can
**straddle** the boundary of two concatenated sub-patterns, so `g` is not a
homomorphism over the AST. The fix is the prefix/suffix/best segment summary
(the shape Bentley's 1984 maximum-subarray divide-and-conquer carries),
inverted: here an **adversary minimizes** the forced run — picks the accepted
string whose longest run is as short as the pattern allows — so each numeric
field is a per-class **lower bound**.

For a fixed class `C`, each AST node `E` carries the summary
(`src/kernel/math/crest.zig` `Profile`):

| field            | one-sided invariant for every `w ∈ L(E)` |
| ---------------- | ---------------------------------------- |
| `F(E)`           | `F(E) ≤ cap(ρ(w,C))`                     |
| `P(E)`           | `P(E) ≤ cap(leading_C_run(w))`           |
| `S(E)`           | `S(E) ≤ cap(trailing_C_run(w))`          |
| `minLen(E)`      | `minLen(E) ≤ cap(length(w))`             |
| `only_c_cert(E)` | `true ⇒ w ∈ C*`                          |

Here `cap(x)=min(x,65535)`. The Boolean is deliberately a **one-sided
certificate**, not an exact classifier: `false` may mean either "not all-C" or
"not proved all-C." Only `true` licenses a run to extend through a whole
child. A conservative false loses pruning but cannot create a false negative.

Three numerically identical zero profiles therefore remain semantically
distinct:

| meaning                         | `F,P,S,minLen` | `only_c_cert`    |
| ------------------------------- | -------------- | ---------------- |
| language `{ε}`                  | `0,0,0,0`      | `true`           |
| unsupported / unknown semantics | `0,0,0,0`      | `false`          |
| optional `E?`                   | `0,0,0,0`      | `only_c_cert(E)` |

The implementation exposes named `Profile.epsilon()` and `Profile.unknown()`
constructors and has no generic empty/zero profile constructor.

### 3.1 Base case — one mandatory byte from set `B ⊆ Σ`

(`B={c}` literal; `B=[…]` class; `B=Σ∖{\n}` for `.`)

- If the byte semantics are certifiable and `B ⊆ C`:
  `F=P=S=minLen=1`, `only_c_cert=true`.
- Otherwise: `F=P=S=0`, `minLen=1`, `only_c_cert=false`. This includes both
  an actual out-of-class choice and semantics the byte analysis declines.

This is the sole source of selectivity: `[0-9]` forces an in-class byte for
`digit` (and every superclass: hex, word); `.` forces nothing.

### 3.2 Concatenation `E = E₁·E₂`

    F(E)           = max(F(E₁), F(E₂), satAdd(S(E₁), P(E₂)))
    P(E)           = only_c_cert(E₁) ? satAdd(minLen(E₁), P(E₂)) : P(E₁)
    S(E)           = only_c_cert(E₂) ? satAdd(minLen(E₂), S(E₁)) : S(E₂)
    minLen(E)      = satAdd(minLen(E₁), minLen(E₂))
    only_c_cert(E) = only_c_cert(E₁) ∧ only_c_cert(E₂)

`satAdd(S(E₁),P(E₂))` is the only cross-boundary term: a forced suffix run of
every `w₁` abuts a forced prefix run of every `w₂`. Prefix/suffix extension
uses a certificate only in the proven-true direction; a false certificate
falls back to the child's own bound.

### 3.3 Alternation `E = E₁ | E₂`

    F = min(F₁,F₂),  P = min(P₁,P₂),  S = min(S₁,S₂),
    minLen = min(minLen₁,minLen₂),
    only_c_cert = only_c_cert₁ ∧ only_c_cert₂

The adversary picks the branch minimizing each field; a min of lower bounds
over a union is a lower bound. The certificate survives only if both branch
certificates prove the implication.

This is the rule for alternation appearing **inside** a larger expression,
where the profile must be a single value to compose. At the **root** the
branches are kept apart instead — §3.9 — because a componentwise min over
disjoint forced classes is `0⃗`, and `0⃗` sieves nothing.

### 3.4 Repetition `E{n,m}` (`0 ≤ n ≤ m ≤ ∞`)

The four numeric fields come from `n` mandatory copies:

    numeric(E{n,m}) = numeric(E · E · ⋯ · E)   (n copies)

The certificate must account for **every permitted copy**, not merely the
mandatory floor:

    only_c_cert(E{n,m}) = (m = 0) ∨ only_c_cert(E)

Thus `E?`, `E*`, and `E{0,m}` have zero numeric fields but retain the child's
certificate when a copy may be emitted; `E{0,0}` is epsilon and certifies
`true`; `E+` and positive-floor repetitions use their mandatory-copy numeric
profile and the same child certificate.

This distinction is correctness-critical. For the digit class,
`[0-9][a-z]?[0-9]` derives `ĝ=1`, because the optional middle can separate the
digits, while `[0-9][0-9]?[0-9]` derives `ĝ=2`, because every byte the optional
child may emit is still a digit.

The implementation computes the `n`-fold concatenation by exponentiation by
squaring in `O(k log n)`, not by an arbitrary repetition clamp. Saturating
arithmetic bounds every intermediate even for `u32`-sized counts.

### Anchors / zero-width (`^`, `$`, `\b`)

`Profile.epsilon()`: `F=P=S=minLen=0`, `only_c_cert=true`. They emit no byte,
so runs cross them freely.

### Unsupported constructs (backreferences, lookaround, flags, …)

The entire query analysis becomes `Profile.unknown()`, whose root `F` is `0⃗`.
Unsupported syntax is never represented as epsilon and never composed into a
partially trusted profile. No pruning is sound.

`ĝ(R,C) = F(root)`; one bottom-up pass, `O(|R|·k)` including logarithmic
counted powers, zero allocations.

### 3.5 Common saturated domain

Document crests and every query profile field inhabit the same `u16` domain:

    cap(x) = min(x, 65535)
    satAdd(a,b) = cap(a+b)

No profile operation wraps. The root `ĝ` is already capped before comparison
with `crest.bin`. Since `x ≥ y ⇒ cap(x) ≥ cap(y)`, common saturation preserves
the necessary-condition order. A real 70,000-byte run and a query requiring
70,000 bytes both compare as 65,535; an uncapped query threshold must never be
compared to a capped document value.

### 3.6 Incompleteness is not unsoundness (the tightness gap, measured)

The calculus is sound, not necessarily tight: one-sided false certificates,
unsupported sublanguages, and componentwise alternation may all understate a
true forced run. Under-pruning costs selectivity, never correctness. Exact
epsilon and optional certificates now close the former empty-group gap:
`[0-9](?:)[0-9]` derives 2 rather than 1.

**How loose, exactly?** The gap is measured against an _independent_ exact
oracle, not asserted. Define the true forced run `g(R,C) = min_{w∈L(R)} ρ(w,C)`
and compute it by automaton intersection: the largest `r` for which
`L(R) ∩ L(M_{C,r})` is empty, where `M_{C,r}` is the monitor DFA accepting
strings with fewer than `i` maximal C-runs of length `≥ r` (state =
current-run-length capped at `r` plus a capped completed-run count),
binary-searched over `r`. This is a textbook min-over-a-max-automaton value
(Kuperberg–Vanden Boom min/max cost automata, STACS 2015; the ranked variant is
Mohri–Riley N-best paths) — we claim none of it. The shipped
`research/crest/oracle/` implementation uses a separate parser and Thompson NFA
compiler, so the AST calculus never grades itself, and explicitly refuses
assertions/lookarounds/backreferences rather than erasing them. Its independent
finite-language suite checks exact q=1/q=2/q=4 values; generated fixtures check
the real Zig compiler stays below the exact ceiling. The 2026-07-19 98.0%
tightness number is retained only as a dated baseline and cannot be attributed
to this revision until the evidence package reruns the measurement.

### 3.7 Alphabet contract (the one real false-negative footgun)

Theorem 1 is stated over one alphabet, and its instantiation is sound **only
if** the class family and the matcher decide over the _same_ alphabet. A
matcher folding `\d` over Unicode scalars, paired with an ASCII-byte family,
admits `w ∈ L(R)` (Arabic-Indic digits) with `ρ_bytes(d, digit_ascii) = 0` —
a false negative of the _instantiation_, not of the theorem.

> **Theorem 2 (Alphabet Contract).** Let the matcher accept `L(R)` over
> alphabet `A` (bytes or Unicode scalars), and let every `Cᵢ ⊆ A` and `ρ(d)`
> be computed over the same `A`. Then Theorem 1 holds verbatim. If a class's
> matcher semantics cannot be expressed over the sieve's alphabet, that class
> must contribute `ĝ = 0` (no pruning) — sound by degradation.

Refusal satisfies Theorem 2, and it was what shipped first — but it refused the
common case. the linear engine folds `\d`/`\w`/`\s` over Unicode scalars at
the rg-parity default, so the ordinary spelling of the query the whole sieve
exists for sieved by nothing: `[0-9]{6}` pruned 92.7% of the corpus while
`\d{6}` — the same intent, the spelling people actually type — pruned 0.0% and
ran at 1.00x. The gap was not a rounding error in the calculus; it was the
calculus declining to speak.

**The repair is to give the byte alphabet a second half that a codepoint class
CAN be read into.** Every family member `C` gains a twin `C+u = C ∪
[0x80,0xFF]`, and the closure is what makes the twin certifiable:

> **Lemma 2b (UTF-8 closure).** Let `C ⊆ Σ_ascii`, let `C+u = C ∪ [0x80,0xFF]`,
> and let `U` be any set of Unicode scalars whose ASCII members all lie in `C`.
> Then every byte of the UTF-8 encoding of every `u ∈ U` lies in `C+u`, and a
> run of `n` consecutive scalars of `U` encodes to a run of at least `n`
> consecutive bytes of `C+u`.
>
> _Proof._ A scalar `u ≤ 0x7F` encodes to the single byte `u`, which lies in
> `C` by hypothesis. A scalar `u > 0x7F` encodes to two to four bytes, every
> one of which has bit 7 set — lead bytes are `0xC2..0xF4`, continuations
> `0x80..0xBF` — by UTF-8's self-synchronizing design (Pike & Thompson), hence
> every one lies in `[0x80,0xFF] ⊆ C+u`. Each scalar contributes at least one
> byte and consecutive scalars encode to adjacent bytes, so the byte run is at
> least as long as the scalar run. ∎

So a `uclass` node is priced by exactly the same `atom(set, min_len)` the byte
`class` node is: `encoded()` reduces its scalar ranges to the byte set they can
spend (ASCII part verbatim, `0x80..0xFF` taken whole if any range leaves ASCII)
and the fewest bytes any member costs (the UTF-8 length of the cheapest scalar,
monotone in the codepoint). Both halves round the safe way — the byte set is a
_superset_ of what the class can really spend, which can only shrink the
intersected membership mask and so only withhold certificates, and `min_len` is
a floor. `\d{6}` under the Unicode default now certifies `digit+u:6 hex+u:6
word+u:6`.

The bound is looser than the ASCII one, and it should be: `word+u` is nearly the
whole byte alphabet, so `\w{8}` prunes 1.4% and `\s{4}` 5.5% — sound, honest,
and nearly worthless, which is the correct price for a class that genuinely
excludes almost nothing. The narrow classes are where it pays. Measured by
ablation on the 21,854-file corpus (`.uclass ⇒ ĝ=0`, then the shipped rule,
back to back):

| query (engine default, `unicode=true`) | ĝ before               | pruned | speedup | ĝ after                      | pruned | speedup |
| -------------------------------------- | ---------------------- | ------ | ------- | ---------------------------- | ------ | ------- |
| `\d{6}`                                | —                      | 0.0%   | 1.00x   | `digit+u:6 hex+u:6 word+u:6` | 73.7%  | 2.12x   |
| `\d{4}`                                | —                      | 0.0%   | 0.97x   | `digit+u:4 hex+u:4 word+u:4` | 52.8%  | 2.13x   |
| `\s{4}`                                | —                      | 0.0%   | 1.01x   | `space+u:4`                  | 5.5%   | 1.04x   |
| `\w{8}`                                | —                      | 0.0%   | 0.97x   | `word+u:8`                   | 1.4%   | 1.07x   |
| `[0-9]{6}` (the ASCII twin)            | `digit:6 hex:6 word:6` | 92.7%  | 11.53x  | unchanged                    | 92.7%  | 10.77x  |

The ASCII lanes keep their indices and their numbers, so nothing that certified
before certifies differently now; the family simply grew a second half that only
a `uclass` reaches. Caseless matching is unaffected in kind: `-i` folds the AST
before the calculus runs, so a fold whose orbit escapes ASCII (`k`→U+212A
KELVIN SIGN, `s`→U+017F LONG S) promotes the node to `uclass` and is then priced
by the rule above rather than by a hand-maintained special case.
`bench/rungs/crest/bench.zig` exercises all four alphabet × case pairings against the
real matcher. §3.7c ships option (b) — codepoint runs, not byte runs — at no
sidecar cost, tightening every `+u` lane above without touching its soundness
argument.

### 3.7a Grammar contract (the second footgun, found by referee, now closed)

The Alphabet Contract pairs the two sides on the alphabet. A 2026-07-25 review
observed that the same argument applies one level up — to the **grammar** — and
that the implementation did not honor it: `ĝ` was derived by a private
mini-parser inside the kernel, separate from the engine's own. Any construct the
two grammars accept with _different meanings_ is a silent false negative, and
the differential harness could only witness the constructs it happened to
generate. The referee was right, and the divergence was real: `\<` and `\>` are
word-boundary assertions to the matcher but were read as escaped literal `<`/`>`
by the private parser, so `ĝ(\<foo\>)` demanded `punct ≥ 1`. On the reproduction
corpus, `\<foo\>` returned 700 files where the unsieved scan returned 2 200 —
1 500 real matches silently elided. It is the exact failure the theorem cannot
see, because the theorem is stated about `L(R)`, and a second parser means the
sieve is reasoning about a different `L(R)` than the matcher accepts.

> **Theorem 2a (Grammar Contract).** Let the matcher accept `L(R)` by compiling
> AST `A = parse(R)`. Theorem 1's instantiation is sound only if `ĝ` is computed
> from **the same `A`** — same parser, same options, same case fold. Any second
> derivation of `R` re-opens the false-negative channel for every construct on
> which the two disagree.

The fix is structural rather than diligent: the calculus was moved out of the
kernel into the engine's own analysis layer (`analysis/swell.zig`), where it
consumes the `syntax.Node` AST the matcher compiles, reached through one shared
`parse()`. There is now no second grammar to diverge from — a construct the
engine rejects yields `ĝ = 0` (sound by degradation) rather than a guess, and
one that it accepts is read from the same tree the NFA is built from. Two
consequences fall out for free: `\x41` and malformed-bound patterns, which the
private parser used to decline, now certify correctly; and PCRE2 patterns —
whose grammar genuinely differs — disable the sieve outright rather than being
approximated. `swell_test.zig` closes the loop by asserting the Sieve Theorem
itself over 1 500 generated patterns spanning every node kind × both engine
modes × caseless — a third of them bare top-level alternations of 2–9 branches,
so Theorem 4's disjunction is exercised on both sides of the `capacity` budget —
and the property is checked rather than sampled.

### 3.7b Class monotonicity, and the superadditivity that is NOT available

For the **count** functional `|w|_C`, disjoint classes add: `|w|_{C₁⊎C₂} =
|w|_{C₁} + |w|_{C₂}`, so the forced count is superadditive in `C` and a finer
partition is strictly more informative before you compute anything. **Crest's
run functional has no such law**, and assuming it would be a false-negative
factory. The counterexample is one line: for `R = [0-9]{4}x[a-f]{4}`,

    g(R, digit) = 4,  g(R, {a-f}) = 4,  but  g(R, hex) = 4  <  4 + 4

because `x ∉ hex` severs the two runs. A run is a **max over positions**, not a
sum over them; two forced runs in disjoint classes need not be adjacent, so
their union forces only the longer of them, never their sum.

What the run functional does obey is **monotonicity in the class**:

> **Lemma 2 (class monotonicity).** `C ⊆ C′ ⇒ ρ(w,C) ≤ ρ(w,C′)` for every `w`,
> hence `g(R,C) ≤ g(R,C′)`.

_Proof._ A C-run is an all-C′ contiguous stretch, so it lies inside some
maximal C′-run. ∎

That lemma is why the shipped family is deliberately **not** a partition: it
carries the superclass chain `digit ⊂ hex ⊂ word` and `upper,lower ⊂ alpha ⊂
word`, so `[0-9]{6}` forces `digit:6 hex:6 word:6` and a document is tested on
all three at once. Under a partition each pattern would fire on one coordinate
and the other seven would be dead weight.

### 3.7c Codepoint runs without decoding (the `+u` lane's real gap, closed)

§3.7's `+u` twin is a **byte**-run over `C ∪ [0x80,0xFF]`, and that byte
membership is the tell: `[0x80,0xFF]` admits every UTF-8 continuation byte as
well as every lead byte, with no way to tell them apart from membership alone.
So a run of `n` non-ASCII _codepoints_ measures as a run of `Σ len(uᵢ)` bytes —
2–4× too long — and the inflation runs the wrong way for pruning: `word+u` is
shared escape valve across every `+u` lane (`digit+u`, `hex+u`, `space+u` all
contain the same `[0x80,0xFF]`), so **any** stretch of 6+ non-ASCII bytes
anywhere in a document — two CJK ideographs, one emoji plus a variation
selector, an em dash beside an accented word — satisfies `ĝ=6` on every `+u`
lane at once and makes the whole document unprunable, whether or not it
contains anything resembling the target class. Measured on the 21,854-file
corpus, that is most of the gap between `\d{6}`'s 62.5% prune rate and
`[0-9]{6}`'s 92.7% — a Unicode-default query pays a real, avoidable tax purely
for co-occurring with unrelated non-ASCII text.

**The repair counts codepoints, not bytes, and never decodes one.** A third
alphabet joins `ascii` and `scalar` (`crest.Alphabet.codepoint`), doubling
nothing about the byte scan's cost model — it is one more set of lanes riding
the same single pass — but changing what "the byte advances the run" means:

> **Lemma 2c (codepoint-run soundness without decoding).** Let `C ⊆
> Σ_ascii`, and let `U` be any set of Unicode scalars whose ASCII members all
> lie in `C`. Define the per-byte codepoint-run rule: an ASCII byte advances
> the run iff it lies in `C`; a UTF-8 lead byte (`[0xC0,0xFF]`) always
> advances it; a continuation byte (`[0x80,0xBF]`) neither advances nor resets
> it (transparent — "hold"). Then a run of `n` consecutive scalars of `U`
> measures as a codepoint-run of **at least** `n` under this rule, and a
> `class` atom whose byte set `B` contains any continuation byte certifies
> **zero** on this lane rather than a wrong number.
>
> _Proof (the `U` case)._ Each `u ∈ U` contributes exactly one lead byte
> (single-byte ASCII scalars are their own lead byte) and zero or more
> continuation bytes. By UTF-8 self-synchronization every continuation byte
> genuinely follows the lead byte of the scalar that produced it — it cannot
> belong to a byte run the rule would otherwise reset — so "hold" is exact,
> not merely safe: it neither drops a real continuation into the count (which
> would overcount, the same failure mode `+u` already has) nor lets a
> continuation break a run mid-codepoint. The lead byte counts once per
> scalar by construction, so `n` scalars advance the counter exactly `n`
> times: a floor that is in fact an equality for `U`, tighter than `+u`'s
> `≥ n` bound whenever any scalar of `U` costs more than one byte. ∎
>
> _Proof (the refusal case)._ `crest.membership`'s codepoint-lane bits for a
> `class` atom are the ASCII bits of `B` — never `[0x80,0xBF]` — by
> construction (`Profile.atom`'s shared intersect: a `class` node passes its
> byte set as both the byte-lane AND the codepoint-lane set). A byte set that
> holds a continuation byte therefore certifies its codepoint lane against a
> set the byte in question is not a member of, but the document-side `keep`
> table treats every continuation byte as HOLD regardless of membership — so
> a document made entirely of continuation bytes (`[\x80-\xFF]{6}`, read as
> raw bytes rather than scalars) would hold a codepoint-run of length `6`
> under naive counting despite matching no ASCII byte of `B`. `atom` refuses
> that certificate outright (`min_cp` stays 0 for a `class` node) rather than
> resolve the ambiguity, so the failure mode is `ĝ=0` — sound by degradation,
> never a false floor. ∎

Mechanically, the fix rides the same three comptime tables §3's scan already
had, widened by one alphabet: `membership` (query-side ⊆-test) sets a
codepoint-lane bit for a lead byte unconditionally and for an ASCII byte only
when the byte itself is a class member, and clears it for every continuation
byte; `keep` (document-side reset mask) diverges from `membership` in exactly
the place Lemma 2c requires — a continuation byte HOLDS a codepoint lane
open (`0xFFFF`) even though it carries no membership bit, where every other
lane resets on a non-member; `step` is the increment those lanes take, `1`
for every byte except a continuation byte's codepoint lanes, which take `0`.
`crest.zig`'s recurrence, `Profile.atom`, and `Piece.join` (rejoining a
document split at an interleave boundary) all read these tables rather than
hand-rolling the rule a second time, so there is exactly one place UTF-8's
self-synchronization gets to be wrong.

Measured on the same corpus, isolating the `+cp` lane's contribution on top
of the already-shipped `+u` lane (§3.7's table shows `+u` alone against the
pre-`uclass` baseline; this one shows `+cp` stacked on `+u`):

| query (`unicode=true` default) | ĝ (`+u` only)                | pruned | speedup | ĝ (`+u`, `+cp`)                             | pruned | speedup |
| ------------------------------- | ----------------------------- | ------ | ------- | -------------------------------------------- | ------ | ------- |
| `\d{6}`                         | `digit+u:6 hex+u:6 word+u:6`   | 62.5%  | 1.94x   | `+ digit+cp:6 hex+cp:6 word+cp:6`             | 72.7%  | 3.05x   |
| `\d{4}`                         | `digit+u:4 hex+u:4 word+u:4`   | 40.9%  | 1.92x   | `+ digit+cp:4 hex+cp:4 word+cp:4`             | 48.3%  | 2.96x   |
| `\s{4}`                         | `space+u:4`                   | 4.8%   | 1.03x   | `+ space+cp:4`                                | 14.6%  | 1.23x   |
| `\w{8}` (wide, adverse)         | `word+u:8`                    | 0.0%   | 1.00x   | `+ word+cp:8`                                 | 0.0%   | 0.89x   |

`\w{8}` stays at zero by design — it is the adverse case the family was never
going to prune (the word class is nearly the whole codepoint alphabet, same
as §3.7's honest assessment of `+u` there), included so the table cannot
quietly drop it. The narrow classes (`digit`, and to a lesser extent `space`)
are where a byte-inflated run was actually hiding real corpus documents from
the sieve, and codepoint-counting recovers most of the remaining gap to the
ASCII twin's 92.7%.

`K` (the lane count `Vector`/`Mask` carry) grew from 16 to 24 for this —
scalar and codepoint lanes both exist for every family member — which
regressed the shipped block scan's raw throughput from 2.07 to roughly 1.0
GiB/s on this machine: `@Vector(24, u16)` costs the same 64 B / 4 NEON
registers as `@Vector(32, u16)` (the width the target already rounds storage
up to), and a microbenchmark of the recurrence's exact shape measured that
_odd_ width 8x slower than the _clean_ one for identical storage — the
signature of a lane count the autovectorizer cannot shuffle cleanly, not of
genuinely more work. Padding `K`'s internal working vector to the
power-of-two width the backend already pays for (`crest.zig`'s
`simd_lanes`, truncated back to `K` only at the public `Vector` boundary)
recovered the ratio: the shipped scan now runs 7.9x the naive per-byte
reference (`ways=2`, re-measured after the padding fix — `ways=4`'s register
footprint doubled with `K`, so the interleave factor tuned for 16 lanes
overflowed at 24 and had to be re-picked by measurement, not assumed) against
the pre-`+cp` baseline's 1.87x on the same corpus and machine. The absolute
GiB/s is genuinely lower — there is more state to carry per byte, which is
the honest cost of a third alphabet — but the vectorization itself is no
longer the bottleneck the odd lane count made it.

### 3.8 Why the _run_, not the _count_ (the weaker cousin, ruled out)

The tempting sibling indexes total class population `#{i : dᵢ ∈ C}` and prunes
below the forced count. Also sound — and strictly dominated: a forced C-run of
length `n` implies a forced population `≥ n`, never the reverse, so on `C{n}`
the run bound prunes a superset of what the count bound prunes. Empirically the
gap is decisive because source files carry hundreds of _scattered_ digits but
rarely a _consecutive_ run of 8 hex bytes. The production harness retains this
ablation at identical thresholds; every revision-bound evidence package
records both survivor counts rather than inheriting a number from an older
calculus revision (§5).

**Why the count cousin's machinery does not transfer.** The count functional is
a shortest path: weight each NFA edge labeled `a` by `[a ∈ C]` and the forced
count is the `(min,+)` tropical distance from start to accept, with `R*`'s
zero-weight cycles handled for free. Swapping the semiring then re-derives a
whole family of filters from one algorithm — weight-1 edges give the minimum
match length, `(max,+)` the maximum, a powerset semiring over k-grams gives
Cox's required-trigram query, Booleans give required-literal extraction. **The
run functional is not in that family.** A run is a `max` over a `min` — the
adversary minimizes the maximum stretch — so it is not additive along a path
and no edge-weight assignment makes Dijkstra compute it. The right machine is
a different one, and §3.6 already ships it as the referee: intersect the NFA
with the monitor DFA `M_{C,r}` that forbids any C-run of length `≥ r`, and
binary-search `r` — the min-max automaton value. That is also why the two
filters are **incommensurable rather than ranked** at the family level: the
count/Parikh ceiling is order-free and structurally cannot see contiguity,
while a run vector cannot see totals (§7.5). At equal thresholds on `C{n}` the
run bound dominates, which is the claim the ablation actually measures.

### 3.9 The disjunctive sieve (one ĝ per top-level alternative)

Corollary 1's `∃C` threshold has a blind spot with a crisp diagnosis: it fails
exactly when `g(R,C) = 0` for every class, and the smallest pattern that does
that is `a|b`, since `b` witnesses `g(R,{a}) = 0` and `a` witnesses
`g(R,{b}) = 0`. Alternation is most of what makes a regex interesting, and in
this engine it is not even opt-in — **multi-`-e` arrives as one alternation**,
so every multi-pattern search collapsed to `0⃗` and ran with the sieve silently
disarmed. §3.3's componentwise min is sound, and that is the whole problem: it
is _too_ sound, throwing away the branch structure the grammar handed us.

The fix is forced by the diagnosis. Keep the branches:

**Definition 3 (swell).** For `R = R₁|⋯|R_m` at the top level, the **swell** is
the list `Ĝ(R) = ⟨ĝ(R₁),…,ĝ(R_m)⟩` — one forced crest per alternative, each
computed by the §3.1–§3.4 calculus on that branch's subtree.

> **Theorem 4 (disjunctive sieve).** If `R = R₁|⋯|R_m` matches a substring of
> `d`, then `ρ(d) ≥ ĝ(R_j)` componentwise for **at least one** `j`. Hence
>
>     prune d  ⟺  ∀ j ≤ m : ∃ C ∈ 𝒞 : ρ(d,C) < ĝ(R_j, C)
>
> never prunes a document `R` matches.

_Proof._ `L(R) = ⋃_j L(R_j)`, so a matching occurrence `w` lies in some
`L(R_j)`; Theorem 1 applied to `R_j` gives `ρ(d) ≥ g(R_j) ≥ ĝ(R_j)`. The prune
rule is the negation of "some branch admits `d`". ∎

> **Corollary 4 (dominance).** The disjunction is never less selective than the
> fold: if `min_j ĝ(R_j)` prunes `d`, then every branch prunes `d`, so the
> swell prunes `d` too. The converse fails, which is the entire point.

_Proof._ `min_j ĝ(R_j) ≤ ĝ(R_i)` componentwise for each `i`, so a document
short of the fold in class `C` is short of every branch in `C`. ∎

Three properties make this cheap rather than a query planner:

- **Bounded.** The implementation keeps at most `Swell.capacity = 8`
  alternatives inline (`crest.Swell`), so the query half stays allocation-free
  and the object copies into a loader thread's frame. A ninth alternative is
  not dropped — the surplus subtree stays folded by §3.3 into one slot, so the
  sieve **degrades toward Corollary 1** and, by Corollary 4, never past it.
- **Iterative.** The branch spine is walked with an explicit worklist, not
  recursion, so a pathological `a|b|c|…` chain cannot exhaust the stack.
  Capture nodes are transparent: `(A|B)` splits exactly like `A|B`.
- **Fail-closed on inertness.** One alternative demanding `0⃗` admits every
  document, so it disarms the whole swell however strong its siblings are —
  `[0-9a-f]{12}|\w+` prunes nothing, and says so.

Cost: `k` compares per alternative, still no byte scan, and the common
single-alternative case is bit-for-bit the old path (`m = 1`).

**Note on the query-language ceiling.** A swell is an OR-of-ANDs over forced
thresholds — the same Boolean shape Cox's trigram query tree uses, reached here
from Crest's own failure mode rather than by citation. It is not the full
ceiling: alternation _nested inside_ a concatenation (`x(a|b)y`) is still
min-folded by §3.3, and distributing it to the root would be exponential. The
top level is where the payoff is concentrated, because that is where multi-`-e`
lands.

### Lemma 1 (profile invariant)

> For every supported `E`, class `C`, and `w ∈ L(E)`:
>
>     F(E)      ≤ cap(ρ(w,C))
>     P(E)      ≤ cap(prefix_C(w))
>     S(E)      ≤ cap(suffix_C(w))
>     minLen(E) ≤ cap(|w|)
>     only_c_cert(E) = true  ⇒  w ∈ C*

_Proof._ Structural induction over the AST.

_Epsilon and degraded analysis._ `Profile.epsilon()` denotes `{ε}`: its
numeric fields are zero and `ε ∈ C*`. `Profile.unknown()` also has zero numeric
fields but a false certificate: zero safely lower-bounds any possible word and
the Boolean claims nothing. A parse failure returns this whole-query profile;
unknown syntax is never composed as epsilon.

_Atom._ A certifiable mandatory byte set `B ⊆ C` yields one in-class byte, so
all numeric fields are 1 and the certificate is valid. Otherwise the class-run
bounds are zero and the certificate false; `minLen=1` remains valid.

_Concatenation._ Any `w=w₁w₂` contains internal runs of at least `F₁` and
`F₂`, plus the seam formed by the trailing C-run of `w₁` and leading C-run of
`w₂`; monotone saturation preserves their sum. If `only_c_cert(E₁)` is true,
all of `w₁` extends the leading run by at least `minLen₁`; otherwise `P₁`
still lower-bounds the leading run. The suffix argument is symmetric. Lengths
saturating-add, and conjunction of valid certificates stays valid.

_Alternation._ Each word comes from one branch. Componentwise minima
lower-bound both branches; the conjunctive certificate implies the property
for either branch.

_Repetition._ Every word in `E{n,m}` contains `k` copies for some `n≤k≤m`.
The `n` mandatory copies establish the numeric lower bounds; extra copies
cannot invalidate those internal, length, or boundary bounds. The certificate
is true when no copy can occur (`m=0`) or the child certificate proves every
copy lies in `C*`. Exponentiation by squaring equals `n`-fold concatenation
because saturated `concat` is associative.

_Saturation._ Every addition is `cap(a+b)`. Monotonicity of `cap` preserves
the inequalities, and no operation wraps. ∎

Together with Theorem 1: `ĝ(R,C) = F(root) ≤ g(R,C)`, so Corollary 1's sieve
is sound. ∎

**Remark (algebraic shape).** Fields `(F,P,S,minLen)` compose in a saturated
min/max-plus shape guarded by `only_c_cert`; alternation is componentwise min
and concatenation a guarded product. The direct induction is shorter than a
semiring treatment, but the algebra explains one-pass evaluation and
logarithmic powers.

---

## 4. Selectivity model (why it wins on narrow classes, and only there)

Model document bytes i.i.d. with `p = P(byte ∈ C) ≈ |C|/256`. The expected
longest C-run in a length-`L` document is the Erdős–Rényi run length

    E[ρ(d,C)] ≈ log_{1/p}( L·(1−p) )     — logarithmic in L.

**Narrow class ⇒ short chance runs ⇒ aggressive pruning.** For hexdigit,
`p ≈ 22/256 ≈ 0.086`: a 4 KiB file expects a longest chance hex run of
`≈ log_{11.6}(3700) ≈ 3.3`. A query forcing `ĝ(hex) = 8` (UUID, SHA
fragment) prunes essentially every file lacking a _genuine_ ≥8 hex structure.

**Wide class ⇒ long natural runs ⇒ honest no-help.** For `\w` in source code
`p` is large, natural runs dwarf any plausible `ĝ`, and the sieve keeps nearly
everything. This is the designed scope, complementary to the trigram index
(which owns the literal-rich patterns Crest ignores). The measurement therefore
reports **both** regimes plus zero-false-negative everywhere (§5).

---

## 5. Production proof (revision-bound, fail-closed)

`bench/rungs/crest/bench.zig` links the production engine and walks the production
corpus:

- **matcher** — the real `Regex.docMatch`, compiled per mode with the same
  flags handed to `ghat` (honoring Theorem 2);
- **corpus** — the live host tree via the same `corpus.load` the optimality
  certificate layers use;
- **index builder** — the production `crest_sidecar.build` (the same parallel
  pass an index build persists as `crest.bin`);
- **soundness, fail-closed** — for _every_ file × _every_ query:
  `matched ⇒ ¬pruned`, plus a 400-pattern randomized adversarial sweep in
  all four engine modes (ASCII/Unicode × case-sensitive/caseless), 24,000
  (pattern,file) pairs per mode and 96,000 total;
  any violation exits non-zero;
- **fixed production regression** — the real matcher accepts `1a2` for
  `[0-9][a-z]?[0-9]` while Crest retains it; the positive precision control
  `[0-9][0-9]?[0-9]` derives digit threshold 2; and the disjunctive control
  `[0-9]{3}|~{3}` derives two alternatives and prunes `1a2` on both;
- **ablations** — the §3.8 count cousin, and the retired single-vector fold of
  §3.9 (componentwise min over the alternatives), both at identical thresholds.
  Corollary 4's dominance is a **fail-closed gate**, not a hope: a row where
  the disjunction left more survivors than the fold exits non-zero;
- **speed** — multiple ordered raw samples of full scan versus
  sieve+survivors, same matcher both sides; `crest.csv` reports the upper
  median and the run JSON preserves every sample.

No numeric result in this source document is assigned to the repaired
calculus. Measurements are minted only after the source revision is committed:

    python3 bench/rungs/crest/evidence/crest_evidence.py package

The command refuses a dirty tree, runs the benchmark and test slate frozen in
`contract/crest_evidence.toml`, archives the exact Git revision, and records:

- `crest.csv` and `crest-run.json` (all raw nanosecond samples, seeds, fixed and
  randomized matcher differentials);
- the path/size/content-SHA corpus manifest;
- machine, OS, CPU, memory, storage, filesystem, power, and cache conditions;
- benchmark and test transcripts plus their hashes;
- a monograph rendered from `git show COMMIT:path`, with fresh measured rows.

The package verifier rejects stale revisions, missing or extra artifacts,
tampered hashes, changed command/seeds/sample counts, corpus drift, or any
`matched && pruned` result. Older pre-repair measurements are historical
evidence only and must not be presented as measurements of this revision.

---

## 6. Complexity summary

| operation          | cost                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------- |
| index corpus       | `O(total input bytes · K · q)` with fixed `K=48`, `q≤4`; documents shard across cores                |
| sieve one document | `O(touched columns · m)`, `m ≤ 8` Pareto alternatives — early-exit on the first branch that admits    |
| index space        | `N·K·q` dense bytes plus sparse u16 overflow, a column directory, and the fixed v6 header              |
| query-time `ĝ`     | `O(\|R\|·K·B·log n)` worst case for bounded Pareto compilation (`B=8`, counted powers by squaring)     |
| sieve whole corpus | sparse gather over candidates or dense SIMD over each demanded physical column                         |
| incremental update | recompute changed documents' spectra; generation-atomic codicil overlay preserves ranked rows          |

`K` and `q` are constants with respect to the corpus, not free machine work.
The q=1 scan uses padded SIMD working vectors; q=4 maintains four rank slots
per predicate, while persistence transposes them into columns so a query reads
only the coordinates it actually demands.

What it did cost was **latency**. The per-byte update is a saturating add
feeding an AND, a loop-carried chain about three cycles deep, and one scan
cannot fill it: measured, a single scan ran at 4.4 cycles/byte with the machine
mostly idle, and preshaping the reset mask into a table to cut the op count
moved it by nothing — the signature of a latency bound rather than a throughput
one. The document is therefore cut into four pieces scanned interleaved, four
chains in flight, and the pieces rejoin **exactly** by the run algebra of §3.2:
each piece reports the run it opens with, its best interior run, the run it
ends with, and whether it never broke, and `Piece.join` is `concat` — the same
`max(F₁, F₂, S₁+P₂)` the calculus folds over the pattern AST. The document side
and the query side share one law, which is what makes the split exact rather
than approximate. The following is the historical pre-v6/q4 ablation, retained
as lineage only:

|                                   | one piece  | four pieces interleaved |
| --------------------------------- | ---------- | ----------------------- |
| single-thread scan                | 0.73 GiB/s | **1.87 GiB/s** (2.56x)  |
| vs. the scalar per-byte reference | 0.63x      | **1.62x**               |
| sharded whole-corpus index build  | 45.4 ms    | **19.1 ms** (2.38x)     |

Those figures do not license the current 48-predicate, q4 columnar build.
Current corpus-dependent q1/q4, dictionary, planner, and end-to-end timings are
explicitly pending the held-out evidence run.

The sieve is embarrassingly composable with the trigram index: intersect
survivor sets (both are necessary conditions, so the intersection is still
sound), letting each filter own the pattern family the other concedes. That
is the shipped wiring. A pruned document's **read is elided entirely** (the
serial `IndexSkip` / parallel `Elide` oracles), not merely its match call,
provided all three obligations in §2.1 hold.

---

## 7. The forced-run _spectrum_ (Ridge — from one run to a multiset)

The production query policy defaults to the **single** longest run per class,
so q=1 is structurally blind to patterns that force **several disjoint** runs.
The v6 sidecar already stores q=4; promotion is a measured policy decision:

    [0-9]{6}[^0-9]+[0-9]{6}      two distinct 6-digit runs forced
    [0-9]{4}-[0-9]{2}-[0-9]{2}   the digit multiset {4,2,2}

A document with one 6-digit run (or a lone 4-digit run) can never match either,
yet `ĝ(digit)=6` (resp. `4`) admits it. **Ridge** lifts the scalar to an order
statistic: index the top-`q` longest **distinct maximal** C-runs per document
(`q≈2–4`; `q=1` _is_ Crest), and derive a forced-run _multiset_ from the AST.

### 7.1 Signature and forced multiset

**Definition 7 (run spectrum).** `σ_q(d,C) ∈ ℕ^q` — the `q` longest maximal
C-runs of `d`, sorted descending (padded with 0). `σ_1 = ρ`. Cost `O(k·q)`
ints/doc; one pass keeps a size-`q` per-class top list.

**Definition 8 (forced-run functional).** `g_i(R,C) = min_{w∈L(R)} σ(w,C)[i]`
— the min over accepted strings of the _i_-th largest maximal C-run. §7.3
computes a sound lower bound `ĝ_i(R,C) ≤ g_i(R,C)`, sorted-descending in `i`.

### 7.2 The Spectrum Sieve Theorem (soundness)

> **Theorem 3 (Spectrum Sieve).** If `R` matches a substring of `d` then
> `σ_q(d,C)[i] ≥ g_i(R,C)` for every class `C` and rank `i ≤ q`.

_Proof._ Let `w ∈ L(R)` occur contiguously in `d`. Each maximal C-run of `w`
sits inside a maximal C-run of `d` that is **≥** as long. Two _distinct_
maximal C-runs of `w` are separated by a non-C byte lying inside `w`, hence
inside `d`, so they fall in **distinct** maximal C-runs of `d`. That is a
length-nondecreasing injection from `w`'s maximal C-runs into `d`'s, so the
sorted-descending run vector of `d` dominates that of `w` componentwise:
`σ(d,C)[i] ≥ σ(w,C)[i] ≥ g_i(R,C)`. Truncating to the top `q` preserves the
first `q` inequalities. ∎ (`q=1` is Theorem 1 verbatim.)

> **Corollary 3.** `prune d ⟺ ∃C,i≤q : σ_q(d,C)[i] < ĝ_i(R,C)` never prunes a
> match. Cost: `k·q` integer compares/doc.

### 7.3 The gap-aware calculus (`only_not_c_cert`, distinctness permission)

Crest's `(F,P,S,minLen,only_c_cert)` profile decides _lengths_; the spectrum
needs to know **when two forced runs are provably distinct**. That is a second
one-sided certificate:

    only_not_c_cert(E,C) = true  ⇒  every w∈L(E) uses only NON-C bytes.

A profile becomes a per-class **ordered list of segments** separated by forced
`only_not_c_cert` boundaries. Concatenation glues the last segment of the left to the
first of the right (Crest's straddle merge — they may abut with no forced
separator between); an atom certified only-not-C commits a boundary, so
runs on either side are counted as distinct entries in the multiset. The
finalized `ĝ_i(R,C)` is the sorted-descending list of per-segment forced runs.

The load-bearing subtlety is **when NOT to split**, and it is where soundness
lives: `[0-9a-f]{8}[^0-9a-f]+[0-9a-f]{8}` does **not** force two _hex_ runs,
because `[^0-9a-f]` still admits `A`–`F` (uppercase hex) — the two runs may
merge into one length-17 hex run through an uppercase letter. `[^0-9a-f]` can
certify only-not-digit but **not** only-not-hex, so the calculus forces two
digit runs and only one hex run. A naive multiset that split on _any_ separator
would manufacture a false negative here; one-sided certification forbids it.
Alternation conservatively collapses each branch to its single Crest run
(componentwise min) — a sound lower bound; intra-branch multi-run structure is
dropped, which only under-forces.

**Invariant (no regression):** `ĝ_1(R,C) = F(root)` exactly — the shipped
Crest forced run. Crest's straddle never crosses a certified separator, so the
global longest forced run equals the max over segments, which is the first
multiset entry. Ridge is a **strict superset**: it only adds lower-ranked
forced runs, never changes the top one, so no query Crest prunes today is
weakened.

### 7.4 Historical spike (14,498 files / 250 MiB) — rerun pending

These results predate the current predicate dictionary, exact UCD lanes,
bounded Pareto compiler, and columnar executor. Base = `q=1`; Ridge = `q=4`.
The historical index was 906 KiB = **0.35%** of corpus (4× Crest's 0.09%).
Soundness was re-asserted per row
(base and ridge survivor hit-counts both ≡ full scan); `ĝ_i ≤ g_i` held on all
5,224 oracle checks (98.2% tight, mean gap 0.037).

| query                              | forced multiset | base (q=1) | ridge (q=4) | Δ      |
| ---------------------------------- | --------------- | ---------- | ----------- | ------ |
| `[0-9a-f]{8}` (single run)         | hex:{8}         | 95.1%      | 95.1%       | +0.0pp |
| `[0-9]{6}` (single run)            | digit:{6}       | 93.7%      | 93.7%       | +0.0pp |
| `[0-9]{6}[^0-9]+[0-9]{6}`          | digit:{6,6}     | 93.7%      | **95.8%**   | +2.1pp |
| `[0-9]{4}-[0-9]{2}-[0-9]{2}` date  | digit:{4,2,2}   | 58.1%      | **64.0%**   | +5.9pp |
| `[0-9a-f]{8}-[0-9a-f]{4}-…` uuid   | hex:{8,4,4}     | 95.1%      | 95.2%       | +0.1pp |
| `[0-9a-f]{8}[^0-9a-f]+[0-9a-f]{8}` | hex:{8} (sound) | 95.1%      | 95.1%       | +0.0pp |
| `\w{3,8}` (wide)                   | word:{3}        | 4.1%       | 4.1%        | +0.0pp |

The gains land exactly where a _positional_ index (CPM 2025, §0/PRIOR_ART §2)
would target — multi-field structured tokens — but reached with a fixed `O(k·q)`
aggregate order-statistic, no positions. The `two-hex-8` row earning +0.0 is
soundness on display, not a miss (the runs may merge; §7.3).

They are not evidence for this revision. The current held-out q1/q4 comparison
and promotion decision remain pending; the evidence package must bind corpus
and query-trace fingerprints before publishing replacement figures.

### 7.5 Scope of the novelty claim (referee re-scope, 2026-07-20)

The independent adversarial referee (`PRIOR_ART.md` §8) returned **no
collision** but two honest downgrades, adopted here:

- Ridge is a **strict generalization of Crest**, not an independent object. The
  new surface is exactly _single max → top-q order statistics_ (index) and
  _single forced run → gap-aware forced-run multiset_ (query). The sieve,
  soundness scaffold, and alphabet contract are inherited.
- The **sieve _shape_** (per-doc vector vs query-derived required vector,
  componentwise dominance, fail-to-candidate, no false negative) is **not**
  new — it is the character/class-population histogram prefilter, whose
  theoretical ceiling is the Parikh/semilinear count necessary condition
  (both order-free, so neither can encode a _run_). The defensible novelty is
  therefore precisely the _quantity_ — sorted top-q distinct maximal **run**
  lengths — and the **forced-run-multiset calculus**, not "multiset dominance"
  in the abstract.

## 8. Lineage

Crest graduated from a Python spike carrying the working name "Rune", retired
at graduation. That spike was a reference sieve plus a randomized property
suite: **240,000** `(regex, text)` pairs against Python `re`, 51,463 of them
carrying a nonzero forced run and therefore prunable, **zero** false negatives.
It also carried the count-cousin ablation that decided the design (on
`[0-9a-f]{8}` the run statistic pruned 92.9% of files where the total-population
cousin at the same threshold pruned 4.2%, a ~22× separation), and a dated
adversarial novelty search. Neither the reference nor the suite ships here; the
calculus they were arguing for is `src/kernel/math/crest.zig`, and the
production-matcher soundness proof that replaced them is `bench/rungs/crest/`.

The forced-run **spectrum** (Ridge, §7) and the **exact automaton oracle**
(§3.6) came from a second Python spike, also unshipped: the gap-aware segment
calculus, the NFA×monitor oracle, a 160,000-pair sieve property suite that found
zero false negatives across 20,494 prunable regexes, and the base-vs-ridge
corpus bench §7.4 tabulates. Referee verdict PARTIAL / no-collision, 2026-07-20.
