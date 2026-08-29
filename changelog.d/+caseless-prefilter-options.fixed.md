- A caseless search could silently lose matches, because the two caseless
  prefilters re-derived their needle under a hand-listed subset of the run's
  options rather than the run's own. `gist -i '(?x) alpha \s+ \d+'` found
  nothing while the same pattern through the library found every match.

  Both `caselessGate` and `caselessFilter` recompile the pattern with folding OFF
  to recover the literal underneath, and both spelled the recompile as
  `.{ .unicode = …, .multiline = … }` — a list that was complete when it was
  written and silently stopped being complete the moment a third option could
  change what a byte *is*. Verbose was that option: the recompile parsed
  `(?x) alpha` non-verbosely, mined the leading space as a required byte, and
  handed the search a gate demanding a character the pattern deliberately does
  not match. A prefilter that is not an over-approximation does not run slow, it
  runs wrong.

  Fixed at the shape rather than the symptom: one `unfoldedOptions` derives the
  run's real options and turns off exactly the one thing being unfolded. A future
  option is carried by construction, so the class of bug cannot come back by
  someone adding a flag and not finding these two call sites.
