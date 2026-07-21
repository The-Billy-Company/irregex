# Crest — a forced-class-run necessary condition for regex indexing

**Status:** theory + soundness proof + Zig implementation + production
integration. Kernel: `src/math/crest.zig` (pure, engine-free; tests
`src/math/crest_test.zig`). Persisted sidecar: `src/index/crest/sidecar.zig`
(`crest.bin`, generation-atomic with the trigram pair). Wiring: both
read-elision oracles (`src/runtime/cold/engine/serial.zig` + `parallel.zig`).
Proof harness: `bench/crest/bench.zig` (links the real gist engine, walks the
real corpus, fail-closed). Run: `zig build crest` from `pkg/kernels/irregex/`;
unit tests ride `zig build test`. Prior art: `PRIOR_ART.md`; test inventory:
`TESTING.md`.

**One sentence.** Index each document by the _vector of its longest
consecutive runs per byte-class_ (its **crest vector**), derive from any regex
the _vector of runs it is forced to contain_ (its **forced crest**) via a
min-of-max run calculus over the pattern AST, and prune a document when its
crest falls below the forced crest — a sound necessary condition that fires
precisely on the literal-free class-repetition patterns where every
trigram/n-gram index in the literature concedes a full scan.

The name: the maximal class-run is the _crest_ — the peak height — of that
class's run-profile across the document. A query demands a minimum crest; a
document that never crests that high cannot contain a match.

---

## 0. Why this is a new object (the novelty claim, pinned to prior art)

The full adversarial review — every neighboring family, the load-bearing
difference to each, and the referee trail — lives in `PRIOR_ART.md`; this
section is the summary. The dominant production document-candidate indexes
surveyed reduce the pattern to **required substrings** and test substring
_presence_:

- Cox, _Regular Expression Matching with a Trigram Index_ (2012) — required
  trigrams, AND/OR query; a pattern with no extractable trigrams degenerates
  to a full scan. gist's own prefilter is this family
  (`src/search/match/query.zig`), and gist's Certificate records the hole
  honestly: `cand% = 100%` on `regex-classcount`.
- PostgreSQL `pg_trgm` (`trgm_regexp.c`) — color-trigram graph; same
  degeneration.
- RE2 `FilteredRE2` / `PrefilterTree` — atoms of `min_atom_len ≥ 3`; patterns
  yielding no atom are `unfiltered_` (always scanned).
- Zoekt, GitHub Blackbird, and the recent n-gram-selection literature
  (REI SIGMOD'25, the VLDB'25 selection study) — all n-gram _presence_
  filters; all concede literal-free class patterns.

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

> **The object that is new:** a per-document signature `ρ(d) ∈ ℕ^k` of maximal
> _consecutive-class-run_ lengths over a fixed class lattice, paired with a
> sound lower-bound _forced-crest_ functional `ĝ(R,·) ∈ ℕ^k` extracted from
> the regex by a segment-composition run algebra, such that `R` can match
> inside `d` **only if** `ρ(d) ≥ ĝ(R)` componentwise. The novel claim is this
> exact composite—not class-run indexing by itself—and the necessary condition
> is not a substring test.
>
> Independently refereed for originality (adversarial prior-art review,
> 2026-07-19, verdict **NOVEL** — see the spike dossier trail): the _composite_
> — per-document crest vector + AST-derived forced-run lower bound + sieve —
> has no published equal, while every ingredient is deliberately standard.

Deliberately **non**-claimed: Crest does not subsume the trigram index (it is
complementary — literals still win where they exist); it is a _filter_, never a
matcher; and the calculus is sound, not tight (§3.5).

---

## 1. Definitions

Fix the byte alphabet `Σ = {0,…,255}`. A **class** `C ⊆ Σ` is a set of bytes.
Fix a small **class lattice** `𝒞 = {C₁,…,C_k}`; the implementation ships
`k = 8`: digit, hexdigit, upper, lower, alpha, word, space, punct
(`src/math/crest.zig` `Class`). `k` is a small constant, chosen once,
query-independent.

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

---

## 3. The forced-crest calculus (computing `ĝ` soundly from the AST)

The obstruction to computing `g(R,C)` compositionally is that a C-run can
**straddle** the boundary of two concatenated sub-patterns, so `g` is not a
homomorphism over the AST. The fix is the prefix/suffix/best segment summary
(the shape Bentley's 1984 maximum-subarray divide-and-conquer carries),
inverted: here an **adversary minimizes** the forced run — picks the accepted
string whose longest run is as short as the pattern allows — so every field is
a per-class **lower bound**.

For a fixed class `C`, each AST node `E` carries the summary
(`src/math/crest.zig` `Profile`):

| field       | meaning (sound lower bound over `L(E)`, except `all_in` which is exact) |
| ----------- | ----------------------------------------------------------------------- |
| `F(E)`      | forced longest C-run: `F(E) ≤ min_{w∈L(E)} ρ(w,C)`                      |
| `P(E)`      | forced leading C-run (prefix)                                           |
| `S(E)`      | forced trailing C-run (suffix)                                          |
| `minLen(E)` | `≤ min_{w∈L(E)}                                                         | w   | `   |
| `all_in(E)` | **true only if** every `w∈L(E)` consists solely of C-bytes              |

`all_in` is the load-bearing exact predicate — the permission slip that lets a
run extend across a boundary. Every other field is a lower bound, so rounding
down anywhere preserves soundness.

### 3.1 Base case — one mandatory byte from set `B ⊆ Σ`

(`B={c}` literal; `B=[…]` class; `B=Σ∖{\n}` for `.`)

- `B ⊆ C` (the adversary cannot escape the class):
  `F=P=S=minLen=1`, `all_in=true`.
- otherwise (`B` offers an out-of-class byte): `F=P=S=0`, `minLen=1`,
  `all_in=false`.

This is the sole source of selectivity: `[0-9]` forces an in-class byte for
`digit` (and every superclass: hex, word); `.` forces nothing.

### 3.2 Concatenation `E = E₁·E₂`

    F(E)      = max( F(E₁), F(E₂), S(E₁) + P(E₂) )          // straddle
    P(E)      = all_in(E₁) ? minLen(E₁) + P(E₂) : P(E₁)
    S(E)      = all_in(E₂) ? minLen(E₂) + S(E₁) : S(E₂)
    minLen(E) = minLen(E₁) + minLen(E₂)
    all_in(E) = all_in(E₁) ∧ all_in(E₂)

`S(E₁)+P(E₂)` is the only cross-boundary term: a forced suffix run of every
`w₁` abuts a forced prefix run of every `w₂`. The `all_in?` guards are exact,
so when a side can emit an out-of-class byte the straddle collapses to the safe
non-crossing bound.

### 3.3 Alternation `E = E₁ | E₂`

    F = min(F₁,F₂),  P = min(P₁,P₂),  S = min(S₁,S₂),
    minLen = min(minLen₁, minLen₂),   all_in = all_in₁ ∧ all_in₂

The adversary picks the branch minimizing each field; a min of lower bounds
over a union of languages is a lower bound. `all_in` survives only if **both**
branches are all-in-class.

### 3.4 Repetition `E{n,m}` (`0 ≤ n ≤ m ≤ ∞`)

The adversary empties the `m−n` optional copies; the forced part is `E`
concatenated `n` times:

    profile(E{n,m}) = profile( E · E · ⋯ · E )   (n copies, by §3.2)

`n = 0` (`E*`, `E?`, `E{0,m}`) yields the empty profile
(`F=P=S=minLen=0, all_in=false`) — the empty string is accepted, nothing is
forced. Closed form for the frequent case (class atom `B ⊆ C` repeated `n`):
`F=P=S=minLen=n, all_in=true` — this is what turns `[0-9a-f]{8}` into
`ĝ(hex)=8` (and `ĝ(word)=8`, since hex ⊂ word).

### Anchors / zero-width (`^`, `$`, `\b`)

Concatenation identity: `F=P=S=minLen=0`, `all_in=true`. They emit no byte, so
runs cross them freely; still a lower bound.

### Unsupported constructs (backreferences, lookaround, flags, …)

The trivial profile — equivalently `ĝ = 0⃗` for the whole pattern
(`src/math/crest.zig` `ghat` returns the zero vector on any parse it cannot
certify).
No pruning ⇒ sound. The sieve degrades to "no help," never to "wrong."

`ĝ(R,C) = F(root)`; one bottom-up pass, `O(|R|·k)` per query, zero
allocations.

### 3.5 Incompleteness is not unsoundness (the tightness gap, measured)

The calculus is sound, not tight. Example: `[0-9](?:)[0-9]` truly forces a
digit run of 2, but the empty group carries `all_in=false`, the straddle term
declines, and `ĝ(digit)=1 < g(digit)=2`. Under-pruning costs selectivity,
never correctness — a referee who exhibits a looser-than-optimal `ĝ` has found
an optimization, not a bug. (Unit-pinned in `crest_test.zig`:
`test "tightness gap is under-prune"`.)

**How loose, exactly?** The gap is measured against an _independent_ exact
oracle, not asserted. Define the true forced run `g(R,C) = min_{w∈L(R)} ρ(w,C)`
and compute it by automaton intersection: the largest `r` for which
`L(R) ∩ L(M_{C,r})` is empty, where `M_{C,r}` is the monitor DFA accepting
strings with _no_ maximal C-run of length `≥ r` (state = current-run-length
capped at `r`), binary-searched over `r`. This is a textbook min-over-a-
max-automaton value (Kuperberg–Vanden Boom min/max cost automata, STACS 2015;
the ranked variant is Mohri–Riley N-best paths) — we claim none of it, we use
it only as a soundness+tightness referee built from a _separate_ Thompson NFA
compiler, so the AST calculus never grades itself. Over 6,549 randomized
(regex, class) forced runs the shipped calculus is **sound on every one
(`ĝ ≤ g` always) and exactly tight on 98.0%**, mean gap `g − ĝ = 0.043` of a
run. So "sound, not tight" is, empirically, "sound and tight 98% of the time";
the 2% are the straddle/alternation cases above, always under-pruning. The
oracle and its property harness live in the lineage spike
(`spikes/ridge-spectrum/ridge.py`, `g_exact`); the corpus-scale
matched⇒¬pruned proof against the real matcher stays in `bench/crest/`.

### 3.6 Alphabet contract (the one real false-negative footgun)

Theorem 1 is stated over one alphabet, and its instantiation is sound **only
if** the class lattice and the matcher decide over the _same_ alphabet. A
matcher folding `\d` over Unicode scalars, paired with an ASCII-byte lattice,
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
whose byte and codepoint semantics provably coincide (explicit ASCII-only
character classes and literals) certify; `\d`/`\w`/`\s` and any class
reaching ≥ 0x80 contribute `ĝ=0`, and caseless disables the sieve entirely.
`bench/crest/bench.zig` exercises both mode pairings against the real
matcher; option (b) — indexing codepoint-runs — remains open future work.

### 3.7 Why the _run_, not the _count_ (the weaker cousin, ruled out)

The tempting sibling indexes total class population `#{i : dᵢ ∈ C}` and prunes
below the forced count. Also sound — and strictly dominated: a forced C-run of
length `n` implies a forced population `≥ n`, never the reverse, so on `C{n}`
the run bound prunes a superset of what the count bound prunes. Empirically the
gap is decisive because source files carry hundreds of _scattered_ digits but
rarely a _consecutive_ run of 8 hex bytes: measured on the live corpus
(§5), `[0-9a-f]{8}` → run-prune **91.4%** vs count-prune **0.7%**.

### Lemma 1 (calculus soundness)

> For every node `E` and class `C`: `F(E) ≤ min_{w∈L(E)} ρ(w,C)`;
> `P(E) ≤ min_w (leading C-run of w)`; `S(E) ≤ min_w (trailing C-run of w)`;
> `minLen(E) ≤ min_w |w|`; and `all_in(E) ⇒ every w ∈ L(E)` is all C-bytes.

_Proof._ Structural induction over the AST.

_Base._ A mandatory byte from `B`: if `B ⊆ C` every accepted `w` is a single
C-byte — all five fields exact. Otherwise the adversary picks an out-of-class
byte: leading/trailing/longest runs can be 0, and `all_in` must be false;
`minLen=1` holds either way.

_Concatenation._ Any `w ∈ L(E)` factors as `w = w₁w₂`, `wᵢ ∈ L(Eᵢ)`. Its
longest C-run either lies inside one factor (length `≥ F(Eᵢ)` by IH) or
crosses the seam — in which case it _contains_ the trailing run of `w₁` abutted
to the leading run of `w₂`, of length `≥ S(E₁)+P(E₂)` by IH. In all cases
`ρ(w,C) ≥ max(F₁, F₂, S₁+P₂)`, and a max of lower bounds valid for every `w`
is a valid lower bound of the min. For `P(E)`: if `all_in(E₁)`, every `w₁` is
all-C of length `≥ minLen(E₁)`, so `w`'s leading run is `≥ minLen(E₁)+P(E₂)`;
otherwise some `w₁` contains an out-of-class byte, the leading run of `w` is
the leading run of `w₁` for that adversarial choice, and `P(E₁)` bounds it.
`S` symmetric. `minLen` adds. `all_in` conjuncts exactly.

_Alternation._ `L(E) = L(E₁) ∪ L(E₂)`: a min over a union is the min of the
mins, and each componentwise min of lower bounds lower-bounds it. `all_in`
must survive both branches.

_Repetition._ Reduces to `n`-fold concatenation (adversary empties optional
copies — legal since those copies accept ε or can be pumped down). ∎

Together with Theorem 1: `ĝ(R,C) = F(root) ≤ g(R,C)`, so Corollary 1's sieve
is sound. ∎

**Remark (algebraic shape).** Fields `(F,P,S,minLen)` compose in a min-plus /
max-plus (tropical) fashion with an exactness guard `all_in`; alternation is
the tropical sum (min), concatenation a guarded tropical product. We do not
lean on semiring machinery for the proof — the direct induction is shorter —
but the shape explains why one bottom-up pass suffices.

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

## 5. Production proof (measured, fail-closed)

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
  BOTH engine modes (24,000 ASCII + 24,000 Unicode (pattern,file) pairs);
  any violation exits non-zero;
- **ablation** — the §3.7 count cousin at identical thresholds;
- **speed** — full scan vs sieve+survivors, same matcher both sides, so the
  ratio is purely avoided verification.

Measured 2026-07-19, Apple Silicon (aarch64), zig 0.16.0, ReleaseFast —
52,724 files, 493.9 MiB; crest table built in **285 ms** (the parallel
production builder; a one-time index-build cost), 823.8 KiB ≈ **0.16%** of
corpus:

| query                | forced ĝ               | run prune% | count prune% | full ms | sieve ms | speedup   |
| -------------------- | ---------------------- | ---------- | ------------ | ------- | -------- | --------- |
| `[0-9a-f]{8}`        | hex:8 word:8           | **91.4%**  | 0.7%         | 407.9   | 52.2     | **7.8×**  |
| `[0-9a-f]{12}`       | hex:12 word:12         | **95.3%**  | 0.9%         | 442.8   | 29.5     | **15.0×** |
| `[0-9]{4}`           | digit:4 hex:4 word:4   | 63.7%      | 24.2%        | 226.8   | 70.5     | 3.2×      |
| `[0-9]{6}`           | digit:6 hex:6 word:6   | **90.3%**  | 30.9%        | 369.6   | 44.8     | **8.3×**  |
| `[A-Z]{4}`           | upper:4 alpha:4 word:4 | 33.5%      | 6.7%         | 99.1    | 40.6     | 2.4×      |
| `[A-Z]{6}`           | upper:6 alpha:6 word:6 | 48.9%      | 8.6%         | 184.0   | 55.4     | 3.3×      |
| `\w{3,8}` (wide)     | word:3                 | 0.2%       | 0.1%         | 0.8     | 0.7      | 1.2×      |
| `[A-Za-z]{5}` (wide) | alpha:5 word:5         | 0.3%       | 0.2%         | 1.1     | 1.0      | 1.1×      |

Reading the table against the theory:

- The **trigram baseline on every one of these queries is cand% = 100%**
  (gist Certificate, `regex-classcount` and kin) — zero pruning. Crest prunes
  91–95% on the narrow-class queries at 8–15× wall-clock, exactly the §4
  narrow-class prediction.
- The **count cousin collapses** (0.7% vs 91.4% on hex-8): the run, not the
  population, is the operative necessary condition — §3.7 made empirical.
- The **wide-class rows are the honest scope boundary**: ≈0% pruning, ≈1×,
  never a slowdown beyond the k-compare noise floor.
- **Soundness held everywhere**: 0 false negatives over 8 × 52,724 corpus
  checks + 48,000 randomized pairs (24k per engine mode), verified against
  the production matcher, fail-closed. (The Python spike additionally holds
  240,000 random (regex, text) property pairs at zero violations.)

Reproduce: `cd pkg/kernels/irregex && zig build crest` (writes
`.local/gist-verify/crest.csv`).

### 5.1 The shipped CLI, end to end (the integration's own numbers)

The harness above isolates the sieve. The stronger claim is the **product**:
same `gist` binary, same trigram index, the only variable being the presence
of the `crest.bin` sidecar in the live generation (absent ⇒ the loader
fail-closes to "no sieve" and the engine scans as before). hyperfine,
`--warmup 2`, whole-process wall time over the full repo:

| query            | sieve OFF | sieve ON    | end-to-end           |
| ---------------- | --------- | ----------- | -------------------- |
| `[0-9a-f]{12}`   | 277.2 ms  | **64.5 ms** | **4.3×**             |
| `[0-9a-f]{8}`    | 253.1 ms  | **69.9 ms** | **3.6×**             |
| `[0-9]{6}`       | 226.0 ms  | **71.0 ms** | **3.2×**             |
| `[A-Z]{6}`       | 245.4 ms  | 172.0 ms    | 1.4×                 |
| `\w{3,8}` (wide) | 420.2 ms  | 418.8 ms    | 1.0× (no regression) |

Match-set parity was verified per query (`gist -c` with the sieve vs
`--no-index`, uncapped, diff-identical file:count sets — including a caseless
`(?i)[0-9a-f]{8}` and a literal-mixed `[0-9]{4}-[0-9]{2}-[0-9]{2}`), and the
full `zig build test` suite — with the rg-parity differential oracles — runs
green with the sieve live. These end-to-end ratios are smaller than the
harness's isolated 8–15× because a real query also pays walk/stat/emit; they
are _realized product speedups_, not model numbers.

---

## 6. Complexity summary

| operation          | cost                                                                                                              |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- |
| index a document   | `O(L)` single pass, 8-lane comptime-unrolled; ~1.7 GiB/s with the parallel production builder (494 MiB in 285 ms) |
| index space        | `k` small ints/doc — 16 B/doc, **0.16%** of corpus bytes                                                          |
| query-time `ĝ`     | `O(                                                                                                               | R   | ·k)`, once per query, allocation-free |
| sieve decision     | `k` integer compares/doc — one 8-lane vector `≥`                                                                  |
| incremental update | recompute one document's crest on change; no global state                                                         |

The sieve is embarrassingly composable with the trigram index: intersect
survivor sets (both are necessary conditions, so the intersection is still
sound), letting each filter own the pattern family the other concedes. That
is exactly the shipped wiring — and in production the win exceeds the table
above, because a pruned document's **read is elided entirely** (the serial
`IndexSkip` / parallel `Elide` oracles), not just its match call.

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

### 7.3 The gap-aware calculus (`all_out`, the distinctness permission slip)

Crest's `(F,P,S,minLen,all_in)` profile decides _lengths_; the spectrum needs
to know **when two forced runs are provably distinct**. That is a second exact
predicate, dual to `all_in`:

    all_out(E,C) = true  ⟺  every w∈L(E) is composed solely of NON-C bytes.

A profile becomes a per-class **ordered list of segments** separated by forced
`all_out` boundaries. Concatenation glues the last segment of the left to the
first of the right (Crest's straddle merge — they may abut with no forced
separator between); an atom that is `all_out` for `C` commits a boundary, so
runs on either side are counted as distinct entries in the multiset. The
finalized `ĝ_i(R,C)` is the sorted-descending list of per-segment forced runs.

The load-bearing subtlety is **when NOT to split**, and it is where soundness
lives: `[0-9a-f]{8}[^0-9a-f]+[0-9a-f]{8}` does **not** force two _hex_ runs,
because `[^0-9a-f]` still admits `A`–`F` (uppercase hex) — the two runs may
merge into one length-17 hex run through an uppercase letter. `[^0-9a-f]` is
`all_out` for `digit` but **not** for `hex`, so the calculus forces two digit
runs and only one hex run. A naive multiset that split on _any_ separator would
manufacture a false negative here; the exactness of `all_out` is what forbids
it. Alternation conservatively collapses each branch to its single Crest run
(componentwise min) — a sound lower bound; intra-branch multi-run structure is
dropped, which only under-forces.

**Invariant (no regression):** `ĝ_1(R,C) = F(root)` exactly — the shipped
Crest forced run. Crest's straddle never crosses an `all_out` atom, so the
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
property pairs, count-cousin ablation, referee verdict NOVEL 2026-07-19);
working name "Rune" retired at graduation. The forced-run **spectrum** (Ridge,
§7) and the **exact automaton oracle** (§3.5) come from
`spikes/ridge-spectrum/` (`ridge.py` — segment calculus + NFA×monitor
oracle + 160k-pair sieve property suite + base-vs-ridge corpus bench; referee
verdict PARTIAL/no-collision 2026-07-20).
