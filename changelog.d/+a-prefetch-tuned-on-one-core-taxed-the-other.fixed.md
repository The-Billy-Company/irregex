The software prefetch in the SIMD literal scan is now a named per-target policy
in `simd.streamAhead`, and it is declined on x86-64.

The block loop hinted eight vectors ahead on every core, which was measured on
an M4 and never re-measured anywhere else. On Raptor Lake it costs **1.29x**
(0.0450 against 0.0349 tick/B, `Qzxjvw` over 8 MiB, min-of-24 round-robin after
warmup, pinned to a P-core). The L2 streamer recognizes a sequential stride
immediately and the loop is issue-bound, so the hint buys a ramp that already
happened and pays for it in slots.

That single coefficient is why the exact literal kernel was losing to a bare
`memchr` on x86 - `settle_literal_one` at 0.092 against `skip_scan` at 0.069
cyc/B - and it cost the auction a 1.32x regret on `Qzxjvw`, which is how it
surfaced. A kernel written to beat `memchr`, shipped losing to it on the most
common target in the world, because a constant tuned on a laptop rode along.

It was measured over many small documents as well as one large one, since the
obvious defense of a prefetch is that it only pays on a cold stream the
hardware has not learned yet. It does not pay there either.

The hint stays on aarch64, where it was measured, and the roofline bench is
what re-prices it. Both the kernel and `bench/bounds/roofline` now call the
same function instead of each spelling the policy out, so a benchmark cannot
measure a loop the engine does not run.
