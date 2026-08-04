# zig-assay-bypass Ratchet

`assay` owns the one diagnostic channel. It exists because scattered
`std.debug.print` calls made the never-write contract — an embedding host must
never see us write to stdout/stderr — an audit instead of a property of one
routing point.

## The Rule

One finding per `std.debug.print(` call in production Zig. Each one is three live
defects at once, depending on what is running the process:

- **Under a `dark` sink**, the call escapes to the host's real stderr,
  breaking the never-write contract.
- **Under a `buffer` sink**, the call lands on the daemon's stderr instead of
  the connected client's.
- **Under a `--json` run**, the call emits English prose into a stream the
  consumer is parsing as NDJSON.

## Structural Exclusions

- **`src/assay/assay.zig` and `src/assay/channel.zig` are the sink.** The stderr
  arm of the channel is literally `.stderr => std.debug.print(fmt, args)`.
  Counting them would make the ratchet circular — it would either always fail or
  be silenced by lifting its own baseline. The exemption is pinned by path and
  the unit tests assert both files exist, so a rename fails loudly instead of
  quietly re-arming the circularity.
- **`*_test.zig` / `*_fuzz.zig` files and inline `test "…" { … }` blocks.** A test
  writing to stderr is fine: there is no embedding host to protect and no
  `--json` consumer to corrupt.

Matching runs on a comment/string-blanked copy of each file
(`quality/ratchets/_lib/zigtext.py`), so `std.debug.print` *named in a doc
comment* — as `src/surface/cli/outcome.zig` does, precisely to record that it
routes through `assay.diag` instead — is prose and does not count.

Scope: `src/**/*.zig`, minus the exclusions above, `*.gen.zig`, and
generated-header files.

## What Is in the Baseline

Two bypasses in `src/corpus/index/frame/frame.zig` — the unreadable-artifact and
corrupt-artifact notes. Both are burn-down targets, not blessed exceptions. Three
further rows came over with the ratchet and were dropped on arrival because the
files they pinned left in the ecosystem split (the daemon client and `grade.zig`
to `gist`, `kinship.zig` to `relate`).

## Surface

```bash
python3 quality/ratchets/run.py assay-bypass             # diff vs the baseline (CI gate)
python3 quality/ratchets/run.py assay-bypass --refresh   # rewrite after routing bypasses through assay.diag
```

Baseline format and diff/CLI scaffolding are shared via
`quality/ratchets/_lib/ratchet.py`.
