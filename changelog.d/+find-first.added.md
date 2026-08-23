- `irgx_find_first` / `irgx_find_first_in`: the leftmost span, without walking the rest of the text.

  Every binding's `search()` was `find_all` with a cap of 1, and that is a
  different question than it looks. `find_all`'s `*written` is the count the
  whole text HAS, on purpose - a saturating count makes "did I get everything?"
  undecidable, and reporting the true total is what lets a short window size its
  own retry in one search. That contract is worth keeping. But it is also why
  `cap = 1` cannot mean "stop": the cap bounds what is WRITTEN, never what is
  walked. So a host that wanted one span paid for every match in the text plus
  the tally, and `re.search(s)` - the most common verb any regex library has -
  spent the entire scan on matches the caller had no way to read.

  The fix is not to weaken the total. A host that wants the count still gets it
  exactly. It is to let a host say it does not want one.

  Nothing here is a second search strategy. Same walk, same modes, same iteration
  rules; the span is the one `find_all` would have put in `out[0]`. `earliest`
  needs no case of its own, because it changes which match is first and this
  reports whichever the walk yields first under the mode it was asked in - and an
  undecidable pattern declines here exactly as it does for the span verbs, rather
  than handing back a leftmost span wearing an earliest label.

  `irgx_find_first_in` is the same verb over `[from, to]`, with `find_all_in`'s
  window contract: the match must fit inside the region while every assertion
  still reads the whole text.

  All three bindings now route their one-span verb through it, so the win is a
  host user's without asking for it: Python's `search()`, Go's `FindStringIndex`
  / `FindIndex` (and any `FindAll...(n=1)`, windowed or not), and Rust's `find`
  / `find_at`. Go's route replaces a 4096-span buffer allocated to hold one
  answer. Rust binds only the windowed spelling, as it already did for
  `find_all`, since `find_at` needs the live bound and `find` passes the inert
  one; that decision is now on the record in `contract/bindings.toml` rather
  than in a comment only a reader already inside `sys.rs` would find.

  Each host's adoption is held to its own oracle rather than to this verb's
  word: over every case in the shared cross-binding corpus - nullable rows
  included, since the thinning conventions that make a host's sequence its own
  are all rules about the match BEFORE this one, and a first match has none -
  the one-span verb must report exactly the span that host's full walk puts at
  index zero.

  Held by a differential over the shapes where a second walk would drift -
  nullable patterns, anchors under the buffer model, alternations, and texts with
  no match at all - each asserting the verb returns exactly `find_all`'s first
  span, and by rows pinning that a window bounds which match is reported without
  moving the edges the assertions read.
