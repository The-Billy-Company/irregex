The caliper's prefilter memo recognized a haystack by its base address, and an
allocator hands a freed block straight back - so two haystacks that never
coexisted could share a pointer, and the second inherited the first's answer.
`\bcat\b` reported no match in `a cat sat`.

The memo caches a claim about BYTES - *the first byte the prefilter admits at or
after `from` is at `at`* - and the walk spends it by skipping `[from, at)` as
provably matchless. Proven over other bytes it skips a real candidate, and the
forward jaw then finds nothing after it. That jaw's `none` is a verdict and not a
decline, so the span engine returns no match and the pattern is reported absent.
Nothing above it can catch that, because a wrong miss looks exactly like an
honest one.

It surfaced through the Python `PatternSet`, which is where the shape is easiest
to hit: a fresh set per subset, a temporary UTF-8 buffer per call, and CPython's
size-class free list handing the same block back. A candidate remembered at
index 3 of one text skipped the real one at index 2 of the next. The same walk
over the same bytes with fresh scratch answered correctly, which is what made it
read as a flake - it moved with the interpreter's allocation history rather than
with the pattern, so it landed on one Python version per run and a different one
the next.

The memo is now a local of the walk that reads it instead of state on the jaw, so
it cannot outlive the region it was proven over: `forwardEnd` pins one region and
one prefilter for its whole length, which is exactly as long as the answer stays
true. Being a local is what makes the stale read unrepresentable rather than
merely unlikely, and it drops the address and prefilter fields from the key,
since inside one walk both are constant by construction. The saving the memo
exists for is intact - it still collapses the candidate scan across the landings
of one glide run - and span walks measured neutral from adjacent matches out to
64 KB gaps.
