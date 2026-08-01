CI now runs the whole suite a second time under an environment that disagrees
with it, so a test that quietly reads the operator's machine fails here instead
of on someone's laptop.

This exists because the class it catches is invisible to every gate we had.
Fourteen tests were reading the ambient skip overlay - fourteen, at once, all of
them green on a clean box and red on a configured one. Nothing in `zig build
test`, `zig fmt --check`, or the four ratchets can see that, because the code is
correct and the suite passes; what is wrong is that the suite passes for a
reason it never stated. The only instrument that finds it is running the tests
somewhere the assumption is false.

So the new `hermetic` job runs `zig build test` twice, once with `GIST_SKIP`
naming the twenty-three directory names a real checkout is most likely to
contain, and once with a `<GIST_DIR>/skips.list` holding the same list. Both,
rather than one and an argument that the other is equivalent, because they are
separate vectors into the same overlay and only the first names a skip in a
variable - a fixture could lean on the file without any environment variable
mentioning it. A charter `skip` is the third vector and is not covered here,
since it lives in the tree rather than around it and a hostile one would have to
be committed to have any effect.

One host, because the defect is reading the environment and not the platform.
It cannot share the engine job's cache: Zig keys the cache on the environment,
and the environment is exactly what moves, which is the cost of the job and also
the reason it genuinely re-runs instead of replaying a green.

Proven to have teeth rather than assumed: over a tree holding `src/a.txt` and
`other/b.txt`, a plain `gist -l` finds both, and each of the two vectors on its
own finds only `other/b.txt`. A job whose hostile environment the engine ignored
would be green forever and prove nothing, which is the failure mode worth
checking before trusting a gate that is supposed to stay quiet.
