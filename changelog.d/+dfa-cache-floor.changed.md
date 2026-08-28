- The lazy DFA's cache floor is 1 MiB now, up from 256 KiB.

  A counted repetition like `[^:]{0,255}` mints ~256 live NFA states whose
  powerset states cost ~1 KiB each, so the old floor could not hold the working
  set: the cache filled, reset, refilled, and the walk got demoted to the Pike
  arm — 3× slower on exactly the shape that needed the DFA most. The budget is
  consumed lazily (states are built on demand), so a pattern that never
  explodes never pays a byte of it; the 4 MiB program-proportional cap is
  unchanged, and rust-regex's hybrid default sits higher still.
