Bounding what a resident daemon may hold stopped gist compiling for every 32-bit
target.

Two things in the new warden are 64-bit by declaration and can't be on a 32-bit
machine. The ration is a `u64` count of bytes the machine will lend, handed
straight to an allocator that takes a `usize` - and the resident ceiling is 4 GiB
*exactly*, which is one byte past what a 32-bit `usize` holds (the
`GIST_MEMORY_MB` override is unbounded outright). And the two diagnostic counters
were `std.atomic.Value(u64)`, which has no lock-free instruction on i386 or ARM32,
so it's a compile error there rather than a slow path.

So `ration.addressable()` now narrows the machine fact to what the process can
address, once, in the policy that owns the number - `standdown` still compares the
unnarrowed one, because what this daemon can address says nothing about what
another already holds - and `refusals`/`relieved` are one machine word each like
`held` and `crest`, still reported as `u64` so the reported shape doesn't depend
on the word size it was counted in.

Found by the portability sweep, which is the point of having one: all five 32-bit
rows (three ARM32 ABIs, two x86-32) had gone from `conforms` with 12/12 probe
classes byte-identical to `unbuilt`, and nothing else noticed, because every host
that runs the test suite is 64-bit. They conform again.
