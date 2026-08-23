- The Python binding gained a native transport, so a short string is no longer mostly FFI.

  `irgx` was a pure ctypes binding, and ctypes charges the same toll whatever it
  is wrapping. Measured against the engine's own floor, `irgx_is_match_in` costs
  12.7 ns to run and 327 ns to *call*; `irgx_find_all_in` costs 66 ns to run and
  585 ns to call. That is a linear-time engine spending eight times longer being
  invoked than working, and no amount of effort on the Zig side can touch it -
  which meant the guarantee this package exists to sell was being paid for out of
  the wrong pocket on exactly the inputs most programs have.

  So the twelve verbs this binding crosses the boundary with *per text* now have
  a second transport: `irgx._accel`, a stable-ABI C extension that takes the
  caller's own `str` and hands back finished Python objects. The other ninety-odd
  symbols stay on ctypes, and the line between them is not a guess - a verb is
  here if it is asked once per text (a search, a scan, a classification) and not
  if it is asked once per program (open a handle, describe it, compile a slate,
  free it). Adding `lines_count` would be boilerplate around a verb whose cost is
  already O(text).

  Interleaved against the ctypes path in one process, on the same handles -
  min-of-11, because the two transports are chosen at import and comparing them
  across two runs measures the machine (`scripts/bench_transport.py`):

                              accel     ctypes         re    vs ctypes   vs re
      find_all  1 match        192n      1096n       439n        5.7x     2.3x
      find_all  9 matches      336n      1934n       869n        5.8x     2.6x
      find_all  ~1 KiB        8.5us     23.1us     18.1us        2.7x     2.1x
      find_all  ~64 KiB       931us     1831us     1181us        2.0x     1.3x
      captures  3 groups       182n      1375n       197n        7.5x     1.1x
      is_match  17 bytes       519n       870n       124n        1.7x     0.2x

  The ratios shrink as the text grows, which is the shape you want: the fix is
  to overhead, and overhead is what a short string is made of. `is_match` is the
  one row that stays behind `re`, and that is not the transport - through this
  same transport, `is_match` on `(\w+)@(\w+)` costs 1845 ns where `find_all` with
  a limit of 1, which is strictly more work, costs 73 ns. `Pattern.isMatch`'s
  boolean kernel does not take the literal prefilter the span walk takes, so a
  pattern with a strong literal scans the whole buffer to answer a question the
  walk answers by skipping to the candidate. It is fast where there is no literal
  to miss (54-78 ns, beating the walk) and 5-25x slow where there is. That is an
  engine bug with its own fix, filed separately; it is visible here only because
  removing the FFI floor is what made it visible.

  Three things carry most of it. A `str` is handed to the engine through
  CPython's own cached UTF-8 rather than re-encoded, and for the ASCII case that
  cache *is* the object's storage - so a text searched twice is copied zero
  times, where `.encode()` mints a fresh `bytes` every call. Span buffers come
  off the C stack for the 128 rows that cover almost every answer, instead of
  ctypes minting an array object per call. And the results are built as tuples
  directly rather than through `Py_BuildValue`, whose format parsing costs more
  than the integers it makes.

  **Nothing requires it.** No accelerator - an interpreter it was not built for,
  a source checkout, `IRGX_NO_ACCEL=1` - and every verb falls back to the ctypes
  implementation beside it, which is the one this package already shipped. The
  routing is per verb, so an engine too old to export one symbol keeps ctypes for
  that verb alone. `irgx._engine.native()` says which answered.

  Both transports are held to one answer rather than trusted to have one:
  `tests/test_transport.py` asks the same handle the same question through both
  in a single process and requires equal objects, over the four cases where the
  two implementations genuinely do different work - buffer growth past the first
  window, a non-participating group, an empty answer, and a refusal - and CI runs
  the whole suite a second time under `IRGX_NO_ACCEL=1`.

  On PyPI this arrives as a second wheel per platform, not a replacement. The
  portable `py3-none-<platform>` wheel is unchanged and still cross-built for the
  whole matrix from one machine; the new `cp312-abi3-<platform>` wheel carries
  the accelerator and is built only where the host is the target, since an
  extension needs its target's own Python headers. pip prefers the accelerated
  one wherever it fits and takes the portable one everywhere else - a
  free-threaded build, PyPy, an architecture no release box runs - so this is an
  optimization for most installs and a narrowing for none. One binary serves 3.12
  and every version after it: the wheel built here against 3.12 headers imports
  and answers on 3.14.
