- `findall` refuses a capture disagreement as `error`, not as a bare
  `RuntimeError`. The guard itself is right and stays: when `find_all` reports a
  match the capture pass will not reproduce, there are no groups to hand back and
  inventing them would be worse than refusing. What was wrong was the class. Every
  other refusal in the package is `error` — which, since it derives from
  `re.error`, is what a caller who swapped `re` for this still has a handler for —
  and this was the one that walked past both `except re.error` and
  `except irgx.error`. In the most-called verb.

  It escaped because the prose lived in the seam rather than at the call site.
  `irgx._engine` documents that the two transports speak statuses and carry no
  error text, precisely so the C module does not have to be handed a class to
  raise; `group_texts` was the verb that broke its own rule, twice, in both
  transports. So the disagreement now answers the offending span — a status is an
  `int`, an answer is a `list`, a span is neither — and `Pattern.findall`
  translates it beside the `check` that translates every other status, where the
  pattern is in scope. The message names it now, which matters to anyone running a
  table of patterns and needing to know which one the engine contradicted itself
  on.
