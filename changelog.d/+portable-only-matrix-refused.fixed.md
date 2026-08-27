- `build_wheels.py` refuses a matrix with no accelerated wheel in it. 2.0.0 and
  2.1.x went out portable-only, so every `pip install` silently got the ctypes
  transport - correct answers, correct exit codes, nothing downstream broken, and
  ~1.7us of argument marshaling per call with no literal prefilter. On the first
  consumer measured against stdlib `re` on its own per-row loop that turned a
  1.18x win into an 11x loss, which is not a packaging detail.

  The script already built both halves; it just exited 0 when it built only one.
  Two ways in, both quiet: a host outside `MATRIX` never reaches the
  `target is here` branch, so no accelerated build is attempted at all, and a
  host inside it can fail that one build while its portable twin succeeds - which
  lands in `failures` as one target among many rather than as the thing that
  gutted the release. `accel_shortfall` now names which of the two happened,
  because the fix differs: publish from a listed host, or repair the compiler on
  this one. A narrow `--only` is not a release and is left alone.
