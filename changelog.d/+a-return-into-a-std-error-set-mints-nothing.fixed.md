The `fault-taxonomy` ratchet was flagging `portal.ntMap` for three error names it
does not own. This is a detector fix, not a code change; the gate was wrong and
the source was right.

`ntMap` is declared `MapError!Mapping`, and `MapError` is `std.posix.MMapError`.
`MappingAlreadyExists`, `MemoryMappingNotSupported` and `PermissionDenied` are
members of that set, so the Windows arm is not minting private vocabulary - its
signature obliges it to say exactly those words. The tell is the other arm of the
same `pub fn map`: on POSIX it returns `std.posix.mmap` directly, which produces
those three identical names from inside std, where the ratchet counts nothing. So
they were already crossing irregex's API surface on every target; only the
platform fork decided whether the token sat in our file or std's. Declaring them
in `[fault_domains]` would have been the actively worse fix - it would have
claimed std's vocabulary as ours, and parked `PermissionDenied` next to
`AccessDenied` in one domain, which is the synonym pair this gate exists to
prevent. std keeps those two apart on purpose; one is a mode conflict on the
descriptor, the other is a `noexec` mount.

So the missing rule is the mirror of the consuming-position one already there: a
`return error.X` from a function whose *declared* error set resolves to std's own
is restating std, not accreting a sixth spelling of `Corrupt`.

The reason this is not just a hole I cut for myself is that the compiler enforces
it, not the driver. A function with an explicit error set may only `return` a
member of it, and Zig rejects anything else at that token - so smuggling a new
fault name into one of these bodies is a build failure, not a finding the gate
learned to ignore. The rule never has to know what std's members are; it only has
to be sure the declared set really is std's. Everything else is fences around
that: it is per function and innermost, so a nested `fn` is judged on its own
signature and the rest of the file is untouched; it covers `return error.X` only,
because a name bound to a local or declared in a set inside the body is never
coerced into the declared set; an inferred `!T` never qualifies, since inferring
your error set from whatever you return is the opposite of a closed vocabulary;
and it engages only in a file that binds `std` to `@import("std")` and nowhere
else, resolving one level of local aliasing, with a name bound twice resolving to
nothing. `const MapError = error{ Sneaky };` and
`std.posix.MMapError || error{ Sneaky }` both stay counted.

Seventeen new detector tests pin that, and fourteen of them are adverse: a
private set wearing the alias's name, an alias rebound in an inner scope, a union
that sneaks a private member into a std-looking signature, a rebound `std`, a
file that mixes one good `std` binding with one bad one, a file that never binds
`std` at all, an alias cycle, an inferred signature, a nested closure, a value
that is never returned, a set declared inside an excluded body, and two parsing
fences (a function-typed parameter and a prototype, neither of which declares a
body that could enclose anything). One proves the exclusion is per function
rather than a whole-file amnesty: a new spelling accreting beside a legitimately
excluded std-set function is still caught. Across the whole tree the rule changes
exactly three findings in one file, and `sheaf.zig`'s sixteen `error.Declined` -
the real debt - are untouched.
