# kernel/math: The Product-Free Floor

The lowest kernel tier. Nothing here knows what a pattern is, what a corpus is,
or that a search exists.

| File | What it gives you | Start with | Ridden by |
|---|---|---|---|
| [`bits.zig`](bits.zig) | two's-complement identities and packed bitsets over storage you own | `ones`, `Field(Word)`, `prefixMask`, `rank`, `laneMask`, `Stream` | `scan/`, `slate/`, the linear engine's symbolic and DFA layers, `regex/syntax`, `regex/analysis` |
| [`mix.zig`](mix.zig) | the hash-mixing floor, including the slice-key context `std` lacks | `SliceCtx(T)`, `finalize` | the linear engine's alphabet, determinize, subset and reduce passes, `frame/`, `relate` |
| [`glob.zig`](glob.zig) | gitignore- and rg-shaped globbing, pure pattern against string | `globApplies`, `globMatch`, `unterminatedClass` | `corpus/scope`, `corpus/tree/ignore`, `slate/loom`, argv, cold read |
| [`misread.zig`](misread.zig) | located configuration faults and a shy did-you-mean | `nearest`, `Diagnostic` | `corpus/scope/charter`, `exec/cold/argv/preference` |
| [`forest.zig`](forest.zig) | union-find, path-halving finds, min-index roots | `Forest` | out of package only: `relate`'s `kinship/cluster` |
| [`dag.zig`](dag.zig) | a hash-consed DAG with structural identity and free topological order | `Dag(Payload, arity)`, then `fold` | `regex/ast` |
| [`lease.zig`](lease.zig) | reader/writer lease guards and the read-mostly reconcile | `Ward.readReconciled`, `Latch` | the warm session, `corpus/tree`, `regex/glean/pool` |
| [`parallel.zig`](parallel.zig) | shard geometry and a partial-spawn-safe fan-out | `shardBounds`, `evenBounds`, `fanOut` | every parallel lane in the package |
| [`crest.zig`](crest.zig) | the sieve for patterns the trigram index cannot prune | `crest(doc)`, `Swell.prunes` | fifteen call sites across query, cold, session, corpus index |
| [`semiring.zig`](semiring.zig) | four semirings and two algebraic-path algorithms | `shortestDistance`, `closure` | nobody in-package yet; the floor a sibling package's parser sits on |
| [`succinct/`](succinct) | SA-IS, RRR and the Huffman wavelet tree the FM-index composes, plus balanced parentheses at 2n + o(n) bits | [its own README](succinct/README.md) | the FM-index and the corpus index |

Not knowing is the membership test, and it cuts both ways. A file belongs here
when it would be just as correct inside somebody else's program, and it stops
belonging the moment it needs to know why it was called.

Keeping it apart from the engine means bit tricks and sieve calculus cannot grow
a dependency on a matcher, and a structure with no product opinion stays
available to every tier above instead of being sealed inside the first one that
wanted it. Union-find arrived through kinship clustering, the glob matcher
through the corpus walk, and edit distance through a config reader; none of them
belong to those callers.

`math.zig` is the door, re-exporting every file below under one name
(`math.bits`, `math.crest`, `math.succinct.rrr`). `forest` and `mix` are also
published through `root.inner.math`, because `relate`'s kinship tiers need those
two and nothing else here.

Half of this is what a reader would otherwise write for themselves. The
difference is that these are the versions this package's hot paths are held to,
and several carry a measurement a hand-rolled copy would not.

## Bits and Hashing

`bits.zig` runs on one fact. Two's complement makes `x - 1` borrow through the
trailing zeros of `x` and flip exactly its lowest set bit, so with `@ctz` a
word's set bits cost popcount steps rather than word-width steps (Warren,
*Hacker's Delight* §2-1).

`Field(Word)` layers the packed bitset on top: the `bits[i>>6] |= 1 << (i&63)`
shape that powerset interning, the pattern slate, `ByteSet`, SA-IS and RRR each
hand-rolled, at both u64 and u8 widths.

These are identities over plain slices, not `std.bit_set`'s owning containers,
because the masks live as hash-map keys, caller-owned attribution masks, and
struct fields. Storage belongs to the caller; only the identities are shared.

Four of them exist because the obvious spelling is wrong.

 - **`prefixMask`** – shifts all-ones down from the top, since the naive
 `(1 << k) - 1` is undefined at `k == width`, where the shift overflows before
 the borrow can wrap it.
 - **`laneMask`** – wraps `@bitCast` in a comptime endianness branch, since the
 raw lowering follows *target* endianness. A 16-lane compare true only in lane 0
 gives `@ctz == 0` on aarch64 and `@ctz == 15` on s390x, so a big-endian build
 reports the first match fifteen bytes from where it is. Little-endian builds
 lower to the bare bitcast, adding no instruction where the bug cannot occur.
 - **`blockMask`** – folds four 16-lane compares into one u64 by the simdjson
 weight-and-`addp` trick, since NEON has no `pmovmskb` and the per-chunk
 lowering costs a shift-narrow ladder each. It dispatches on the *feature*
 rather than the architecture, because the fold is inline asm LLVM's subtarget
 check cannot see through, and an arch-only test would emit NEON into an
 artifact built for a NEON-disabled baseline.
 - **`Stream`** – a 128-bit shift window over densely packed fields, so after
 the first positioned load each `take` is one shift and one mask. It requires
 one readable word past the last field consumed, the usual `+1` pad word.

`Stream` is profiling-derived, measured 2026-07-18 with macOS `sample` over
`codex-scale` 16 MB in ReleaseFast. The positioned-read walk it replaced was
~41 % of FM-index `count()` samples, and the cursor with paired takes measured
~5 % median and up to ~14 % faster ns/query; do not swap it back without
re-running `bench/codex`.

`SliceCtx(T)` refuses to compile unless `T` has a unique representation, because
`hash` reads the key as bytes. A padded `T` hashes memory no field assigned, so
two keys naming the same thing land in different buckets and the interner they
front hands back two ids for one value.

Refusing there keeps `hash` and `eql` agreeing on what identity means, since
`std.mem.eql` already consults uniqueness before it will `memcmp`. `finalize` is
splitmix64, needed because FNV alone clusters short phrases in the low bits
where bottom-k selection wants uniformity.

## Globs and Misreadings

`glob.zig` states the dialect once. A pattern with no `/` matches the *basename*
at any depth and one with a `/` matches the *full path*; `*` spans a single
segment, `**` spans `/`, `?` is one non-`/` byte, `[...]` is a negatable
range-aware class that never matches `/`, and a trailing `/` makes it a
directory glob covering everything beneath.

Two rules bite. A `**` bounded by `/` on both sides is a *segment token* whose
continuation may resume only at a segment boundary, so `**/_pb2*` excludes a
basename starting with `_pb2` and never one that merely contains it, leaving
`outreach_pb2.pyi` in and matching rg.

The other is that an unclosed `[` is lenient in the matcher, treated as a
literal `[` the way a `.gitignore` line would be, but strict at the argv seam
where rg errors. `unterminatedClass` is that check, reusing the matcher's own
class scan so the two cannot drift.

`misread.zig` answers the two questions somebody mistyping a persisted
configuration file has, *where is it* and *what did I mean*, once for both the
charter and the preferences file. ripgrep answers neither: a bad flag in a
`.ripgreprc` is passed through to the search, which then behaves oddly with no
message at all.

The distance is Damerau-Levenshtein in its optimal-string-alignment form, rather
than plain Levenshtein, because plain charges 2 for a transposition and
`--headnig` for `--heading` would fall outside a budget tight enough to reject
real non-matches.

`nearest` is deliberately shy, which is the whole reason a suggestion can be
trusted. The budget is `max(1, len/4)`, the row minimum abandons as soon as the
cap is provably exceeded, candidates longer than 63 bytes never match, and two
candidates equally close return null.

A coin flip is worse than silence, because a wrong guess sends the reader to
edit a line that was never the problem. `Diagnostic.token` borrows the source
bytes, so `keepToken` copies it out before the file's buffer goes away.

## Forests and the Interned DAG

`forest.zig` is union-find with path-halving finds, rooted at the minimum member
index. A component's identity is then stable regardless of join order, so a
clustering gets the same canonical member whichever direction it walked its
edges.

`dag.zig` is the substrate under `regex/ast`, generic over payload and arity
because the regex AST is one instantiation rather than the only one. Three
properties fall out of a single rule, that *a node may only be interned after
its children are*.

 1. **Structural equality is identity** – the same shape gets the same `Id`, so
 `a == b` replaces a recursive comparison and common subexpressions collapse on
 the way in (Filliâtre and Conchon, *Type-Safe Modular Hash-Consing*, ML '06).
 2. **Topological order is free** – `child_id < parent_id` always holds, so a
 bottom-up analysis is a forward loop over a flat array with no recursion,
 stack, visited set, worklist, or revisit under sharing. `fold` enforces it by
 construction, since the callback sees only `out[0..i]`.
 3. **Sharing is exploitable** – `power` builds an n-fold combination in
 `O(log n)` distinct nodes by repeated squaring, so `a{1000}` is about 19 nodes
 to every analysis while still lowering to the thousand-state automaton its
 language requires.

Storage is struct-of-arrays on purpose: the ordering invariant exists to make
analyses linear scans, and pointer-linked nodes would hand back the cache misses
it was bought to remove.

A payload holding a slice or pointer whose contents define identity must declare
`hash` and `eql`. Without them it is hashed field-wise and compared with
`std.meta.eql`, which is right for POD and wrong for that.

Interning never removes anything, so a rewrite leaves its superseded nodes in
place. `live(roots)` tells the DAG from the rubble, and `census` counts parents
so a lowering pass knows which fragments are worth caching.

`descend`'s `meet` must be commutative, associative and idempotent, so a node
reached two ways gets the weakest claim both parents support rather than
whichever arrived last. This is deliberately not an e-graph, with no equivalence
class per node and no saturation, because the consumers need one canonical form
cheaply rather than the space of all equivalent forms.

## Leases and Sharding

`lease.zig` gathers the two things a raw `RwLock` makes easy to get wrong. Lease
guards pair acquisition with release, so `release()` drops exactly the mode you
took and a `defer` can never unbalance a shared against an exclusive unlock.

`readReconciled` is the read-mostly dance, written once instead of at every
answer face: enter shared and answer there when the snapshot is fresh so readers
overlap, otherwise drop shared, take exclusive, refresh, and *downgrade* back
(Schmidt and Harrison, "Double-Checked Locking", PLoP '96).

The two reconcile faces differ only on the error path, and choosing wrong is a
double unlock or a leak.

 - **`readReconciled`** – propagates a refresh error with nothing held, suiting
 a caller that registers its `defer release()` after the `try`.
 - **`reconcileHeld`** – returns the error beside a still-live lease, suiting a
 caller already holding a `Read` under a `defer` and therefore obliged to end
 holding one on every path.

`downgrade` is not atomic, since a competing writer may slip into the
release-and-reacquire gap. Downgrade only once every mutation is published and
any staleness a racing writer could introduce is independently re-checked.

`Ward` is writer-preferring, inherited from `std.Io.RwLock`, so a stream of
readers cannot starve a queued refresh. `Latch` covers the one case it cannot, a
thread with no `std.Io` handle at all.

`Latch` is a spin on an atomic swap, neither recursive nor fair, and honest only
under the discipline it enforces by existing: a critical section of a few map or
field operations, never a syscall and never a wait. `tryLock` exists for code
reached from inside a critical section, such as a memory-pressure hand called
from a failing allocation the latch may already be held across.

`parallel.zig` divides work in two shapes because work comes in two shapes.
`shardBounds` weighs items so a few large files cannot stall one thread, while
`evenBounds` splits arithmetically, because weighing 200 M equal-cost
suffix-array rows costs about as much as running a shard.

`fanOut` runs either, and carries the fallback both need. A mid-fan-out spawn
failure must not return with live threads still scanning buffers the caller's
defers would free, so the unspawned tail runs inline on the calling thread.

Three constants hold the crossover policy in one place.

 - **`min_bytes`** (256 KiB) – the search floor below which a sharded face stays
 serial, since thread spawn plus per-shard scratch (a recompiled engine, a span
 VM, an arena) only amortizes once the scan dominates.
 - **`build_min_bytes`** (4 MiB) – the higher floor for index construction,
 which touches every item once with no early exit and no engine to warm, so the
 only cost to amortize is the spawn.
 - **`max_shards`** (16) – the realistic core ceiling, so a giant corpus cannot
 spawn hundreds of scheduler-thrashing threads.

`shardBounds` returns null for "stay serial", whether from the floor, a single
usable core, or a failed allocation, since serial is always correct. `evenBounds`
never returns null and always yields at least one shard, so its caller keeps one
code path; pass it `grain = 64` when shards write into one shared bit-packed word
array, so no two carry a read-modify-write on the same word.

## The Crest Sieve

Crest is the contiguity bound the trigram index concedes. A literal-free
class-repetition pattern such as `[0-9a-f]{8}` or `\d{6}` extracts no required
substring, so every substring-presence prefilter degenerates to a full scan.

It prunes by a different sound necessary condition, in three pieces.

 - **ρ(d), the crest vector** – per document, the longest run of consecutive
 bytes in each member of a fixed family, one O(|d|) pass for K small integers.
 - **ĝ(R), the forced crest** – a sound lower bound on what any match must show,
 folded out of the pattern AST by a min-of-max prefix, best and suffix algebra.
 That half lives with the engine in `../regex/analysis/swell.zig`, since
 deriving it from a second private grammar was a silent false-negative factory.
 - **The sieve itself** – R can match inside d only if some alternative's ĝ is
 componentwise met, so a `Swell` whose alternatives all fall short prunes d, at
 K integer compares per alternative and no byte scan.

Everything rounds down. A construct `swell` cannot certify contributes nothing
or zeroes the vector, quantities saturate at `maxInt(u16)`, and saturation is
monotone on both sides of the compare, so under-pruning is the only failure mode
and the sieve can never manufacture a prune. The proof is
[`research/crest/PROOF.md`](../../../research/crest), §2 and §3.9.

The family is 8 classes across 3 alphabets, so K = 24 lanes, and the third
alphabet is the interesting one. A byte sieve and a codepoint matcher disagree
about what a class *is*: under the default `unicode=true`, `\d{6}` once sieved by
nothing while `[0-9]{6}` pruned 92.8 %.

The `+u` repair measures classes closed under the non-ASCII bytes, sound because
every byte of a multi-byte UTF-8 sequence has bit 7 set, but loose because a
3-byte CJK character spends 3 bytes.

The `+cp` alphabet tightens that without decoding anything, treating continuation
bytes (`0x80..0xBF`) as *transparent*, neither extending nor breaking a run, the
way they are to a human reading one character at a time. The same CJK character
then costs exactly 1, and "was the previous byte a continuation" is answerable
from the current byte alone.

`Swell` is a disjunction rather than a single vector, one ĝ per top-level
alternative, because `R₁|R₂` obliges a match to satisfy only one branch.
Collapsing them into a componentwise min keeps soundness but throws that
structure away: two branches with disjoint forced classes min to 0⃗, a sieve that
prunes nothing.

That was a real outage of the feature. Multi-`-e` reaches the engine as
`(?:a)|(?:b)`, so every multi-pattern search once ran with the sieve silently
stood down. `no_sieve` is now the one spelling of "this run proves nothing",
covering a declined pattern, a PCRE2 arm, or an output mode that must read every
byte.

There are two membership tables. `membership` is the query-side bitset
`Profile.atom` intersects, where a bare continuation byte is in no codepoint
lane, since admitting it would certify a forced run that six lone continuation
bytes do not honor. `keep` is what the document scan reads, where a continuation
byte must hold the run rather than reset it; the two agree everywhere else.

The scan is two interleaved pieces (`ways = 2`) over a padded
`@Vector(32, u16)`, joined by the same prefix/best/suffix concatenation law the
query half uses over the AST, which is what makes cutting the document up exact
rather than approximate.

Padding to a power of two is deliberate: at the odd `K = 24` the identical
storage measured 0.089 GiB/s against a clean 32's 0.713, the signature of a lane
count the autovectorizer cannot shuffle cleanly.

`ways` was re-measured after that fix, and 2 is the corpus optimum at ≈7.9× the
per-byte reference, against ≈6.6× at 4 and ≈5.8× at 1. Two alternatives were
measured and rejected: an `inline for` over plain arrays reads better but spills,
at 3.7× slower in the sharded build that ships, and a bitmap pass classifies more
cheaply but pays a step per run, at 3.8× slower.

Anything that changes the family's meaning must bump `SidecarSchema`'s
`format_version`, which moves its signet and invalidates every persisted
sidecar. The whole membership table sits inside the digest preimage, so a change
cannot be silently narrower than the version claims.

## Semirings

A semiring is two operations over one carrier, where `⊕` picks between
alternatives and `⊗` extends along a path. Both are associative, `⊕` commutes,
`zero` and `one` are their identities, `⊗` distributes over `⊕`, and `zero`
annihilates `⊗`.

That contract is enough to write shortest-path once, after which changing the
semiring changes the question while the code stays put.

 - **`Boolean`** – or and and, from false to true, answering whether a path
 exists at all.
 - **`Tropical(Cost)`** – min and plus, from ∞ to 0, answering what the cheapest
 path costs.
 - **`Viterbi(P)`** – max and times, from 0 to 1, answering which derivation is
 likeliest.
 - **`Counting(N)`** – plus and times, from 0 to 1, answering how many
 derivations there are.

A semiring is a *type* here, not a value. It carries `T`, `zero`, `one`, `add`,
`mul` and `star` as a comptime parameter, so every operation inlines and a
tropical relaxation costs a compare and an add.

`closure` is Lehmann's Gauss-Jordan asteration over a dense `n × n` matrix, in
place, O(n³), no allocation. Read it in the tropical semiring and it is literally
Floyd-Warshall; read it in the Boolean one and it is Warshall's transitive
closure.

In place is safe without snapshotting row and column k, for a reason worth
stating. Pass k rewrites row k to `s ⊗ rowₖ` and column k to `colₖ ⊗ s`, so a
later row reads a doubled `s`, and it lands on the same value because star is
⊗-idempotent in any closed semiring.

`shortestDistance` is Mohri's generic single-source walk, not Bellman-Ford. Each
vertex carries a residual, what has arrived since it was last expanded, and only
the residual is pushed forward, so a vertex re-expands exactly as often as new
weight reaches it.

Closure is the one place a semiring needs care, since `a* = 1 ⊕ a ⊕ a² ⊕ …` is
how a cycle gets summed. Tropical and Boolean have a total `star`; counting does
not, because a reachable cycle means infinitely many derivations, and Viterbi
diverges above 1.

So `star` returns an optional, `closure` raises `error.NoClosure` rather than a
silently wrong finite number, and `shortestDistance` carries a visit budget that
fails closed the same way when handed a semiring that is not k-closed.

Tropical's integer carrier is unsigned by compile error. A negative weight admits
a negative cycle, `star` stops existing, and every guarantee evaporates, so
refusing signed costs is what buys totality.

Costs saturate to `zero`, meaning unreachable, rather than wrapping. That is not
a hack around overflow but the quotient semiring identifying everything at or
above the cap with ∞, where saturating addition stays associative and monotone.

Wrapping is the failure that would actually hurt, since an overflowed repair path
would come back looking *cheap* and win the minimum. `Counting` saturates for the
same reason, a wrapped count reporting a hugely ambiguous parse as unambiguous.

A float carrier needs no saturation, as `inf` already absorbs, but it is
associative only up to rounding. Reach for an integer carrier when the laws must
hold exactly, or work in the log domain, which is `Tropical`.

### Prior Art

 - [Mohri, *Semiring Frameworks and Algorithms for Shortest-Distance Problems*
 (JALC 7(3), 2002)](https://cs.nyu.edu/~mohri/pub/jalc.pdf) – the algorithm
 `shortestDistance` implements, with the residual trick that lets one worklist
 serve idempotent and non-idempotent semirings alike, and the k-closed condition
 saying when it terminates.
 - [Lehmann, *Algebraic Structures for Transitive Closure* (TCS 4(1),
 1977)](https://doi.org/10.1016/0304-3975%2877%2990056-1) – the asteration
 `closure` is, derived from the semiring axioms rather than from arithmetic on
 reals, which is why one triple loop both closes a Boolean matrix and counts
 paths.
 - [Goodman, *Semiring Parsing* (Computational Linguistics 25(4),
 1999)](https://aclanthology.org/J99-4004/) – why a parser wants this rather
 than four parsers, since recognition, Viterbi, inside and derivation counting
 are one algorithm over four semirings.
 - Kuich and Salomaa, *Semirings, Automata, Languages* (EATCS Monographs 5,
 Springer 1986) – the algebra itself, and where "closed semiring" and the
 formal-power-series view of `star` are set up properly.

## Invariants

 - **Caller-owned storage** – `Field`, `crest`, `glob`, `misread`, `pruned` and
 the semiring operations allocate nothing. The four that do (`Forest`, `Dag`,
 the `Dag` sweeps, and `shortestDistance`) take a `gpa` and hand ownership
 straight back, through a `deinit` or as a slice the caller frees.
 - **Crest soundness rounds down only** – under-prune, never a false negative.
 - **Saturate, never wrap** – crest counters, tropical costs and derivation
 counts pin at their cap, because a wrapped value would read as *better* than
 the truth and win a comparison it should lose.
 - **Fail closed on a missing guarantee** – no closure is `error.NoClosure`
 rather than a finite lie, a tie in `nearest` is null rather than a coin flip,
 and a non-unique payload representation is a compile error rather than a silent
 second id.
 - **No persistence opinion** – the artifact digest lives on the wire floor
 beside framing, in `corpus/index/frame/signet.zig`. Crest's `SidecarSchema` is
 the one thing reaching for it, and only to stamp a semantic contract this tier
 defines, since it does not know what a file is.
 - **Three imports out, all downward** – beyond `std`, `builtin` and its own
 siblings, this tier reaches for exactly `portal` in `parallel`, `fault` in
 `sais`, and `signet` in `crest`. Each is a floor declared below `math` in
 `contract/irregex.zone`, so the tier stays reachable from everywhere above it,
 and that is checked rather than hoped for.

## How It Is Proven

Every risky surface is checked against an independent oracle rather than against
itself.

 - **`bits_test.zig`** – a naive bit-at-a-time walk, at both deployed widths
 (u64 masks and u8 SA-IS type maps), over random and adversarial words that are
 empty, full, single-bit, alternating, and boundary-straddling.
 - **`crest_test.zig`** – ρ(d) straight from the definition, plus a schema test
 altering each preimage field to prove it is inside the digest. The Sieve
 Theorem differential is `../regex/analysis/swell_test.zig`, and corpus scale is
 `zig build crest`.
 - **`dag_test.zig`** – a naive recursion that re-walks shared nodes, so a
 disagreement means the sweep is wrong rather than that the two compute
 different things.
 - **`semiring_test.zig`** – the axioms over randomized elements including the
 saturation boundary, since a "semiring" whose ⊗ wraps is not one, then
 Bellman-Ford, BFS reachability, and a topological path-count DP.
 - **`glob_test.zig`** – the segment rules, basename-versus-full-path dispatch,
 class edges, and pathological star backtracking, because a wrong boundary
 silently drops files, which reads as "no matches" and gets trusted.
 - **`lease_test.zig`** – a call-counting oracle over the fast, miss, race and
 error paths of both reconcile faces, plus a threaded reader/writer invariant.
 - **`succinct/parens_test.zig`** – one O(n) explicit-stack scan knowing nothing
 about excess, blocks or min-max trees, over the shapes the range min-max tree
 can get wrong.

`forest`, `misread` and `parallel` keep their tests inline, because each property
reads beside the code it constrains: transitive joins collapsing to one
min-rooted component, a tie yielding no suggestion, and shard bounds tiling
`[0, n)` with no gap or overlap even when no thread can spawn.

Run them with `zig build test`, or `zig build test -Dtest-filter='<substr>'` for
just what you touched. `crest.zig`'s throughput claims are re-checked by
`bench/rungs/crest/`.

## When to Edit

New shared bit operations, a crest class-family change, a concurrency lease, a
succinct structure, a graph or set structure more than one tier can use, a
semiring, or an algorithm over one.

Never file I/O, never ignore-file rules, and never anything that has to ask what
the caller wanted, which is `corpus/` and `exec/cold/`. If a new file would need
to import a tier above this one to make sense it belongs in that tier instead,
and `contract/irregex.zone` is where that is enforced rather than merely
intended.
