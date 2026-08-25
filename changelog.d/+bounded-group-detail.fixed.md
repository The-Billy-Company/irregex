- Asking a bounded match for its groups no longer refuses. `search(text, pos,
  endpos)` ran against a cut of the subject, but group spans are filled in
  lazily on the first request, and that second pass was handed the whole
  subject. So a greedy group ran past `endpos` and reported a wider whole-match
  than the search had found, the two arms disagreed, and the caller met an
  `irgx.error` about internal disagreement for a match that was perfectly fine.

  The view now records the text it was actually searched over, and the capture
  pass reads that. A truncation is a suffix cut, so nothing to the left of it
  moves and no offset needed adjusting; the bug was only ever that the second
  pass could not see the cut the first one made.
