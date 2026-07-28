---
doc_radar:
  sentinels:
    - description: "the two jaws, the tri-state verdict, and the eligibility gate that keeps multiline on the VM"
      file: pkg/kernels/irregex/src/kernel/regex/linear/caliper/caliper.zig
      contains: ["pub const Verdict", "pub fn eligible", "pub fn measure", "!multiline"]
    - description: "priority-ordered determinization: an ordered state list, dominance, and quitting as an answer"
      file: pkg/kernels/irregex/src/kernel/regex/linear/caliper/automaton.zig
      contains: ["pub const Machine", "pub const Cache", "dominate", "quit"]
    - description: "the reversal reuses the forward lowering rather than re-parsing"
      file: pkg/kernels/irregex/src/kernel/regex/linear/caliper/reverse.zig
      contains: ["pub fn build", "pub fn matchIndex"]
    - description: "one transcription of the zero-width assertions serves both the boolean DFA and both jaws"
      file: pkg/kernels/irregex/src/kernel/regex/linear/dfa/subset.zig
      contains: ["pub const Gap", "pub fn passes"]
---

# linear/caliper — where a match lies

**The determinized answer to _where_, after `dfa/` determinized _whether_.**
`-o` and everything built on it — `--count-matches`, `--column`, `--vimgrep`,
`--json`, `-w`, colored highlighting — need a match's byte extent, not a yes/no.
That question had exactly one general answer in the tree: the Pike VM's
span walk, a priority-ordered thread list carrying a start offset per state. It
costs roughly forty times the boolean DFA per byte, because every byte re-closes
every live thread. This package pays a table lookup per byte instead.

A caliper measures an extent by closing two jaws on it, which is the shape of
the construction (RE2 / rust-`regex`):

1. the **forward** jaw runs the leftmost-first automaton from the search origin
   and records the last position at which a match completed;
2. the **backward** jaw runs the reversed program from that end, anchored, and
   records the furthest left it can still be inside a match — the leftmost start
   reaching that end.

Two table walks over the match region. No thread list, no per-state offset map.

## Why a bitset was not enough

`dfa/subset.zig` interns a DFA state as a _set_ of NFA states, because a boolean
answer only asks whether anything matches. A span asks more: `a|ab` must report
`a`, `a+` must report the whole run. Which surviving thread **outranks** which is
precisely what a bitset throws away.

So a state here is an **ordered list** in priority order, and the closure is a
strict priority DFS — `split{a,b}` exhausts `a` before `b`, and dedup happens on
pop rather than on push, so a state reachable by two threads settles at the rank
of the better one. On top of that sits the rule that makes leftmost-first fall
out: reaching `match` **abandons the rest of the worklist**, since every thread
still on it is worse than a match already in hand.

The unanchored re-seed is the other half of that rule, and it is a parameter
rather than a property of the machine: the forward loop seeds a fresh start only
while no match has been committed. Once one has, no later start can displace it
— which is what "leftmost" means. The backward jaw never seeds; it is anchored
to the end the forward jaw found.

## Files

| File               | Role                                                                                                                                                                               |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `caliper.zig`      | The handle and the two-pass search: eligibility, the `Caliper` (reversed program + both machine configurations) built once at compile time, the per-thread `Jaws`, and `measure`.  |
| `automaton.zig`    | The lazy priority-ordered determinizer both jaws run: ordered-list states, the dominance-aware closure, interning, the transition memo, and `quit`. Direction lives in the caller. |
| `reverse.zig`      | The forward Thompson program read right to left — built from the lowered program, so no second parse can disagree about what the pattern means.                                    |
| `caliper_test.zig` | Leftmost-first unit cases plus a differential sweep against the Pike span oracle.                                                                                                  |

## What it does not answer

Eligibility is decided once, at compile time, and the caliper is simply absent
when it does not apply — there is no runtime branch to mispredict:

- **Multiline (`-U`)** stays on the Pike whole-buffer span walk.
- **A cheaper reduction already wins.** A pure-literal alternation resolves by
  SIMD substring scan and a span-exact class run by the SIMD window kernel, both
  strictly cheaper than any automaton. `pike/span.zig` tries those first and
  never builds a caliper behind them.

**Quitting is a first-class answer**, as it is for the on-demand boolean DFA. A
pattern whose determinization outgrows the budget sets `quit`, `measure` returns
`decline`, and the Pike span answers that line. Declining costs throughput,
never correctness — which is what lets the VM remain the oracle it is fuzzed
against rather than dead weight.

## Assertions are not reversed

`^ $ \b \B \< \>` are _position predicates_: `^` asserts that a gap is a line
start, `\b` that the bytes straddling a gap differ in word-ness. Neither says
anything about which direction a scan travels, so a reversed edge carries its
assertion verbatim and both jaws resolve it against the same real coordinates.
Only the order in which a path meets its assertions flips, and a path is a set
of predicates over positions, not a sequence.

That resolution has **one** transcription in the determinized tier —
`subset.passes`, shared with the boolean DFA. Two traversal policies, one
predicate; a second copy is the one place where an engine could silently
disagree with itself about what a pattern means.
