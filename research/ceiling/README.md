---
doc_radar:
  sentinels:
    - description: "the closed-roads record keeps both citations that shut the cascade route"
      file: research/ceiling/CLOSED.md
      contains: ["Chandra", "Maler"]
    - description: "the eager driver's two bounds are what the ceiling argument is about"
      file: src/kernel/regex/linear/dfa/powerset.zig
      contains: ["pub const max_states: u32 = 4096;", "pub const max_visits: u64 = 750_000;"]
---

# `ceiling/` — how fast a scan can go, and which roads are shut

The other three dossiers each defend something we built. This one defends a
**number and a map**: the speed limit our scanning engines actually run into,
why it is the limit, and which routes past it have been tried and closed. It
exists so that the same three dead ends are not rediscovered annually.

Unlike `crest/`, `gist/`, and `relate/`, no road here defends a shipped
**novel technique** — the shipped accelerator tier (compose, parabix, sieve)
applies known ideas to escape the bound this document measures. Treat each
road below as the investigation record that led to those rungs, not as a
description of the engine in its current form.

## The limit, measured

One probe, 64 MiB haystack, every pattern chosen to miss so that `docMatch`
must retire every byte and an early return cannot flatter the number. Apple M4
Max P-core.

**Throughput is the measurement; bytes/cycle is a derived figure, so read the
first column and treat the second as a band.** A later lane put a
dependent-add chain on this box and measured its actual clock at **3.27–3.92
GHz under contention**, not the 4.512 GHz nominal these numbers were first
normalized against. Every ratio below is unaffected, because every row was
measured on the same machine — but any single absolute bytes/cycle figure was
understated by 15–38%, and the original table has been re-derived here rather
than left standing.

| condition                              | GB/s (measured) | bytes/cycle (3.27–3.92 GHz) |
| -------------------------------------- | --------------- | --------------------------- |
| start acceleration armed (memchr skip) | 40.0–40.6       | 10.2–12.4                   | *   |
| no skip available, 9-state DFA         | 1.250           | 0.319–0.382                 |
| no skip available, 73-state DFA        | 1.245           | 0.318–0.381                 |
| no skip, on-demand driver              | 0.623           | 0.159–0.191                 |

\* **The armed row is the top of a 30× range, not a value.** A later lane
measured the same code path at **7.667 B/cycle on `{z}` and 0.302 on `{e}`** —
because the arming predicate counts start bytes and never asks how often they
occur. An armed skip on two common letters measures 0.256, _slower than arming
nothing_. Read this row as the ceiling of the skip path on a rare needle; the
floor is down among the no-skip rows, and which one you get is currently decided
by a byte count. See `CLOSED.md`.

**The two no-skip rows being equal across an eight-fold difference in
automaton size is the whole finding**, and it is a ratio, so the clock
correction leaves it untouched. 1.25 GB/s is **2.6–3.1 cycles/byte**, which is
one L1 load-to-use latency — and lands _closer_ to the hardware's actual L1
figure than the original 3.61 did, so the correction strengthens the argument
it was supporting. The loop
`state = trans[state + class[byte]]` cannot issue the next load until
the previous one lands, so the cost is the serial dependency chain and not the
table. Shrinking the automaton therefore cannot help, and neither can a better
table layout. Only a change of _bound type_ — from latency-bound to
throughput-bound — moves this number.

**That last clause has since been tested directly, and it held.** The engine
later grew a byte-indexed mirror of the transition tables (`Dfa.Wide`), which
folds the class column into the row and deletes one load per byte — precisely
the "better table layout" this paragraph predicts cannot help. On the serial
chain it does not: the `bench/bounds/port` probes measure 4.59 ns/step classed
against 4.62 mirrored, a wash, because `class[byte]` depends on the document byte
rather than on `state` and so was never on the critical path. The same mirror is
worth ~1.28× to the shipped document walk — which bursts four lines in lockstep,
i.e. is exactly the change of bound type this sentence names as the only thing
that moves the number.

For calibration, a reference table DFA measures 0.15 bytes/cycle on Skylake
(Langdale), so the engine is already roughly 2.1–2.5× better than the naive
baseline. We are at the wall rather than behind it.

### The bound type did change, and here is what it bought

That last sentence was a prediction when it was written. Two rungs have since
been built to test it, and both escape the dependency chain — one by making the
step a register shuffle instead of a load, the other by not stepping at all.

| construction                | B/cycle   | how it escapes the chain                                              |
| --------------------------- | --------- | --------------------------------------------------------------------- |
| transformation composition  | 1.94      | `(f∘g)[i] = f[g[i]]` is one `vqtbl`; a reduction, so it re-associates |
| transposed class bitstreams | 0.73–1.29 | no per-byte state at all; 128 bytes advance as 8 planes               |
| table DFA (the wall above)  | 0.32–0.38 | —                                                                     |

So the escape is real and worth 2–6×, and the two rungs hit **different**
ceilings once out: composition stops at the `TBL4` instruction when |Q| > 31,
while the bitstream path is currently held at roughly a third of its own limit
by a class-circuit _interpreter_ (transposition alone still runs at 3.12) and
wants an emitter. Neither is anywhere near L1 latency any more, which is the
point — **the wall this document measures is real, and it is specific to the
one loop, not to matching.**

## The two regimes, and why the ladder is shaped the way it is

The 32× gap between the accelerated and unaccelerated rows is the single most
important fact about our scan performance, and it explains the dispatch ladder
better than any argument about automaton quality. When a literal is long
enough to arm a skip, the engine is in memchr territory and nothing else
matters. When the pattern is literal-free — a class repetition like
`[0-9a-f]{12}`, or `\p{Greek}{3}` — no skip can arm, the trigram index reports
every document as a candidate, and the scan pays full freight.

That literal-free cell is attacked at two different stages, and they multiply
rather than compete:

- **document stage** — `crest/`, shipped: prune whole files with integer
  compares and no byte scan (96.4% pruned on `[0-9a-f]{12}`).
- **scan stage** — also shipped now, as the ladder's accelerator tier: three
  optional rungs that each escape the dependent load rather than shorten it,
  admitted per pattern and absent when they cannot help.

That second bullet read "open" for most of this document's life, and closing it
produced one result worth keeping above all the throughput numbers: **the
rungs' arming rate matters more than their peak.** Composition arms on most
realistic field patterns and is the tier's whole measured value; the bitstream
rung's admission window turned out to be a strict subset of composition's, and
the sieve's own best pattern never reaches it because the class-run kernel takes
that shape first. A rung that is 12× faster on patterns nobody writes is worth
less than one that is 6× faster on patterns everybody writes, and neither the
research phase nor the build phase could see that — only integration could.

## The dossier

| File                           | Question                                                                                                                               |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| [`PRIOR_ART.md`](PRIOR_ART.md) | What the field has achieved, at what throughput, with what feature set — and where the plane is genuinely empty.                       |
| [`CLOSED.md`](CLOSED.md)       | Routes past the limit that were tried and shut, each with the citation that shuts it and the residue still open.                       |
| [`LOWERING.md`](LOWERING.md)   | The three places the compiler cost more than the algorithm did — each a spelling of identical semantics that LLVM lowers 1.6–2× apart. |

Production context for the numbers above:
[`../../src/kernel/regex/linear/ladder/`](../../src/kernel/regex/linear/ladder/)
(the tier that admits a rung and the order it consults them in),
[`../../src/kernel/regex/linear/shuffle/`](../../src/kernel/regex/linear/shuffle/),
[`../../src/kernel/regex/linear/parabix/`](../../src/kernel/regex/linear/parabix/),
and [`../../src/kernel/regex/linear/sieve/`](../../src/kernel/regex/linear/sieve/)
(the three escapes, each with its own measured limit),
[`../../src/kernel/regex/linear/dfa/`](../../src/kernel/regex/linear/dfa/)
(the two determinization drivers and their bounds),
[`../../src/kernel/math/crest.zig`](../../src/kernel/math/crest.zig)
(the document-stage sieve), and
`gist/bench/certificate/` (the certificate whose
`regex-classcount` row is the 100%-candidate hole named above).
