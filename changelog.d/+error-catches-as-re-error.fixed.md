- `irgx.error` derives from `re.error`, so an existing `except re.error` keeps
  catching. The class was already named `error` rather than `IrregexError` to
  promise that code written against `re` ports by changing the import alone, and
  the name alone could not keep half of that promise: a library that already
  wraps its compile in `except re.error` is the exact caller most likely to
  change one import, and a sibling class would have had that handler silently
  stop catching — no error at the import, no error at the call, just an
  exception escaping a handler written for it. Subclassing costs nothing, since
  `re.error` carries the same three attributes this class already carried.

  The parent is initialised without the position deliberately. Given one,
  `re.error` appends "at position N" to the message it hands `Exception`, so
  `str(err)` would stop being `msg`. The position is reported through `pos`, and
  now also through the `lineno` / `colno` that `re.error` promises, derived the
  way it derives them: 1-based, counted through the newline the offset lives in,
  and both `None` when there is nothing to point at — a pattern refused for its
  grammar rather than its spelling is not wrong anywhere in particular.
