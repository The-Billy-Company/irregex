The public surface is now a contract with a gate over it. Every top-level `pub`
in `src/root.zig` has a row in the new `contract/exports.toml` naming its tier -
`stable`, `provisional`, or `internal` - and stating in one line who it is for,
and `quality/surface/check.py` fails when the two disagree in either direction.

`contract/irregex.zone` already governed what a file inside this package may
reach, and nothing governed what the package hands out. That asymmetry is how
seventeen `regex_*` names shaped by one bench harness ended up in the front door
with no note saying who they were for, beside a `commands` namespace that
existed because a CLI once wanted that spelling. Someone arriving at the root
could not tell the vocabulary every signature is written in from a door opened
for one benchmark, because the file gave them no way to tell.

A retired spelling carries `now = "<address>"` saying where the name went, and
the gate checks that address still resolves - so a migration note cannot outlive
the thing it points at, which is the failure that makes a deprecation worse than
no deprecation. A name declared in two tiers, a row with an empty `why`, and a
contract that stopped parsing are each their own error rather than fifty-three
lines of phantom drift.

The schedule is checked too, and that check earned its place immediately: the
first draft of this contract scheduled the retired block for removal in `0.5.0`,
on a package shipping `1.0.0`. Nothing would ever have come due, so the aliases
would have been carried forever while reading as temporary. `[deprecation]
remove_in` is now compared against `build.zig.zon`, and a target the live
version has already passed fails the gate. The real target is `2.0.0`, because
these names shipped in 1.0.0 - thirteen of the fifteen have no consumer left in
the ecosystem, which is an argument for keeping them rather than against it,
since an alias nobody here imports is exactly the one an outside consumer of
1.0.0 might.

It reads text and needs no Zig, like the ratchets it runs beside. The `why` is
the load-bearing part: a name nobody can write one for is a name that should not
be public.
