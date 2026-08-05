# Result 1 — one site, and it was the interner

Measured 2026-08-05 against `zig build test` on macOS arm64, Zig 0.16.0.

Four of the five predictions in [`PREDICTION-1-seams.md`](PREDICTION-1-seams.md)
held. **1c is falsified twice over**, and that is the most useful part of this
dossier: the mechanism I predicted is not the mechanism, and the mechanism that
is really there costs nothing measurable today. Both halves of that are written
up below, because a lane reading only the fix would take away a scarier and
less accurate story than the one the measurements support.

## The sweep

Every `asBytes`, `sliceAsBytes` and `bytesAsSlice` under `src/`, with each
element type resolved and classified by what the bytes reach.

| Where | Type it views | Reaches | Verdict |
|---|---|---|---|
| `corpus/index/phantom/treemap.zig` | `Rec {u32,u32}` · `Ent {…,_pad:u8=0,…}` | disk | seamless — `_pad` is why |
| `corpus/index/crest/sidecar.zig` · `trigrams/codicil.zig` | `crest.Vector = [K]u16` | disk | seamless |
| `corpus/index/postings/persisted_blob.zig` | `[]const u32` | disk | seamless |
| `corpus/index/content/shard.zig` | `u64` | disk | seamless |
| `corpus/index/trigrams/trigram.zig` | `[]u32` | disk | seamless |
| `corpus/fresh/fresh.zig` | `i64` | disk | seamless |
| `kernel/regex/linear/automata/reduce.zig` | `u32` table cells | hash | seamless |
| `kernel/math/mix.zig` (`SliceCtx`) | *any* `T` the caller picks | hash | **unbounded — now gated** |
| `kernel/regex/ast/intern.zig` (`Op.hash`) | `[2]u21` | hash | **the defect** |
| `surface/ffi/contract.zig` | `@memset(asBytes(&out), 0xAA)` | nothing | deliberate poison |

**1a held** — one live site. **1b held** — it is a hash, not a file; every
persisted record in this repository already tiles itself, and `Ent._pad` is the
prior art that says somebody once thought about exactly this. **1d held** — the
site is not a struct with a hole. It is `[2]u21`: `@sizeOf(u21)` is **4** and
`@bitSizeOf(u21)` is **21**, so a pair spans **eight bytes of which forty-two
bits are the bounds** and twenty-two belong to whoever held the allocation
first. Nothing at the call site looks like padding.

## What it cost

`Op.uclass` is `[]const [2]u21` — the scalar ranges of a Unicode class. **Both**
halves read bytes: `Op.hash` through `sliceAsBytes`, and `Op.eql` through
`std.mem.eql(u8, sliceAsBytes(a), sliceAsBytes(b))`.

**I described this wrongly the first time** and the correction is worth more
than the original sentence. I wrote that `hash` read bytes while `eql` compared
values, so the two halves disagreed and the map's own invariant broke. They do
not disagree — they agree, and they are wrong together. The consequence is
narrower and it is still a defect: two byte images of one class compare unequal,
so the DAG **keeps two nodes for one class** rather than corrupting a bucket.

The reason `eql` reached for the byte view at all is the interesting half.
`std.mem.eql([2]u21, a, b)` **does not compile** — Zig will not apply `!=` to
`[2]u21` — so the byte view was the short spelling available, and the byte view
is precisely the one this type cannot honor. A type that cannot be compared the
obvious way pushes every author toward the unsound way.

`scalars.finish` dupes the ranges onto the parser arena, so what sits in the
unowned bits is a function of what that arena was used for before.

The repair reads the ranges as **values**: `Range = extern struct { lo: u32, hi:
u32 }`, which `hasUniqueRepresentation` accepts, so `asBytes` of it is a promise
rather than a hope. `eql` compares bounds. No allocation, no normalization pass,
and the widening is per range at hash time only.

## Then I measured it, and nothing moved

An un-canonical DAG should show up as node count, so I asked. Ten Unicode-heavy
patterns interned on both arms — the shipped byte comparison and the widened
one — with one long-lived allocator across all of them:

| arm | offered | distinct |
| --- | --- | --- |
| byte comparison (before) | 79 | 49 |
| widened bounds (after) | 79 | 49 |

Then the adversarial arm: one arena, `reset(.retain_capacity)` between rounds,
with a **pointer-heavy non-class pattern** parsed in between each round so the
recycled bytes belong to `Node` structs rather than to other bounds. Eight
parses of `[α-ω]`, both arms: **one distinct node, 7/7 matching the first.**

The bytes say why. Dumped raw at every round: `b1 03 00 00 c9 03 00 00`. The
parser's store path **zero-extends** — a `u21` written through
`ScalarSet.addRange` lands as a full four-byte store — so the byte image is
canonical by codegen, not by contract.

So **the defect is latent and the fix buys no number today.** Writing that down
is the point: it bounds what this was costing at zero, and it stops the next
person rediscovering the type and assuming it was expensive.

It is still worth having fixed, and not on principle. `hasUniqueRepresentation`
is false for this type, which means the guarantee is absent — and the absence is
already visible in this repo: `twoWays` in the regression assigns
`dst.* = .{ src[0], src[1] }` and the `0xAA` poison **survives** in the slack,
where the parser's own path zeroes it. Two spellings of a store of one type,
disagreeing about the bytes, in one repository. Today's canonical image is a
property of which spelling the hot path happens to use, at this optimization
level, on this target.

**Blast radius, for the same reason: none moves.** `gist`, `relate` and `blast`
are three faces over this engine and share this interner, so a defect that costs
zero nodes here costs zero there. If it ever stops being latent it stops for all
four at once, which is the argument for the compile-time gates below rather than
for a benchmark row.

### 1c, judged

Its falsifier was: *"build the same value twice, poison the slack of one copy,
and intern both. If the DAG returns one node, either the bits are not reachable
or something else already normalizes them, and the diagnosis is wrong."*

Poisoned **by hand**, the pre-fix code splits the node — the bits are reachable
in principle. Poisoned **by the parser**, through arena reuse with unrelated
data in between, it never splits, because the store zero-extends. So the second
disjunct of my own falsifier is what happened: something does normalize them,
and it is the code generator rather than any code anybody wrote. A normalization
nobody chose and nobody can point at is not a guarantee, which is why the fix
stands — but the prediction's *diagnosis* was wrong, and its own falsifier said
so.

## The near-miss, which is the point

**My first regression test passed, and it was worthless.** It built the two
copies with `@memcpy` from a `.rodata` array of literals — and a copy carries
the *source's* bytes, so the `.rodata` zeros landed on top of the `0xAA` poison
and both sides came out identical under the slack. The test asserted a fix that
was not being exercised.

The helper now assigns each bound as a literal (`dst.* = .{ src[0], src[1] }`),
which is what `ScalarSet.addRange` actually does and what leaves the slack
alone, and the test opens by asserting the two sides **do** differ byte-wise
before it asserts they hash the same. That assertion is the only thing standing
between this test and the first draft of it.

This is the same shape as the bug it tests. `dag_test.zig`'s slice-payload test
was green for the whole life of the defect because both of its operands were
`.rodata` literals, which are zero-filled by the linker; it has been given a
heap allocation and a poison fill for the same reason.

## The gate

Structural, per **1e**, and stated once rather than per site:

- **`frame.seamless(T)`** — a comptime `@compileError` if `T`'s fields do not
  tile it. Applied to `treemap.Rec` and `treemap.Ent`, and to `crest.Vector` at
  the sidecar that writes it. One assertion per *type*, not per reader: a
  `crest.Vector` that failed in `sidecar.zig` fails the build before
  `codicil.zig` maps one back, so a second copy in codicil would be a second
  thing to keep right rather than a second check.
- **`mix.SliceCtx(T)`** now refuses at compile time to be instantiated over a
  `T` with unowned bytes. That is the generic that turns "hash a slice by its
  bytes" into a reusable thing, so it is the one place a future caller can
  reintroduce this without touching any of the code above.
- **Anti-vacuity** rides both. `frame_test.zig` asserts the predicate can still
  say **no** — over `struct { hi: u32, mask: u64 }`, the shape that started
  this — and `intern.zig` keeps a test asserting `[2]u21` really is unseamless,
  because the moment that stops being true the regression test above is green
  for having nothing to get wrong.

`Op` itself is deliberately **not** routed through `seamless`. It is a tagged
union with a slice payload and can never be seamless; the discipline there is
that its `hash` reads values, and the test is what holds that.

## Near-misses rejected

- **`crest.Vector`** looked like the second finding: a named type, persisted,
  read back with `bytesAsSlice` in two different modules. It is `[K]u16` and has
  no slack. Gated anyway — as a precondition on a type that could grow a tag,
  not as a repair.
- **`contract.zig`'s `@memset(asBytes(&out), 0xAA)`** is an `asBytes` over a
  struct with padding and is entirely correct: it is poisoning an FFI out-param
  on purpose, so the test can prove the callee wrote every field.
- **`reduce.zig` hashing `u32` table cells one at a time** reads like it is
  working around something. It is not; `asBytes` of a `u32` is four owned bytes
  and the loop is about column identity.

## The instrument I trust least

**`std.meta.hasUniqueRepresentation` on a type I have not read.** It is the
right predicate and it is the one the standard library itself consults before
it will `memcmp`, but it answers a question about *layout* and I kept reading it
as a question about *safety*. It says `true` for `extern struct { lo: u32, hi:
u32 }` — correct — and it also says `true` for a struct whose fields tile it
perfectly and are never all assigned. Tiling is necessary and not sufficient:
`flat` in the sibling repo exists because a writer can leave an owned field
unwritten just as easily. A gate built only on this predicate would pass a
record that is fully described and half filled in.

Second, and specific to this sweep: **a byte-identity check on a compiled
binary is not an oracle for behavioral identity.** Two builds of this tree
differing only in comment lines produce different `sha256` and identical
behavior, because the line tables move. I predicted identical bytes, got
different bytes, and had to go and measure the thing I actually cared about.
