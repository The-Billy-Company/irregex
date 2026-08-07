# kernel/math — arithmetic and structure with no product opinion

The lowest kernel tier. Nothing here knows what a pattern is, what a corpus is,
or that a search exists, and that is the membership test: **a file belongs here
when it would be just as correct inside somebody else's program, and it stops
belonging the moment it needs to know why it was called.**

It is kept physically apart from engine code for two reasons that pull the same
direction. Bit tricks and sieve calculus cannot grow a dependency on a matcher
if the matcher is not reachable from here. And a structure with no product
opinion stays available to every tier above, rather than being sealed inside
the first one that happened to need it — union-find arrived via kinship
clustering, the glob matcher via the corpus walk, edit distance via a config
reader, and none of them belong to those callers.

`math.zig` is the door. It re-exports every file below under one name
(`math.bits`, `math.crest`, `math.succinct.rrr`, …), which is how `root.zig`
and every other tier reach this floor. Two of them — `forest` and `mix` — are
also published through `root.inner.math` for the sibling packages, because
`relate`'s kinship tiers need exactly those and nothing else here.

Half of this package is things a reader would otherwise write for themselves.
The versions here are the ones this package's own hot paths are held to, and
several carry a measurement or a proof that a hand-rolled copy would not.

---

## The map

| File | What you get | Who rides it |
|---|---|---|
| [`bits.zig`](bits.zig) | Two's-complement identities over words and word-packed sets: set-bit walks, `Field(Word)` bitsets, edge-safe masks, endian-correct movemask, a dense bit-field cursor | `scan/`, `slate/`, the linear engine's symbolic + DFA layers, `regex/syntax`, `regex/analysis` |
| [`mix.zig`](mix.zig) | The hash-mixing floor: FNV-1a constants, the splitmix64 finalizer, and `SliceCtx` — the HashMap context `std` lacks for slice keys | the linear engine's alphabet/determinize/subset/reduce path, `frame/`, and `relate` through `inner.math` |
| [`glob.zig`](glob.zig) | The gitignore/rg-shaped glob matcher — pure pattern-vs-string, no filesystem | `corpus/scope`, `corpus/tree/ignore`, `slate/loom`, argv, cold read |
| [`misread.zig`](misread.zig) | Located config faults and the shy did-you-mean over Damerau–Levenshtein | `corpus/scope/charter`, `exec/cold/argv/preference` |
| [`forest.zig`](forest.zig) | Union-find with path halving and min-index representatives | out-of-package: `relate`'s `kinship/cluster` |
| [`dag.zig`](dag.zig) | Hash-consed DAG over a caller's payload — structural equality as identity, free topological order, and the three sweeps (`fold` / `descend` / `power`) | `regex/ast` |
| [`lease.zig`](lease.zig) | Reader/writer lease guards and the double-checked read-mostly reconcile dance; plus `Latch` for threads with no `std.Io` | the warm session (`resident`, `watch`, `keep`, `annals`, `dirty`), `corpus/tree`, `regex/glean/pool` |
| [`parallel.zig`](parallel.zig) | Shard geometry — byte-balanced and arithmetic division, the floors that decide when to bother, and a partial-spawn-safe fan-out | every parallel lane: cold engine + emit, session facets, trigram kiln, codex build, `scan/verify` |
| [`crest.zig`](crest.zig) | The forced-class-run sieve: the document vector ρ(d), the `Swell` disjunction, and the dominance test that prunes a literal-free pattern the trigram index cannot | `query/prefilter`, cold `writ`/`quarry`/`engine`, session `mirror`/`gather`, the crest sidecar, `regex/analysis/swell` |
| [`semiring.zig`](semiring.zig) | Four semirings and two algebraic-path algorithms — swap the arithmetic, answer a different question with the same code | nothing in-package yet; the floor a sibling package's parser sits on |
| [`succinct/`](succinct) | SA-IS, RRR, the Huffman wavelet tree — the three the FM-index composes — plus balanced parentheses, a pointerless ordinal tree at 2n + o(n) bits. [Its own README](succinct/README.md) | `kernel/codex` (the first three); `parens` has no in-package caller yet |

## Reach for this when

| You want | Call |
|---|---|
| To walk the set bits of a word or a packed set | `bits.ones(x)` · `bits.Field(u64).ones(slice)` |
| A bitset over storage you already own | `bits.Field(Word)` — `set`/`clear`/`setRange`/`get`/`count`/`first` |
| The low-k mask without the `k == width` trap | `bits.prefixMask(Word, k)` |
| The index of the first SIMD lane that hit | `bits.laneMask(u16, cmp)` then `@ctz` — never a bare `@bitCast` |
| To hash a `[]const T` key | `mix.SliceCtx(T)` |
| To spread a weak accumulator before bottom-k | `mix.finalize(h)` |
| To test a path against `*.go` / `src/**/*.zig` / `build/` | `glob.globApplies(pat, path)` |
| To validate a `-g` glob strictly, as rg does | `glob.unterminatedClass(g)` |
| To suggest a spelling for a mistyped key | `misread.nearest(typo, candidates)` |
| To collapse verified pair edges into components | `forest.Forest` |
| To ask a tree-shaped IR many questions cheaply | `dag.Dag(Payload, arity)`, then `fold` |
| To hold state read-mostly across threads | `lease.Ward.readReconciled` (or `reconcileHeld` if you already hold one) |
| To divide work across cores | `parallel.shardBounds` (weighted) · `parallel.evenBounds` (uniform) · `parallel.fanOut` |
| To prune documents a class-repetition pattern cannot match | `crest.crest(doc)` and `Swell.prunes` |
| Shortest path / reachability / counting over one graph | `semiring.shortestDistance` or `closure`, instantiated at the semiring you want |

---

## Bits and hashing

`bits.zig` runs on one fact. Hardware encodes negatives in two's complement, so
`x - 1` borrows through the trailing zeros of `x` and flips exactly its lowest
set bit; pair that with `@ctz` and you walk a word's set bits in popcount steps
rather than word-width steps (Warren, *Hacker's Delight* §2-1). `Field(Word)`
layers the word-packed bitset on top — the `bits[i>>6] |= 1 << (i&63)` shape
that powerset interning, the pattern slate, `ByteSet`, SA-IS and RRR each
hand-rolled at both u64 and u8 widths.

These are **identities over plain slices**, deliberately not `std.bit_set`'s
owning containers: the masks live as hash-map keys, as caller-owned attribution
masks, and as struct fields. The storage belongs to the caller; only the
identities are shared.

Four things here exist because the obvious spelling is wrong:

- **`prefixMask`** shifts all-ones *down* from the top. The naive
  `(1 << k) - 1` is UB at `k == width` — the shift overflows before the borrow
  can wrap it.
- **`laneMask`** is `@bitCast` plus a comptime endianness branch. Raw
  `<n x i1>` → integer follows *target* endianness: measured on one source and
  one compiler, a 16-lane compare true only in lane 0 gives `@ctz == 0` on
  aarch64 and `@ctz == 15` on s390x. Every "index of the first hit" in the scan
  path assumes lane 0 is bit 0, so on big-endian the raw bitcast reports a match
  fifteen bytes from where it is. Little-endian builds lower to exactly the bare
  bitcast — no instruction added where the bug cannot occur.
- **`blockMask`** folds four 16-lane compares into one u64. NEON has no
  `pmovmskb`, so the per-chunk lowering costs a shift-narrow ladder each; the
  simdjson weight-and-`addp` fold replaces it. It is selected by the **feature**
  (`cpu.has(.aarch64, .neon)`), not the architecture, because the fold is inline
  asm that LLVM's subtarget check cannot see through — an arch-only test would
  emit NEON into an artifact built for a NEON-disabled baseline.
- **`Stream`** is a 128-bit shift window over densely packed bit fields, so
  after the first positioned load each `take` is one shift and one mask.
  Profiling-derived (2026-07-18, macOS `sample` over `codex-scale` 16 MB,
  ReleaseFast): the positioned-read walk it replaced was ~41 % of FM-index
  `count()` samples, and the cursor plus paired takes measured ~5 % median and
  up to ~14 % faster ns/query. **It requires one readable word past the last
  field consumed** — the usual `+1` pad word. Don't swap it back to per-field
  positioned reads without re-running `bench/codex`.

`mix.zig` is small and has one sharp edge. `SliceCtx(T)` **refuses to compile**
unless `T` has a unique representation, because `hash` reads the key as bytes: a
`T` with padding hashes memory no field assigned, two keys naming the same thing
land in different buckets, and the interner they front hands back two ids for
one value. `std.mem.eql` already consults uniqueness before it will `memcmp`, so
refusing here keeps hash and eql agreeing on what identity means. `finalize` is
the splitmix64 finalizer — FNV alone clusters short phrases in the low bits, and
bottom-k selection needs uniformity.

## Matching text without a matcher

`glob.zig` is the dialect, stated once: a pattern with no `/` matches the
**basename** at any depth (`*.go`), one with a `/` matches the **full path**;
`*` spans a single segment, `**` spans `/`, `?` is one non-`/` byte, `[...]` is
a negatable range-aware class that never matches `/`, and a trailing `/` makes
it a directory glob that covers everything beneath.

Two rules are the ones that bite. A `**` bounded by a `/` on both sides is a
*segment token*, and its continuation may only resume at a segment boundary —
`**/_pb2*` excludes a basename that *starts* with `_pb2`, never one that merely
contains it, so `outreach_pb2.pyi` stays in, matching rg. And an unclosed `[` is
**lenient in the matcher** (treated as a literal `[`, as a `.gitignore` line
would be) but **strict at the argv seam**, where rg errors; `unterminatedClass`
is that strict check, and it reuses the matcher's own class scan so the two
cannot drift.

`misread.zig` answers the two questions somebody mistyping a persisted config
file has — *where is it* and *what did I mean* — for both the charter and the
preferences file, once. The distance is Damerau–Levenshtein (OSA) rather than
plain Levenshtein because plain charges 2 for a transposition, the single most
common typing error, and `--headnig` for `--heading` would then fall outside a
budget tight enough to reject real non-matches.

`nearest` is **deliberately shy**, and that is the whole reason a suggestion can
be trusted: the budget is `max(1, len/4)` so short names are not corrected into
each other, the row-minimum abandons as soon as the cap is provably exceeded,
candidates longer than 63 bytes never match at all, and **two candidates equally
close return null** — a coin flip is worse than silence, because a wrong guess
sends the reader to edit a line that was never the problem. `Diagnostic.token`
borrows the source bytes, so `keepToken` copies it out before the file's buffer
goes away.

(ripgrep answers neither question: a bad flag in a `.ripgreprc` is passed through
to the search, which then behaves oddly with no message at all.)

## Structures over graphs

`forest.zig` is union-find with path-halving finds. The one design choice worth
naming is that roots are the **minimum member index**, so a component's identity
is stable regardless of join order — a clustering that reports canonical members
gets the same answer whichever direction it walked its edges.

`dag.zig` is the substrate under `regex/ast`, and it is generic over payload and
arity because the regex AST is one instantiation, not the only possible one.
Three properties fall out of a single construction rule — *a node may only be
interned after its children are*:

1. **Structural equality is identity.** Same shape ⇒ same `Id`, so `a == b`
   replaces a recursive comparison and common subexpressions collapse on the way
   in (Filliâtre & Conchon, *Type-Safe Modular Hash-Consing*, ML '06).
2. **Topological order is free.** `child_id < parent_id` always holds, so a
   bottom-up analysis is a forward `for` loop over a flat array — no recursion,
   no stack, no visited set, no worklist, no revisit even under heavy sharing.
   `fold` enforces it by construction: the callback sees only `out[0..i]`, which
   is every child's result and nothing else.
3. **Sharing is exploitable.** `power` builds an n-fold combination in
   `O(log n)` distinct nodes by repeated squaring, so `a{1000}` is ~19 nodes to
   every analysis while still lowering to the thousand-state automaton its
   language requires.

Storage is struct-of-arrays on purpose: the point of the ordering invariant is
that analyses become linear scans, and pointer-linked nodes would hand back the
cache misses the invariant was bought to remove.

Two traps. A **payload holding a slice or pointer whose contents define identity
must declare `hash` and `eql`** — without them the payload is hashed field-wise
and compared with `std.meta.eql`, which is right for POD and wrong for that.
And interning never removes anything, so a rewrite leaves its superseded nodes
in place; `live(roots)` is how a later pass tells the DAG from the rubble, and
`census` counts parents so a lowering pass knows which fragments are worth
caching. `descend`'s `meet` must be commutative, associative and idempotent, so
a node reached two ways gets the weakest claim both parents support rather than
whichever arrived last.

Deliberately **not** an e-graph — no equivalence class per node, no saturation —
because the consumers here need one canonical form cheaply, not the space of all
equivalent forms.

## Concurrency and division

`lease.zig` gathers the two things a raw `RwLock` makes easy to get wrong.
**Lease guards** (`Read` / `Write`) pair acquisition with release: you hold a
value whose `release()` drops exactly the mode you took, so a `defer` can never
unbalance a shared against an exclusive unlock. **`readReconciled`** is the
read-mostly dance — answer over an immutable snapshot, refresh on a miss —
written once instead of at every answer face: enter shared, and if the snapshot
is fresh answer under the shared lock so readers overlap; otherwise drop shared,
take exclusive, refresh, and *downgrade* back to shared (Schmidt & Harrison,
"Double-Checked Locking", PLoP '96).

The error paths of the two reconcile faces differ, and choosing wrong is a
double unlock or a leak:

| | On a refresh error | For a caller who… |
|---|---|---|
| `readReconciled` | propagates with **nothing held** | registers its `defer release()` *after* the `try` |
| `reconcileHeld` | returns the error **beside a live lease** | already holds a `Read` under a `defer`, so it must end holding one on every path |

`downgrade` is **not atomic** — a competing writer may slip into the
release/reacquire gap — so only downgrade once every mutation is published and
any staleness a racing writer could introduce is independently re-checked.
`Ward` is writer-preferring, inherited from `std.Io.RwLock`, so a stream of
readers cannot starve a queued refresh. `Latch` is the smaller sibling for the
one case `Ward` cannot serve: a thread with no `std.Io` handle at all. It is a
spin-on-atomic-swap, not recursive and not fair, and it is honest only under the
discipline it enforces by existing — a critical section of a few map or field
operations, never a syscall and never a wait. `tryLock` exists for code reached
from *inside* a critical section, such as a memory-pressure hand called from a
failing allocation the latch may already be held across.

`parallel.zig` divides work in two shapes because work comes in two shapes.
`greedyBounds` / `shardBounds` weigh items that differ in size, so a few large
files cannot stall one thread — the load imbalance that caps naive
count-splitting. `evenBounds` splits arithmetically where every item costs the
same, because weighing 200 M equal-cost suffix-array rows to discover they are
equal costs about as much as running a shard. `fanOut` runs either, and carries
the fallback every fan-out here shares: a mid-fan-out spawn failure must not
return with live threads still scanning buffers the caller's defers would free,
so the unspawned tail runs inline on the calling thread.

The three constants are the crossover policy, and they live here so it lives in
one place: `min_bytes` (256 KiB) is the search floor below which a sharded face
stays serial, because thread spawn plus per-shard scratch — a recompiled engine,
a span VM, an arena — only amortizes once the scan dominates. `build_min_bytes`
(4 MiB) is the higher floor for index *construction*, which touches every item
once with no early exit and no engine to warm, so the only cost to amortize is
the spawn. `max_shards` (16) caps a giant corpus at the realistic core ceiling.

Two API shapes worth noticing: `shardBounds` returns **null for "stay serial"**
(below the floor, one usable core, or a failed allocation — serial is always a
correct fallback), while `evenBounds` **never** returns null and always yields at
least one shard, so its caller keeps one code path and staying serial is the
one-shard case rather than a second branch free to drift. Pass `grain = 64` to
`evenBounds` when shards write into one shared bit-packed word array, so no two
carry a read-modify-write on the same word.

## Crest — the sieve

The contiguity bound the trigram index concedes. A literal-free
class-repetition pattern (`[0-9a-f]{8}`, `\d{6}`) extracts no required
substring, so every substring-presence prefilter degenerates to a full scan.
Crest prunes by a *different* sound necessary condition, in three pieces:

- **ρ(d)**, the crest vector: per document, the longest run of consecutive bytes
  in each member of a fixed family — one O(|d|) pass, K small ints.
- **ĝ(R)**, the forced crest: a sound lower bound on what any match must show,
  folded out of the pattern AST by a min-of-max prefix/best/suffix algebra. That
  half lives with the engine, in `../regex/analysis/swell.zig`, because deriving
  it from a second private grammar was a silent false-negative factory.
- **The sieve**: R can match inside d only if some alternative's ĝ is
  componentwise met, so a `Swell` all of whose alternatives fall short prunes d
  — K integer compares per alternative, no byte scan. The proof is
  [`research/crest/PROOF.md`](../../../research/crest) §2 and §3.9.

**The soundness posture is that everything rounds down.** A construct `swell`
cannot certify contributes nothing or zeroes the vector, quantities saturate at
`maxInt(u16)`, and saturation is monotone on both sides of the compare — so
under-pruning is the only failure mode, and the sieve can never manufacture a
prune.

The family is 8 classes × 3 alphabets = **K = 24 lanes**, and the third alphabet
is the interesting one. A byte sieve and a codepoint matcher disagree about what
a class *is*: under the engine's default `unicode=true`, `\d{6}` once sieved by
nothing while `[0-9]{6}` pruned 92.8 %. The `+u` repair measures classes closed
under the non-ASCII bytes — sound, since every byte of a multi-byte UTF-8
sequence has bit 7 set, but loose, since a 3-byte CJK character spends 3 bytes.
The `+cp` alphabet tightens it without decoding anything: continuation bytes
(`0x80..0xBF`) are **transparent**, neither extending nor breaking a run, the way
they are to a human reading one character at a time. That same CJK character
costs `+cp` exactly 1, and "was the previous byte a continuation" is answerable
from the current byte alone.

`Swell` is a **disjunction, not a single vector** — one ĝ per top-level
alternative, because `R₁|R₂` obliges a match to satisfy only one branch.
Collapsing the branches into a componentwise min keeps soundness but throws that
structure away: two branches with disjoint forced classes min to 0⃗, a sieve that
prunes nothing. Since multi-`-e` reaches the engine as `(?:a)|(?:b)`, every
multi-pattern search used to run with the sieve silently stood down. `no_sieve`
is the one spelling of "this run proves nothing" — a declined pattern, a PCRE2
arm, an output mode that must read every byte — so a stand-down is named rather
than open-coded.

Two tables, not one: `membership` is the **query-side** bitset `Profile.atom`
intersects, where a bare continuation byte is in no codepoint lane (admitting it
would certify a forced run a document of six lone continuation bytes does not
honor — a false negative). `keep` is what the **document scan** reads, where a
continuation byte must hold the run rather than reset it. They agree everywhere
else.

The scan itself is two interleaved pieces (`ways = 2`) over a padded
`@Vector(32, u16)`, joined by the same P/F/S concatenation law the query half
uses over the AST — which is what makes cutting the document up exact rather
than approximate. The width is padding-to-a-power-of-two on purpose: at the odd
`K = 24` the identical storage measured 0.089 GiB/s against a clean 32's 0.713,
the signature of a lane count the autovectorizer cannot shuffle cleanly. `ways`
was re-measured after that fix: 2 is the corpus optimum at ≈7.9× the per-byte
reference, against `ways=4`'s ≈6.6× and `ways=1`'s ≈5.8×. Two alternative
shapes were measured and rejected — an `inline for` over plain arrays (reads
better, spills, 3.7× slower in the sharded build that ships) and a bitmap pass
(cheaper classification, but extracting a longest run costs a step per run and a
dense mask has one every few bits — 3.8× slower).

Anything that changes the family's meaning must bump `SidecarSchema`'s
`format_version` and will move its signet, which invalidates every persisted
sidecar. The whole membership table is inside the digest preimage, so a change
cannot be silently narrower than the version claims.

## Semirings — one algorithm, four questions

A semiring is two operations over one carrier: `⊕` picks between alternatives,
`⊗` extends along a path. Both associative, `⊕` commutative, `zero` and `one`
their identities, `⊗` distributes over `⊕`, `zero` annihilates `⊗`. That is the
whole contract, and it is enough to write shortest-path once:

| carrier | `⊕` | `⊗` | `zero` | `one` | answers |
|---|---|---|---|---|---|
| `Boolean` | or | and | false | true | is it reachable |
| `Tropical(Cost)` | min | + | ∞ | 0 | the cheapest path |
| `Viterbi(P)` | max | × | 0 | 1 | the likeliest derivation |
| `Counting(N)` | + | × | 0 | 1 | how many derivations |

A semiring is a **type**, not a value: it carries `T`, `zero`, `one`, `add`,
`mul`, `star` and is passed as a comptime parameter, so every operation inlines
and a tropical relaxation costs a compare and an add.

Two algorithms ride them. **`closure`** is Lehmann's Gauss-Jordan asteration —
`A* = I ⊕ A ⊕ A² ⊕ …` over a dense `n × n` matrix, in place, O(n³), no
allocation. Read it in the tropical semiring and it is literally
Floyd–Warshall; read it in the Boolean one and it is Warshall's transitive
closure. In-place is safe without snapshotting row/column k for a reason worth
stating: pass k rewrites row k to `s ⊗ rowₖ` and column k to `colₖ ⊗ s`, so a
later row reads a doubled `s` — and it lands on the same value because star is
⊗-idempotent in any closed semiring. **`shortestDistance`** is Mohri's generic
single-source walk, and it is *not* Bellman–Ford: each vertex carries a residual
(what has arrived since it was last expanded) and only the residual is pushed
forward, so a vertex re-expands exactly as often as new weight reaches it.

The one place a semiring needs care is closure — `a* = 1 ⊕ a ⊕ a² ⊕ …`, which is
how a cycle gets summed. Tropical and Boolean have a total `star`; counting does
not (a reachable cycle means infinitely many derivations) and Viterbi diverges
above 1. So `star` returns an optional, `closure` raises `error.NoClosure`
rather than a silently wrong finite number, and `shortestDistance` carries a
visit budget that fails closed the same way for a caller who hands it a
semiring that is not k-closed.

Tropical's integer carrier is **unsigned by compile error**. A negative weight
admits a negative cycle, `star` stops existing, and every guarantee evaporates;
refusing signed costs is what buys totality. Costs then saturate to `zero`
(= unreachable) rather than wrapping — not a hack around overflow but the
quotient semiring in which everything at or above the cap is identified with ∞,
where saturating addition stays associative and monotone. Wrapping is the one
failure that would actually hurt: an overflowed repair path would come back
looking *cheap* and win the minimum. `Counting` saturates for the same reason —
a wrapped count would report a hugely ambiguous parse as unambiguous. A float
carrier needs no saturation (`inf` already absorbs) but is associative only up to
rounding, so reach for an integer carrier when the laws must hold exactly, or
work in the log domain, which is `Tropical`.

### Prior art

- [Mohri, *Semiring Frameworks and Algorithms for Shortest-Distance Problems*
  (JALC 7(3), 2002)](https://cs.nyu.edu/~mohri/pub/jalc.pdf) — the generic
  single-source algorithm `shortestDistance` implements, including the residual
  trick that lets one worklist serve idempotent and non-idempotent semirings
  alike, and the k-closed condition that says when it terminates.
- [Lehmann, *Algebraic Structures for Transitive Closure* (TCS 4(1),
  1977)](https://doi.org/10.1016/0304-3975%2877%2990056-1) — the Gauss-Jordan
  asteration `closure` is: Floyd-Warshall's shape, but derived from the
  semiring axioms instead of from arithmetic on reals, which is why the same
  triple loop transitively closes a Boolean matrix and counts paths.
- [Goodman, *Semiring Parsing* (Computational Linguistics 25(4),
  1999)](https://aclanthology.org/J99-4004/) — the argument for why a parser
  wants this rather than four parsers: recognition, Viterbi, inside, and
  derivation counting are one algorithm over four semirings.
- Kuich & Salomaa, *Semirings, Automata, Languages* (EATCS Monographs 5,
  Springer 1986) — the algebra itself, and where "closed semiring" and the
  formal-power-series view of `star` are set up properly.

---

## Invariants

- **Caller-owned storage.** The identities operate over slices the caller
  allocated — `Field`, `crest`, `glob`, `misread`, `pruned` and the semiring ops
  allocate nothing at all. The four that do (`Forest`, `Dag`, the `Dag` sweeps,
  and `shortestDistance`) take a `gpa` in their signature and hand ownership
  straight back, either through a `deinit` or as a slice the caller frees.
- **Crest soundness rounds down only** — under-prune, never a false negative.
- **Saturate, never wrap.** Crest counters, tropical costs, and derivation
  counts all pin at their cap, because in each case the wrapped value would read
  as *better* than the truth and win a comparison it should lose.
- **Fail closed on a missing guarantee.** No closure is `error.NoClosure`, not a
  finite lie; a tie in `nearest` is null, not a coin flip; a non-unique payload
  representation is a compile error, not a silent second id.
- **No persistence opinion.** The artifact digest lives on the wire floor beside
  framing (`corpus/index/frame/signet.zig`), not here. Crest's `SidecarSchema`
  is the one thing that reaches for it, and only to *stamp* a semantic contract
  this file defines — it does not know what a file is.
- **Three imports out, all of them downward.** Beyond `std`, `builtin` and its
  own siblings, this whole tier reaches for exactly `portal` (in `parallel`, for
  the core count), `fault` (in `sais`, for the resource error set) and `signet`
  (in `crest`, for the schema stamp) — every one of them a floor declared
  *below* `math` in `contract/irregex.zone`. That is what keeps this tier
  reachable from everywhere above it, and it is checked, not hoped for.

## How it is proven

Every risky surface here is checked against an **independent oracle**, not
against itself:

| File | Held against |
|---|---|
| `bits_test.zig` | a naive bit-at-a-time walk, at both deployed widths (u64 masks, u8 SA-IS type maps), over random and adversarial words — empty, full, single-bit, alternating, boundary-straddling |
| `crest_test.zig` | ρ(d) straight from the definition, plus a schema test that alters each preimage field to prove it is inside the digest. The Sieve Theorem differential is `../regex/analysis/swell_test.zig`; corpus scale is `zig build crest` |
| `dag_test.zig` | a naive recursion that re-walks shared nodes, so a disagreement means the sweep is wrong rather than that the two compute different things |
| `semiring_test.zig` | the axioms directly over randomized elements *including the saturation boundary* (a "semiring" whose ⊗ wraps is not one), then Bellman–Ford, BFS reachability, and a topological path-count DP |
| `glob_test.zig` | the segment/`/` rules, basename-vs-full-path dispatch, class edges, and pathological star backtracking — a wrong boundary silently drops files, which reads as "no matches" and gets trusted |
| `lease_test.zig` | a call-counting oracle over the fast/miss/race/error paths of both reconcile faces, plus a threaded reader/writer invariant |
| `succinct/parens_test.zig` | one O(n) explicit-stack scan that knows nothing about excess, blocks, or min-max trees, over the shapes the range min-max tree can get wrong |

`forest`, `misread` and `parallel` keep their tests inline instead, because in
each case the property is small enough to read beside the code it constrains —
transitive joins collapsing to one min-rooted component, a tie yielding no
suggestion, shard bounds tiling `[0, n)` with no gap or overlap even when no
thread can spawn.

Run them with `zig build test`, or `zig build test -Dtest-filter='<substr>'` for
just what you touched. `crest.zig`'s throughput claims are re-checked by
`bench/rungs/crest/`.

## When to edit

New shared bit ops; a crest class-family change; a concurrency lease; a succinct
structure; a graph or set structure more than one tier can use; a semiring or an
algorithm over one.

Never file I/O, never ignore-file rules, never anything that has to ask what the
caller wanted — that is `corpus/` and `exec/cold/`. If the new file would need
to import a tier above this one to make sense, it belongs in that tier instead;
`contract/irregex.zone` is where that is enforced rather than merely intended.
