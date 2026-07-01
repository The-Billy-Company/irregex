**A `./root` positional no longer breaks anchored ignore matching**
(`bench/rgignore.zig`). When the search root was given as `./some_dir`, gist
prefixed every walked path with `./`, so an anchored rule (or a whitelist like
`!/some_dir/build/`) failed to match and the path was mis-ignored.

- **`match` normalizes a leading `./`** (new `stripDot`) on both the candidate
  path and the rule's `base` before comparing, so `./some_dir/build/foo` is
  matched identically to `some_dir/build/foo` — the anchored/negated rules now
  fire regardless of how the root was spelled. Output still keeps the `./` prefix
  ripgrep prints.

Proven against real ripgrep as the oracle: `r829_2731` (`-l string ./some_dir`
with a `build/` ignore + `!/some_dir/build/` whitelist) and `f1757`'s `./rust1`
invocation now diff to **0 bytes** vs `rg`.
