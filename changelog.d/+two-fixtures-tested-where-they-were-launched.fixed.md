Two test fixtures asserted `.gitignore` behaviour they were not actually
creating the conditions for, and passed anyway because of where the test binary
happened to be run from.

`.gitignore` governs a repository and nothing else - `Ignore` finds one by
ascending from CWD, ripgrep's require-git rule. Neither the `loadpar` parity
fixture nor the `scoped` session fixtures put a `.git` in the corpus they built,
so their VCS rules were switched on only by the ambient fact that the runner sat
inside this checkout. Run the suite from anywhere else and the rules simply did
not apply:

```
MEMBER: /tmp/gist_loadpar_parity_fixture/foo.log        # `*.log` said drop it
MEMBER: /tmp/gist_loadpar_parity_fixture/sub/ignored.txt # so did `ignored.txt`
```

Both walks agreed on that six-file answer, so the parity half of the test was
still honest - what had quietly stopped holding was every assertion about what
should have been pruned. The scoped suite failed the same way one step further
along: the `.gitignore` it writes mid-test changed no verdict, so the file it
was meant to drop stayed admitted and the count came back one too high.

Each fixture now creates its own `.git`, which is what makes it a repository and
what the production probe actually stats. The assertions are unchanged; they
just describe the corpus under test instead of the directory the runner was
launched from. Caught by running the suite on a bare x86_64 box with no checkout
above it, where both tests went red.
