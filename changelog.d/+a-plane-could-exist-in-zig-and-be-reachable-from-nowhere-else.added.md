Every promised export now says whether a C host can reach it. `contract/exports.toml`
gained a `[door]` table naming one `include/irgx.h` symbol per plane, and a
`[door.none]` table carrying the reason a plane has none, and `quality/surface/check.py`
holds all thirty-eight to it: twenty-four with a door, fourteen without and saying so.

The hole was structural, not an oversight anyone could have caught by reading. The
zone contract governs what a file inside this package may reach. The export gate
governs what the package hands a Zig caller. The parity gate compares the three
bindings — and every lane in it starts from the ABI. So a plane that never got an
`export fn` was absent from the header, absent from all three bindings, and
reported by nobody, while being correct, tested and documented in Zig.

That is the shape of what just landed: the corpus planes were finished long before
a C host could open a tree, and the only thing that eventually noticed was a
product face minting its own cursor shim because the ABI published a regex matcher
and called itself a search toolkit.

A `[door.none]` row is a decision on the record, weighted like a waiver. Two species
live there. One is the product — the ranking weights, the rg-shaped output, the flag
grammar, the machine-local preferences file — where an ABI verb would publish our
editorial judgment as somebody else's contract. The other is the floor: `math` is
generic over comptime types, and the pieces a search verb needs cross the ABI inside
the verb, as `irgx_walk_term` and as the plan `irgx_sieve_describe` reports.

Comments are stripped before the header is read, because this header now carries a
paragraph naming the doorless planes and a rule reading prose would take that
paragraph as proof they have doors.

`[internal]` is exempt and may not be listed. It promises nothing to anyone, so
whether C can reach it is not a question it owes an answer to.
