- `\b` no longer drops the whole program onto the Pike VM, which it did for every binding.

  The buffer model armed its DFA only for `assert_free` programs. That is a
  stronger question than the site is asking. `assert_free` means "match validity
  depends on nothing but the consumed bytes", and the reason the buffer model
  wants care is narrower than that: `^`/`$` under `(?m)` hold at every `\n`, so
  their meaning is content-dependent in a way no eager BOL/EOL table can encode.

  A word-context assertion is not that. `\b` reads the two bytes beside a
  position. It is haystack-local, it means the same thing in both models, and
  the powerset has always determinized it - `powerset.build` refines byte classes
  by word-ness and `matchWord` resolves the axis at the DFA floor. The per-line
  model proved this daily by arming a DFA for exactly these programs while the
  buffer model refused one for the same bytes.

  Which mattered more than it looks, because the buffer model is the only model a
  language binding ever compiles under; `compile/captures.zig` forces it. So this
  was not an edge case, it was most real patterns: every `\b` any host ever
  compiled ran on the Pike VM. One catalogue pattern - seven verbs, a hinge, a
  trailing alternation, one `\b` - took 314 us over 4 KB where the same pattern
  with the `\b` deleted took 12 us on the DFA. Same automaton, 26x the price, for
  an assertion the determinizer had never had trouble with.

  So the gate is now `buf_exact` rather than `assert_free`: everything positional
  in the program has to resolve against the haystack's own bytes and ends. Word
  assertions are in, `^`/`$` under `(?m)` are still out, and `\A`/`\z` stay out
  for now because `bufMatch` carries a phantom-position rule for the trailing
  `\n` that is the VM's and not the automaton's - admitting them needs that rule
  lifted into the DFA first, which is its own change with its own proof.
  Zero-width-reaching programs are excluded for the same reason, since that rule
  is exactly what would make the table and the VM disagree about `\B` over
  `"abc\n"`.

  The tier of per-line rungs stays on `assert_free`, deliberately. A rung answers
  the slice question, which needs "no match crosses a `\n`" - substring closure,
  which only assertion-freeness gives. A `\b` program is exactly determinizable
  over the buffer and still not sliceable; those are two different claims and
  they were sharing one flag.

  Held by a new whole-buffer differential over the widened class: the same
  generator as the assertion-free case with a word assertion welded on, every
  verdict checked against the whole-buffer Pike reference, and a floor asserting
  the run actually admitted programs the old gate would have refused.
