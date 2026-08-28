- `Match.lastindex` and `Match.lastgroup` exist now, on both the pure-Python
  match and the accelerated C one.

  They exist above all for the dispatch idiom — an alternation of named groups
  where exactly one participates and the name says which branch fired
  (`(?P<import>…)|(?P<call>…)` and read `m.lastgroup`). The engine keeps spans,
  not an execution-order mark, so `lastindex` derives from them: the matched
  group whose span ends last, ties to the outermost. That reproduces every case
  `re` documents — `(a)b`, `((a)(b))`, `((ab))` give 1 on `'ab'`, `(a)(b)`
  gives 2 — with one honest corner: a capture inside a lookaround that outruns
  every later group is where `re`'s mark ordering could answer differently.
