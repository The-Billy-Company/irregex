# Prior art — `regex-automata`, and the field behind it

The lineage of every fast regex engine runs through one 1968 paper and one 2007
essay. Ken Thompson, *Programming Techniques: Regular expression search
algorithm* (CACM 11(6), 1968), gave the NFA construction whose size is linear in
the pattern and the simulation whose time is linear in the haystack. Russ Cox,
*Regular Expression Matching Can Be Simple And Fast* (2007), plus the RE2
implementation, gave the modern packaging: lazy determinization with a bounded
cache, a bitstate backtracker for small inputs, a one-pass DFA for captures, and
prefilters in front of everything. `regex-automata` is the most complete
realization of that program in existence. It is also the thing to beat.

What follows is what it does, in mathematics, with the seams marked. Quotes are
verbatim from the clone at `upstream/regex/`; the crate is MIT/Apache-2.0 and none of
it is vendored into this tree.

## 1. The alphabet: their weakest link, and they know it

A DFA transition table is `states × alphabet`. Shrink the alphabet and you
shrink the table quadratically in effect, because a smaller table means more of
it lives in L1. Everyone therefore quotients the 256 bytes into equivalence
classes: bytes that no state distinguishes share a column.

Their `ByteClassSet` records **range boundaries**. Each class in the AST marks a
cut at the byte before each range start and at each range end; the classes are
the intervals between consecutive cuts. This is fast to compute and it is not the
coarsest correct partition:

> Note though that this does not compute the minimal set of equivalence classes.
> For example, in the regex `[ac]+`, both `a` and `c` are in the same equivalence
> class for the same reason that `a` and `b` are in the same equivalence class in
> the aforementioned regex. However, in this implementation, `a` and `c` are put
> into distinct equivalence classes. The reason for this is implementation
> complexity. In the future, we should endeavor to compute the minimal
> equivalence classes since they can have a rather large impact on the size of
> the DFA.
>
> — `regex-automata/src/util/alphabet.rs:672`

That is the gap, conceded, with the cost estimate attached. The fix requires
"changing the representation here, which is only able to group contiguous bytes
into the same equivalence class" — and that is precisely the representation we do
not use. We refine by the whole transition **set** of each consuming state, so
`[ac]` induces the two-block partition `{a,c} | rest`. Non-contiguous by
construction.

They then pad. `stride2` is a shift, so the row width is the alphabet size
rounded up to a power of two, capped at 512. The padding buys a shift instead of
a multiply for state indexing. We premultiply state IDs at build time and index
by exact class count, so we pay neither the multiply nor the padding.

## 2. Determinization: the state is a set plus a context

The classical subset construction says a DFA state is a set of NFA states. Their
refinement, in `util/determinize/state.rs`, is that a DFA state is an **ordered**
set of NFA states plus the look-behind context that got you there — packed into a
single `Arc<[u8]>` whose bytes are the identity used for interning:

- flags: is-from-word, is-half-crlf, match-ness, start-ness
- `look_have`: which zero-width assertions hold at this position
- `look_need`: which the remaining machine still cares about
- pattern IDs for match states
- NFA state IDs, delta-varint encoded

Two consequences worth stealing and worth rejecting, respectively.

**Worth understanding:** interning on the byte image makes state equality a
`memcmp`, and the `look_need` field means two states that differ only in an
assertion nobody downstream inspects collapse to one. That is a cheap partial
minimization performed *during* determinization — Hopcroft's third suggestion to
himself, already half-implemented.

**Worth rejecting:** the order is always preserved, because leftmost-first
priority needs it. So even a boolean `is_match` search carries the cost of
ordered states, and two NFA-state sets that differ only in priority order become
two DFA states. Our boolean determinizer interns the unordered set — strictly
fewer states on the same pattern, for the question that is asked most often. We
pay by needing a second construction for spans.

The look-behind-in-the-state choice is a real fork in the road. We instead refine
the byte alphabet by word-ness and split the transition table, keeping the state
set small and paying in table area. Neither is obviously right; §4 of `CLAIM.md`
puts it up for measurement rather than assertion.

## 3. The hot loop, and the trick we do not have

Their inner loop is:

```rust
let byte = haystack[at];
sid = dfa.next_state(sid, byte);
if sid <= special.max { /* one of: dead, quit, match, accel, start */ }
```

The comparison is the whole idea. States are **shuffled at build time** so that
every "special" state occupies a contiguous prefix of the ID space, and the
sub-ranges nest: dead and quit first, then match, then accelerated, then start.
So `id <= max_special` is one unsigned compare that rules out five conditions at
once, and only when it fires do you sort out which. `dfa/special.rs` is the
bookkeeping for that shuffle.

Ours does a dependent load: `is_match[sid >> shift]`, a second cache line touched
per byte, on the byte after the transition load that produced `sid`. That is the
single clearest algorithmic borrow available to us, and it is better than a
borrow, because their version needs the power-of-two stride to recover an index
and ours does not. Premultiplied IDs are monotone in the state index, so if the
match states occupy `[lo, hi]` then `s ∈ [lo·ncls, hi·ncls]` iff the state
matches — one compare, exact stride, no padding. We can take their trick and keep
our smaller table.

## 4. Minimization: shipped, slow, off

`dfa/minimize.rs` is Hopcroft, O(ns log n). Its author's assessment, verbatim:

> This code has had some light optimization attention paid to it, particularly in
> the form of reducing allocation as much as possible. However, it is still
> generally slow.

And the config:

> minimization can take around an order of magnitude more time than compiling the
> initial DFA via determinization. […] This option is disabled by default.

So in practice `regex-automata` ships non-minimal DFAs over a non-minimal
alphabet. Both of those multiply out into table size, and table size is L1
residency, and L1 residency is throughput. This is the largest single opening in
the crate.

Our `symbolic/minimize.zig` is Moore refinement, O(n²·k) worst case and linear in
practice, and it runs on the symbolic path today — but not on the byte path. The
asymmetry is ours to close, and the SP-lattice framing in `README.md` says how:
Moore and the sieve harvest are the same refinement engine at two stopping
points.

## 5. The meta layer: heuristics all the way down

Above the engines sits `meta/strategy.rs`, choosing between five strategies by a
fixed priority: literal-only `Pre`, then `ReverseAnchored`, `ReverseSuffix`,
`ReverseInner`, then `Core`. `Core` itself is a ladder — full DFA, else lazy DFA,
else one-pass, else bounded backtracker, else Pike VM — where a build failure or
a search-time quit escalates *up* the tier list, never back down.

The reverse strategies are the genuinely clever part, and the part with the
sharpest failure mode. `ReverseSuffix` finds the longest common suffix literal,
scans for it, then runs an anchored **reverse** DFA leftward to find the start.
Sound only if no earlier suffix hit could be interior to a real match, which
`reverse_suffix::has_no_earlier_match` proves conservatively — fixed-length
prefix, or a disjoint separator class, or a prefix that cannot embed the suffix
bytes. Otherwise: bail. `ReverseInner` does the same with a literal in the
middle, then reverses to the start and forwards to the end.

Both carry a `min_start` floor, because without it repeated candidates re-scan
overlapping haystack and the search goes quadratic. Hit the floor and the engine
raises `RetryError::Quadratic` and the whole strategy silently downgrades to
`Core` for that search. Correctness is preserved by abandoning the optimization,
which is the honest design; it also means the fast path is a bet that can be lost
at runtime with no telemetry.

Beneath that, the literal layer. Its own header:

> literal optimizations are generally a black art
>
> — `regex-syntax/src/hir/literal.rs:14`

The mathematics is a semiring on literal sequences — `Seq` is `Some(finite
union)` or `None` meaning infinite, concatenation is cross product, alternation is
union, and every operation is guarded by ad-hoc limits (10 per class, 10 per
repeat, 100 bytes per literal, 250 total). Then a pipeline of heuristics: a
byte-frequency `rank` table to promote `memchr`, "poison" literals discarded when
a single byte ranks ≥250, an `ATTEMPTS` ladder of `(len, count)` pairs tried in
order, and a revert-if-it-got-worse escape at the end. Prefilter choice is a
first-match cascade: memchr, memchr2, memchr3, memmem, Teddy, byteset,
Aho-Corasick. `is_fast()` is a build-time guess, not a measurement, and only the
reverse strategies consult it.

The candid annotations run the length of the crate — "I have not benchmarked it"
on the trait-object-versus-enum question, "kind of just an arbitrary number" on
the 500-needle Aho-Corasick threshold, "educated but conservative guess" on
Teddy's fast threshold, "This hasn't been litigated quantitatively with
benchmarks. Just a hunch." on the backtracker's 128-byte cutoff, and on the
memory pool: "Note that I am not entirely happy with this pool", whose
eight-way sharding he calls "untenable" on 32-to-128-core machines.

I read that as an invitation. Every one of those numbers is a place where a
measured decision beats a guessed one.

## 6. What they have that we do not

Honest accounting, in rough order of value:

1. **Special-state ID partitioning** (§3) — one compare replacing a dependent
   load, every byte.
2. **An EOI column instead of a duplicate table.** They reserve alphabet slot
   `len-1` for end-of-input, so a single table answers both interior and final
   transitions. We build `trans_in` *and* `trans_fin`, twice the area, and the
   second exists only to let the last byte behave differently.
3. **State acceleration beyond the start state.** Any state whose escape set is
   ≤3 bytes gets a `memchr`-class skip while it loops. We accelerate the start
   state only, so an interior class-run still walks byte by byte.
4. **A serializable, zero-copy wire format.** `from_bytes` is constant-time given
   alignment and native endianness — build once, embed or mmap forever.
5. **Reverse-inner literal search.** For patterns whose selective literal is in
   the middle, nothing we have finds it.
6. **Sparse DFA.** A variable-width state representation trading a per-transition
   binary search for a much smaller table; a real option for cold-start.
7. **A general one-pass engine.** Ours bails at 2048 states and on ambiguity;
   theirs is more permissive about what qualifies.
8. **`look_need` collapse** — partial minimization for free, during
   determinization.

## 7. What we have that they do not

1. **A coarser alphabet by construction** (§1) — set-refinement, not
   range-cutting; the thing they filed as future work.
2. **Determinization over a predicate alphabet.** `symbolic/` determinizes over
   minterms of codepoint predicates and then products with a UTF-8 decoder,
   instead of walking a byte-level range trie. For large Unicode classes this
   changes the shape of the construction, not just its constants.
3. **The SP-quotient sieve.** A deliberately non-language-preserving quotient
   used to refute. They have no over-approximating automaton at all.
4. **Register-resident execution.** `shuffle/` folds the transformation monoid
   through a SIMD permute; `parabix/` simulates bit-parallel. Both keep the whole
   machine in registers for small enough state counts. Neither exists in Rust.
5. **Unordered boolean determinization** (§2) — a smaller automaton for the
   yes/no question.
6. **Minimization that actually runs** — on the symbolic path, by default.

## The papers behind the seams

- Thompson, *Regular expression search algorithm*, CACM 11(6), 1968 — the linear
  construction.
- Hartmanis & Stearns, *Algebraic Structure Theory of Sequential Machines*,
  Prentice-Hall 1966 — the SP-partition lattice that unifies our `reduce/`.
- Hopcroft, *An n log n algorithm for minimizing states in a finite automaton*,
  1971 — their minimizer.
- Moore, *Gedanken-experiments on sequential machines*, 1956 — ours.
- Cox, *Regular Expression Matching Can Be Simple And Fast*, 2007, and the RE2
  source — lazy DFA, bitstate, one-pass captures.
- D'Antoni & Veanes, *Minimization of symbolic automata*, POPL 2014, and
  *The Power of Symbolic Automata and Transducers*, CAV 2017 — the predicate
  alphabet our `symbolic/` is built on.
- Cameron et al., *Bitwise Data Parallelism in Regular Expression Matching*,
  PACT 2014 — Parabix.
- Hyperscan's Teddy, via BurntSushi's `aho-corasick` port — the SIMD multi-literal
  prefilter, and the naive verification step it leaves on the table.
