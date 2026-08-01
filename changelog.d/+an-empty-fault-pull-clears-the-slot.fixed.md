`irregex_last_fault` now clears the struct when there is no fault, instead of
leaving your own stack in it.

It used to return `IRREGEX_OK` and touch nothing, which sounds harmless and
isn't: a host that cleared only the field it went on to test kept whatever
garbage was in the rest, and nothing downstream could tell that `at` had never
been set. Two bindings independently had to defend against it, which is the tell
that it was the seam's problem and not theirs. So the seam does it once - every
field zeroed, and `name` goes to `""` rather than NULL so it keeps its promise.

While I was in there I wrote down the rule both of those bindings had to work
out for themselves: don't follow an `IRREGEX_STALE` with a fault read. A
declinature installs nothing, the slot is per-thread and never consumed, so what
you'd get back is an *earlier* call's fault wearing a fresh face. Decide a
declinature from the status code and stop.
