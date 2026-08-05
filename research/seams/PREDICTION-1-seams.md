# Prediction 1 — where else a type's unowned bytes become a value

Written before the sweep that decides it.

A lane on the sibling parser [outliner](https://github.com/The-Billy-Company/outliner)
found uninitialized memory reaching a persisted artifact: two record types were
handed to `std.mem.asBytes` / `sliceAsBytes` and written to a folio, and both
have bytes no field owns. `lexicon.Head` is sixty bytes of fields in a type
`@sizeOf` rounds to sixty-four; **`Dfa.PatRun` is ours** — `struct { hi: u32,
mask: u64 }` under auto layout, twelve bytes of fields rounded to sixteen. So
four bytes of stack per automaton and four of heap per pattern run went into
every folio ever written.

Two record types were found by chasing one symptom. Nobody has asked whether
there are others, in either repository. This dossier is that question for
irregex.

The shape of the class, stated once so the predictions can be about *this* and
not about padding in general: a type has bytes no field owns, some code turns a
value of that type into a byte sequence, and something downstream treats that
sequence as if it meant the value. The three downstreams are not the same
severity — a **file** leaks process memory, a **hash** silently splits equal
values, and a buffer **fully rewritten before use** is fine.

## Prediction 1a — the sweep finds at least one live site

> **Prediction:** enumerating every `asBytes` / `sliceAsBytes` / `bytesAsSlice`
> in `src/` and resolving each one's element type finds **at least one** type
> with bytes no field owns, beyond the two already known.
>
> *Falsifier:* every element type at every site has
> `std.meta.hasUniqueRepresentation`. That would make outliner's two an isolated
> pair rather than an instance of a class, and this dossier a clean negative.

## Prediction 1b — it reaches a hash, not a file

> **Prediction:** whatever the sweep finds is on a **hash or comparison** path
> rather than a disk path, because irregex's persisted records already apply the
> discipline outliner's were missing. `corpus/index/phantom/treemap.zig` carries
> an explicit `_pad: u8 = 0` on `Ent` precisely so `sliceAsBytes` has nothing
> unassigned to write. The habit exists here; it is the hash sites that nobody
> thought of as serialization.
>
> *Falsifier:* a persisted record with slack — a type written to an index file
> whose fields do not tile it. That would be strictly worse than outliner's bug,
> because a search index is shared between machines.

## Prediction 1c — the damage is that `hash` and `eql` disagree

> **Prediction:** the mechanism is not "the hash is wrong". It is that a
> byte-wise `hash` paired with a value-wise `eql` are answering **different
> questions about the same pair of values**. Zig's `std.mem.eql` compares
> element by element for a type without a unique representation, so it ignores
> the unowned bits; a `Wyhash` over `sliceAsBytes` cannot. Two values `eql` calls
> equal therefore hash differently, a hash map stores both, and a hash-consing
> interner silently stops interning.
>
> *Falsifier:* build the same value twice, poison the slack of one copy, and
> intern both. If the DAG returns one node, either the bits are not reachable or
> something else already normalizes them, and the diagnosis is wrong.

## Prediction 1d — `u21` is where it hides

> **Prediction:** the type is not a struct. Every struct in this tree with an
> obvious hole has already been looked at at least once, and a struct's padding
> is the thing people know to look for. The one that gets through review is an
> integer that is not a whole number of bytes wide — `@sizeOf(u21)` is **four**
> while a store writes **twenty-one bits**, so eleven bits per value are
> whatever the allocation last held, and nothing about `[2]u21` looks like
> padding at the call site.
>
> *Falsifier:* the site the sweep finds is an ordinary struct with an alignment
> hole. Then the interesting part is only that we missed it, not that it was
> hard to see.

## Prediction 1e — the gate has to be structural, not observational

> **Prediction:** a byte-equality check that notices after two runs disagree
> cannot catch this class before it ships, because whether it fires depends on
> what the allocator last held. The population is not even stable: against
> outliner's writer, two mints called nine of thirty grammars unstable and six
> mints called fourteen, and there was never a fixed set. So the gate has to be
> a **compile-time** assertion that a type's fields tile it, applied at the
> boundary where bytes become the value's identity.
>
> *Falsifier:* a structural gate that cannot be stated without listing types by
> hand. A roster somebody has to remember to extend is the same bug wearing a
> checklist, and would mean the observational gate is genuinely the best
> available.

## What would make this dossier worth nothing

If the gate passes because it examined an empty set, or because its predicate
says yes to everything. Both read exactly like a clean bill of health. Any
assertion this dossier lands has to be paired with a check that the set was
non-empty **and** that the predicate can still say no.
