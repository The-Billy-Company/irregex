The status vocabulary is now gated against every artifact that restates it.
`contract/engine.toml` declares it once and three places spell it again: the
`Status` enum in `src/surface/ffi/contract.zig`, the `IRREGEX_*` defines in
`include/irregex.h`, and the error sets in `src/fault.zig`. The contract's
argument for declaring it in one place was that a single gate could then cover
all of it. That gate did not exist. In any language: no Zig test parsed the
contract, and the Rust and Go mirrors, which do resolve the file, never asserted
this table against their own constants. It was a declaration nothing compared
anything to.

`bindings/python/tests/test_contract.py` is that comparison — the Zig enum
against the table, the C defines against the `c` macro each row names, each
fault domain against the Zig error set its key capitalizes to, `fault.Fault`'s
union against the taxonomy's total membership, `fault.Decline` against
`[decline_reasons]`, and the rule that every fault status names an existing
domain and no two claim the same one.

Nothing is listed twice. Every expectation is derived from the pair being
compared, including the awkward one: nothing here knows that `out_of_memory`
answers to `IRREGEX_OOM`, because the contract's `c` field says so and the
assertion reads it from there. Rename a macro in both places and the gate
follows; rename it in one and the gate stops you.

It fails closed. An artifact it cannot find or read is a failure, never a skip —
this repository has already had a parity test skip on an unresolvable path for a
whole release while the thing it guarded drifted, and a gate that goes quiet
when its subject moves is precisely the drift it exists to catch.

Each of its seven assertions was checked by mutation: drift the Zig enum, drift a
C value, mint a status macro the contract does not declare, drop a member from a
Zig error set, add a fault the taxonomy does not name, rename a decline reason,
point a status at a domain that does not exist. Every one of the seven is caught,
and the suite still passes unmutated.
