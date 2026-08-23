- A caseless pattern now gets a literal prefilter. It never had one.

  `-i` folding runs before every downstream analysis, and it has to: the
  prefilter and the match engines must agree on what a construct means, so the
  fold happens once at parse time and everything reads the same classes
  afterward. The cost of that ordering was invisible. By the time the literal
  pass walks the AST, `ignore` is six two-element classes and there is no
  literal left to find; `required` comes out empty, the literal-set engine
  declines, and every acceleration that hangs off a literal fact quietly turns
  itself off. A caseless search ran the automaton over every byte of every
  haystack with no prefilter of any kind, on exactly the patterns - case-blind
  scans of untrusted text - where a prefilter pays most.

  Two more paths were dark even case-sensitively. The literal set that
  `lineMatch` and `docMatch` consult carries an authority: `.exact` decides a
  line outright, which is only sound *per line*. So `bufMatch` (`-U`, where the
  buffer is one haystack and a match may cross `\n`) and `matchWindow` (`-o`
  leftmost-first spans) had no license to read it, and never rejected on a
  literal at all - they walked, byte by byte, past a required literal the
  compiler had already proven absent.

  So the compiled pattern now carries one presence gate, and the two walking
  paths reject on it. Under `-i` it is mined from the raw unfolded twin: the same
  source parsed a second time with the fold off, whose required literal is the
  one the fold was about to erase. Only the parse and the literal pass run on the
  twin - the literal is a property of the AST, so lowering it would mean building
  an entire second engine to read one field off the front. One extra parse per
  caseless *compile*, to spare a scan per haystack *byte*.

  The gate is a necessary condition and nothing more. A miss rejects; a hit
  proves nothing and falls through, because the literal can sit anywhere inside a
  match and its position is not a start. No authority is claimed, so the gate can
  prune work and cannot decide an answer.

  Soundness is the fold-closed window, which is why the whole literal is not the
  gate. Under Unicode fold `k` also matches KELVIN SIGN (U+212A) and `s` matches
  LONG S (U+017F), and a non-ASCII byte's orbit is multi-byte and positional -
  gate on those and you go looking for a spelling a real match need not contain.
  The rule keeps the longest run of bytes whose fold orbit stays inside its two
  ASCII spellings, so `sun` gates on `un` and still finds `ſun`, `mass` gates on
  `ma` and still finds `maſſ`, and `café` declines rather than guess. It moved
  down beside the caseless kernel it guards, which had been naming it across a
  tier boundary for exactly this reason.

  Measured on a 1.09 MB caseless prompt-injection corpus, this commit against its
  own parent, the two dylibs built from the same source but for this change and
  run interleaved against the same harness: 11.4 ms to 3.95 ms, **2.9x**, each arm
  steady to a hundredth of a millisecond over three rounds. Disabling only the
  consult - the gate still derived, one line - lands back on the parent's number,
  so the win is the rejection and not a side effect of the extra parse.

  That does not yet make it the fastest engine on this workload: Google RE2 runs
  it in 0.71 ms and Python's `re` in 3.3 ms, so caseless `is_match` is still
  losing here and closing it takes the buffer-model span fix landing beside this
  one. With both present the same corpus answers in 0.20 ms - 3.4x RE2, 16x `re`,
  57x this commit's parent - and gate-off/gate-on over *that* tree isolates 1.86x
  to the gate. Two independent holes on one path, each of which hides most of the
  other; neither number is the whole repair.

  Answers are unchanged and that is the load-bearing claim, not the ratio. The
  engine suite passes, and 96,000 randomized differential checks against `re` -
  patterns carrying literals, haystacks spelling them through the fold-escaping
  orbits, with and without `-i`, with and without dotall - agree exactly. They
  also agree with the gate *off*, which is the property a prefilter owes you: it
  buys time and is not load-bearing for a single answer. Deleting the
  fold-closure rule breaks that differential inside a few hundred cases, every
  failure a false negative on precisely the orbits the rule exists for - so the
  harness can see the bug the rule prevents.
