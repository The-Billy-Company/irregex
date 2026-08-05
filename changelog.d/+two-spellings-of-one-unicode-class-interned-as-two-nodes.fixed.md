A sibling parser found uninitialized memory in its own persisted records and
asked whether this engine had the same class of defect. It had one, in the AST
interner: `Op.uclass` is `[]const [2]u21`, and both `hash` and `eql` read it
through `std.mem.sliceAsBytes`.

`@sizeOf(u21)` is four and only twenty-one bits are a bound, so eight bytes of a
range carry forty-two bits of set and twenty-two bits of whatever the allocation
last held. Two byte images of one class therefore compare unequal, and the
hash-consed DAG keeps **two nodes for one Unicode class** — after which the
alphabet, the determinization, and the automaton every consumer receives are
downstream of a graph that failed to canonicalize.

The reason `eql` read bytes is the part worth keeping. `std.mem.eql([2]u21, …)`
**does not compile** — Zig will not apply `!=` to that type — so the byte view
was the short spelling available, and it is the one this type cannot honor. A
type that refuses the obvious comparison pushes every author toward the unsound
one. Both halves now read values: `hash` widens each range through
`extern struct { lo: u32, hi: u32 }`, whose fields tile it, and `eql` compares
bounds.

**Measured, and nothing moved.** Ten Unicode-heavy patterns interned on both
arms give the same 79 offered / 49 distinct. An adversarial arm — one arena,
`reset(.retain_capacity)`, a pointer-heavy non-class pattern parsed between
rounds so the recycled bytes belong to `Node` structs — interns eight parses of
`[α-ω]` to **one** node on both arms. The raw bytes say why: `b1 03 00 00 c9 03
00 00` every round, because the parser's store path zero-extends. So the defect
was latent, it was costing zero, and `gist` / `relate` / `blast` inherit that
same zero. The number is recorded so nobody rediscovers the type and assumes it
was expensive.

It is still a fix rather than a formality: the guarantee is absent, and the
absence is visible in this repo. The regression's `twoWays` helper assigns
`dst.* = .{ src[0], src[1] }` and the `0xAA` poison **survives** in the slack,
where the parser's own path zeroes it — two spellings of one type's store,
disagreeing about the bytes. Today's canonical image is a property of which
spelling the hot path uses, at this optimization level, on this target.

The near-miss: my first regression built the second copy with `@memcpy` from a
`.rodata` literal, which copies the source's zeroed slack over the poison, so it
**passed against the unfixed code**. A test that reproduces a bug only when the
bug is absent is worse than no test. It assigns element-wise now and opens by
asserting the two sides really do differ byte-wise. `dag_test.zig`'s slice
payload was green for the whole life of this defect for exactly that reason and
has been given a heap allocation and a poison fill.

The rule is now structural in three places. `frame.seamless(T)` is a comptime
`@compileError` when a type's fields do not tile it; `phantom/treemap.zig`'s
`Rec` and `Ent` assert it — which is what `Ent._pad: u8 = 0` has always been for
and why it cannot be deleted as unused — and `crest/sidecar.zig` asserts it of
`crest.Vector` before writing vectors to disk. `mix.SliceCtx(T)` refuses to
instantiate over an element type with unowned bytes at all, so the shape cannot
be respelled through the shared context. Anti-vacuity is a test that the
predicate still says **no**, over `struct { hi: u32, mask: u64 }` and over
`[2]u21` itself, because a predicate that says yes to everything reads exactly
like a clean sweep.
