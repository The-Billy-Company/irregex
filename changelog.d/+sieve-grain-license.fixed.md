The quotient sieve's worth test is now judged once **per grain**, and the field is
admitted if either grain pays — with the ladder holding each path to its own verdict
through the mirrored pair `lineSafe` / `docSafe`.

Arming had gated on `pays(.line)` alone. That is the dearer of the two kernels: the
per-line chains run at ~1.27 cyc/B where `survivesDoc` takes four lines at a time at
0.729, and on every row of the production slate the buffer total comes out cheaper. So
the single line-grain gate was a silently _stricter_ policy than the one being
published — the doc comment on `nominal_line`/`nominal_doc` said arming was judged at
the coarser grain, and the bench banner printed "at buffer grain", while the code
withheld the sieve entirely wherever the incumbent's price fell between the two
totals. That band is the document path, which is what `docMatch` actually walks.

The premise the old wording rested on — "a sieve serves both paths from one field, so
it has to pay at the harder grain" — had already been retired by `doc_ok`, the
per-grain license that makes serving one path without the other safe. `lineSafe` is
its missing twin: worth-only, with no correctness half, so it gates the ladder's line
walk and never an assert.

The defect was latent, and the production proof says so rather than being taken on
faith: `zig build sieve` after the change reproduces the slate exactly — the same 6 of
9 patterns declined, the same single published `uuid` loss, 0 soundness violations over
1.60 B byte-positions — because no pattern on the slate falls in the band. Both
residuals behind that `uuid` row now have measured fix shapes rather than conjectures,
built in a separate Rust sheng sibling: a persistence-aware (block, class)
chain that stops pricing a `k`-byte run as `p^k`, and a rival term read from the
engine's own start-state accelerator with an excursion coefficient for what a tripped
skip really costs.
