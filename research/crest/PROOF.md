# Crest — a forced-class-run necessary condition for regex indexing

**Status:** theory + soundness proof + Zig implementation + production
integration. Kernel: `src/kernel/primitives/crest.zig` (pure, engine-free;
tests `src/kernel/primitives/crest_test.zig`). Persisted sidecar:
`src/corpus/index/crest/sidecar.zig`
(`crest.bin`, generation-atomic with the trigram pair). Wiring: both
read-elision oracles (`src/surface/exec/cold/engine/serial.zig` +
`parallel.zig`).
Proof harness: `bench/crest/bench.zig` (links the real gist engine, walks the
real corpus, fail-closed). Run: `zig build crest` from `pkg/kernels/irregex/`;
unit tests ride `zig build test`. Prior art: `PRIOR_ART.md`; test inventory:
`TESTING.md`.

**One sentence.** Index each document by the _vector of its longest
consecutive runs per byte-class_ (its **crest vector**), derive from any regex
the _vector of runs it is forced to contain_ (its **forced crest**) via a
min-of-max run calculus over the pattern AST, and prune a document when its
crest falls below the forced crest — a sound necessary condition that fires
precisely on the literal-free class-repetition patterns where Gist's
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
  to a full scan. gist's own prefilter is this family
  (`src/kernel/match/query.zig`), and gist's Certificate records the hole
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
Regular Expressions_ (CPM 2025). It genuinely indexes character-class runs
and interval lengths, so class-run indexing itself is prior art. Its result is
different: a positional, near-linear-space index over one text for exact
occurrence reporting on restricted **anchored** forms `P₁D*P₂` and
`P₁D^{[l,r]}P₂`. It neither stores a fixed `O(k)` max-run vector per document
nor derives forced runs compositionally from a general regex AST; its
unanchored lower bound does not apply to a coarse sieve that admits false
positives and scans survivors. `PRIOR_ART.md` §2 gives the full comparison.

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
Fix a small **class family** `𝒞 = {C₁,…,C_k}`; the implementation ships
`k = 8`: digit, hexdigit, upper, lower, alpha, word, space, punct
(`src/kernel/primitives/crest.zig` `Class`). `k` is a small constant, chosen once,
query-independent. This family is not claimed to contain every pairwise meet
and join, so "lattice" would be mathematically inaccurate.

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

### 2.1 Read elision requires three separate theorems

The calculus alone cannot justify skipping a filesystem read. The production
claim is the conjunction of three obligations with different assumptions:

> **Calculus theorem.** For every analyzed regex `R`, class `C`, and emitted
> `w ∈ L(R)`, the root profile satisfies
> `ĝ(R,C) = F(root) ≤ cap(ρ(w,C))`. Unsupported or alphabet-ambiguous syntax
> contributes zero, never epsilon. Therefore a matcher-visible occurrence in
> the indexed bytes cannot be pruned by their crest vector. §3 proves this by
> structural induction in the same saturated `u16` domain the code compares.

> **Artifact theorem.** If the `GISTCRS2` sidecar decoder accepts generation
> `g`, record `i` is the crest of the exact byte string assigned to document ID
> `i` when generation `g` was built. The producer computes vectors from the
> same ordered `corpus.docs` used for `paths.list`; `pair.gen` publishes the
> index, paths, roots, and sidecar together; exact document count and body
> length reject missing/extra records; and the semantic-schema hash
> binds class order, all 256 membership masks, saturation cap, element
> interpretation, and format version. This theorem assumes published generation
> files are not maliciously rewritten in place: the format has no per-record
> identity tag and cannot detect an attacker who reorders equal-width records.
> Rejection disables Crest.

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
(`src/kernel/primitives/crest.zig` `Profile`):

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
strings with _no_ maximal C-run of length `≥ r` (state = current-run-length
capped at `r`), binary-searched over `r`. This is a textbook min-over-a-
max-automaton value (Kuperberg–Vanden Boom min/max cost automata, STACS 2015;
the ranked variant is Mohri–Riley N-best paths) — we claim none of it, we use
it only as a soundness+tightness referee built from a _separate_ Thompson NFA
compiler, so the AST calculus never grades itself. The 2026-07-19 harness run,
before the epsilon/optional-certificate repair, was sound on all 6,549 random
(regex, class) checks and exactly tight on 98.0%, with mean gap 0.043. That
number is retained only as a dated baseline; it must be remeasured before being
claimed for the repaired calculus. The exact oracle and property harness live
in the lineage spike
(`spikes/ridge-spectrum/ridge.py`, `g_exact`); the corpus-scale
matched⇒¬pruned proof against the real matcher stays in `bench/crest/`.

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

Deployment rule: **byte classes ⇔ byte matcher; Unicode classes ⇔
codepoint-run crest; otherwise refuse (ĝ=0).** gist's linear engine folds
`\d`/`\w` at the rg-parity Unicode default, so `ghat` takes the engine's mode
as an argument (`crest.Opts{ .unicode, .caseless }`) and the production
`crestSieve` passes exactly the flags the matcher compiled with. The shipped
wiring implements options (a)+(c): under the Unicode default only constructs
whose byte and codepoint semantics provably coincide certify. Caseless matching
widens explicit ASCII atoms to their case closure; case-closed classes retain
their certificate, while upper/lower self-decline. In Unicode mode any closure
containing k/K/s/S also declines because those folds reach non-ASCII Kelvin/long-s
codepoints. `\d`/`\w`/`\s` and any class reaching ≥ 0x80 contribute `ĝ=0`.
`bench/crest/bench.zig` exercises all four alphabet × case pairings against the
real matcher; option (b) — indexing codepoint-runs — remains open future work.

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

`bench/crest/bench.zig` links the production engine and walks the production
corpus:

- **matcher** — gist's real `Regex.docMatch`, compiled per mode with the same
  flags handed to `ghat` (honoring Theorem 2);
- **corpus** — the live Billy tree via the same `corpus.load` the optimality
  certificate layers use;
- **index builder** — the production `crest_sidecar.build` (the same parallel
  pass `gist index` persists as `crest.bin`);
- **soundness, fail-closed** — for _every_ file × _every_ query:
  `matched ⇒ ¬pruned`, plus a 400-pattern randomized adversarial sweep in
  all four engine modes (ASCII/Unicode × case-sensitive/caseless), 24,000
  (pattern,file) pairs per mode and 96,000 total;
  any violation exits non-zero;
- **fixed production regression** — the real matcher accepts `1a2` for
  `[0-9][a-z]?[0-9]` while Crest retains it; the positive precision control
  `[0-9][0-9]?[0-9]` derives digit threshold 2;
- **ablation** — the §3.8 count cousin at identical thresholds;
- **speed** — multiple ordered raw samples of full scan versus
  sieve+survivors, same matcher both sides; `crest.csv` reports the upper
  median and the run JSON preserves every sample.

No numeric result in this source document is assigned to the repaired
calculus. Measurements are minted only after the source revision is committed:

    python3 pkg/kernels/irregex/bench/crest/evidence/crest_evidence.py package

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

| operation          | cost                                                                               |
| ------------------ | ---------------------------------------------------------------------------------- |
| index corpus       | `O(total input bytes · k)`; one streaming pass, with `k=8` comptime-unrolled       |
| index space        | `N·k·sizeof(u16)` — 16 bytes per indexed document, plus the fixed sidecar header   |
| query-time `ĝ`     | `O(                                                                                | R   | ·k)`plus`O(k log n)` for counted repetition, once per query, allocation-free |
| sieve whole corpus | `O(N·k)` and `N·k·sizeof(u16)` mapped bytes potentially touched, not merely `O(k)` |
| incremental update | recompute one document's crest on change; publication remains generation-atomic    |

The sieve is embarrassingly composable with the trigram index: intersect
survivor sets (both are necessary conditions, so the intersection is still
sound), letting each filter own the pattern family the other concedes. That
is the shipped wiring. A pruned document's **read is elided entirely** (the
serial `IndexSkip` / parallel `Elide` oracles), not merely its match call,
provided all three obligations in §2.1 hold.

---

## 7. The forced-run _spectrum_ (Ridge — from one run to a multiset)

Crest indexes the **single** longest run per class and forces a single run, so
it is structurally blind to patterns that force **several disjoint** runs:

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

### 7.4 Measured (spike, 14,498 files / 250 MiB) — and the honest boundary

Base = `q=1` (byte-identical to shipped Crest); Ridge = `q=4`. Index 906 KiB =
**0.35%** of corpus (4× Crest's 0.09%). Soundness re-asserted per row
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

Crest graduated from `spikes/classrun-formula/` (Python `rune.py`, 240k
property pairs, count-cousin ablation, dated adversarial novelty search);
working name "Rune" retired at graduation. The forced-run **spectrum** (Ridge,
§7) and the **exact automaton oracle** (§3.6) come from
`spikes/ridge-spectrum/` (`ridge.py` — segment calculus + NFA×monitor
oracle + 160k-pair sieve property suite + base-vs-ridge corpus bench; referee
verdict PARTIAL/no-collision 2026-07-20).
