A daemon-served no-match reconstructs the full query shape, scope included.

The warm client re-derives a `Shape` to emit the same guidance the cold engines
do, and the constructor it called took the pattern, `-F`, and the resolved case
state - but not the roots, and not `-v`. So the identical query answered warm and
cold produced different stderr: cold knew the caller had scoped the search and
could offer to widen it, warm silently could not, and an inverted match got advice
written for a normal one. The information was sitting in the `Request` the
classifier had already parsed; it just was not being passed.

`shapeWarm` takes both, so the two tiers say the same thing about the same query.
This is what lets the new scope-versus-corpus sighting reach the warm path at
all - an evidence probe against roots that were dropped on the floor has nothing
to compare against.
